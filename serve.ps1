<#
  serve.ps1 - a small local web server that turns the tracker page from a
  read-only report into something with working buttons.

  Opened straight from disk, ssl-tracker.html cannot run anything: file:// has
  no way to invoke PowerShell, call a DNS API, or write to its own folder.
  Served over loopback it can, so this hosts the same page plus a small JSON API
  behind it.

  Started by "Open Tracker.bat". Close that window to stop the server.

  Deliberately TcpListener rather than HttpListener: HttpListener needs a
  "netsh http add urlacl" reservation or an elevated prompt on Windows, and
  this bundle has never required admin. A loopback TcpListener needs neither.
#>

[CmdletBinding()]
param(
    # 0 means "let Windows pick a free port", which avoids colliding with
    # whatever else is already listening.
    [int]$Port = 0,

    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'acme-lib.ps1')

New-TrackerDirectories

# --------------------------------------------------------------------------- #
# Access control
# --------------------------------------------------------------------------- #
# Loopback alone is not access control: every other program on this PC, and any
# web page you happen to have open, can reach 127.0.0.1. Since the API can order
# certificates and hand back private keys, each run mints a token that must
# accompany every request.

$bytes = New-Object byte[] 32
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
$rng.GetBytes($bytes)
$rng.Dispose()
$script:Token = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''

# Constant-time-ish compare so a token cannot be guessed a character at a time.
function Test-Token {
    param([string]$Candidate)

    if ([string]::IsNullOrEmpty($Candidate)) { return $false }
    if ($Candidate.Length -ne $script:Token.Length) { return $false }

    $diff = 0
    for ($i = 0; $i -lt $script:Token.Length; $i++) {
        $diff = $diff -bor ([int]$script:Token[$i] -bxor [int]$Candidate[$i])
    }
    return ($diff -eq 0)
}

# --------------------------------------------------------------------------- #
# Minimal HTTP
# --------------------------------------------------------------------------- #

$script:Mime = @{
    '.html' = 'text/html; charset=utf-8'
    '.js'   = 'application/javascript; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.pem'  = 'application/x-pem-file'
    '.cer'  = 'application/x-x509-ca-cert'
    '.key'  = 'application/octet-stream'
    '.pfx'  = 'application/x-pkcs12'
}

function Read-HttpRequest {
    <#
      Read one request off the wire. Only what this API actually uses is
      supported: a request line, headers, and an optional Content-Length body.
      No chunked encoding, no keep-alive - the connection closes after each
      response, which keeps the whole thing single-threaded and predictable.
    #>
    param([IO.Stream]$Stream)

    $lineBytes = New-Object Collections.Generic.List[byte]
    $headerText = $null
    $prev = -1

    # Read byte by byte until the blank line that ends the headers. Requests are
    # small, and this avoids buffering past the header boundary into the body.
    while ($true) {
        $b = $Stream.ReadByte()
        if ($b -lt 0) { return $null }
        $lineBytes.Add([byte]$b)

        if ($prev -eq 13 -and $b -eq 10) {
            $count = $lineBytes.Count
            if ($count -ge 4 -and
                $lineBytes[$count - 4] -eq 13 -and $lineBytes[$count - 3] -eq 10) {
                $headerText = [Text.Encoding]::ASCII.GetString($lineBytes.ToArray())
                break
            }
        }
        $prev = $b

        if ($lineBytes.Count -gt 65536) { return $null }   # runaway guard
    }

    $lines = $headerText -split "`r`n"
    if ($lines.Count -lt 1 -or -not $lines[0]) { return $null }

    $parts = $lines[0] -split ' '
    if ($parts.Count -lt 2) { return $null }

    $headers = @{}
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if (-not $lines[$i]) { continue }
        $idx = $lines[$i].IndexOf(':')
        if ($idx -lt 1) { continue }
        $headers[$lines[$i].Substring(0, $idx).Trim().ToLowerInvariant()] =
            $lines[$i].Substring($idx + 1).Trim()
    }

    $body = ''
    if ($headers.ContainsKey('content-length')) {
        $len = 0
        [void][int]::TryParse($headers['content-length'], [ref]$len)
        if ($len -gt 0) {
            if ($len -gt 1048576) { return $null }   # 1 MB is far more than any call here needs
            $buf = New-Object byte[] $len
            $read = 0
            while ($read -lt $len) {
                $n = $Stream.Read($buf, $read, $len - $read)
                if ($n -le 0) { break }
                $read += $n
            }
            $body = [Text.Encoding]::UTF8.GetString($buf, 0, $read)
        }
    }

    $rawUrl = $parts[1]
    $path   = $rawUrl
    $query  = ''
    $q = $rawUrl.IndexOf('?')
    if ($q -ge 0) {
        $path  = $rawUrl.Substring(0, $q)
        $query = $rawUrl.Substring($q + 1)
    }

    return @{
        Method  = $parts[0].ToUpperInvariant()
        Path    = [Uri]::UnescapeDataString($path)
        Query   = $query
        Headers = $headers
        Body    = $body
    }
}

function Get-QueryValue {
    param([string]$Query, [string]$Name)

    foreach ($pair in ($Query -split '&')) {
        if (-not $pair) { continue }
        $kv = $pair -split '=', 2
        if ($kv[0] -eq $Name) {
            if ($kv.Count -gt 1) { return [Uri]::UnescapeDataString($kv[1].Replace('+', ' ')) }
            return ''
        }
    }
    return $null
}

function Send-Response {
    param(
        [IO.Stream]$Stream,
        [int]$Status = 200,
        [string]$StatusText = 'OK',
        [string]$ContentType = 'text/plain; charset=utf-8',
        [byte[]]$Body = $null,
        [hashtable]$ExtraHeaders = $null
    )

    if ($null -eq $Body) { $Body = New-Object byte[] 0 }

    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine("HTTP/1.1 $Status $StatusText")
    [void]$sb.AppendLine("Content-Type: $ContentType")
    [void]$sb.AppendLine("Content-Length: $($Body.Length)")
    [void]$sb.AppendLine("Cache-Control: no-store")
    # This UI is local-only; nothing here should ever be framed or sniffed.
    [void]$sb.AppendLine("X-Content-Type-Options: nosniff")
    [void]$sb.AppendLine("X-Frame-Options: DENY")
    [void]$sb.AppendLine("Connection: close")
    if ($ExtraHeaders) {
        foreach ($k in $ExtraHeaders.Keys) { [void]$sb.AppendLine("${k}: $($ExtraHeaders[$k])") }
    }
    [void]$sb.AppendLine()

    $head = [Text.Encoding]::ASCII.GetBytes($sb.ToString())
    $Stream.Write($head, 0, $head.Length)
    if ($Body.Length) { $Stream.Write($Body, 0, $Body.Length) }
    $Stream.Flush()
}

function Send-Json {
    param([IO.Stream]$Stream, $Object, [int]$Status = 200, [string]$StatusText = 'OK')

    $json = $Object | ConvertTo-Json -Depth 10 -Compress
    Send-Response -Stream $Stream -Status $Status -StatusText $StatusText `
        -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json))
}

function Send-Error {
    param([IO.Stream]$Stream, [int]$Status, [string]$Message)

    $text = switch ($Status) {
        400 { 'Bad Request' }; 403 { 'Forbidden' }; 404 { 'Not Found' }
        405 { 'Method Not Allowed' }; default { 'Error' }
    }
    Send-Json -Stream $Stream -Object @{ error = $Message } -Status $Status -StatusText $text
}

# --------------------------------------------------------------------------- #
# API handlers
# --------------------------------------------------------------------------- #

function Get-StateResponse {
    $settings = Get-TrackerSettings
    $zoneCache = Get-ZoneCache
    $checker  = Get-CheckerResults

    $grouping = @{ certs = @(); unmapped = @(); haveZones = $false }
    $groupError = $null
    try {
        $grouping = Get-CertificateGroups -Results @($checker.results) -Settings $settings -ZoneCache $zoneCache
    }
    catch { $groupError = $_.Exception.Message }

    # Report which credentials exist, never the credentials themselves. The page
    # only ever needs to know whether a field is filled in.
    $providers = @()
    foreach ($p in @($settings.providers)) {
        $catalog = $script:PluginCatalog[$p.plugin]
        $argState = @{}
        if ($catalog) {
            foreach ($a in $catalog.Args) {
                $have = ($p.args -and $p.args.ContainsKey($a.Name))
                if ($a.Secret) {
                    # A boolean "is it stored", never the value itself.
                    $argState[$a.Name] = [bool](Test-TrackerSecret -Key "$($p.id):$($a.Name)")
                }
                elseif ($a.Type -eq 'bool') {
                    $argState[$a.Name] = [bool]$(if ($have) { $p.args[$a.Name] } else { $false })
                }
                elseif ($have) { $argState[$a.Name] = [string]$p.args[$a.Name] }
                else { $argState[$a.Name] = '' }
            }
        }
        $providers += @{
            id     = $p.id
            label  = $p.label
            plugin = $p.plugin
            args   = $argState
        }
    }

    $catalogOut = @{}
    foreach ($k in $script:PluginCatalog.Keys) {
        $catalogOut[$k] = @{ label = $script:PluginCatalog[$k].Label; args = @($script:PluginCatalog[$k].Args) }
    }

    # Deployment targets. Same rule as everywhere else: report whether a secret
    # is stored, never the secret.
    $targetsOut = @()
    foreach ($t in @($settings.targets)) {
        $catalog  = $script:TargetCatalog[$t.type]
        $argState = @{}
        if ($catalog) {
            foreach ($a in $catalog.Args) {
                $have = ($t.args -and $t.args.ContainsKey($a.Name))
                if ($a.Secret)            { $argState[$a.Name] = [bool](Test-TrackerSecret -Key "$($t.id):$($a.Name)") }
                elseif ($a.Type -eq 'bool'){ $argState[$a.Name] = [bool]$(if ($have) { $t.args[$a.Name] } else { $false }) }
                elseif ($have)             { $argState[$a.Name] = [string]$t.args[$a.Name] }
                else                       { $argState[$a.Name] = '' }
            }
        }
        $targetsOut += @{
            id    = $t.id
            label = $t.label
            type  = $t.type
            nodes = @(@($t.nodes) | ForEach-Object {
                @{ name = $_.name; url = $_.url
                   verifyHost = $(if ($_.ContainsKey('verifyHost')) { $_.verifyHost } else { '' }) }
            })
            args  = $argState
        }
    }

    $targetCatalogOut = @{}
    foreach ($k in $script:TargetCatalog.Keys) {
        $targetCatalogOut[$k] = @{ label = $script:TargetCatalog[$k].Label; args = @($script:TargetCatalog[$k].Args) }
    }

    # Which targets each certificate is assigned to, plus the outcome of the last
    # deployment so the page can show per-node state without re-probing.
    $deployOut = @{}
    foreach ($c in @($grouping.certs)) {
        $assigned = @()
        if ($settings.certs -and $settings.certs.ContainsKey($c.certId)) {
            $cfg = $settings.certs[$c.certId]
            if ($cfg.ContainsKey('targets')) { $assigned = @($cfg.targets) }
        }
        $last = $null
        $lastFile = Join-Path $script:JobsDir "deploy-$($c.certId).json"
        if (Test-Path $lastFile) {
            try { $last = (Get-Content $lastFile -Raw -Encoding UTF8) | ConvertFrom-Json } catch { }
        }
        $deployOut[$c.certId] = @{ targets = $assigned; last = $last }
    }

    return @{
        generated  = $checker.generated
        certs      = @($grouping.certs)
        unmapped   = @($grouping.unmapped)
        haveZones  = [bool]$grouping.haveZones
        groupError = $groupError
        zones      = @{
            refreshed = $zoneCache.refreshed
            count     = @($zoneCache.zones).Count
            errors    = @($(if ($zoneCache.ContainsKey('errors')) { $zoneCache.errors } else { @() }))
        }
        settings   = @{
            contact     = $settings.contact
            defaultCaId = $settings.defaultCaId
            cas         = @(@($settings.cas) | ForEach-Object {
                @{
                    id           = $_.id
                    label        = $_.label
                    directoryUrl = $_.directoryUrl
                    stagingUrl   = $_.stagingUrl
                    useStaging   = [bool]$_.useStaging
                    eabKid       = $(if ($_.ContainsKey('eabKid')) { $_.eabKid } else { '' })
                    # Whether an HMAC is stored, never the HMAC itself.
                    eabHmacSet   = [bool](Test-TrackerSecret -Key "ca:$($_.id):eabHmacKey")
                }
            })
            providers   = @($providers)
            targets     = @($targetsOut)
            alerts      = @{
                smtp = @{
                    host = $settings.alerts.smtp.host; port = $settings.alerts.smtp.port
                    encryption = $settings.alerts.smtp.encryption; from = $settings.alerts.smtp.from
                    to = @($settings.alerts.smtp.to); authRequired = [bool]$settings.alerts.smtp.authRequired
                    username = $settings.alerts.smtp.username
                    # Whether a password is stored, never the password itself -
                    # the same rule every other credential in this file follows.
                    passwordSet = [bool](Test-TrackerSecret -Key 'alerts:smtpPassword')
                }
                expiry             = @{ enabled = [bool]$settings.alerts.expiry.enabled; thresholds = @($settings.alerts.expiry.thresholds) }
                renewalSuccess     = @{ enabled = [bool]$settings.alerts.renewalSuccess.enabled }
                deploymentFailure  = @{ enabled = [bool]$settings.alerts.deploymentFailure.enabled }
                monthlySummary     = @{ enabled = [bool]$settings.alerts.monthlySummary.enabled }
            }
        }
        catalog       = $catalogOut
        targetCatalog = $targetCatalogOut
        deployment    = $deployOut
        acmeReady     = [bool](Get-VendoredPoshAcme)
    }
}

function Invoke-SaveSettings {
    param($Payload)

    $settings = Get-TrackerSettings

    if ($null -ne $Payload.contact) { $settings.contact = [string]$Payload.contact }

    if ($Payload.PSObject.Properties['cas'] -and $null -ne $Payload.cas) {
        $keptCas = @()
        foreach ($c in @($Payload.cas)) {
            $id = [string]$c.id
            if (-not $id -or $id -notmatch '^[a-zA-Z0-9_\-]{1,64}$') {
                throw "A certificate authority has an invalid id."
            }
            if (-not $c.directoryUrl) { throw "'$([string]$c.label)' needs a directory URL." }

            # A blank secret means "leave the stored one alone", so an unchanged
            # form cannot wipe a credential nobody retyped.
            if ($c.PSObject.Properties['eabHmacKey'] -and $c.eabHmacKey) {
                Set-TrackerSecret -Key "ca:$id`:eabHmacKey" -Value ([string]$c.eabHmacKey)
            }

            $keptCas += @{
                id           = $id
                label        = [string]$c.label
                directoryUrl = [string]$c.directoryUrl
                stagingUrl   = [string]$c.stagingUrl
                useStaging   = [bool]$c.useStaging
                eabKid       = [string]$c.eabKid
            }
        }
        if (-not $keptCas.Count) { throw "At least one certificate authority is required." }

        # Drop EAB secrets for CAs that were removed. Same reasoning as for the
        # DNS profiles below: only prune when something survives, and only write
        # when something actually changed.
        if (@($keptCas).Count -gt 0) {
            $liveCaIds = @($keptCas | ForEach-Object { $_.id })
            $store = Get-SecretStore
            $removed = 0
            foreach ($key in @($store.Keys)) {
                if ($key -notlike 'ca:*') { continue }
                $owner = ($key -split ':')[1]
                if ($liveCaIds -notcontains $owner) { $store.Remove($key); $removed++ }
            }
            if ($removed -gt 0) { Save-SecretStore $store }
        }

        $settings.cas = $keptCas
    }

    if ($null -ne $Payload.defaultCaId) {
        $wanted = [string]$Payload.defaultCaId
        if (@($settings.cas | ForEach-Object { $_.id }) -contains $wanted) {
            $settings.defaultCaId = $wanted
        }
    }

    if ($Payload.PSObject.Properties['providers'] -and $null -ne $Payload.providers) {
        $kept = @()
        foreach ($p in @($Payload.providers)) {
            $id = [string]$p.id
            if (-not $id -or $id -notmatch '^[a-zA-Z0-9_\-]{1,64}$') {
                throw "A DNS profile has an invalid id."
            }

            $plugin = [string]$p.plugin
            if (-not $script:PluginCatalog.ContainsKey($plugin)) {
                throw "Unknown DNS plugin '$plugin'."
            }

            $plain = @{}
            foreach ($a in $script:PluginCatalog[$plugin].Args) {
                $val = $null
                if ($p.args -and $p.args.PSObject.Properties[$a.Name]) { $val = $p.args.($a.Name) }

                if ($a.Secret) {
                    # Blank means "keep what is stored", so an unchanged form
                    # cannot wipe a credential that was never retyped.
                    if ($val) { Set-TrackerSecret -Key "$id`:$($a.Name)" -Value ([string]$val) }
                }
                elseif ($a.Type -eq 'bool') { $plain[$a.Name] = [bool]$val }
                else { $plain[$a.Name] = [string]$val }
            }

            $kept += @{
                id     = $id
                label  = [string]$p.label
                plugin = $plugin
                args   = $plain
            }
        }

        # Drop secrets belonging to profiles that were removed, rather than
        # leaving orphaned credentials encrypted on disk forever.
        #
        # Only when there is still at least one profile, though. A payload that
        # arrives with an empty provider list is far more likely to be a bug than
        # a deliberate "delete everything", and pruning on it wipes every stored
        # credential with no error and no way back.
        if (@($kept).Count -gt 0) {
            $liveIds = @($kept | ForEach-Object { $_.id })

            # Only prune keys that belonged to a DNS profile before this save.
            # The secret store is one flat namespace shared with load balancer
            # targets, so without this guard the loop reads every non-"ca:" key
            # as a provider key - and a target id can never appear in $liveIds,
            # which made saving settings silently delete the Data Plane API
            # password every single time. The targets branch below has the
            # mirror of this guard; this one was missing it.
            $knownProviderIds = @($settings.providers | ForEach-Object { $_.id })

            $store = Get-SecretStore
            $removed = 0
            foreach ($key in @($store.Keys)) {
                if ($key -like 'ca:*') { continue }
                $owner = ($key -split ':')[0]
                if ($knownProviderIds -notcontains $owner) { continue }
                if ($liveIds -notcontains $owner) { $store.Remove($key); $removed++ }
            }
            if ($removed -gt 0) { Save-SecretStore $store }
        }

        $settings.providers = $kept
    }

    if ($Payload.PSObject.Properties['targets'] -and $null -ne $Payload.targets) {
        $keptTargets = @()
        foreach ($t in @($Payload.targets)) {
            $id = [string]$t.id
            if (-not $id -or $id -notmatch '^[a-zA-Z0-9_\-]{1,64}$') { throw "A deployment target has an invalid id." }

            $type = [string]$t.type
            if (-not $script:TargetCatalog.ContainsKey($type)) { throw "Unknown deployment target type '$type'." }
            if (-not $t.label) { throw "Every deployment target needs a name." }

            $nodes = @()
            foreach ($n in @($t.nodes)) {
                if (-not $n.url) { continue }
                # A malformed URL here becomes an unexplained failure much later,
                # during a deployment, so reject it at save time.
                try { [void][Uri]$n.url } catch { throw "'$($n.url)' is not a valid URL." }
                $nodes += @{
                    name = $(if ($n.name) { [string]$n.name } else { ([Uri]$n.url).Host })
                    url  = [string]$n.url
                    verifyHost = [string]$n.verifyHost
                }
            }
            if (-not $nodes.Count) { throw "'$([string]$t.label)' needs at least one node." }

            $plain = @{}
            foreach ($a in $script:TargetCatalog[$type].Args) {
                $val = $null
                if ($t.args -and $t.args.PSObject.Properties[$a.Name]) { $val = $t.args.($a.Name) }

                if ($a.Secret) {
                    # Blank means "keep what is stored", so an unchanged form
                    # cannot wipe a credential nobody retyped.
                    if ($val) { Set-TrackerSecret -Key "$id`:$($a.Name)" -Value ([string]$val) }
                }
                elseif ($a.Type -eq 'bool') { $plain[$a.Name] = [bool]$val }
                else { $plain[$a.Name] = [string]$val }
            }

            $keptTargets += @{ id = $id; label = [string]$t.label; type = $type; nodes = $nodes; args = $plain }
        }

        # Only prune when something survives - an empty list is far more likely a
        # bug than a deliberate "delete every credential".
        if (@($keptTargets).Count -gt 0) {
            $liveTargetIds = @($keptTargets | ForEach-Object { $_.id })
            $store = Get-SecretStore
            $removed = 0
            foreach ($key in @($store.Keys)) {
                if ($key -like 'ca:*') { continue }
                $owner = ($key -split ':')[0]
                # Only prune keys that clearly belong to a removed TARGET; DNS
                # provider secrets are pruned by their own branch above.
                $isTargetKey = @($settings.targets | ForEach-Object { $_.id }) -contains $owner
                if ($isTargetKey -and $liveTargetIds -notcontains $owner) { $store.Remove($key); $removed++ }
            }
            if ($removed -gt 0) { Save-SecretStore $store }
        }

        $settings.targets = $keptTargets
    }

    if ($Payload.PSObject.Properties['alerts'] -and $null -ne $Payload.alerts) {
        $al   = $Payload.alerts
        $smtp = $(if ($al.PSObject.Properties['smtp']) { $al.smtp } else { $null })

        $toList = @()
        if ($smtp -and $smtp.PSObject.Properties['to']) {
            $toList = @(@($smtp.to) | ForEach-Object { [string]$_ } | Where-Object { $_ })
        }

        $expiryOn  = [bool]($al.PSObject.Properties['expiry']            -and $al.expiry.enabled)
        $renewOn   = [bool]($al.PSObject.Properties['renewalSuccess']    -and $al.renewalSuccess.enabled)
        $failOn    = [bool]($al.PSObject.Properties['deploymentFailure'] -and $al.deploymentFailure.enabled)
        $monthlyOn = [bool]($al.PSObject.Properties['monthlySummary']    -and $al.monthlySummary.enabled)
        $anyOn     = $expiryOn -or $renewOn -or $failOn -or $monthlyOn

        if ($anyOn -and (-not $smtp -or -not $smtp.host)) { throw "An SMTP host is required to send any alert." }
        if ($anyOn -and -not $toList.Count)                { throw "At least one alert recipient is required to send any alert." }

        # Blank means "keep what is stored", same rule as every other credential
        # here. This key is fixed rather than per-id (there is only ever one SMTP
        # profile), so unlike CAs, DNS profiles and targets it has nothing to
        # prune - there is no list an id can fall out of.
        if ($smtp -and $smtp.PSObject.Properties['password'] -and $smtp.password) {
            Set-TrackerSecret -Key 'alerts:smtpPassword' -Value ([string]$smtp.password)
        }

        $thresholds = @()
        if ($al.PSObject.Properties['expiry'] -and $al.expiry.PSObject.Properties['thresholds']) {
            $thresholds = @(@($al.expiry.thresholds) | ForEach-Object { [int]$_ } | Where-Object { $_ -ge 0 } |
                             Sort-Object -Descending -Unique)
        }
        if (-not $thresholds.Count) { $thresholds = @(30, 14, 7) }

        # Only two real values exist (see Send-AlertEmail for why "ssl" is not
        # one of them). Anything else - a stale client, a hand-made request -
        # normalises to the encrypted default rather than being trusted as-is,
        # so a typo here fails toward "still encrypted" and not toward "silently
        # sends in the clear".
        $enc = $(if ($smtp) { [string]$smtp.encryption } else { '' })
        if ($enc -ne 'none') { $enc = 'starttls' }

        $settings.alerts = @{
            smtp = @{
                host         = $(if ($smtp) { [string]$smtp.host } else { '' })
                port         = $(if ($smtp -and $smtp.port) { [int]$smtp.port } else { 587 })
                encryption   = $enc
                from         = $(if ($smtp) { [string]$smtp.from } else { '' })
                to           = $toList
                authRequired = [bool]($smtp -and $smtp.authRequired)
                username     = $(if ($smtp) { [string]$smtp.username } else { '' })
            }
            expiry             = @{ enabled = $expiryOn;  thresholds = $thresholds }
            renewalSuccess     = @{ enabled = $renewOn }
            deploymentFailure  = @{ enabled = $failOn }
            monthlySummary     = @{ enabled = $monthlyOn }
        }
    }

    Save-TrackerSettings -Settings $settings
    return @{ ok = $true }
}

function Start-ChildJob {
    <#
      Renewals take minutes, mostly waiting for DNS to propagate. Running one
      inline would block the single-threaded listener and freeze the page, so
      each is a detached child process writing to a log file this server only
      ever reads. If the server is killed mid-renewal, the order still finishes.
    #>
    param([string[]]$ScriptArgs, [string]$Kind)

    # Start-Process joins an -ArgumentList array with plain spaces and quotes
    # nothing, so any path containing a space - "Web Admin", for one - arrives
    # at powershell.exe split in half. Quote them here instead.
    function ConvertTo-ArgumentString {
        param([string[]]$Items)
        (@($Items | ForEach-Object {
            if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
        })) -join ' '
    }

    $id = [Guid]::NewGuid().ToString('n').Substring(0, 12)
    $log = Join-Path $script:JobsDir "$id.log"
    $err = Join-Path $script:JobsDir "$id.err"
    $res = Join-Path $script:JobsDir "$id.result.json"

    # Start-Process refuses to point both streams at one file, so stderr gets
    # its own and the reader stitches them together.
    New-Item -ItemType File -Path $log -Force | Out-Null

    $argString = ConvertTo-ArgumentString (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File') + $ScriptArgs)

    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argString `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError $err

    $script:Jobs[$id] = @{
        id         = $id
        kind       = $Kind
        pid        = $proc.Id
        log        = $log
        err        = $err
        result     = $res
        startedAt  = (Get-Date).ToString('o')
    }

    return $id
}

function Get-JobState {
    param([string]$Id)

    if (-not $script:Jobs.ContainsKey($Id)) { return $null }
    $j = $script:Jobs[$Id]

    $running = $false
    try {
        $p = Get-Process -Id $j.pid -ErrorAction Stop
        $running = -not $p.HasExited
    }
    catch { $running = $false }

    $log = ''
    # Share both read and write: the child still has these files open.
    foreach ($f in @($j.log, $j.err)) {
        if (Test-Path $f) {
            try {
                $fs = [IO.File]::Open($f, 'Open', 'Read', 'ReadWrite')
                try {
                    $sr = New-Object IO.StreamReader($fs)
                    $log += $sr.ReadToEnd()
                    $sr.Dispose()
                } finally { $fs.Dispose() }
            } catch { }
        }
    }

    $result = $null
    if (-not $running -and (Test-Path $j.result)) {
        try { $result = (Get-Content $j.result -Raw -Encoding UTF8) | ConvertFrom-Json } catch { }
    }

    return @{
        id      = $Id
        kind    = $j.kind
        running = $running
        log     = $log
        result  = $result
    }
}

# --------------------------------------------------------------------------- #
# Router
# --------------------------------------------------------------------------- #

$script:Jobs = @{}

function Invoke-Route {
    param($Request, [IO.Stream]$Stream)

    $path = $Request.Path

    # --- static ------------------------------------------------------------ #

    if ($path -eq '/' -or $path -eq '/index.html' -or $path -eq '/ssl-tracker.html') {
        $file = Join-Path $PSScriptRoot 'ssl-tracker.html'
        if (-not (Test-Path $file)) { Send-Error $Stream 404 'ssl-tracker.html is missing.'; return }
        $html = Get-Content $file -Raw -Encoding UTF8
        Send-Response -Stream $Stream -ContentType $script:Mime['.html'] -Body ([Text.Encoding]::UTF8.GetBytes($html))
        return
    }

    if ($path -eq '/haproxy-setup.html') {
        $file = Join-Path $PSScriptRoot 'haproxy-setup.html'
        if (-not (Test-Path $file)) { Send-Error $Stream 404 'haproxy-setup.html is missing.'; return }
        $html = Get-Content $file -Raw -Encoding UTF8
        Send-Response -Stream $Stream -ContentType $script:Mime['.html'] -Body ([Text.Encoding]::UTF8.GetBytes($html))
        return
    }

    if ($path -eq '/readme.html') {
        $file = Join-Path $PSScriptRoot 'readme.html'
        if (-not (Test-Path $file)) { Send-Error $Stream 404 'readme.html is missing.'; return }
        $html = Get-Content $file -Raw -Encoding UTF8
        Send-Response -Stream $Stream -ContentType $script:Mime['.html'] -Body ([Text.Encoding]::UTF8.GetBytes($html))
        return
    }

    if ($path -eq '/ssl-data.js') {
        $file = Join-Path $PSScriptRoot 'ssl-data.js'
        # No data yet is normal on a first run; hand back an empty global so the
        # page shows its own "no data" state rather than a script error.
        $js = if (Test-Path $file) { Get-Content $file -Raw -Encoding UTF8 } else { 'window.SSL_DATA = null;' }
        Send-Response -Stream $Stream -ContentType $script:Mime['.js'] -Body ([Text.Encoding]::UTF8.GetBytes($js))
        return
    }

    if ($path.StartsWith('/assets/')) {
        # Every other static route above is an exact, hardcoded path - this is
        # the first one built from what the client asked for, so it is the
        # first one that needs a real traversal guard rather than just a
        # lookup. Resolve to a full path and require it land inside the assets
        # directory; ".." or an absolute path either fails to resolve under it
        # or gets caught by the prefix check below.
        $assetsRoot = Join-Path $PSScriptRoot 'assets'
        $relative   = $path.Substring('/assets/'.Length) -replace '/', '\'
        $requested  = Join-Path $assetsRoot $relative

        $full = $null
        try { $full = [IO.Path]::GetFullPath($requested) } catch { }
        # A trailing separator on the root, not a bare prefix check: without it
        # "...\assets-evil\file" passes a StartsWith("...\assets") test, because
        # the string "assets-evil" itself starts with "assets". Appending the
        # separator makes the only way to match "the assets folder, or a real
        # child of it" - a sibling directory that merely shares the prefix
        # cannot satisfy it.
        $rootFull = [IO.Path]::GetFullPath($assetsRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar

        if (-not $full -or -not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $full -PathType Leaf)) {
            Send-Error $Stream 404 'Not found.'
            return
        }

        $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
        $ct  = if ($script:Mime.ContainsKey($ext)) { $script:Mime[$ext] } else { 'application/octet-stream' }
        Send-Response -Stream $Stream -ContentType $ct -Body ([IO.File]::ReadAllBytes($full))
        return
    }

    if (-not $path.StartsWith('/api/')) { Send-Error $Stream 404 'Not found.'; return }

    # --- everything below is API and needs the token ----------------------- #

    $supplied = $null
    if ($Request.Headers.ContainsKey('x-tracker-token')) { $supplied = $Request.Headers['x-tracker-token'] }
    if (-not $supplied) { $supplied = Get-QueryValue -Query $Request.Query -Name 't' }

    if (-not (Test-Token $supplied)) {
        Send-Error $Stream 403 'Missing or invalid session token. Reopen the tracker from "Open Tracker.bat".'
        return
    }

    # Guard against DNS rebinding: a hostile page can point a name it controls
    # at 127.0.0.1, but it cannot make the browser send our Host header.
    $hostHeader = ''
    if ($Request.Headers.ContainsKey('host')) { $hostHeader = $Request.Headers['host'] }
    if ($hostHeader -notmatch '^(127\.0\.0\.1|localhost|\[::1\]):\d+$') {
        Send-Error $Stream 403 'Unexpected Host header.'
        return
    }

    $payload = $null
    if ($Request.Body) {
        try { $payload = $Request.Body | ConvertFrom-Json }
        catch { Send-Error $Stream 400 'Request body was not valid JSON.'; return }
    }

    switch -Regex ($path) {

        '^/api/state$' {
            Send-Json $Stream (Get-StateResponse)
            return
        }

        '^/api/settings$' {
            if ($Request.Method -ne 'POST') { Send-Error $Stream 405 'Use POST.'; return }
            try { Send-Json $Stream (Invoke-SaveSettings -Payload $payload) }
            catch { Send-Error $Stream 400 $_.Exception.Message }
            return
        }

        '^/api/targets/test$' {
            if ($Request.Method -ne 'POST') { Send-Error $Stream 405 'Use POST.'; return }

            $wanted = $null
            if ($payload -and $payload.PSObject.Properties['targetId']) { $wanted = [string]$payload.targetId }

            $settings = Get-TrackerSettings
            $results = @()
            foreach ($t in @($settings.targets)) {
                if ($wanted -and $t.id -ne $wanted) { continue }

                $user     = Get-TargetArg -Target $t -Name 'user'
                $password = Get-TargetSecret -TargetId $t.id -Name 'password'
                $insecure = [bool](Get-TargetArg -Target $t -Name 'insecureTls' -Default $false)

                foreach ($n in @($t.nodes)) {
                    $r = @{ targetId = $t.id; targetLabel = $t.label; node = $n.name; url = $n.url
                            ok = $false; apiVersion = $null; certificates = @(); error = $null }
                    try {
                        $api = Get-DataPlaneApiVersion -BaseUrl $n.url -User $user -Password $password -InsecureTls:$insecure
                        $r.apiVersion = $api
                        $r.certificates = @(Get-HAProxyCertificates -BaseUrl $n.url -User $user -Password $password `
                                              -ApiVersion $api -InsecureTls:$insecure)
                        $r.ok = $true
                    }
                    catch { $r.error = ($_.Exception.Message -split "`n")[0].Trim() }
                    $results += $r
                }
            }

            if (-not $results.Count) { Send-Error $Stream 400 'No deployment target to test.'; return }
            Send-Json $Stream @{ ok = (@($results | Where-Object { -not $_.ok }).Count -eq 0); nodes = @($results) }
            return
        }

        '^/api/deploy$' {
            if ($Request.Method -ne 'POST') { Send-Error $Stream 405 'Use POST.'; return }

            $certIds = @()
            if ($payload -and $payload.PSObject.Properties['certs']) { $certIds = @($payload.certs) }
            if (-not $certIds.Count) { Send-Error $Stream 400 'No certificate was selected.'; return }
            if ($certIds.Count -gt 50) { Send-Error $Stream 400 'Too many certificates in one run.'; return }

            $settings = Get-TrackerSettings

            # An explicit selection from the deployment dialog overrides whatever
            # each certificate is assigned to, so a group can be deployed to
            # before anyone has assigned it.
            $chosen = @()
            if ($payload -and $payload.PSObject.Properties['targets']) { $chosen = @($payload.targets) }

            $known = @(@($settings.targets) | ForEach-Object { $_.id })
            foreach ($t in $chosen) {
                if ($known -notcontains [string]$t) {
                    Send-Error $Stream 400 "Unknown deployment target '$t'."
                    return
                }
            }

            foreach ($c in $certIds) {
                $cl = ([string]$c).ToLowerInvariant()
                if (-not (Test-SafeCertName $cl)) { Send-Error $Stream 400 "'$c' is not a valid certificate name."; return }

                if ($chosen.Count) { continue }   # the dialog already said where

                # Refuse early rather than spawning a job that will only fail.
                $assigned = @()
                if ($settings.certs -and $settings.certs.ContainsKey($cl)) {
                    $cfg = $settings.certs[$cl]
                    if ($cfg.ContainsKey('targets')) { $assigned = @($cfg.targets) }
                }
                if (-not $assigned.Count) {
                    Send-Error $Stream 400 "'$c' has no deployment target assigned. Pick one on its row first."
                    return
                }
            }

            $id = [Guid]::NewGuid().ToString('n').Substring(0, 12)
            $resultPath = Join-Path $script:JobsDir "$id.result.json"
            $scriptArgs = @((Join-Path $PSScriptRoot 'deploy.ps1'), '-ResultPath', $resultPath, '-Cert') + $certIds
            if ($chosen.Count) { $scriptArgs += @('-TargetList') + $chosen }

            $jobId = Start-ChildJob -Kind 'deploy' -ScriptArgs $scriptArgs
            $script:Jobs[$jobId].result = $resultPath
            $script:Jobs[$jobId].certs  = @($certIds)

            Send-Json $Stream @{ jobId = $jobId }
            return
        }

        '^/api/cert/(?<certId>[^/]+)/targets$' {
            if ($Request.Method -ne 'POST') { Send-Error $Stream 405 'Use POST.'; return }

            $certKey = ([string]$Matches.certId).ToLowerInvariant()
            if (-not (Test-SafeCertName $certKey)) { Send-Error $Stream 400 'Invalid certificate name.'; return }

            $settings = Get-TrackerSettings
            $wanted = @()
            if ($payload -and $payload.PSObject.Properties['targets']) { $wanted = @($payload.targets) }

            $known = @($settings.targets | ForEach-Object { $_.id })
            foreach ($w in $wanted) {
                if ($known -notcontains [string]$w) { Send-Error $Stream 400 "Unknown deployment target '$w'."; return }
            }

            if (-not $settings.certs) { $settings.certs = @{} }
            if (-not $settings.certs.ContainsKey($certKey)) { $settings.certs[$certKey] = @{} }
            $settings.certs[$certKey].targets = @($wanted)

            Save-TrackerSettings -Settings $settings
            Send-Json $Stream @{ ok = $true; certId = $certKey; targets = @($wanted) }
            return
        }

        '^/api/cert/(?<certId>[^/]+)/ca$' {
            if ($Request.Method -ne 'POST') { Send-Error $Stream 405 'Use POST.'; return }

            $certKey = ([string]$Matches.certId).ToLowerInvariant()
            if (-not (Test-SafeCertName $certKey)) { Send-Error $Stream 400 'Invalid certificate name.'; return }

            $settings = Get-TrackerSettings
            $wanted = ''
            if ($payload -and $payload.PSObject.Properties['caId']) { $wanted = [string]$payload.caId }

            # Empty means "follow the default", which is different from pinning
            # to whichever CA happens to be the default today.
            if ($wanted -and @($settings.cas | ForEach-Object { $_.id }) -notcontains $wanted) {
                Send-Error $Stream 400 "Unknown certificate authority '$wanted'."
                return
            }

            if (-not $settings.certs) { $settings.certs = @{} }
            if (-not $settings.certs.ContainsKey($certKey)) { $settings.certs[$certKey] = @{} }
            $settings.certs[$certKey].caId = $wanted

            Save-TrackerSettings -Settings $settings
            Send-Json $Stream @{ ok = $true; certId = $certKey; caId = $wanted }
            return
        }

        '^/api/cert/(?<certId>[^/]+)/external$' {
            if ($Request.Method -ne 'POST') { Send-Error $Stream 405 'Use POST.'; return }

            $certKey = ([string]$Matches.certId).ToLowerInvariant()
            if (-not (Test-SafeCertName $certKey)) { Send-Error $Stream 400 'Invalid certificate name.'; return }

            $wanted = $false
            if ($payload -and $payload.PSObject.Properties['external']) { $wanted = [bool]$payload.external }

            $settings = Get-TrackerSettings
            if (-not $settings.certs) { $settings.certs = @{} }
            if (-not $settings.certs.ContainsKey($certKey)) { $settings.certs[$certKey] = @{} }
            $settings.certs[$certKey].external = $wanted

            Save-TrackerSettings -Settings $settings
            Send-Json $Stream @{ ok = $true; certId = $certKey; external = $wanted }
            return
        }

        '^/api/settings/test$' {
            if ($Request.Method -ne 'POST') { Send-Error $Stream 405 'Use POST.'; return }
            try {
                $settings = Get-TrackerSettings
                $cache = Update-ZoneCache -Settings $settings
                $errors = @($cache.errors)

                # Listing zones only proves read access. Renewal needs write
                # access, so prove that too - otherwise a read-only credential
                # passes this check and fails halfway through an order.
                $writes = @()
                foreach ($p in @($settings.providers)) {
                    $owned = @(@($cache.zones | Where-Object { $_.providerId -eq $p.id } |
                                ForEach-Object { $_.zone }) | Sort-Object -Unique)
                    if (-not $owned.Count) { continue }

                    try {
                        $probe = Test-ProviderWriteAccess -Provider $p -Zone $owned[0]
                        $writes += @{
                            providerId    = $p.id
                            providerLabel = $p.label
                            zone          = $probe.zone
                            canWrite      = $probe.canWrite
                            cleanedUp     = $probe.cleanedUp
                            error         = $probe.error
                        }
                        if (-not $probe.canWrite) {
                            $errors += @{
                                providerId = $p.id; providerLabel = $p.label
                                error = "can read zones but cannot write records ($($probe.error)). The credential needs permission to edit DNS records, not just read them."
                            }
                        }
                        elseif (-not $probe.cleanedUp) {
                            $errors += @{
                                providerId = $p.id; providerLabel = $p.label
                                error = "wrote a test record but could not delete it. Remove $($probe.recordName) by hand."
                            }
                        }
                    }
                    catch {
                        $errors += @{
                            providerId = $p.id; providerLabel = $p.label
                            error = "write check could not run: $(($_.Exception.Message -split "`n")[0].Trim())"
                        }
                    }
                }

                Send-Json $Stream @{
                    ok        = (@($errors).Count -eq 0)
                    zoneCount = @($cache.zones).Count
                    zones     = @(@($cache.zones | ForEach-Object { $_.zone }) | Sort-Object -Unique | Select-Object -First 200)
                    writes    = @($writes)
                    errors    = @($errors)
                }
            }
            catch { Send-Error $Stream 400 $_.Exception.Message }
            return
        }

        '^/api/settings/test-email$' {
            if ($Request.Method -ne 'POST') { Send-Error $Stream 405 'Use POST.'; return }
            try {
                $settings = Get-TrackerSettings
                Send-AlertEmail -Settings $settings -Subject 'Cert Camel test email' `
                    -Body "This is a test message from Cert Camel, sent $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')).`r`n`r`nIf this arrived, alerts are configured correctly."
                Send-Json $Stream @{ ok = $true }
            }
            catch { Send-Error $Stream 400 $_.Exception.Message }
            return
        }

        '^/api/check$' {
            if ($Request.Method -ne 'POST') { Send-Error $Stream 405 'Use POST.'; return }
            $id = Start-ChildJob -Kind 'check' -ScriptArgs @((Join-Path $PSScriptRoot 'check-ssl.ps1'))
            Send-Json $Stream @{ jobId = $id }
            return
        }

        '^/api/renew$' {
            if ($Request.Method -ne 'POST') { Send-Error $Stream 405 'Use POST.'; return }

            $zones = @()
            if ($payload -and $payload.PSObject.Properties['zones']) { $zones = @($payload.zones) }
            if (-not $zones.Count) { Send-Error $Stream 400 'No certificates were selected.'; return }
            if ($zones.Count -gt 50) { Send-Error $Stream 400 'Too many certificates in one run.'; return }

            # Check the zones are real before spawning anything. renew.ps1
            # validates them again - it has to, since it also runs standalone -
            # but catching it here means a mistyped name comes back as an error
            # on the button instead of a job that opens, runs and dies.
            $known = @()
            $external = @()
            try {
                $g = Get-CertificateGroups -Results @((Get-CheckerResults).results) `
                        -Settings (Get-TrackerSettings) -ZoneCache (Get-ZoneCache)
                $known    = @($g.certs | ForEach-Object { $_.certId })
                $external = @($g.certs | Where-Object { $_.external } | ForEach-Object { $_.certId })
            }
            catch { Send-Error $Stream 400 $_.Exception.Message; return }

            foreach ($z in $zones) {
                $zl = ([string]$z).ToLowerInvariant()
                if (-not (Test-SafeCertName $zl)) {
                    Send-Error $Stream 400 "'$z' is not a valid certificate name."
                    return
                }
                if ($known -notcontains $zl) {
                    Send-Error $Stream 400 "'$z' is not a renewable certificate. Its DNS zone is not managed by any configured provider."
                    return
                }
                # Enforced here, not just hidden in the page. Issuing a second
                # certificate for something another system already auto-renews
                # is exactly the mistake this flag exists to prevent.
                if ($external -contains $zl) {
                    Send-Error $Stream 400 "'$z' is marked as managed elsewhere. Switch it to 'Renew here' first if you really want this tool to issue it."
                    return
                }
            }

            # Where to push afterwards. The renewal dialog always sends this key,
            # so an EMPTY array is a deliberate "renew only, push nothing" and is
            # not the same as the key being absent - which means "use whatever
            # each certificate is assigned to", the path the scheduled task uses.
            $deployTargets = $null
            if ($payload -and $payload.PSObject.Properties['targets']) {
                $deployTargets = @($payload.targets)

                $known = @(@((Get-TrackerSettings).targets) | ForEach-Object { $_.id })
                foreach ($t in $deployTargets) {
                    if ($known -notcontains [string]$t) {
                        Send-Error $Stream 400 "Unknown deployment target '$t'."
                        return
                    }
                }
            }

            $id = [Guid]::NewGuid().ToString('n').Substring(0, 12)
            $resultPath = Join-Path $script:JobsDir "$id.result.json"

            $scriptArgs = @((Join-Path $PSScriptRoot 'renew.ps1'), '-ResultPath', $resultPath, '-Zone') + $zones
            if ($null -ne $deployTargets) {
                if ($deployTargets.Count) { $scriptArgs += @('-TargetList') + $deployTargets }
                else                      { $scriptArgs += '-NoDeploy' }
            }

            $jobId = Start-ChildJob -Kind 'renew' -ScriptArgs $scriptArgs
            # Point the job at the result file we already named.
            $script:Jobs[$jobId].result = $resultPath

            Send-Json $Stream @{ jobId = $jobId }
            return
        }

        '^/api/job/(?<id>[a-f0-9]{12})$' {
            $state = Get-JobState -Id $Matches.id
            if (-not $state) { Send-Error $Stream 404 'No such job.'; return }
            Send-Json $Stream $state
            return
        }

        '^/api/download/(?<certId>[^/]+)$' {
            $certKey = ([string]$Matches.certId).ToLowerInvariant()
            if (-not (Test-SafeCertName $certKey)) { Send-Error $Stream 400 'Invalid certificate name.'; return }

            $requested = Get-QueryValue -Query $Request.Query -Name 'file'
            $name = if ($requested) { $requested } else { "$certKey-full.pem" }

            # Only a bare filename is ever acceptable here - no separators, no
            # traversal, no absolute paths.
            if ($name -match '[\\/:]' -or $name -match '\.\.') {
                Send-Error $Stream 400 'Invalid file name.'
                return
            }

            $file = Join-Path (Join-Path $script:CertsDir $certKey) $name
            if (-not (Test-Path $file)) {
                Send-Error $Stream 404 'That file has not been generated yet. Renew the certificate first.'
                return
            }

            $ext = [IO.Path]::GetExtension($name).ToLowerInvariant()
            $ct  = if ($script:Mime.ContainsKey($ext)) { $script:Mime[$ext] } else { 'application/octet-stream' }

            Send-Response -Stream $Stream -ContentType $ct -Body ([IO.File]::ReadAllBytes($file)) `
                -ExtraHeaders @{ 'Content-Disposition' = "attachment; filename=`"$name`"" }
            return
        }

        default { Send-Error $Stream 404 'Unknown endpoint.'; return }
    }
}

# --------------------------------------------------------------------------- #
# Listen
# --------------------------------------------------------------------------- #

# IPAddress.Loopback, never IPAddress.Any: this must not be reachable from the
# network, only from this machine.
$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
$listener.Start()

$actualPort = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
$url = "http://127.0.0.1:$actualPort/?t=$script:Token"

Write-Host ""
Write-Host "  SSL Certificate Tracker" -ForegroundColor Cyan
Write-Host "  $PSScriptRoot" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Listening on 127.0.0.1:$actualPort (this PC only)" -ForegroundColor Green
Write-Host ""
Write-Host "  If your browser did not open, paste this in:" -ForegroundColor DarkGray
Write-Host "  $url" -ForegroundColor White
Write-Host ""
Write-Host "  Close this window to stop the server." -ForegroundColor DarkGray
Write-Host ""

if (-not $NoBrowser) {
    try { Start-Process $url } catch { Write-Host "  Could not open the browser automatically." -ForegroundColor Yellow }
}

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        $stream = $null
        try {
            $client.ReceiveTimeout = 15000
            $client.SendTimeout    = 30000
            $stream = $client.GetStream()

            $request = Read-HttpRequest -Stream $stream
            if ($request) {
                try { Invoke-Route -Request $request -Stream $stream }
                catch {
                    # A handler blowing up must not take the server down with
                    # it - report it and keep listening.
                    $msg = ($_.Exception.Message -split "`n")[0].Trim()
                    Write-Host "  ! $($request.Method) $($request.Path) -> $msg" -ForegroundColor Red
                    try { Send-Error $stream 500 $msg } catch { }
                }
            }
        }
        catch { }
        finally {
            if ($stream) { try { $stream.Dispose() } catch { } }
            try { $client.Close() } catch { }
        }
    }
}
finally {
    $listener.Stop()
}
