<#
  acme-lib.ps1 - shared plumbing for the renewal side of the tracker.

  Dot-sourced by serve.ps1, renew.ps1 and setup.ps1; it is not meant to be run
  on its own. Everything resolves from $PSScriptRoot so the folder stays
  copy-anywhere, with one documented exception: saved credentials are encrypted
  with DPAPI and are therefore bound to this Windows user on this machine.

  Contents:
    paths and constants        - where everything lives
    settings                   - settings.json read/write
    secrets                    - DPAPI-encrypted credential store
    Posh-ACME                  - vendored install + import
    DNS Made Easy              - signed API client, zone listing
    zone cache                 - zones.json
    certificate grouping       - hosts -> zones -> SAN lists
    PEM output                 - the combined fullchain+key file
#>

# --------------------------------------------------------------------------- #
# Paths and constants
# --------------------------------------------------------------------------- #

$script:Root         = $PSScriptRoot
$script:SettingsFile = Join-Path $script:Root 'settings.json'
$script:SecretsFile  = Join-Path $script:Root 'secrets.xml'
$script:ZonesFile    = Join-Path $script:Root 'zones.json'
$script:AlertStateFile = Join-Path $script:Root 'alert-state.json'
$script:DomainsFile  = Join-Path $script:Root 'domains.txt'
$script:SecretAuditFile = Join-Path $script:Root 'secrets-audit.log'
$script:AuditFile    = Join-Path $script:Root 'audit.log'
# Rotation, not deletion: see Invoke-LogRetention for why the audit trail is
# exempt from the size cap that governs run logs.
$script:AuditMaxBytes = 5mb
$script:LibDir       = Join-Path $script:Root 'lib'
$script:AcmeState    = Join-Path $script:Root 'acme-state'
$script:CertsDir     = Join-Path $script:Root 'certs'
$script:JobsDir      = Join-Path $script:Root 'jobs'
$script:SweepFile    = Join-Path $script:JobsDir 'renew-due-sweep.json'

$script:SettingsVersion = 2

# The scheduled tasks, in the order a person cares about them: what actually
# renews first, then what only looks, then what only emails. Shared between
# setup.ps1 (which registers them) and serve.ps1 (which reports on them) so the
# two cannot drift apart - a task renamed in one place and not the other would
# read as "not registered" on the page while working perfectly well.
#
# "level" is the distinction that matters when reading the Home page: only ONE
# of these three can change anything about a live certificate.
$script:ScheduledTaskNames = @(
    @{ key = 'renew';  name = 'Cert Camel Renew'
       script = 'renew-due.ps1'
       label = 'Renew and deploy'
       level = 'Issues certificates and pushes them to load balancers'
       detail = "Renews only what the certificate authority says is due, deploys each one to its assigned load balancers, then verifies every node is really serving it." }
    @{ key = 'check';  name = 'SSL Cert Check'
       script = 'check-ssl.ps1'
       label = 'Expiry check'
       level = 'Read-only'
       detail = "Re-reads the expiry date of every tracked host so the page is current. Never issues or deploys anything." }
    @{ key = 'report'; name = 'Cert Camel Monthly Report'
       script = 'monthly-report.ps1'
       label = 'Monthly summary email'
       level = 'Read-only'
       detail = "Sends the summary email on the 1st. Registered as a daily task that does nothing on the other days, because there is no monthly trigger to reach for." }
)

# Certificate authorities are profiles, not a single global setting: a real
# estate often keeps some certificates on a paid CA for policy reasons while
# moving the rest to a free one. Each certificate picks a CA; anything without
# an explicit choice uses the default.
#
# Let's Encrypt ships as the default because it is free and needs no account.
# Any ACME CA works - point directoryUrl elsewhere and supply EAB if it asks.
$script:BuiltInCAs = @(
    @{
        id           = 'letsencrypt'
        label        = "Let's Encrypt"
        directoryUrl = 'https://acme-v02.api.letsencrypt.org/directory'
        stagingUrl   = 'https://acme-staging-v02.api.letsencrypt.org/directory'
        # Staging defaults ON. A first run against production burns real rate
        # limit on a configuration nobody has proven yet.
        useStaging   = $true
        eabKid       = ''
    }
)

# Which DNS plugins the settings UI knows how to render a form for. Posh-ACME
# ships ~100; renew.ps1 passes whatever is here straight through as -PluginArgs,
# so adding another provider is an entry in this table, not new code.
$script:PluginCatalog = @{
    DMEasy = @{
        Label = 'DNS Made Easy'
        Args  = @(
            @{ Name = 'DMEKey';        Label = 'API Key';    Secret = $false; Type = 'text' }
            @{ Name = 'DMESecret';     Label = 'Secret Key'; Secret = $true;  Type = 'text' }
            @{ Name = 'DMEUseSandbox'; Secret = $false; Type = 'bool'
               Label = 'Use the DNS Made Easy sandbox (sandbox.dnsmadeeasy.com)'
               Hint  = 'Free test account with its own API keys. Good for proving credentials and zone discovery work, but sandbox zones are not authoritative on the internet, so a certificate authority cannot validate against them - no real certificate can be issued this way.' }
        )
    }
    NS1 = @{
        Label = 'NS1 (IBM NS1 Connect)'
        Args  = @(
            @{ Name = 'NS1Key'; Label = 'API Key'; Secret = $true; Type = 'text'
               Hint  = 'NS1 portal: Account Settings > API Keys. Needs DNS read and record write on the zones you want to renew.' }
        )
    }
    Cloudflare = @{
        Label = 'Cloudflare'
        Args  = @(
            # A scoped API token, not the old Global API Key: the global key can
            # do anything to the whole account, a token can be limited to DNS
            # edit on specific zones.
            @{ Name = 'CFToken'; Label = 'API Token'; Secret = $true; Type = 'text'
               Hint  = 'Cloudflare dashboard: My Profile > API Tokens > Create Token. Permissions needed are Zone:Zone:Read and Zone:DNS:Edit. Do not use the Global API Key.' }
        )
    }
}

# --------------------------------------------------------------------------- #
# Small shared helpers
# --------------------------------------------------------------------------- #

# Set-Content -Encoding utf8 writes a BOM on PS 5.1, which breaks anything that
# parses the file strictly. Write via .tmp + move so an interrupted write can
# never leave a half-file behind - same approach check-ssl.ps1 uses.
function Write-TextFileAtomic {
    param([string]$Path, [string]$Content)

    $tmp  = "$Path.tmp"
    $utf8 = New-Object Text.UTF8Encoding $false
    [IO.File]::WriteAllText($tmp, $Content, $utf8)
    Move-Item -Path $tmp -Destination $Path -Force
}

function New-TrackerDirectories {
    foreach ($d in @($script:LibDir, $script:AcmeState, $script:CertsDir, $script:JobsDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
}

function Get-CertTargetIds {
    <#
      The per-certificate target assignment, read defensively. PS 5.1's
      ConvertTo-Json unwraps a one-element array to a bare scalar on every
      settings round-trip, so on disk this field has been seen as a real array,
      a lone string, and - after enough cycles - an empty object. Normalise to
      an array of non-empty strings here, once, instead of every caller
      re-discovering a shape the hard way. (The symptom that forced this was a
      deploy skipping its target with "Target 'System.Collections.Hashtable' is
      no longer configured".)
    #>
    param($CertConfig)
    return @(@(Get-CertTargetBindings -CertConfig $CertConfig) | ForEach-Object { $_.id })
}

function Get-CertTargetBindings {
    <#
      The same assignment read as { id; overrides } pairs.

      An entry is either a bare id string - "use everything the group says", the
      only shape that existed before and still the common one - or an object
      carrying per-certificate overrides:

          "targets": [ "office", { "id": "office", "crtList": "/etc/haproxy/wild.txt" } ]

      That exists because a group answers "which nodes, and what credentials",
      while a crt-list answers "where is this certificate referenced". Those are
      different questions, and tying them together meant one group could only
      ever manage one frontend; two frontends on the same pair required defining
      the same nodes twice with duplicate credentials.

      Same defensive parsing as before - PS 5.1's ConvertTo-Json unwraps a
      one-element array to a bare scalar on every settings round-trip, so on
      disk this field has been seen as an array, a lone string, and an empty
      object. Anything that does not yield a usable id is dropped rather than
      being allowed to reach a deployment as a phantom target.
    #>
    param($CertConfig)

    if (-not $CertConfig) { return @() }
    if ($CertConfig -is [hashtable] -and -not $CertConfig.ContainsKey('targets')) { return @() }

    $out = @()
    foreach ($t in @($CertConfig.targets)) {
        if ($null -eq $t) { continue }

        if ($t -is [string]) {
            if ($t) { $out += @{ id = $t; overrides = @{} } }
            continue
        }

        # Object form. Reached as a hashtable via ConvertTo-HashtableDeep, but
        # tolerate PSCustomObject too so a hand-edited or freshly-parsed
        # settings.json behaves the same either way.
        $id = $null
        $ov = @{}
        if ($t -is [hashtable]) {
            if ($t.ContainsKey('id')) { $id = [string]$t.id }
            foreach ($k in $t.Keys) { if ($k -ne 'id') { $ov[$k] = $t[$k] } }
        }
        elseif ($t.PSObject -and $t.PSObject.Properties['id']) {
            $id = [string]$t.id
            foreach ($p in $t.PSObject.Properties) { if ($p.Name -ne 'id') { $ov[$p.Name] = $p.Value } }
        }

        if ($id) { $out += @{ id = $id; overrides = $ov } }
    }
    return $out
}

function Resolve-TargetSetting {
    <#
      One setting, resolved through the precedence that makes overrides useful:
      what this certificate says for this group, then what the group says, then
      the built-in default. Mirrors how a certificate's CA is already resolved,
      so "pinned here, inherited from there" reads the same way throughout.
    #>
    param([hashtable]$Target, $Binding, [string]$Name, $Default = $null)

    if ($Binding -and $Binding.overrides -and $Binding.overrides.ContainsKey($Name)) {
        $v = $Binding.overrides[$Name]
        if ($null -ne $v -and "$v" -ne '') { return $v }
    }
    return (Get-TargetArg -Target $Target -Name $Name -Default $Default)
}

# PowerShell 5.1 has no ConvertFrom-Json -AsHashtable, and PSCustomObject is
# awkward to build up incrementally. This walks a parsed object into hashtables.
function ConvertTo-HashtableDeep {
    param($InputObject)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [hashtable]) { return $InputObject }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return @($InputObject | ForEach-Object { ConvertTo-HashtableDeep $_ })
    }

    # Test the type rather than the property count: an empty JSON object parses
    # to a PSCustomObject with no properties, and returning that unchanged would
    # hand callers something without .ContainsKey().
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) {
            $h[$p.Name] = ConvertTo-HashtableDeep $p.Value
        }
        return $h
    }

    return $InputObject
}

function ConvertFrom-SecureStringPlain {
    param([System.Security.SecureString]$Secure)

    if (-not $Secure) { return $null }
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try   { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

# --------------------------------------------------------------------------- #
# Settings
# --------------------------------------------------------------------------- #

function New-DefaultAlertSettings {
    # Off by default and no SMTP host, so a fresh install sends nothing until
    # someone deliberately fills this in.
    @{
        smtp = @{
            host = ''; port = 587; encryption = 'starttls'; from = ''; to = @()
            authRequired = $false; username = ''
        }
        expiry            = @{ enabled = $false; thresholds = @(30, 14, 7) }
        renewalSuccess    = @{ enabled = $false }
        deploymentFailure = @{ enabled = $false }
        monthlySummary    = @{ enabled = $false }
    }
}

function New-DefaultSettings {
    $cas = @()
    foreach ($c in $script:BuiltInCAs) {
        $copy = @{}
        foreach ($k in $c.Keys) { $copy[$k] = $c[$k] }
        $cas += $copy
    }

    @{
        version     = $script:SettingsVersion
        contact     = ''
        cas         = $cas
        defaultCaId = 'letsencrypt'
        providers   = @()
        # Where issued certificates get pushed. Empty by default: issuing works
        # perfectly well on its own, and a half-configured target is worse than
        # no target at all.
        targets     = @()
        certs       = @{}
        alerts      = New-DefaultAlertSettings
        # Run-log retention. The audit trail is not governed by these - see
        # Invoke-LogRetention for why.
        logs        = @{ retentionDays = 90; maxSizeMb = 200 }
    }
}

function Get-TrackerSettings {
    if (-not (Test-Path $script:SettingsFile)) { return New-DefaultSettings }

    try {
        $raw = Get-Content $script:SettingsFile -Raw -Encoding UTF8
        if (-not $raw.Trim()) { return New-DefaultSettings }
        $s = ConvertTo-HashtableDeep ($raw | ConvertFrom-Json)
    }
    catch {
        throw "settings.json could not be read: $($_.Exception.Message)"
    }

    # v1 stored a single global 'ca'. Promote it to the first CA profile so an
    # existing configuration keeps issuing from the same place after an upgrade.
    if ($s.ContainsKey('ca') -and $s.ca -and -not $s.ContainsKey('cas')) {
        $old = $s.ca
        $s.cas = @(@{
            id           = 'letsencrypt'
            label        = $(if ($old.ContainsKey('label') -and $old.label) { $old.label } else { "Let's Encrypt" })
            directoryUrl = $old.directoryUrl
            stagingUrl   = $old.stagingUrl
            useStaging   = [bool]$old.useStaging
            eabKid       = $(if ($old.ContainsKey('eabKid')) { $old.eabKid } else { '' })
        })
        $s.defaultCaId = 'letsencrypt'
        $s.Remove('ca')

        # The v1 EAB secret was stored unqualified; re-key it to the profile.
        $legacy = Get-TrackerSecret -Key 'ca:eabHmacKey' -AsPlainText
        if ($legacy) {
            Set-TrackerSecret -Key 'ca:letsencrypt:eabHmacKey' -Value $legacy
            Set-TrackerSecret -Key 'ca:eabHmacKey' -Value ''
        }
    }

    # Fill in anything a hand-edited or older file is missing, so a partial file
    # degrades to defaults instead of throwing somewhere further down.
    $def = New-DefaultSettings
    foreach ($k in $def.Keys) {
        if (-not $s.ContainsKey($k) -or $null -eq $s[$k]) { $s[$k] = $def[$k] }
    }
    $s.providers = @($s.providers)
    $s.targets   = @($s.targets)
    $s.cas       = @($s.cas)
    if (-not @($s.cas).Count) { $s.cas = $def.cas }

    # The in-memory shape is now current whether or not it has been written
    # back, so report it as such rather than echoing the version on disk.
    $s.version = $script:SettingsVersion

    return $s
}

# Resolve the CA a certificate should use. An unknown or missing id falls back
# to the default rather than failing - a renamed profile should not strand a
# certificate with no way to be issued.
function Get-CaProfile {
    param([hashtable]$Settings, [string]$CaId)

    $cas = @($Settings.cas)
    if ($CaId) {
        $match = @($cas | Where-Object { $_.id -eq $CaId })
        if ($match.Count) { return $match[0] }
    }
    $match = @($cas | Where-Object { $_.id -eq $Settings.defaultCaId })
    if ($match.Count) { return $match[0] }
    if ($cas.Count) { return $cas[0] }

    throw "No certificate authority is configured."
}

function Save-TrackerSettings {
    param([hashtable]$Settings)

    $Settings.version = $script:SettingsVersion
    Write-TextFileAtomic -Path $script:SettingsFile -Content ($Settings | ConvertTo-Json -Depth 10)
}

# The directory URL actually in force for one CA, honouring its staging toggle.
# Staging is per-CA: Let's Encrypt has a test environment, many CAs do not.
function Get-ActiveDirectoryUrl {
    param([hashtable]$Ca)

    if ($Ca.useStaging -and $Ca.stagingUrl) { return $Ca.stagingUrl }
    return $Ca.directoryUrl
}

# --------------------------------------------------------------------------- #
# Secrets
# --------------------------------------------------------------------------- #
# Export-Clixml encrypts any SecureString it serialises with DPAPI, scoped to
# the current user on the current machine. That is why credentials do not travel
# with the folder: someone else copying this bundle re-enters their own, which
# is the behaviour we want for a tool meant to be shared.

function Get-SecretStore {
    <#
      Returning an empty store on a read failure is how credentials get silently
      destroyed: the caller modifies that empty store and saves it back over a
      perfectly good file. So a genuine read failure throws, and only a genuinely
      absent file yields an empty store.
    #>
    if (-not (Test-Path $script:SecretsFile)) { return @{} }

    try   { $store = Import-Clixml $script:SecretsFile }
    catch {
        # Wrong Windows user or wrong machine: DPAPI refuses to decrypt.
        throw "secrets.xml exists but could not be read ($($_.Exception.Message)). Refusing to continue, because saving now would overwrite it. If this folder came from another PC or user, delete secrets.xml and re-enter the credentials."
    }

    if ($null -eq $store) { return @{} }
    if ($store -is [hashtable]) { return $store }
    throw "secrets.xml is not in the expected format. Delete it and re-enter the credentials in Settings."
}

function Save-SecretStore {
    <#
      Writing an empty store over a file that had entries is almost always a bug
      rather than an intention, so it needs saying out loud. -AllowEmpty is for
      the one caller that really does mean "remove the last credential".
    #>
    param([hashtable]$Store, [switch]$AllowEmpty)

    if ($Store.Keys.Count -eq 0 -and -not $AllowEmpty -and (Test-Path $script:SecretsFile)) {
        $existing = 0
        try { $existing = @((Import-Clixml $script:SecretsFile).Keys).Count } catch { $existing = 0 }
        if ($existing -gt 0) {
            throw "Refusing to replace $existing stored credential(s) with an empty store. This is a bug - report it rather than working around it."
        }
    }

    # Via a temp file, like Write-TextFileAtomic - not Export-Clixml straight to
    # the real path. Get-SecretStore deliberately throws rather than returning an
    # empty store on a read failure, specifically so a bad read cannot lead to a
    # good file being silently overwritten. That protection is defeated if the
    # write itself can be interrupted mid-file: a kill or power loss during a
    # direct write leaves a truncated secrets.xml, which then throws on every
    # future read and forces every credential to be re-entered - the very loss
    # the throw-on-failure design exists to prevent, from a different cause.
    $tmp = "$($script:SecretsFile).tmp"
    $Store | Export-Clixml -Path $tmp -Force
    Move-Item -Path $tmp -Destination $script:SecretsFile -Force
}

# --------------------------------------------------------------------------- #
# Run logs and the audit trail
# --------------------------------------------------------------------------- #
# Two different things, deliberately kept apart:
#
#   run log    the narrative of one run. What a person reads when something
#              went wrong. Verbose, disposable, governed by retention.
#   audit log  one line per state change, append-only, never auto-deleted.
#              What answers "who changed what, when, and did it work".
#
# Before this existed the scheduled tasks wrote NOTHING - they launch with
# -WindowStyle Hidden and no redirection, so the runs nobody watches were the
# only ones with no record at all.

$script:RunLogPath   = $null
$script:RunLogSource = 'cli'
$script:SecretMasks  = $null

function Get-SecretMasks {
    <#
      Plaintext secret values, read once per run, so a log line can never carry
      one even if some future change starts echoing more than it should.

      Nothing currently leaks - that was verified before any of this was built -
      so this is a guard against tomorrow rather than a fix for today. The values
      are already resident during a run (the Data Plane API password is used on
      every push), so holding them costs no exposure that did not already exist.
    #>
    if ($null -ne $script:SecretMasks) { return $script:SecretMasks }

    $masks = @()
    try {
        $store = Get-SecretStore
        foreach ($k in @($store.Keys)) {
            $v = ConvertFrom-SecureStringPlain $store[$k]
            # Very short values would mask harmless text everywhere.
            if ($v -and $v.Length -ge 8) { $masks += $v }
        }
    }
    catch { }   # unreadable store is not a reason to refuse to log

    $script:SecretMasks = @($masks)
    return $script:SecretMasks
}

function Protect-LogLine {
    param([string]$Line)
    if (-not $Line) { return $Line }
    foreach ($m in (Get-SecretMasks)) {
        if ($Line.Contains($m)) { $Line = $Line.Replace($m, '[redacted]') }
    }
    return $Line
}

function Start-RunLog {
    <#
      Open the run log for this process. serve.ps1 passes a path so the page can
      tail the same file it will keep; a scheduled task passes nothing and gets a
      self-describing name, which is also what makes the folder readable - the
      old GUID filenames said nothing about what they were without opening them.
    #>
    param([string]$Kind, [string]$Path, [string]$Source = 'cli')

    if (-not (Test-Path $script:JobsDir)) {
        New-Item -ItemType Directory -Path $script:JobsDir -Force | Out-Null
    }

    if ($Path) { $script:RunLogPath = $Path }
    else {
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHHmmssZ')
        $script:RunLogPath = Join-Path $script:JobsDir "$stamp-$Kind.log"
    }
    $script:RunLogSource = $Source
    return $script:RunLogPath
}

function Write-RunLog {
    param([string]$Line)
    if (-not $script:RunLogPath) { return }
    try {
        [IO.File]::AppendAllText($script:RunLogPath, (Protect-LogLine $Line) + "`r`n", [Text.Encoding]::UTF8)
    }
    catch { }   # a logging failure must never be why a renewal fails
}

function Write-AuditEvent {
    <#
      One line per state change. Fixed columns so it stays greppable by eye and
      parseable by anything else:

        when · who · source · event · object · outcome · detail

      "who" is the Windows user, because in an assessment that is the answer to
      the question. "source" separates ui from task - whether a person or the
      scheduler made this change is usually the next thing asked.

      Never carries a secret VALUE. Key names only, and everything goes through
      the same redaction the run log uses.
    #>
    param(
        [string]$Event,
        [string]$Object,
        [ValidateSet('ok','fail','warn','info')][string]$Outcome = 'ok',
        [string]$Detail = '',
        [string]$Source
    )

    if (-not $Source) { $Source = $script:RunLogSource }

    # PadRight widens a short value but never truncates a long one, so a name
    # that overruns its column pushes the rest of ITS line along and leaves every
    # other line still lined up. Losing characters from a hostname to keep the
    # columns pretty would be the wrong trade in a record.
    $line = '{0}  {1}  {2}  {3}  {4}  {5}  {6}' -f `
        (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'),
        $env:USERNAME.PadRight(12),
        $Source.PadRight(4),
        $Event.PadRight(8),
        $(if ($Object) { $Object } else { '-' }).PadRight(24),
        $Outcome.PadRight(4),
        (Protect-LogLine $Detail)

    try {
        # Rotate rather than truncate. The archive is kept - see the retention
        # note about why this file is not subject to the size cap.
        if ((Test-Path $script:AuditFile) -and (Get-Item $script:AuditFile).Length -gt $script:AuditMaxBytes) {
            $archive = Join-Path $script:Root ("audit-{0}.log" -f (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))
            Move-Item -LiteralPath $script:AuditFile -Destination $archive -Force
        }
        [IO.File]::AppendAllText($script:AuditFile, $line + "`r`n", [Text.Encoding]::UTF8)
    }
    catch { }
}

function Get-LogSettings {
    <#
      Retention, with defaults that keep a useful amount without growing without
      limit. Both are user-adjustable under Settings > General.
    #>
    param([hashtable]$Settings)

    $days = 90
    $mb   = 200
    if ($Settings -and $Settings.ContainsKey('logs') -and $Settings.logs) {
        if ($Settings.logs.ContainsKey('retentionDays') -and $Settings.logs.retentionDays) { $days = [int]$Settings.logs.retentionDays }
        if ($Settings.logs.ContainsKey('maxSizeMb')     -and $Settings.logs.maxSizeMb)     { $mb   = [int]$Settings.logs.maxSizeMb }
    }
    if ($days -lt 1) { $days = 1 }
    if ($mb   -lt 1) { $mb   = 1 }
    return @{ retentionDays = $days; maxSizeMb = $mb }
}

function Invoke-LogRetention {
    <#
      Trim RUN logs, oldest first, by age then by total size - whichever bites
      first. Every trim is itself an audit event, so the trail can account for
      its own gaps rather than just having them.

      The audit log is deliberately NOT subject to this. Deleting audit records
      to reclaim disk is precisely what an assessor would object to, and a silent
      exception would be worse than a stated one: it rotates to audit-<stamp>.log
      and those archives are kept. If a retention policy genuinely requires audit
      expiry, that wants to be its own explicit setting, not a side effect of a
      disk cap.
    #>
    param([hashtable]$Settings)

    if (-not (Test-Path $script:JobsDir)) { return @{ removed = 0; freedMb = 0 } }

    $cfg   = Get-LogSettings -Settings $Settings
    $limit = (Get-Date).AddDays(-1 * $cfg.retentionDays)
    $removed = 0
    $freed   = 0

    # Result JSON keyed by certificate (deploy-<id>.json, renew-due-<id>.json) is
    # current state rather than history - the page reads it to show the last
    # outcome - so it is never trimmed. Only dated run artifacts are.
    $isTrimmable = {
        param($f)
        ($f.Extension -in @('.log', '.err')) -or ($f.Name -like '*.result.json')
    }

    $files = @(Get-ChildItem $script:JobsDir -File -ErrorAction SilentlyContinue |
               Where-Object { & $isTrimmable $_ } | Sort-Object LastWriteTime)

    foreach ($f in $files) {
        if ($f.LastWriteTime -ge $limit) { continue }
        $sz = $f.Length
        try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $removed++; $freed += $sz } catch { }
    }

    $remaining = @(Get-ChildItem $script:JobsDir -File -ErrorAction SilentlyContinue |
                   Where-Object { & $isTrimmable $_ } | Sort-Object LastWriteTime)
    $total = ($remaining | Measure-Object -Property Length -Sum).Sum
    if (-not $total) { $total = 0 }
    $cap = $cfg.maxSizeMb * 1mb

    foreach ($f in $remaining) {
        if ($total -le $cap) { break }
        $sz = $f.Length
        try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $removed++; $freed += $sz; $total -= $sz } catch { }
    }

    if ($removed -gt 0) {
        $mb = [math]::Round($freed / 1mb, 2)
        Write-AuditEvent -Event 'retention' -Object 'jobs' -Outcome 'info' `
            -Detail "trimmed $removed run log file(s), $mb MB (keeping $($cfg.retentionDays) days / $($cfg.maxSizeMb) MB)"
    }
    return @{ removed = $removed; freedMb = [math]::Round($freed / 1mb, 2) }
}

function Get-AutomationStatus {
    <#
      What the Windows scheduler actually has registered for this folder.

      Read through the Schedule.Service COM object rather than the ScheduledTasks
      cmdlets. Measured on the three task names: Get-ScheduledTask plus
      Get-ScheduledTaskInfo takes ~2200 ms, this takes ~150 ms for strictly more
      information. The cmdlets are CIM-backed and pay for it.

      Three outcomes that must not be conflated, because the response to each is
      different:

        registered = $false   nothing was ever set up here
        enabled    = $false   set up, then switched off
        available  = $false   the scheduler could not be read at all

      Reporting the third as "off" would be a lie in the dangerous direction -
      it would say automation is not running when it may well be.
    #>

    $out = @{ available = $true; error = $null; tasks = @() }

    $folder = $null
    try {
        $svc = New-Object -ComObject 'Schedule.Service'
        $svc.Connect()
        $folder = $svc.GetFolder('\')
    }
    catch {
        $out.available = $false
        $out.error = ($_.Exception.Message -split "`n")[0].Trim()
        # Still list the tasks, so the page can name what it cannot see.
        foreach ($def in $script:ScheduledTaskNames) {
            $out.tasks += @{
                key = $def.key; name = $def.name; label = $def.label
                level = $def.level; detail = $def.detail
                registered = $false; enabled = $false; state = 'unknown'
                nextRun = $null; lastRun = $null; lastResult = $null
                schedule = $null; pathMatches = $true; commandPath = $null
            }
        }
        return $out
    }

    # 1 disabled, 2 queued, 3 ready, 4 running.
    $stateNames = @{ 0 = 'unknown'; 1 = 'disabled'; 2 = 'queued'; 3 = 'ready'; 4 = 'running' }

    foreach ($def in $script:ScheduledTaskNames) {
        $entry = @{
            key = $def.key; name = $def.name; label = $def.label
            level = $def.level; detail = $def.detail
            registered = $false; enabled = $false; state = 'not registered'
            nextRun = $null; lastRun = $null; lastResult = $null
            schedule = $null; pathMatches = $true; commandPath = $null
        }

        $task = $null
        try { $task = $folder.GetTask($def.name) } catch { }

        if ($task) {
            $entry.registered = $true
            try { $entry.enabled = [bool]$task.Enabled } catch { }
            try { $entry.state = $stateNames[[int]$task.State] } catch { $entry.state = 'unknown' }
            try { if ($task.NextRunTime -and $task.NextRunTime.Year -gt 1999) { $entry.nextRun = $task.NextRunTime.ToString('o') } } catch { }
            try { if ($task.LastRunTime -and $task.LastRunTime.Year -gt 1999) { $entry.lastRun = $task.LastRunTime.ToString('o') } } catch { }
            try { $entry.lastResult = [int]$task.LastTaskResult } catch { }

            try {
                $d = $task.Definition

                # The trigger's StartBoundary carries the time of day for a daily
                # trigger. Reported as the raw boundary; the page formats it.
                foreach ($tr in $d.Triggers) {
                    if ($tr.StartBoundary) { $entry.schedule = [string]$tr.StartBoundary; break }
                }

                # Which script is really being run. The task stores an ABSOLUTE
                # path, so copying this folder leaves the task pointing at the
                # old one - renewal silently stops and the first symptom is an
                # expiry warning weeks later. Worth catching on sight.
                foreach ($a in $d.Actions) {
                    if (-not $a.Arguments) { continue }
                    $m = [regex]::Match([string]$a.Arguments, '-File\s+"?([^"]+)"?\s*$')
                    if ($m.Success) {
                        $entry.commandPath = $m.Groups[1].Value.Trim()
                        $expected = Join-Path $script:Root $def.script
                        try {
                            $entry.pathMatches = ([IO.Path]::GetFullPath($entry.commandPath) -eq [IO.Path]::GetFullPath($expected))
                        }
                        catch { $entry.pathMatches = $false }
                        break
                    }
                }
            }
            catch { }
        }

        $out.tasks += $entry
    }

    return $out
}

function Get-RenewalForecast {
    <#
      The last sweep's per-certificate verdict, as recorded by renew-due.ps1.

      Nothing is computed here. renew-due.ps1 already works this out properly -
      with the right ACME server selected, through the supported Posh-ACME API -
      and now writes it to jobs/renew-due-sweep.json. Recomputing it in the
      server would mean importing Posh-ACME into the long-lived listener, which
      serve.ps1 deliberately does not do.
    #>

    if (-not (Test-Path $script:SweepFile)) { return $null }

    # ReadAllText, not Get-Content: Get-Content attaches PSPath/PSDrive
    # NoteProperties, and this object is handed straight to ConvertTo-Json.
    try { return ([IO.File]::ReadAllText($script:SweepFile) | ConvertFrom-Json) }
    catch { return $null }
}

function Write-SecretAuditLog {
    <#
      A persistent, append-only record of every secret a settings save removes,
      separate from the server's console output. The console window closes or
      scrolls away; this survives a restart and a support request. Never
      records a value - only which key, why, and when - the key names
      themselves are ids ("p1a2b3c4:CFToken"), not secrets.

      Deliberately scoped to pruning, not every write: a save that legitimately
      sets a new password is not the failure mode this exists to catch. It is
      a credential vanishing with nothing to explain why - which has happened
      twice in this codebase already, both times from a prune loop.
    #>
    param([string]$Category, [string[]]$Keys)

    if (-not $Keys -or -not @($Keys).Count) { return }

    # Now one line in the main trail rather than a file of its own, so a
    # credential disappearing sits in the same timeline as the settings save
    # that caused it. secrets-audit.log is still appended to as well: it
    # predates the trail, someone may already be watching it, and this is the
    # last record anyone should have to go looking for twice.
    Write-AuditEvent -Event 'secret' -Object ($Keys -join ', ') -Outcome 'warn' `
        -Detail "removed $(@($Keys).Count) stored credential(s) - $Category"

    $line = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] pruned $(@($Keys).Count) secret(s) ($Category): $($Keys -join ', ')"
    try {
        [IO.File]::AppendAllText($script:SecretAuditFile, $line + "`r`n", [Text.Encoding]::UTF8)
    }
    catch {
        # A logging failure must not be why a settings save fails.
        Write-Output "[$((Get-Date).ToString('HH:mm:ss'))] [warn] Could not write to secrets-audit.log: $(($_.Exception.Message -split "`n")[0].Trim())"
    }
}

# Secrets are keyed "<providerId>:<argName>" so one provider can hold several.
function Set-TrackerSecret {
    param([string]$Key, [string]$Value)

    $store = Get-SecretStore
    if ([string]::IsNullOrEmpty($Value)) { $store.Remove($Key) }
    else { $store[$Key] = ConvertTo-SecureString $Value -AsPlainText -Force }
    Save-SecretStore $store
}

function Get-TrackerSecret {
    param([string]$Key, [switch]$AsPlainText)

    $store = Get-SecretStore
    if (-not $store.ContainsKey($Key)) { return $null }
    if ($AsPlainText) { return ConvertFrom-SecureStringPlain $store[$Key] }
    return $store[$Key]
}

function Send-AlertEmail {
    <#
      Sends one plain-text email through the configured SMTP profile. Throws on
      failure - callers on the alerting path (renewal, deployment, expiry) catch
      and log rather than let a mail problem interrupt what it is reporting on.
      The test-email endpoint lets the throw reach the caller instead, because
      there the failure is the answer being asked for.

      Encryption is deliberately two real options, not three:

        starttls - connects in plain text on the given port (587 is standard)
                   and upgrades via STARTTLS. This is what .NET's SmtpClient
                   actually implements when EnableSsl is true, and it is
                   reliable.
        none     - no encryption. For a relay that only accepts connections
                   from this machine and never leaves it.

      Implicit TLS (a server that expects TLS from the first byte, historically
      port 465) is NOT offered. System.Net.Mail.SmtpClient - what PowerShell
      5.1 has, since it predates System.Net.Mail.SmtpClient's newer
      Framework-only replacements - has long-documented unreliable support for
      it: EnableSsl assumes a plaintext handshake to negotiate STARTTLS on, so
      pointing it at a 465-only server tends to hang or fail outright rather
      than connect insecurely. Silently attempting it and sometimes failing
      closed is fine; silently attempting it and sometimes failing OPEN - or
      just being flaky - is not a trade worth making for a security control.
      A provider offering both STARTTLS-on-587 and implicit-TLS-on-465 should
      be pointed at the former.
    #>
    param(
        [hashtable]$Settings,
        [string]$Subject,
        [string]$Body,
        [string[]]$ToOverride
    )

    $smtp = $Settings.alerts.smtp
    if (-not $smtp -or -not $smtp.host) { throw "No SMTP host is configured." }

    $to = if ($ToOverride -and @($ToOverride).Count) { @($ToOverride) } else { @($smtp.to) }
    if (-not @($to).Count) { throw "No alert recipient is configured." }

    $from = if ($smtp.from) { [string]$smtp.from } else { [string]$Settings.contact }
    if (-not $from) { throw "No 'from' address is configured, and no contact email to fall back to." }

    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $msg = New-Object Net.Mail.MailMessage
    $client = $null
    try {
        $msg.From = $from
        foreach ($addr in @($to)) { $msg.To.Add($addr) }
        $msg.Subject = $Subject
        $msg.Body = $Body
        $msg.IsBodyHtml = $false

        $port = $(if ($smtp.port) { [int]$smtp.port } else { 587 })
        $client = New-Object Net.Mail.SmtpClient($smtp.host, $port)
        $client.EnableSsl = ($smtp.encryption -eq 'starttls')

        if ($smtp.authRequired) {
            $pw = Get-TrackerSecret -Key 'alerts:smtpPassword' -AsPlainText
            if (-not $pw) { throw "This SMTP profile requires a password, but none is stored." }
            $client.Credentials = New-Object Net.NetworkCredential([string]$smtp.username, $pw)
        }
        else {
            $client.UseDefaultCredentials = $false
        }

        $client.Send($msg)
    }
    finally {
        $msg.Dispose()
        if ($client) { $client.Dispose() }
    }
}

function Send-RenewalOutcomeAlert {
    <#
      One certificate's renewal (and, on the normal path, deployment) just
      finished. Sends the success or failure alert if the operator asked for
      it. Deliberately does not throw - the caller wraps this anyway, but the
      point of an alert about a renewal is that it must never become the
      reason the renewal is recorded as failed.
    #>
    param([hashtable]$Settings, [string]$DisplayName, [bool]$Ok, $Deployed, [string]$ErrorMessage)

    try {
        $alerts = $Settings.alerts
        if (-not $alerts) { return }

        if ($Ok) {
            if (-not $alerts.renewalSuccess.enabled) { return }
            $where = if ($null -eq $Deployed) { 'issued (no load balancer assigned)' }
                     elseif ($Deployed)        { 'issued and deployed' }
                     else                       { 'issued' }
            Send-AlertEmail -Settings $Settings -Subject "Cert Camel: $DisplayName renewed" `
                -Body "$DisplayName was $where successfully, $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))."
        }
        else {
            if (-not $alerts.deploymentFailure.enabled) { return }
            Send-AlertEmail -Settings $Settings -Subject "Cert Camel: $DisplayName FAILED" `
                -Body "$DisplayName did not fully succeed, $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')).`r`n`r`n$ErrorMessage`r`n`r`nCheck the tracker for the full log."
        }
    }
    catch {
        Write-Output "[$((Get-Date).ToString('HH:mm:ss'))] [warn] Alert email could not be sent: $(($_.Exception.Message -split "`n")[0].Trim())"
    }
}

function Send-ExpiryAlerts {
    <#
      Compares every watched host's days-remaining against the configured
      thresholds and emails once per host per threshold crossed, not on every
      run. State is one flat file recording the smallest (most urgent)
      threshold already alerted on for each host, so crossing 30 fires once
      and stays quiet until the same host also crosses 14, then 7. A renewal
      pushes days-remaining back above every threshold, which clears the
      record so the next approach to expiry can alert again.

      Takes the raw checker results (every watched host, including ones this
      tool does not renew) rather than the renewable-certificate list, so an
      externally-managed certificate still gets a warning if whatever renews
      it elsewhere falls behind.
    #>
    param([hashtable]$Settings, [array]$Results)

    if (-not $Settings.alerts -or -not $Settings.alerts.expiry.enabled) { return }
    $thresholds = @($Settings.alerts.expiry.thresholds | Sort-Object -Descending)
    if (-not $thresholds.Count) { return }

    $state = @{}
    if (Test-Path $script:AlertStateFile) {
        try {
            $parsed = (Get-Content $script:AlertStateFile -Raw -Encoding UTF8) | ConvertFrom-Json
            $state = ConvertTo-HashtableDeep $parsed
        }
        catch { $state = @{} }
    }
    if ($null -eq $state) { $state = @{} }

    $changed = $false
    $now = Get-Date

    foreach ($r in @($Results)) {
        if (-not $r.ok -or -not $r.notAfter) { continue }
        $hostName = [string]$r.host
        $days = [math]::Floor(([datetime]$r.notAfter - $now).TotalDays)

        $prevAlerted = $null
        if ($state.ContainsKey($hostName) -and $state[$hostName].ContainsKey('lastThresholdAlerted')) {
            $prevAlerted = $state[$hostName].lastThresholdAlerted
        }

        # The smallest (most urgent) configured threshold this host is at or
        # under right now.
        $crossed = $null
        foreach ($t in $thresholds) { if ($days -le $t) { $crossed = $t } }

        if ($null -eq $crossed) {
            # Back above every threshold - a renewal happened. Clear the record
            # so the next approach to expiry alerts again rather than staying
            # silent forever because of what it alerted on last time.
            if ($state.ContainsKey($hostName)) { $state.Remove($hostName); $changed = $true }
            continue
        }

        # Only a NEW (smaller, more urgent) threshold than whatever was last
        # alerted triggers a send, so 30 does not re-fire every day until 14.
        if ($null -eq $prevAlerted -or $crossed -lt $prevAlerted) {
            try {
                Send-AlertEmail -Settings $Settings -Subject "Cert Camel: $hostName expires in $days day(s)" `
                    -Body "$hostName has $days day(s) remaining (crossed the $crossed-day threshold), expiring $(([datetime]$r.notAfter).ToString('yyyy-MM-dd'))."
            }
            catch {
                Write-Output "[$((Get-Date).ToString('HH:mm:ss'))] [warn] Expiry alert for $hostName could not be sent: $(($_.Exception.Message -split "`n")[0].Trim())"
            }
            $state[$hostName] = @{ lastThresholdAlerted = $crossed }
            $changed = $true
        }
    }

    if ($changed) {
        try { Write-TextFileAtomic -Path $script:AlertStateFile -Content ($state | ConvertTo-Json -Depth 5) }
        catch { Write-Output "[$((Get-Date).ToString('HH:mm:ss'))] [warn] Could not save alert-state.json: $(($_.Exception.Message -split "`n")[0].Trim())" }
    }
}

function Test-TrackerSecret {
    param([string]$Key)
    (Get-SecretStore).ContainsKey($Key)
}

# --------------------------------------------------------------------------- #
# Posh-ACME
# --------------------------------------------------------------------------- #

function Get-VendoredPoshAcme {
    $manifest = Get-ChildItem -Path $script:LibDir -Filter 'Posh-ACME.psd1' -Recurse -ErrorAction SilentlyContinue |
                Sort-Object FullName -Descending |
                Select-Object -First 1
    if ($manifest) { return $manifest.FullName }
    return $null
}

function Install-PoshAcmeLocal {
    <#
      Vendors Posh-ACME into lib/ with Save-Module. Two things reliably go wrong
      on Windows PowerShell 5.1 and both produce unhelpful errors, so handle
      them up front: the default security protocol excludes TLS 1.2 (PSGallery
      requires it) and the NuGet provider may not be present yet.
    #>
    param([switch]$Force)

    New-TrackerDirectories

    if (-not $Force) {
        $existing = Get-VendoredPoshAcme
        if ($existing) { return $existing }
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }

    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -Scope CurrentUser -Force -ErrorAction Stop | Out-Null
    }

    Save-Module -Name 'Posh-ACME' -Path $script:LibDir -Force -ErrorAction Stop

    $manifest = Get-VendoredPoshAcme
    if (-not $manifest) { throw "Save-Module reported success but no Posh-ACME.psd1 landed in $($script:LibDir)." }
    return $manifest
}

function Import-PoshAcme {
    <#
      POSHACME_HOME must be set BEFORE the module is imported - it is read at
      import time, and changing it afterwards has no effect without a -Force
      re-import. Pointing it inside the bundle keeps account keys and order
      state with the folder rather than in %LOCALAPPDATA%.
    #>
    New-TrackerDirectories
    $env:POSHACME_HOME = $script:AcmeState

    $manifest = Get-VendoredPoshAcme
    if (-not $manifest) {
        throw "Posh-ACME is not installed in this folder. Run 'First Time Setup.bat' to fetch it."
    }

    Import-Module $manifest -Force -ErrorAction Stop
}

# --------------------------------------------------------------------------- #
# DNS Made Easy API
# --------------------------------------------------------------------------- #
# Used only to discover which zones an account manages, so hostnames can be
# grouped into certificates. The actual challenge records are written by
# Posh-ACME's own DMEasy plugin during a renewal.

function Get-DMEBaseUrl {
    param([switch]$Sandbox)
    if ($Sandbox) { return 'https://api.sandbox.dnsmadeeasy.com/V2.0' }
    return 'https://api.dnsmadeeasy.com/V2.0'
}

function Invoke-DMERequest {
    <#
      DNS Made Easy signs each request with an HMAC-SHA1 of the request date,
      keyed by the secret. The server rejects anything more than ~30 seconds
      out of step with its own clock, which otherwise surfaces as a bare 403 -
      so that case is detected and reported in plain language.
    #>
    param(
        [string]$Path,
        [string]$ApiKey,
        [string]$SecretKey,
        [switch]$Sandbox
    )

    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }

    # RFC 1123 in the invariant culture: a non-English locale would otherwise
    # emit localised day and month names and every signature would fail.
    $requestDate = [DateTime]::UtcNow.ToString('r', [Globalization.CultureInfo]::InvariantCulture)

    $hmac = New-Object Security.Cryptography.HMACSHA1
    $hmac.Key = [Text.Encoding]::UTF8.GetBytes($SecretKey)
    $sig = ($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($requestDate)) |
            ForEach-Object { $_.ToString('x2') }) -join ''
    $hmac.Dispose()

    $headers = @{
        'x-dnsme-apiKey'      = $ApiKey
        'x-dnsme-requestDate' = $requestDate
        'x-dnsme-hmac'        = $sig
        'Accept'              = 'application/json'
    }

    $uri = (Get-DMEBaseUrl -Sandbox:$Sandbox) + $Path

    try {
        Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -TimeoutSec 30 -ErrorAction Stop
    }
    catch {
        $status = $null
        $serverDate = $null
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
            try { $status = [int]$_.Exception.Response.StatusCode } catch { }
            try { $serverDate = $_.Exception.Response.Headers['Date'] } catch { }
        }

        if ($status -eq 403) {
            # Prefer the server's own clock for the comparison; fall back to
            # saying "check the clock" when the header is missing.
            if ($serverDate) {
                $skew = [Math]::Abs(([DateTime]::Parse($serverDate)).ToUniversalTime().Subtract([DateTime]::UtcNow).TotalSeconds)
                if ($skew -gt 30) {
                    throw ("This PC's clock is {0:N0} seconds off from DNS Made Easy, which rejects requests more than 30 seconds out. Sync the system clock and try again." -f $skew)
                }
            }
            throw "DNS Made Easy rejected the credentials (403). Check the API key and secret key, and that this PC's clock is accurate."
        }

        if ($status -eq 404) { throw "DNS Made Easy returned 404 for $Path." }
        throw "DNS Made Easy request failed: $($_.Exception.Message)"
    }
}

function Get-DMEZones {
    <#
      Returns every managed zone name on the account. The endpoint pages, and an
      account with more zones than fit on one page would otherwise silently lose
      the tail - which would show up much later as "why is that domain
      unmapped?", so follow the pages properly.
    #>
    param([string]$ApiKey, [string]$SecretKey, [switch]$Sandbox)

    $names = @()
    $page  = 0

    while ($true) {
        $resp = Invoke-DMERequest -Path "/dns/managed?rows=500&page=$page" `
                                  -ApiKey $ApiKey -SecretKey $SecretKey -Sandbox:$Sandbox

        if ($resp -and $resp.PSObject.Properties['data'] -and $resp.data) {
            foreach ($z in $resp.data) { if ($z.name) { $names += [string]$z.name } }
        }

        $totalPages = 1
        if ($resp -and $resp.PSObject.Properties['totalPages'] -and $resp.totalPages) {
            $totalPages = [int]$resp.totalPages
        }

        $page++
        if ($page -ge $totalPages) { break }
    }

    return @($names | Sort-Object -Unique)
}

# --------------------------------------------------------------------------- #
# NS1 API
# --------------------------------------------------------------------------- #

function Get-NS1Zones {
    <#
      Every zone on an NS1 account. Simpler than DNS Made Easy: a single header,
      no request signing, no clock sensitivity, and the list is not paged.
    #>
    param([string]$ApiKey)

    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }

    try {
        $resp = Invoke-RestMethod -Uri 'https://api.nsone.net/v1/zones' `
                    -Headers @{ 'X-NSONE-Key' = $ApiKey; 'Accept' = 'application/json' } `
                    -Method Get -TimeoutSec 30 -ErrorAction Stop
    }
    catch {
        $status = $null
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
            try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        }
        if ($status -eq 401 -or $status -eq 403) {
            throw "NS1 rejected the API key. Check it in the NS1 portal under Account Settings > API Keys, and that it has DNS permissions."
        }
        throw "NS1 request failed: $($_.Exception.Message)"
    }

    $names = @()
    foreach ($z in @($resp)) { if ($z.zone) { $names += [string]$z.zone } }
    return @($names | Sort-Object -Unique)
}

# --------------------------------------------------------------------------- #
# Cloudflare API
# --------------------------------------------------------------------------- #

function Get-CloudflareZones {
    <#
      Every zone the token can see. Cloudflare reports its own failures inside a
      200 response ("success": false), so the body has to be checked rather than
      relying on the HTTP status alone - a wrong permission scope otherwise looks
      like an account with no zones.
    #>
    param([string]$Token)

    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }

    $headers = @{ 'Authorization' = "Bearer $Token"; 'Accept' = 'application/json' }
    $names = @()
    $page  = 1

    while ($true) {
        try {
            $resp = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones?per_page=50&page=$page" `
                        -Headers $headers -Method Get -TimeoutSec 30 -ErrorAction Stop
        }
        catch {
            # Cloudflare answers a malformed token with 400, not 401, and puts
            # the real reason in the body. Read it, or an obvious credential
            # mistake surfaces as an unexplained "400 Bad Request".
            $status = $null
            $detail = $null
            if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
                try { $status = [int]$_.Exception.Response.StatusCode } catch { }
                try {
                    $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $body = $sr.ReadToEnd(); $sr.Dispose()
                    $parsed = $body | ConvertFrom-Json
                    if ($parsed.errors -and @($parsed.errors).Count) {
                        $detail = (@($parsed.errors) | ForEach-Object { $_.message }) -join '; '
                    }
                } catch { }
            }

            if ($status -in @(400, 401, 403)) {
                $msg = "Cloudflare rejected the API token"
                if ($detail) { $msg += ": $detail" }
                throw "$msg. It must be a scoped API token (not the Global API Key) with Zone:Read and DNS:Edit permissions."
            }
            if ($detail) { throw "Cloudflare request failed: $detail" }
            throw "Cloudflare request failed: $($_.Exception.Message)"
        }

        if ($resp -and $resp.PSObject.Properties['success'] -and -not $resp.success) {
            $msg = 'unknown error'
            if ($resp.errors -and @($resp.errors).Count) { $msg = (@($resp.errors) | ForEach-Object { $_.message }) -join '; ' }
            throw "Cloudflare returned an error: $msg"
        }

        foreach ($z in @($resp.result)) { if ($z.name) { $names += [string]$z.name } }

        $totalPages = 1
        if ($resp.PSObject.Properties['result_info'] -and $resp.result_info -and $resp.result_info.total_pages) {
            $totalPages = [int]$resp.result_info.total_pages
        }
        $page++
        if ($page -gt $totalPages) { break }
    }

    return @($names | Sort-Object -Unique)
}

# --------------------------------------------------------------------------- #
# Provider dispatch
# --------------------------------------------------------------------------- #

# Assemble the -PluginArgs hashtable for one provider: plain values from
# settings.json, secret values decrypted from secrets.xml.
function Get-ProviderPluginArgs {
    param([hashtable]$Provider)

    # Not $args - that is an automatic variable inside a function.
    $pluginArgs = @{}

    $catalog = $script:PluginCatalog[$Provider.plugin]
    if (-not $catalog) { throw "Unknown DNS plugin '$($Provider.plugin)'." }

    foreach ($a in $catalog.Args) {
        if ($a.Secret) {
            # Posh-ACME's secure parameter sets want the SecureString itself.
            $secure = Get-TrackerSecret -Key "$($Provider.id):$($a.Name)"
            if ($secure) { $pluginArgs[$a.Name] = $secure }
            continue
        }

        $value = $null
        if ($Provider.ContainsKey('args') -and $Provider.args -and $Provider.args.ContainsKey($a.Name)) {
            $value = $Provider.args[$a.Name]
        }

        if ($a.Type -eq 'bool') {
            # These map to switch parameters. Passing $false is fine, but only
            # send it when it is actually on so the args stay readable in logs.
            if ($value) { $pluginArgs[$a.Name] = $true }
        }
        elseif ($null -ne $value -and "$value" -ne '') {
            $pluginArgs[$a.Name] = $value
        }
    }

    return $pluginArgs
}

function Get-ProviderZones {
    <#
      Ask one provider which zones it manages. Only DNS Made Easy is wired up;
      other Posh-ACME plugins can still be used for renewal, they just cannot
      auto-discover zones yet, so they fall back to the suffix heuristic.
    #>
    param([hashtable]$Provider)

    switch ($Provider.plugin) {
        'DMEasy' {
            $key = $null
            if ($Provider.ContainsKey('args') -and $Provider.args -and $Provider.args.ContainsKey('DMEKey')) {
                $key = $Provider.args.DMEKey
            }
            $secret = Get-TrackerSecret -Key "$($Provider.id):DMESecret" -AsPlainText

            if (-not $key -or -not $secret) {
                throw "This DNS Made Easy profile is missing its API key or secret key."
            }

            $sandbox = $false
            if ($Provider.ContainsKey('args') -and $Provider.args -and $Provider.args.ContainsKey('DMEUseSandbox')) {
                $sandbox = [bool]$Provider.args.DMEUseSandbox
            }

            return Get-DMEZones -ApiKey $key -SecretKey $secret -Sandbox:$sandbox
        }
        'NS1' {
            $key = Get-TrackerSecret -Key "$($Provider.id):NS1Key" -AsPlainText
            if (-not $key) { throw "This NS1 profile is missing its API key." }
            return Get-NS1Zones -ApiKey $key
        }
        'Cloudflare' {
            $token = Get-TrackerSecret -Key "$($Provider.id):CFToken" -AsPlainText
            if (-not $token) { throw "This Cloudflare profile is missing its API token." }
            return Get-CloudflareZones -Token $token
        }
        default {
            throw "Zone discovery is not implemented for the '$($Provider.plugin)' plugin yet. Renewal itself will still work - the zone just has to be covered by another configured profile."
        }
    }
}

# --------------------------------------------------------------------------- #
# Write-access probe
# --------------------------------------------------------------------------- #

function Test-ProviderWriteAccess {
    <#
      Actually write a challenge record and delete it again.

      Listing zones only proves read access, and a token with read but not write
      sails through a read-only check and then dies partway through a renewal -
      after an order has been created and an account registered. Since the
      permission that matters is the one nobody can see, exercise it directly.

      This calls the plugin's own Add-DnsTxt / Remove-DnsTxt, dot-sourced inside
      the Posh-ACME module scope so its internal helpers resolve. That means it
      tests the exact code path a renewal uses, for any of the ~100 plugins,
      without a line of per-provider code.
    #>
    param([hashtable]$Provider, [string]$Zone)

    Import-PoshAcme
    $mod = Get-Module Posh-ACME
    if (-not $mod) { throw "Posh-ACME is not loaded." }

    $pluginFile = Join-Path (Join-Path (Split-Path $mod.Path) 'Plugins') "$($Provider.plugin).ps1"
    if (-not (Test-Path $pluginFile)) {
        throw "No Posh-ACME plugin file found for '$($Provider.plugin)'."
    }

    $pluginArgs = Get-ProviderPluginArgs -Provider $Provider

    # The same record name a real challenge uses, so zone detection is exercised
    # too. A value that is obviously a probe, in case one is ever left behind.
    $recordName = "_acme-challenge.$Zone"
    $bytes = New-Object byte[] 16
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes); $rng.Dispose()
    $txtValue = 'tracker-write-probe-' + (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')

    $result = & $mod {
        param($pf, $rec, $val, $pargs)

        . $pf
        $out = @{ wrote = $false; cleaned = $false; error = $null }

        try {
            Add-DnsTxt -RecordName $rec -TxtValue $val @pargs -ErrorAction Stop
            # Plugins that batch their changes only commit on Save-DnsTxt; ones
            # that write immediately define it as a no-op.
            if (Get-Command Save-DnsTxt -ErrorAction SilentlyContinue) {
                Save-DnsTxt @pargs -ErrorAction Stop
            }
            $out.wrote = $true
        }
        catch {
            $out.error = ($_.Exception.Message -split "`n")[0].Trim()
            return $out
        }

        # Clean up on a best-effort basis. A leftover probe record is harmless -
        # a CA looks for a matching value among the TXT records, so an extra one
        # is ignored - but it should be reported rather than left silently.
        try {
            Remove-DnsTxt -RecordName $rec -TxtValue $val @pargs -ErrorAction Stop
            if (Get-Command Save-DnsTxt -ErrorAction SilentlyContinue) {
                Save-DnsTxt @pargs -ErrorAction SilentlyContinue
            }
            $out.cleaned = $true
        }
        catch { $out.cleaned = $false }

        return $out
    } $pluginFile $recordName $txtValue $pluginArgs

    return @{
        zone       = $Zone
        recordName = $recordName
        canWrite   = [bool]$result.wrote
        cleanedUp  = [bool]$result.cleaned
        error      = $result.error
    }
}

# --------------------------------------------------------------------------- #
# Zone cache
# --------------------------------------------------------------------------- #
# Hitting every provider on every page load would be slow and rude. Zones change
# rarely, so cache them and refresh on demand from Settings.

function Get-ZoneCache {
    if (-not (Test-Path $script:ZonesFile)) { return @{ refreshed = $null; zones = @() } }
    try {
        $c = ConvertTo-HashtableDeep ((Get-Content $script:ZonesFile -Raw -Encoding UTF8) | ConvertFrom-Json)
        if (-not $c.ContainsKey('zones') -or $null -eq $c.zones) { $c.zones = @() }
        $c.zones = @($c.zones)
        return $c
    }
    catch { return @{ refreshed = $null; zones = @() } }
}

function Update-ZoneCache {
    <#
      Refresh every configured provider. One bad profile must not wipe the zones
      of the good ones, so failures are collected and returned alongside the
      results rather than thrown.
    #>
    param([hashtable]$Settings)

    $zones  = @()
    $errors = @()

    foreach ($p in @($Settings.providers)) {
        try {
            foreach ($z in (Get-ProviderZones -Provider $p)) {
                $zones += @{
                    zone          = $z.ToLowerInvariant()
                    providerId    = $p.id
                    providerLabel = $p.label
                    plugin        = $p.plugin
                }
            }
        }
        catch {
            $errors += @{ providerId = $p.id; providerLabel = $p.label; error = $_.Exception.Message }
        }
    }

    $cache = @{
        refreshed = (Get-Date).ToString('o')
        zones     = @($zones)
        errors    = @($errors)
    }

    Write-TextFileAtomic -Path $script:ZonesFile -Content ($cache | ConvertTo-Json -Depth 6)
    return $cache
}

# --------------------------------------------------------------------------- #
# Checker output
# --------------------------------------------------------------------------- #

function Get-CheckerResults {
    <#
      Read back what check-ssl.ps1 wrote. The file is JavaScript rather than
      JSON on purpose (see the note at the bottom of check-ssl.ps1), so the
      assignment wrapper is stripped before parsing.
    #>
    $file = Join-Path $script:Root 'ssl-data.js'
    if (-not (Test-Path $file)) { return @{ generated = $null; results = @() } }

    $raw = Get-Content $file -Raw -Encoding UTF8
    $m = [regex]::Match($raw, 'window\.SSL_DATA\s*=\s*(?<j>\{.*\})\s*;', 'Singleline')
    if (-not $m.Success) {
        throw "ssl-data.js is not in the expected format. Run 'Check Now.bat' to regenerate it."
    }

    $d = $m.Groups['j'].Value | ConvertFrom-Json
    $results = @()
    if ($d.PSObject.Properties['results'] -and $d.results) { $results = @($d.results) }

    return @{
        generated = $(if ($d.PSObject.Properties['generated']) { $d.generated } else { $null })
        results   = $results
    }
}

# --------------------------------------------------------------------------- #
# Certificate grouping
# --------------------------------------------------------------------------- #

# Longest managed zone that the hostname sits under. Longest wins so a
# delegated sub-zone beats its parent when both are on the account.
function Resolve-HostZone {
    param([string]$HostName, $Zones)

    $h = $HostName.ToLowerInvariant().TrimEnd('.')
    $best = $null

    foreach ($z in $Zones) {
        $name = $z.zone
        if ($h -eq $name -or $h.EndsWith(".$name")) {
            if (-not $best -or $name.Length -gt $best.zone.Length) { $best = $z }
        }
    }

    return $best
}

# Used only when no provider has been configured yet, purely so the UI can show
# a plausible grouping before setup. Wrong for multi-part suffixes like co.uk,
# which is exactly why the real answer comes from the provider.
function Get-FallbackZone {
    param([string]$HostName)

    $parts = $HostName.ToLowerInvariant().TrimEnd('.').Split('.')
    if ($parts.Count -le 2) { return ($parts -join '.') }
    return ($parts[-2..-1] -join '.')
}

function Get-CertificateGroups {
    <#
      Turn the checker's results into one certificate per zone.

      A group's name list is the tracked hosts plus any SANs observed on the
      certificate currently being served, so renewing reproduces what is live
      rather than quietly dropping a name that exists in production but was
      never added to domains.txt. Names belonging to a zone we do not manage are
      set aside instead of silently included - we could not validate them.
    #>
    param(
        [array]$Results,
        [hashtable]$Settings,
        $ZoneCache
    )

    $zones     = @()
    if ($ZoneCache -and $ZoneCache.zones) { $zones = @($ZoneCache.zones) }
    $haveZones = $zones.Count -gt 0

    $groups   = @{}
    $order    = @()
    $unmapped = @()

    # Zones that asked for a wildcard, via a "*.example.com" line in domains.txt.
    # A wildcard always becomes its own certificate and is never folded into the
    # explicit-name one: some routers (OpenShift among them) refuse HTTP/2
    # against a wildcard certificate, so contaminating the SAN cert would break
    # exactly the hosts it exists to serve.
    $wildcardZones = @{}

    foreach ($r in $Results) {
        $hostName = ([string]$r.host).ToLowerInvariant()

        # A wildcard is matched against the zone it covers, not itself.
        $lookupName = $hostName
        $isWildcard = $hostName.StartsWith('*.')
        if ($isWildcard) { $lookupName = $hostName.Substring(2) }

        $match = $null
        if ($haveZones) { $match = Resolve-HostZone -HostName $lookupName -Zones $zones }

        if ($isWildcard) {
            if ($match) { $wildcardZones[$match.zone] = $match }
            else {
                $unmapped += @{
                    host     = $hostName
                    category = $r.category
                    guess    = Get-FallbackZone -HostName $lookupName
                }
            }
            continue
        }

        if (-not $match) {
            # No configured provider owns this name. Under this tool's premise -
            # everything watched exists to be renewed - that is a gap worth
            # showing, not a quiet skip.
            $unmapped += @{
                host     = $hostName
                category = $r.category
                guess    = Get-FallbackZone -HostName $hostName
            }
            continue
        }

        $zone = $match.zone
        if (-not $groups.ContainsKey($zone)) {
            $order += $zone
            $groups[$zone] = @{
                zone          = $zone
                providerId    = $match.providerId
                providerLabel = $match.providerLabel
                plugin        = $match.plugin
                hosts         = @()
                names         = @()
                deferredNames = @()
                categories    = @()
                notAfter      = $null
            }
        }
        $g = $groups[$zone]

        if ($g.hosts -notcontains $hostName) { $g.hosts += $hostName }
        if ($r.category -and $g.categories -notcontains [string]$r.category) {
            $g.categories += [string]$r.category
        }
        if ($g.names -notcontains $hostName) { $g.names += $hostName }

        # Earliest expiry across the group drives its urgency: the cert is only
        # as good as its soonest-expiring member.
        if ($r.ok -and $r.notAfter) {
            $na = [datetime]$r.notAfter
            if (-not $g.notAfter -or $na -lt $g.notAfter) { $g.notAfter = $na }
        }

        if ($r.PSObject.Properties['sans'] -and $r.sans) {
            foreach ($san in $r.sans) {
                $s = ([string]$san).ToLowerInvariant().TrimEnd('.')
                if (-not $s) { continue }

                if ($s.StartsWith('*.')) {
                    # Wildcards are opt-in: they are excluded by default (they
                    # rule out HTTP/2 on some routers) but reported so the UI can
                    # say the live cert has one.
                    if ($g.deferredNames -notcontains $s) { $g.deferredNames += $s }
                    continue
                }

                $sanZone = Resolve-HostZone -HostName $s -Zones $zones
                if ($sanZone -and $sanZone.zone -eq $zone) {
                    if ($g.names -notcontains $s) { $g.names += $s }
                } elseif ($g.deferredNames -notcontains $s) {
                    $g.deferredNames += $s
                }
            }
        }
    }

    # Apply per-cert overrides and flatten to plain objects for JSON.
    #
    # A zone can yield two certificates: the explicit-name one, and - if
    # domains.txt asked for it - a wildcard one. They are separate orders with
    # separate files so either can be deployed without disturbing the other.
    $out = @()

    # Every zone that produces anything, including wildcard-only zones that have
    # no explicit hosts listed at all.
    $allZones = @($order)
    foreach ($z in $wildcardZones.Keys) { if ($allZones -notcontains $z) { $allZones += $z } }

    foreach ($zone in $allZones) {
        $g = $null
        if ($groups.ContainsKey($zone)) { $g = $groups[$zone] }
        $wantsWildcard = $wildcardZones.ContainsKey($zone)

        # Provider details come from whichever source knows the zone.
        $zoneInfo = $(if ($g) { $g } else { $wildcardZones[$zone] })

        # --- the certificate kinds this zone produces --------------------- #
        #
        # The apex belongs to the wildcard whenever a zone has one. Both
        # certificates would otherwise carry it - the wildcard because it must
        # (*.example.com does not match example.com) and the SAN certificate
        # because the operator listed the apex in domains.txt, which is the
        # normal way to use this tool. That puts ONE name on TWO certificates
        # with equal specificity, where only one can ever serve it: HAProxy
        # picks by exact SNI match and the loser silently never appears. It also
        # made verification report a perfectly good wildcard deployment as
        # failed, because the apex was the name being probed.
        #
        # Subdomains overlapping between the two is harmless by comparison - an
        # exact match always beats a wildcard, so the winner is predictable.
        #
        # This is deliberately not something the operator fixes by editing
        # domains.txt. A line there means two things at once, "watch this name"
        # and "put it on the SAN certificate", and they want the first without
        # the second. Deleting the line would drop it from monitoring instead,
        # which is worse. check-ssl.ps1 reads domains.txt directly and never
        # calls this function, so what is watched is unaffected either way.
        $kinds = @()
        if ($g -and @($g.names).Count) {
            $snames = @($g.names)
            if ($wantsWildcard) { $snames = @($snames | Where-Object { $_ -ne $zone }) }

            # The guard matters: a zone listing only its apex plus a wildcard
            # now yields the wildcard alone, rather than an empty SAN order.
            if (@($snames).Count) {
                $kinds += @{
                    kind = 'san'; id = $zone; display = $zone; names = $snames
                    apexOnWildcard = [bool]$wantsWildcard
                }
            }
        }
        if ($wantsWildcard) {
            # "*" is not legal in a Windows filename, so the identifier used for
            # folders and URLs is "wildcard.<zone>" while the display name is the
            # wildcard itself.
            #
            # The apex rides along because *.example.com does NOT match
            # example.com - a wildcard-only certificate leaves the bare domain
            # uncovered, which is a confusing outage to debug.
            $kinds += @{
                kind = 'wildcard'; id = "wildcard.$zone"; display = "*.$zone"
                names = @("*.$zone", $zone)
            }
        }

        foreach ($k in $kinds) {
            $names    = @($k.names)
            $external = $false
            $caId     = $null
            $targets  = @()
            $override = $null

            # Overrides are keyed by the certificate identifier, so the SAN and
            # wildcard certificates for one zone are configured independently.
            if ($Settings.certs -and $Settings.certs.ContainsKey($k.id)) {
                $override = $Settings.certs[$k.id]
                if ($override.ContainsKey('caId') -and $override.caId) { $caId = [string]$override.caId }
                # Which load balancers this certificate belongs on. Empty means
                # issued but never deployed, which the page states outright
                # rather than leaving as a blank column.
                $targets = Get-CertTargetIds -CertConfig $override
                # "Managed elsewhere": still watched, never renewed from here. A
                # domain someone else auto-renews is worth watching precisely so
                # you find out when that automation stops - but issuing a second
                # certificate for it from this tool would be a mistake.
                if ($override.ContainsKey('external') -and $override.external) { $external = $true }
                if ($override.ContainsKey('sans') -and $override.sans) {
                    $names = @($override.sans)   # explicit list wins outright
                }
            }

            $certDir = Join-Path $script:CertsDir $k.id
            $pemPath = Join-Path $certDir "$($k.id)-full.pem"

            # Resolved rather than passed through, so the page always shows the CA
            # that would actually be used - including when a certificate inherits
            # the default or points at a profile that has since been removed.
            $ca = Get-CaProfile -Settings $Settings -CaId $caId

            # A wildcard certificate has no live counterpart to measure - nothing
            # serves "*.example.com" - so it borrows the zone's soonest expiry
            # when there is one, purely so it sorts sensibly next to the others.
            $notAfter = $null
            if ($g -and $g.notAfter) { $notAfter = $g.notAfter.ToString('o') }

            # The apex rule changes what gets ISSUED, not what is already on
            # disk. Until this certificate is renewed, the old one still carries
            # the apex and still contests it in HAProxy - which looks exactly
            # like the bug the rule was written to prevent. Say so on the row
            # rather than letting someone rediscover it during a deployment.
            #
            # Only parsed for a certificate the rule actually affects, so the
            # common case pays nothing.
            $staleNames = @()
            if ($k.ContainsKey('apexOnWildcard') -and $k.apexOnWildcard -and (Test-Path $pemPath)) {
                try {
                    $leafDer = @(Read-PemBlocks -Text ([IO.File]::ReadAllText($pemPath)) |
                                 Where-Object { $_.Label -eq 'CERTIFICATE' -and $_.Der })[0]
                    if ($leafDer) {
                        $issued = New-Object Security.Cryptography.X509Certificates.X509Certificate2 (,$leafDer.Der)
                        foreach ($sanName in @(Get-CertificateSanNames -Certificate $issued)) {
                            if (@($names) -notcontains $sanName) { $staleNames += $sanName }
                        }
                    }
                }
                catch { }   # unreadable is not worth failing a page load over
            }

            $out += [pscustomobject]@{
                certId        = $k.id
                displayName   = $k.display
                kind          = $k.kind
                zone          = $zone
                # True when this zone's wildcard owns the apex, so the UI can
                # explain why it is absent here rather than looking like a loss.
                apexOnWildcard = [bool]$(if ($k.ContainsKey('apexOnWildcard')) { $k.apexOnWildcard } else { $false })
                staleNames     = @($staleNames)
                providerId    = $zoneInfo.providerId
                providerLabel = $zoneInfo.providerLabel
                plugin        = $zoneInfo.plugin
                hosts         = @($(if ($g) { $g.hosts } else { @() }))
                names         = @($names)
                deferredNames = @($(if ($g -and $k.kind -eq 'san') { $g.deferredNames } else { @() }))
                categories    = @($(if ($g) { $g.categories } else { @() }))
                wildcard      = ($k.kind -eq 'wildcard')
                external      = $external
                targets       = @($targets)
                caId          = $ca.id
                caLabel       = $ca.label
                caStaging     = [bool]$ca.useStaging
                caInherited   = [bool](-not $caId)
                overridden    = [bool]($override -and $override.ContainsKey('sans') -and $override.sans)
                notAfter      = $notAfter
                hasLocalCert  = (Test-Path $pemPath)
                issuedAt      = $(if (Test-Path $pemPath) { (Get-Item $pemPath).LastWriteTime.ToString('o') } else { $null })
            }
        }
    }

    return @{
        certs    = @($out)
        unmapped = @($unmapped)
        haveZones = $haveZones
    }
}

# --------------------------------------------------------------------------- #
# PEM output
# --------------------------------------------------------------------------- #

function Save-CertificateHistory {
    <#
      Copy the certificate currently on disk aside before it gets overwritten.

      Copied rather than moved: if writing the new certificate then fails, the
      stable path still holds a working certificate instead of nothing.

      The folder is stamped with when the OLD certificate was written, so the
      archive reads as "this is the certificate that was live from this date"
      rather than "this is when it happened to be superseded".

      Returns the archive path, or $null when there was nothing worth keeping.
    #>
    param([string]$CertDir, [string]$CertId, [string]$NewPemContent)

    $pem = Join-Path $CertDir "$CertId-full.pem"
    if (-not (Test-Path $pem)) { return $null }

    # Repeated runs against an order the CA considers current would otherwise
    # archive an identical copy every time.
    try {
        if ((Get-Content $pem -Raw -Encoding UTF8).Trim() -eq $NewPemContent.Trim()) { return $null }
    } catch { }

    $stamp   = (Get-Item $pem).LastWriteTime.ToString('yyyy-MM-dd_HHmmss')
    $archive = Join-Path (Join-Path $CertDir 'history') $stamp
    if (-not (Test-Path $archive)) { New-Item -ItemType Directory -Path $archive -Force | Out-Null }

    foreach ($f in @(Get-ChildItem -LiteralPath $CertDir -File)) {
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $archive $f.Name) -Force
    }

    # A note about what this actually was, so the archive is browsable without
    # having to open each certificate to find out.
    $cer = Join-Path $archive 'cert.cer'
    if (Test-Path $cer) {
        try {
            $c = New-Object Security.Cryptography.X509Certificates.X509Certificate2 (,[IO.File]::ReadAllBytes($cer))
            $names = @()
            $ext = $c.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' }
            if ($ext) {
                foreach ($line in (($ext.Format($true)) -split "`r?`n")) {
                    if ($line -match '=\s*(?<v>\S+)\s*$') { $names += $Matches.v.Trim() }
                }
            }
            Write-TextFileAtomic -Path (Join-Path $archive 'about.json') -Content (
                @{ certId = $CertId; subject = $c.Subject; issuer = $c.Issuer
                   notBefore = $c.NotBefore.ToString('o'); notAfter = $c.NotAfter.ToString('o')
                   names = @($names); archivedAt = (Get-Date).ToString('o')
                } | ConvertTo-Json -Depth 4)
        } catch { }
    }

    return $archive
}

function Remove-OldCertificateHistory {
    <#
      Keep only the most recent $Keep archived versions.

      Bounded on purpose: every archived version contains a usable private key,
      and one that stays usable until that certificate expires. An unlimited
      archive quietly turns into a pile of live credentials.
    #>
    param([string]$CertDir, [int]$Keep = 5)

    $historyDir = Join-Path $CertDir 'history'
    if (-not (Test-Path $historyDir)) { return @() }

    # Folder names sort chronologically by construction (yyyy-MM-dd_HHmmss).
    $all     = @(Get-ChildItem -LiteralPath $historyDir -Directory | Sort-Object Name -Descending)
    $dropped = @()

    if ($Keep -lt 0) { $Keep = 0 }
    if ($all.Count -gt $Keep) {
        foreach ($d in $all[$Keep..($all.Count - 1)]) {
            try { Remove-Item -LiteralPath $d.FullName -Recurse -Force; $dropped += $d.Name } catch { }
        }
    }

    return $dropped
}

function New-CombinedPem {
    <#
      Posh-ACME writes cert.cer, chain.cer, fullchain.cer, cert.key and the two
      .pfx files, but not the single "certificate + chain + key" file most
      appliances want pasted in. Build it here: leaf, then intermediates, then
      the private key. fullchain.cer is already leaf+chain in that order.
    #>
    param([string]$FullChainPath, [string]$KeyPath, [string]$Destination)

    if (-not (Test-Path $FullChainPath)) { throw "Expected fullchain at $FullChainPath but it was not there." }
    if (-not (Test-Path $KeyPath))       { throw "Expected private key at $KeyPath but it was not there." }

    $chain = (Get-Content $FullChainPath -Raw -Encoding UTF8).Trim()
    $key   = (Get-Content $KeyPath -Raw -Encoding UTF8).Trim()

    Write-TextFileAtomic -Path $Destination -Content ($chain + "`n" + $key + "`n")
    return $Destination
}

# A zone name becomes a folder name and a download filename, so it must not be
# able to walk out of certs/. Reject anything that is not a plain DNS label set.
function Test-SafeCertName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name.Length -gt 253)                { return $false }
    if ($Name -match '\.\.')                 { return $false }
    return ($Name -match '^[a-z0-9][a-z0-9.\-]*$')
}

# --------------------------------------------------------------------------- #
# Deployment targets
# --------------------------------------------------------------------------- #
# A third profile type alongside DNS providers and certificate authorities, and
# deliberately the same shape: a catalog entry describes the fields, values live
# in settings.json, and anything marked Secret goes to the DPAPI store instead.

$script:TargetCatalog = @{
    'haproxy-dataplane' = @{
        Label = 'HAProxy (Data Plane API)'
        Args  = @(
            @{ Name = 'user';     Label = 'API username'; Secret = $false; Type = 'text'
               Hint  = 'From the HAProxy userlist that dataplaneapi.yml points at.' }
            @{ Name = 'password'; Label = 'API password'; Secret = $true;  Type = 'text' }
            @{ Name = 'remoteName'; Label = 'Certificate filename on HAProxy'; Secret = $false; Type = 'text'
               Hint  = 'Inside the Data Plane API ssl_certs_dir. Leave blank for "<cert>.pem". This is the certificate IDENTITY to HAProxy - it must never change between renewals, so no dates in it.' }
            @{ Name = 'crtList';  Label = 'crt-list path (optional)'; Secret = $false; Type = 'text'
               Hint  = 'e.g. /etc/haproxy/ssl/crt-list.txt, exactly as it appears on the bind line. When set, a pushed certificate the list does not reference yet is appended and hot-loaded, so a brand-new certificate starts serving without a config edit. Must live inside ssl_certs_dir.' }
            @{ Name = 'verifyPort'; Label = 'Port to verify on'; Secret = $false; Type = 'text'
               Hint  = 'Usually 443. Verification connects to each node here and reads what it actually serves.' }
            @{ Name = 'insecureTls'; Label = 'Skip TLS verification of the API endpoint'; Secret = $false; Type = 'bool'
               Hint  = 'Only for a Data Plane API using a self-signed certificate. It does not affect certificate verification, which never trusts anything anyway.' }
        )
    }
}

# Nodes are stored separately from the catalog args because they are a list, not
# a scalar: one target is a group of load balancers sharing credentials and a
# certificate set. Verification is still per node - that is the whole point.
function Get-TargetProfile {
    param([hashtable]$Settings, [string]$TargetId)

    if (-not $Settings.ContainsKey('targets')) { return $null }
    $match = @(@($Settings.targets) | Where-Object { $_.id -eq $TargetId })
    if ($match.Count) { return $match[0] }
    return $null
}

function Get-TargetArg {
    param([hashtable]$Target, [string]$Name, $Default = $null)

    if ($Target.ContainsKey('args') -and $Target.args -and $Target.args.ContainsKey($Name)) {
        $v = $Target.args[$Name]
        if ($null -ne $v -and "$v" -ne '') { return $v }
    }
    return $Default
}

# Same "<id>:<argName>" convention the DNS providers and CAs already use, so
# every credential in the tool lives in one DPAPI-encrypted store.
function Get-TargetSecret {
    param([string]$TargetId, [string]$Name)
    return Get-TrackerSecret -Key "$TargetId`:$Name" -AsPlainText
}

# --------------------------------------------------------------------------- #
# HAProxy Data Plane API
# --------------------------------------------------------------------------- #
# Chosen over the raw Runtime API for one reason: the Runtime API is memory-only.
# A certificate pushed that way is live immediately but vanishes on the next
# reload for any unrelated cause, silently reverting to whatever is on disk. The
# Data Plane API storage endpoint writes to disk AND pushes to the runtime
# socket, falling back to a reload only if the runtime push fails. Durable and
# hitless, which is the combination that matters.

$script:DataPlaneApiVersion = @{}

function Get-DataPlaneBaseUrl {
    <#
      Reduce whatever was pasted into the nodes box to scheme://host:port.

      Every Data Plane API example URL in HAProxy's own documentation carries a
      /v3 on the end, so that is what gets copied in. Every path this file builds
      already starts with /v3 or /v2, so leaving it on produces /v3/v3/... - a
      404 that reads like the endpoint is missing rather than like a pasted URL.
      Only a trailing version segment is removed; a base path from a reverse
      proxy in front of the API is left alone.
    #>
    param([string]$BaseUrl)
    $u = ([string]$BaseUrl).Trim().TrimEnd('/')
    return [regex]::Replace($u, '/v\d+$', '')
}

function Invoke-DataPlaneRequest {
    param(
        [string]$BaseUrl,
        [string]$User,
        [string]$Password,
        [string]$Method = 'GET',
        [string]$Path,
        $Body = $null,
        [string]$ContentType = 'application/json',
        [switch]$InsecureTls,
        [int]$TimeoutSeconds = 30
    )

    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        # .NET sends "Expect: 100-continue" on request bodies by default and then
        # waits for the interim response. Plenty of servers and reverse proxies
        # never send it, which shows up as a body that silently never uploads.
        # Certificates are small; the round trip buys nothing here.
        [Net.ServicePointManager]::Expect100Continue = $false
    } catch { }

    $uri = (Get-DataPlaneBaseUrl $BaseUrl) + $Path

    # ServerCertificateValidationCallback is process-global on PS 5.1 - there is
    # no per-request option. Save and restore it so one target's self-signed API
    # certificate cannot quietly disable validation for everything else.
    $savedCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
    try {
        if ($InsecureTls) {
            [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        }

        # HttpWebRequest rather than Invoke-RestMethod. IRM's *first* call in a
        # process reliably fails against a Data Plane API over TLS with "the
        # underlying connection was closed: an unexpected error occurred on a
        # send" - the handshake completes, the send does not, and every later
        # call in the same process then succeeds. Since serve.ps1 launches a
        # fresh PowerShell per job, that first call is the only call, so the
        # symptom was every test and every push failing. HttpWebRequest is
        # reliable cold, and it also keeps the response object on a 4xx, which
        # is what carries the status code into the message below.
        $req = [Net.HttpWebRequest]::Create($uri)
        $req.Method           = $Method
        $req.Timeout          = $TimeoutSeconds * 1000
        $req.ReadWriteTimeout = $TimeoutSeconds * 1000
        $req.Accept           = 'application/json'
        # Send credentials unasked. A NetworkCredential waits to be challenged,
        # and costs an extra round trip on every request to do it.
        $auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${User}:${Password}"))
        $req.Headers.Add('Authorization', "Basic $auth")

        if ($null -ne $Body) {
            $bytes = if ($Body -is [byte[]]) { $Body }
                     else { [Text.Encoding]::UTF8.GetBytes([string]$Body) }
            $req.ContentType   = $ContentType
            $req.ContentLength = $bytes.Length
            $rs = $req.GetRequestStream()
            try { $rs.Write($bytes, 0, $bytes.Length) } finally { $rs.Dispose() }
        }

        $resp = $req.GetResponse()
        try {
            $sr = New-Object IO.StreamReader($resp.GetResponseStream())
            $raw = $sr.ReadToEnd(); $sr.Dispose()
        }
        finally { $resp.Close() }

        if (-not $raw) { return $null }
        try { return ($raw | ConvertFrom-Json) } catch { return $raw }
    }
    catch [Net.WebException] {
        $wex = $_.Exception
        # Captured out here on purpose: inside the switch below, $_ is the
        # switch's input ($status), not the error record, so reading
        # $_.Exception.Message in the default branch yields nothing at all.
        $transport = $wex.Message

        $status = $null; $detail = $null
        if ($wex.Response) {
            try { $status = [int]$wex.Response.StatusCode } catch { }
            try {
                $sr = New-Object IO.StreamReader($wex.Response.GetResponseStream())
                $errRaw = $sr.ReadToEnd(); $sr.Dispose()
                $parsed = $errRaw | ConvertFrom-Json
                if ($parsed.message) { $detail = $parsed.message } elseif ($errRaw) { $detail = $errRaw }
            } catch { }
        }

        $msg = switch ($status) {
            401     { 'authentication failed - check the Data Plane API username and password' }
            403     { 'authorised but forbidden - the user may lack write permission' }
            404     { 'endpoint not found - check the URL and API version' }
            409     { 'conflict - either a file of that name already exists, or the configuration version moved on mid-flight' }
            default { $transport }
        }
        if ($detail) { $msg = "$msg ($detail)" }
        throw "$Method $Path -> $(if ($status) { "HTTP $status" } else { 'no response' }): $msg"
    }
    catch {
        throw "$Method $Path -> no response: $($_.Exception.Message)"
    }
    finally {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = $savedCallback
    }
}

function Get-DataPlaneApiVersion {
    <#
      Probe /v3 first, fall back to /v2. HAPEE 3.0 serves v3; older builds serve
      v2, and pinning either one would break on upgrade. Cached per base URL for
      the life of the process.
    #>
    param([string]$BaseUrl, [string]$User, [string]$Password, [switch]$InsecureTls)

    # Normalise before caching, so a URL pasted with a /v3 on it and the same URL
    # without one are not probed twice and cached under two keys.
    $BaseUrl = Get-DataPlaneBaseUrl $BaseUrl

    if ($script:DataPlaneApiVersion.ContainsKey($BaseUrl)) {
        return $script:DataPlaneApiVersion[$BaseUrl]
    }

    $lastError = $null
    foreach ($v in @('v3', 'v2')) {
        try {
            [void](Invoke-DataPlaneRequest -BaseUrl $BaseUrl -User $User -Password $Password `
                     -Path "/$v/services/haproxy/configuration/version" -InsecureTls:$InsecureTls -TimeoutSeconds 15)
            $script:DataPlaneApiVersion[$BaseUrl] = $v
            return $v
        }
        catch {
            $lastError = ($_.Exception.Message -split "`n")[0].Trim()
            # A 401 means we reached the API and it works - the credentials are
            # simply wrong. Retrying under a different version prefix would only
            # produce a more confusing error, so surface this one.
            if ($lastError -match 'HTTP 401|HTTP 403') { throw }
        }
    }

    # Carry the last real response through. "Nothing answered" when the node in
    # fact replied 500 sends people hunting for a network fault that is not
    # there; the server's own error is the useful thing to report.
    if ($lastError) { throw "No usable Data Plane API at $BaseUrl (tried /v3 and /v2). Last response: $lastError" }
    throw "No Data Plane API answered at $BaseUrl on /v3 or /v2."
}

function Get-DataPlaneConfigVersion {
    param([string]$BaseUrl, [string]$User, [string]$Password, [string]$ApiVersion, [switch]$InsecureTls)

    $v = Invoke-DataPlaneRequest -BaseUrl $BaseUrl -User $User -Password $Password `
            -Path "/$ApiVersion/services/haproxy/configuration/version" -InsecureTls:$InsecureTls
    return [int]$v
}

function Get-HAProxyCertificates {
    <#
      Every certificate in the Data Plane API's ssl_certs_dir. Used by Test
      connection, and to decide whether a push is a replace or a first upload.
    #>
    param([string]$BaseUrl, [string]$User, [string]$Password, [string]$ApiVersion, [switch]$InsecureTls)

    $resp = Invoke-DataPlaneRequest -BaseUrl $BaseUrl -User $User -Password $Password `
                -Path "/$ApiVersion/services/haproxy/storage/ssl_certificates" -InsecureTls:$InsecureTls

    $names = @()
    foreach ($c in @($resp)) {
        if ($c.storage_name) { $names += [string]$c.storage_name }
        elseif ($c.file)     { $names += [string]$c.file }
        elseif ($c -is [string]) { $names += $c }
    }
    return @($names)
}

function Get-HAProxyFrontends {
    <#
      Which frontends this node terminates TLS on, and for each: the port it
      binds and the crt-list (or single crt) it loads certificates from.

      Strictly read-only, and that boundary is the point. Cert Camel writes
      certificate storage and crt-list entries, never a bind line and never a
      frontend, so it can sit alongside whatever config management owns
      haproxy.cfg. This exists so the operator picks a frontend from a list
      instead of retyping a path and a port that the node already knows - the
      entire class of typo that the filename-rewrite warning exists to catch.

      Frontends with no TLS bind are skipped: there is nothing to deploy a
      certificate to.
    #>
    param([string]$BaseUrl, [string]$User, [string]$Password, [string]$ApiVersion, [switch]$InsecureTls)

    $out = @()
    $frontends = Invoke-DataPlaneRequest -BaseUrl $BaseUrl -User $User -Password $Password `
                    -Path "/$ApiVersion/services/haproxy/configuration/frontends" -InsecureTls:$InsecureTls

    foreach ($fe in @($frontends)) {
        $name = [string]$fe.name
        if (-not $name) { continue }

        $binds = @()
        try {
            $binds = @(Invoke-DataPlaneRequest -BaseUrl $BaseUrl -User $User -Password $Password `
                        -Path "/$ApiVersion/services/haproxy/configuration/frontends/$([Uri]::EscapeDataString($name))/binds" `
                        -InsecureTls:$InsecureTls)
        }
        catch { continue }   # a frontend whose binds cannot be read is not a usable target

        foreach ($b in $binds) {
            if (-not $b.ssl) { continue }
            $out += @{
                frontend = $name
                port     = $(if ($b.port) { [int]$b.port } else { $null })
                crtList  = [string]$b.crt_list
                crt      = [string]$b.crt
            }
        }
    }
    return @($out)
}

function Get-NormalisedStorageName {
    # The Data Plane API's own rewrite: interior dots become underscores, the
    # extension is kept. "www.example.com.pem" -> "www_example_com.pem".
    param([string]$Name)
    $ext  = [IO.Path]::GetExtension($Name)
    $base = if ($ext) { $Name.Substring(0, $Name.Length - $ext.Length) } else { $Name }
    return (($base -replace '\.', '_') + $ext)
}

function Resolve-StoredCertificateName {
    <#
      Work out what name the Data Plane API has actually filed a certificate
      under, which is not necessarily the name it was given.

      The API rewrites interior dots to underscores, so "www.example.com.pem" is
      stored as "www_example_com.pem". Every certificate is named after a domain,
      so every certificate hits this. The first push creates the rewritten name
      quite happily; the next one looks for the name it asked for, does not find
      it, decides the file is new, tries to create it and gets a 409. The result
      is a deployment that works once and then fails on every renewal after it -
      months later, unattended, with nobody watching.

      Matching is done against the names the API reports rather than by trusting
      the rewrite rule, so a build that rewrites differently still resolves.
      Returns the stored name, or $null when it genuinely is not there yet.
    #>
    param([string[]]$Existing, [string]$RemoteName)

    if (@($Existing) -contains $RemoteName) { return $RemoteName }

    $want = Get-NormalisedStorageName $RemoteName
    foreach ($e in @($Existing)) {
        if ($e -eq $want -or (Get-NormalisedStorageName $e) -eq $want) { return $e }
    }
    return $null
}

function Push-CertificateToNode {
    <#
      Upload a combined PEM to one HAProxy node.

      Replace (PUT) when the file already exists, create (POST, multipart) when
      it does not. The distinction matters: PUT against a name HAProxy has never
      seen returns 404, and POST against one it has returns a conflict.

      force_reload and skip_reload are deliberately not passed. skip_reload
      suppresses the fallback, so a failed runtime push would leave disk and
      memory diverged with no error - the exact silent failure this whole design
      exists to avoid. The default (runtime push, reload only if that fails) is
      what is wanted.
    #>
    param(
        [string]$BaseUrl, [string]$User, [string]$Password,
        [string]$RemoteName, [string]$PemContent,
        [switch]$InsecureTls
    )

    $out = @{ node = $BaseUrl; remoteName = $RemoteName; ok = $false
              action = $null; apiVersion = $null; error = $null
              storedName = $null; renamed = $false }

    try {
        $api = Get-DataPlaneApiVersion -BaseUrl $BaseUrl -User $User -Password $Password -InsecureTls:$InsecureTls
        $out.apiVersion = $api

        $existing = @()
        try { $existing = Get-HAProxyCertificates -BaseUrl $BaseUrl -User $User -Password $Password -ApiVersion $api -InsecureTls:$InsecureTls } catch { }

        # Match on what the API reports, not on the name we asked for - see
        # Resolve-StoredCertificateName. An exact-match test here is what makes a
        # second push try to create a file that is already there.
        $stored    = Resolve-StoredCertificateName -Existing $existing -RemoteName $RemoteName
        $isReplace = [bool]$stored

        $cfgVer = Get-DataPlaneConfigVersion -BaseUrl $BaseUrl -User $User -Password $Password -ApiVersion $api -InsecureTls:$InsecureTls

        if ($isReplace) {
            $out.action     = 'replace'
            $out.storedName = $stored
            $out.renamed    = ($stored -ne $RemoteName)
            [void](Invoke-DataPlaneRequest -BaseUrl $BaseUrl -User $User -Password $Password `
                     -Method 'PUT' -ContentType 'text/plain' -Body $PemContent -InsecureTls:$InsecureTls `
                     -Path "/$api/services/haproxy/storage/ssl_certificates/$stored`?version=$cfgVer")
        }
        else {
            $out.action = 'create'
            # multipart/form-data by hand: Invoke-RestMethod -Form is PS 6+.
            $boundary = [Guid]::NewGuid().ToString('n')
            $lf = "`r`n"
            $body = "--$boundary$lf" +
                    "Content-Disposition: form-data; name=`"file_upload`"; filename=`"$RemoteName`"$lf" +
                    "Content-Type: application/octet-stream$lf$lf" +
                    $PemContent + $lf +
                    "--$boundary--$lf"

            [void](Invoke-DataPlaneRequest -BaseUrl $BaseUrl -User $User -Password $Password `
                     -Method 'POST' -ContentType "multipart/form-data; boundary=$boundary" `
                     -Body $body -InsecureTls:$InsecureTls `
                     -Path "/$api/services/haproxy/storage/ssl_certificates`?version=$cfgVer")

            # Ask what it ended up called rather than assuming the name survived.
            # HAProxy loads certificates by path, so if the API filed this under a
            # rewritten name, that rewritten name is what the bind line has to
            # reference - and the operator needs telling, now, not at renewal.
            try {
                $after = Get-HAProxyCertificates -BaseUrl $BaseUrl -User $User -Password $Password `
                             -ApiVersion $api -InsecureTls:$InsecureTls
                $found = Resolve-StoredCertificateName -Existing $after -RemoteName $RemoteName
                if ($found) {
                    $out.storedName = $found
                    $out.renamed    = ($found -ne $RemoteName)
                }
            } catch { }
        }

        if (-not $out.storedName) { $out.storedName = $RemoteName }
        $out.ok = $true
    }
    catch { $out.error = ($_.Exception.Message -split "`n")[0].Trim() }

    return $out
}

function Sync-HAProxyCrtList {
    <#
      Make sure a pushed certificate is referenced by the node's crt-list, so a
      brand-new certificate starts being served without anyone editing HAProxy
      config. Without this, uploading a file HAProxy has never heard of is a
      push into the void: the API says 200, the file sits in ssl_certs_dir, and
      no bind line ever reads it - T1 green, T3 red, and nothing in between
      explains why.

      Everything here was verified against a live Data Plane API rather than
      taken from the docs:

        - A crt-list is addressed by its storage_name (the basename), not its
          path - the same name-mangling family as certificate uploads.
        - Appending an entry is one POST to storage/.../entries with
          {file: <full path>}. It appends, never prepends, which matters
          because the FIRST entry is what unmatched SNI falls back to.
        - The storage POST alone triggers the API's reload pipeline; the
          running process picks the entry up within a few seconds. Do NOT also
          call the runtime entries endpoint - that stacks a second, duplicate
          entry on top of the one the reload just loaded.
        - The runtime entries listing reflects the live process, so polling it
          is the proof the entry is actually being served from, not just
          written to disk.
    #>
    param(
        [string]$BaseUrl, [string]$User, [string]$Password, [string]$ApiVersion,
        # The crt-list path exactly as it appears on the node's bind line.
        [string]$CrtListPath,
        # The certificate's storage name on the node (after any dot rewriting).
        [string]$CertStorageName,
        [switch]$InsecureTls,
        [int]$LoadTimeoutSeconds = 15
    )

    $out = @{ ok = $false; action = $null; runtimeLoaded = $false; error = $null }

    try {
        # Which storage object is that path? The API only manages crt-lists
        # inside ssl_certs_dir, so a path outside it simply will not be here.
        $lists = @(Invoke-DataPlaneRequest -BaseUrl $BaseUrl -User $User -Password $Password `
                     -Path "/$ApiVersion/services/haproxy/storage/ssl_crt_lists" -InsecureTls:$InsecureTls)
        $list = @($lists | Where-Object { $_.file -eq $CrtListPath }) | Select-Object -First 1
        if (-not $list) {
            $known = (@($lists | ForEach-Object { $_.file }) -join ', ')
            throw "The Data Plane API does not manage a crt-list at '$CrtListPath'.$(if ($known) { " It manages: $known." } else { ' It manages none - the crt-list must live inside ssl_certs_dir.' })"
        }
        $storageName = [string]$list.storage_name

        # The full path the entry must carry. Read it from the certificate's own
        # storage record rather than assembling it, falling back to "same
        # directory as the crt-list" only when the record does not say.
        $certPath = $null
        $certs = @(Invoke-DataPlaneRequest -BaseUrl $BaseUrl -User $User -Password $Password `
                     -Path "/$ApiVersion/services/haproxy/storage/ssl_certificates" -InsecureTls:$InsecureTls)
        $rec = @($certs | Where-Object { $_.storage_name -eq $CertStorageName }) | Select-Object -First 1
        if ($rec -and $rec.file) { $certPath = [string]$rec.file }
        else { $certPath = ($CrtListPath -replace '/[^/]+$', '') + '/' + $CertStorageName }

        $entries = @(Invoke-DataPlaneRequest -BaseUrl $BaseUrl -User $User -Password $Password `
                       -Path "/$ApiVersion/services/haproxy/storage/ssl_crt_lists/$storageName/entries" -InsecureTls:$InsecureTls)
        if (@($entries | Where-Object { $_.file -eq $certPath }).Count) {
            $out.action = 'present'
        }
        else {
            [void](Invoke-DataPlaneRequest -BaseUrl $BaseUrl -User $User -Password $Password -Method 'POST' `
                     -Path "/$ApiVersion/services/haproxy/storage/ssl_crt_lists/$storageName/entries" `
                     -Body (@{ file = $certPath } | ConvertTo-Json -Compress) -InsecureTls:$InsecureTls)
            $out.action = 'added'
        }

        # Disk is not serving; the running process is. Poll the runtime list
        # until the entry lands (the reload takes a couple of seconds) so the
        # caller's T3 check that follows is not racing the reload.
        $listEnc  = [Uri]::EscapeDataString($CrtListPath)
        $deadline = (Get-Date).AddSeconds($LoadTimeoutSeconds)
        do {
            $rt = @(Invoke-DataPlaneRequest -BaseUrl $BaseUrl -User $User -Password $Password `
                      -Path "/$ApiVersion/services/haproxy/runtime/ssl_crt_lists/entries?name=$listEnc" -InsecureTls:$InsecureTls)
            if (@($rt | Where-Object { $_.file -eq $certPath }).Count) { $out.runtimeLoaded = $true; break }
            Start-Sleep -Seconds 2
        } while ((Get-Date) -lt $deadline)

        if (-not $out.runtimeLoaded) {
            throw "The crt-list file now references '$certPath', but the running process has not loaded it after $LoadTimeoutSeconds seconds - disk and memory have diverged. A reload on the node should reconcile them."
        }

        $out.ok = $true
    }
    catch { $out.error = ($_.Exception.Message -split "`n")[0].Trim() }

    return $out
}

# --------------------------------------------------------------------------- #
# Certificate bundle validation  (verification tier T0)
# --------------------------------------------------------------------------- #
# Run before anything is pushed anywhere. Deploying a broken bundle to six load
# balancers is the worst outcome this tool can produce, and it is entirely
# preventable: everything below is checkable locally, in milliseconds, with no
# network involved.

function Read-PemBlocks {
    <#
      Split a PEM into its labelled blocks. Returns objects with Label (e.g.
      "CERTIFICATE", "PRIVATE KEY") and Der (the decoded bytes).
    #>
    param([string]$Text)

    $blocks = @()
    foreach ($m in [regex]::Matches($Text,
        '-----BEGIN (?<label>[A-Z0-9 ]+)-----(?<b64>[\s\S]*?)-----END \k<label>-----')) {
        $der = $null
        try { $der = [Convert]::FromBase64String(($m.Groups['b64'].Value -replace '\s','')) } catch { }
        $blocks += [pscustomobject]@{ Label = $m.Groups['label'].Value.Trim(); Der = $der }
    }
    return $blocks
}

function Get-RsaModulusFromKeyDer {
    <#
      Pull the RSA modulus out of a private key so it can be compared against the
      certificate's. This is the check that catches a certificate and key from
      different orders being stitched together - the one failure mode that looks
      perfectly valid on inspection and takes the site down on deployment.

      Hand-rolled ASN.1 because .NET Framework has no PEM key import;
      RSA.ImportRSAPrivateKey arrived in .NET Core 3.0. Only the shape needed is
      parsed, not a general DER decoder.

        PKCS#1  RSAPrivateKey ::= SEQUENCE { version INTEGER, modulus INTEGER, ... }
        PKCS#8  PrivateKeyInfo ::= SEQUENCE { version INTEGER,
                                              algorithm SEQUENCE,
                                              privateKey OCTET STRING (a PKCS#1 blob) }

      Returns $null for anything not RSA - EC keys have no modulus, and are
      reported as "not verified" rather than failed.
    #>
    param([byte[]]$Der, [string]$Label)

    if (-not $Der) { return $null }

    $pos = 0
    function Read-Len {
        param([byte[]]$B, [ref]$P)
        $first = $B[$P.Value]; $P.Value++
        if ($first -lt 0x80) { return [int]$first }
        $n = $first -band 0x7F
        $len = 0
        for ($i = 0; $i -lt $n; $i++) { $len = ($len -shl 8) -bor $B[$P.Value]; $P.Value++ }
        return $len
    }

    try {
        if ($Der[$pos] -ne 0x30) { return $null }        # outer SEQUENCE
        $pos++; [void](Read-Len $Der ([ref]$pos))

        if ($Der[$pos] -ne 0x02) { return $null }        # version INTEGER
        $pos++
        $vLen = Read-Len $Der ([ref]$pos)
        $pos += $vLen

        if ($Label -eq 'PRIVATE KEY') {
            # PKCS#8: skip the algorithm SEQUENCE, then unwrap the OCTET STRING
            # and recurse into the PKCS#1 structure it contains.
            if ($Der[$pos] -ne 0x30) { return $null }
            $pos++
            $aLen = Read-Len $Der ([ref]$pos)
            $pos += $aLen

            if ($Der[$pos] -ne 0x04) { return $null }    # OCTET STRING
            $pos++
            $oLen = Read-Len $Der ([ref]$pos)
            $inner = New-Object byte[] $oLen
            [Array]::Copy($Der, $pos, $inner, 0, $oLen)
            return Get-RsaModulusFromKeyDer -Der $inner -Label 'RSA PRIVATE KEY'
        }

        if ($Der[$pos] -ne 0x02) { return $null }        # modulus INTEGER
        $pos++
        $mLen = Read-Len $Der ([ref]$pos)
        $mod = New-Object byte[] $mLen
        [Array]::Copy($Der, $pos, $mod, 0, $mLen)

        # DER signs its INTEGERs, so a high bit set means a leading 0x00 pad that
        # the certificate's raw modulus will not have.
        if ($mod.Length -gt 1 -and $mod[0] -eq 0) {
            $trimmed = New-Object byte[] ($mod.Length - 1)
            [Array]::Copy($mod, 1, $trimmed, 0, $trimmed.Length)
            $mod = $trimmed
        }
        return $mod
    }
    catch { return $null }
}

function Get-CertificateSanNames {
    <#
      Every DNS name a certificate covers, lower-cased and de-duplicated.

      .NET Framework has no typed SAN extension class (that arrived in .NET 7),
      so the extension is formatted to text and parsed. The label on each line is
      LOCALISED - "DNS Name=" in English, something else elsewhere - so match on
      the value after the "=" rather than on the label, then keep only values
      shaped like hostnames. That drops IP, email and URI entries, and any label
      wording we did not anticipate.

      check-ssl.ps1 carries its own copy of this on purpose: it runs the parse
      inside a runspace, which cannot see functions defined out here.
    #>
    param($Certificate)

    $found = @()
    if (-not $Certificate) { return $found }
    $ext = $Certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' }
    if (-not $ext) { return $found }

    foreach ($line in (($ext.Format($true)) -split "`r?`n")) {
        if ($line -notmatch '=\s*(?<v>\S+)\s*$') { continue }
        $v = $Matches.v.Trim().TrimEnd('.').ToLowerInvariant()
        if ($v -match '^(\*\.)?([a-z0-9]([a-z0-9\-]*[a-z0-9])?\.)+[a-z]{2,}$' -and $found -notcontains $v) {
            $found += $v
        }
    }
    return $found
}

function Test-NameCoveredBySans {
    <#
      Would a TLS client accept this certificate for this name? Matches RFC 6125
      wildcard rules, which are narrower than people expect and are the whole
      reason the apex keeps causing trouble:

        *.example.com  matches  a.example.com
        *.example.com  does NOT match  example.com        (no label to consume)
        *.example.com  does NOT match  a.b.example.com    (one label only)

      Used to tell "someone else's certificate is winning this name" (a
      configuration fact) apart from "this node is serving something that has
      nothing to do with the name I asked for" (genuinely broken).
    #>
    param([string[]]$Sans, [string]$Name)

    if (-not $Name) { return $false }
    $n = $Name.Trim().TrimEnd('.').ToLowerInvariant()

    foreach ($s in @($Sans)) {
        $san = ([string]$s).Trim().TrimEnd('.').ToLowerInvariant()
        if (-not $san) { continue }
        if ($san -eq $n) { return $true }

        if ($san.StartsWith('*.')) {
            $suffix = $san.Substring(1)          # ".example.com"
            if (-not $n.EndsWith($suffix)) { continue }
            # Exactly one label may be consumed, so what precedes the suffix must
            # not itself contain a dot.
            $label = $n.Substring(0, $n.Length - $suffix.Length)
            if ($label -and $label.IndexOf('.') -lt 0) { return $true }
        }
    }
    return $false
}

function Test-CertificateBundle {
    <#
      Validate a combined PEM before it goes anywhere. Returns a result object
      with ok, plus per-check detail so the log can say which part failed rather
      than just "invalid".
    #>
    param(
        [string]$Path,
        [string[]]$ExpectedNames = @(),
        [int]$MinimumDaysRemaining = 1
    )

    $result = @{
        ok = $false; path = $Path; checks = @(); errors = @()
        serial = $null; notAfter = $null; notBefore = $null; subject = $null
        issuer = $null; names = @(); chainCount = 0; keyType = $null
    }
    function Add-Check { param($Name, $Pass, $Detail)
        $result.checks += @{ name = $Name; pass = [bool]$Pass; detail = $Detail }
        if (-not $Pass) { $result.errors += "$Name - $Detail" }
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-Check 'file exists' $false "no file at $Path"
        return $result
    }

    $text   = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($Path))
    $blocks = Read-PemBlocks -Text $text
    $certs  = @($blocks | Where-Object { $_.Label -eq 'CERTIFICATE' -and $_.Der })
    $keys   = @($blocks | Where-Object { $_.Label -like '*PRIVATE KEY' -and $_.Der })

    Add-Check 'PEM parses' ($blocks.Count -gt 0) "$($blocks.Count) block(s)"
    Add-Check 'has a certificate' ($certs.Count -ge 1) "$($certs.Count) certificate block(s)"
    Add-Check 'exactly one private key' ($keys.Count -eq 1) "$($keys.Count) key block(s)"
    if ($certs.Count -lt 1 -or $keys.Count -ne 1) { return $result }

    # HAProxy wants leaf first, then intermediates, then the key. A bundle
    # assembled in another order still loads but the leaf would be misidentified
    # here, so check it rather than assume.
    $leaf = $null
    try { $leaf = New-Object Security.Cryptography.X509Certificates.X509Certificate2 (,$certs[0].Der) }
    catch { Add-Check 'leaf parses' $false $_.Exception.Message; return $result }
    Add-Check 'leaf parses' $true $leaf.Subject

    $result.serial     = $leaf.SerialNumber
    $result.notAfter   = $leaf.NotAfter.ToString('o')
    $result.notBefore  = $leaf.NotBefore.ToString('o')
    $result.subject    = $leaf.Subject
    $result.issuer     = $leaf.Issuer
    $result.chainCount = $certs.Count - 1

    $now  = Get-Date
    $days = [math]::Floor(($leaf.NotAfter - $now).TotalDays)
    Add-Check 'not expired' ($days -ge $MinimumDaysRemaining) "$days day(s) remaining"
    Add-Check 'already valid' ($leaf.NotBefore -le $now) "valid from $($leaf.NotBefore.ToString('yyyy-MM-dd'))"

    # A leaf on its own will fail validation for most clients, because they have
    # no way to build a path to the root. Publicly-trusted CAs always issue via
    # an intermediate, so a single-certificate bundle is almost always a mistake.
    Add-Check 'chain included' ($certs.Count -ge 2) "$($certs.Count - 1) intermediate(s)"

    $sans = @(Get-CertificateSanNames -Certificate $leaf)
    $result.names = @($sans)

    if ($ExpectedNames.Count) {
        $missing = @()
        foreach ($n in $ExpectedNames) {
            $nl = $n.ToLowerInvariant()
            if ($sans -notcontains $nl) { $missing += $nl }
        }
        Add-Check 'covers expected names' ($missing.Count -eq 0) $(
            if ($missing.Count) { "missing: $($missing -join ', ')" } else { "$($sans.Count) name(s)" })
    }

    # The one that matters most.
    $certMod = $null
    try {
        $rsa = $leaf.PublicKey.Key -as [Security.Cryptography.RSA]
        if ($rsa) { $certMod = $rsa.ExportParameters($false).Modulus; $result.keyType = 'RSA' }
        else { $result.keyType = $leaf.PublicKey.Oid.FriendlyName }
    } catch { }

    if ($certMod) {
        $keyMod = Get-RsaModulusFromKeyDer -Der $keys[0].Der -Label $keys[0].Label
        if (-not $keyMod) {
            Add-Check 'key matches certificate' $false 'could not read the private key modulus'
        } else {
            $match = ($keyMod.Length -eq $certMod.Length)
            if ($match) { for ($i = 0; $i -lt $keyMod.Length; $i++) { if ($keyMod[$i] -ne $certMod[$i]) { $match = $false; break } } }
            Add-Check 'key matches certificate' $match $(
                if ($match) { "RSA $($certMod.Length * 8)-bit" } else { 'the private key belongs to a DIFFERENT certificate' })
        }
    }
    else {
        # EC keys have no modulus to compare, and deriving the public point from
        # the private key is not available on .NET Framework. Say so rather than
        # implying the pair was checked.
        $result.checks += @{ name = 'key matches certificate'; pass = $true
                             detail = "not verified - $($result.keyType) key, RSA-only check" }
    }

    $result.ok = (@($result.checks | Where-Object { -not $_.pass }).Count -eq 0)
    return $result
}

# --------------------------------------------------------------------------- #
# Served-certificate probe  (verification tier T3)
# --------------------------------------------------------------------------- #

function Get-ServedCertificate {
    <#
      Read the certificate a specific endpoint actually serves for a given SNI.

      The connect address and the SNI name are separate parameters on purpose.
      Verification has to reach ONE NODE by its own address while asking for a
      name that node serves - connecting to the name instead would resolve to the
      VIP, and with a floating VIP that only ever tests whichever node currently
      holds it. A stale standby stays invisible until failover.
    #>
    param(
        [string]$ConnectHost,
        [int]$Port = 443,
        [string]$SniName,
        [int]$TimeoutSeconds = 8
    )

    if (-not $SniName) { $SniName = $ConnectHost }

    $client = $null; $stream = $null
    try {
        # A parameterless TcpClient is IPv4-only on .NET Framework. That makes it
        # refuse an IPv6 literal outright ("none of the discovered addresses match
        # the socket address family"), and - worse, because it looks like the node
        # is down - it makes a dual-stack hostname try only its A record. A host
        # reachable on AAAA but not A then reports a flat connection refusal with
        # nothing pointing at why. An IPv6 socket in dual mode reaches both, with
        # IPv4 arriving as ::ffff:x.x.x.x.
        try {
            $client = New-Object Net.Sockets.TcpClient([Net.Sockets.AddressFamily]::InterNetworkV6)
            $client.Client.DualMode = $true
        }
        catch {
            # IPv6 disabled at the OS level. Fall back rather than fail.
            $client = New-Object Net.Sockets.TcpClient
        }
        $client.ReceiveTimeout = $TimeoutSeconds * 1000
        $client.SendTimeout    = $TimeoutSeconds * 1000

        $connect = $client.ConnectAsync($ConnectHost, $Port)
        $completed = $false
        try   { $completed = $connect.Wait($TimeoutSeconds * 1000) }
        catch { throw $_.Exception.GetBaseException() }
        if (-not $completed) { throw "Timed out connecting to ${ConnectHost}:$Port" }

        # Accept anything: the point is to inspect what is served, including a
        # certificate that is expired, self-signed or for the wrong name.
        $validate = [Net.Security.RemoteCertificateValidationCallback] { $true }
        $stream = New-Object Net.Security.SslStream($client.GetStream(), $false, $validate)
        $stream.AuthenticateAsClient($SniName)

        New-Object Security.Cryptography.X509Certificates.X509Certificate2 $stream.RemoteCertificate
    }
    finally {
        if ($stream) { $stream.Dispose() }
        if ($client) { $client.Close() }
    }
}

function Test-ServedCertificate {
    <#
      T3: is the expected certificate the one this endpoint is actually serving?

      Compares SERIAL, not expiry. A serial is unique per issuance, so it is the
      only value that identifies a specific certificate. Two certificates issued
      the same day have indistinguishable expiry dates, which is why "days
      remaining went up" is reassurance and not evidence. Days remaining is still
      reported, because it is the number a human wants to see.
    #>
    param(
        [string]$ConnectHost,
        [int]$Port = 443,
        [string]$SniName,
        [string]$ExpectedSerial,
        [int]$TimeoutSeconds = 8
    )

    $out = @{
        node = "${ConnectHost}:$Port"; sni = $SniName; ok = $false
        servedSerial = $null; expectedSerial = $ExpectedSerial
        notAfter = $null; daysRemaining = $null; issuer = $null; error = $null
        # Set when a DIFFERENT certificate answered but legitimately covers this
        # name. That is a fact about the configuration, not a failed deployment -
        # see the classification note below.
        contested = $false; servedSubject = $null; servedCovers = $false
    }

    try {
        $cert = Get-ServedCertificate -ConnectHost $ConnectHost -Port $Port `
                    -SniName $SniName -TimeoutSeconds $TimeoutSeconds

        $out.servedSerial  = $cert.SerialNumber
        $out.notAfter      = $cert.NotAfter.ToString('o')
        $out.daysRemaining = [math]::Floor(($cert.NotAfter - (Get-Date)).TotalDays)
        $out.issuer        = $cert.Issuer
        $out.servedSubject = $cert.Subject

        if ($ExpectedSerial) {
            $out.ok = ($cert.SerialNumber -eq $ExpectedSerial)
            if (-not $out.ok) {
                # Two very different situations produce a serial mismatch, and
                # conflating them is what made a correct deployment report as a
                # failure:
                #
                #   contested - the certificate being served ALSO covers this
                #               name. Both are valid for it and only one can win
                #               (an exact SNI match beats a wildcard). Nothing is
                #               broken; the operator needs to know which won.
                #   failed    - the certificate being served does not cover this
                #               name at all, so the node is serving something
                #               unrelated. That is genuinely wrong.
                $out.servedCovers = Test-NameCoveredBySans `
                                        -Sans (Get-CertificateSanNames -Certificate $cert) -Name $SniName
                $out.contested = $out.servedCovers

                if ($out.contested) {
                    $out.error = "served by $($cert.Subject) (serial $($cert.SerialNumber)), which also covers this name"
                } else {
                    $out.error = "serving serial $($cert.SerialNumber), expected $ExpectedSerial"
                }
            }
        } else {
            $out.ok = $true   # nothing to compare against; report what is served
        }
    }
    catch { $out.error = ($_.Exception.Message -split "`n")[0].Trim() }

    return $out
}
