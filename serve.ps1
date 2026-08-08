<#
  serve.ps1 - a small local web server that turns the tracker page from a
  read-only report into something with working buttons.

  Opened straight from disk, ssl-tracker.html cannot run anything: file:// has
  no way to invoke PowerShell, call a DNS API, or write to its own folder.
  Served over loopback it can, so this hosts the same page plus a small JSON API
  behind it.

  Started by "Open Tracker.bat", or by the Cert Camel service when one is
  installed. Close that window to stop an interactive server.

  Deliberately TcpListener rather than HttpListener. The original reason was
  that HttpListener needs a "netsh http add urlacl" reservation or elevation,
  and this bundle required no admin - that no longer holds, since installing a
  service needs admin anyway. The reason it still holds: TLS here is an
  SslStream wrap, so the tool can serve a certificate it issued itself, whereas
  HTTP.sys binds by thumbprint and would need a netsh rebind after every
  renewal. Same conclusion, different justification.
#>

[CmdletBinding()]
param(
    # 0 means "let Windows pick a free port", which avoids colliding with
    # whatever else is already listening. The startup task passes an explicit
    # port so it is predictable across restarts, and enabling HTTPS pins one for
    # interactive launches too - a hostname is worthless on a port that moves.
    [int]$Port = 0,

    [switch]$NoBrowser,

    # Running under the Service Control Manager: no console to print to, and no
    # desktop to open a browser on. Also makes the diagnostics file the only
    # record of anything going wrong.
    [switch]$ServiceMode,

    # Serve plain HTTP even when HTTPS is configured.
    #
    # The way back in, and it exists for one failure specifically. An EXPIRED
    # certificate is survivable - the browser still offers Advanced > Proceed,
    # and the 03:20 renewal runs from the scheduled task rather than from here,
    # so it repairs itself unattended. What is not survivable is the certificate
    # failing to load at all: missing file, unreadable key, wrong password. Then
    # there is no handshake, so the browser has nothing to warn about and
    # nothing to accept, and the UI is unreachable exactly when it is needed.
    [switch]$NoTls
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'acme-lib.ps1')

New-TrackerDirectories

# Everything the server itself does is a person at the page.
$script:RunLogSource = 'ui'

# --------------------------------------------------------------------------- #
# Diagnostics, for when there is no console to print to
# --------------------------------------------------------------------------- #
# Deliberately at the ROOT rather than in jobs\: Invoke-LogRetention only scans
# jobs\, so keeping this outside it means retention can never try to delete a
# file the server currently has open - which would fail into an empty catch and
# retry silently forever. It carries its own rotation instead.

$script:DiagFile    = Join-Path $PSScriptRoot 'server.log'
$script:DiagMaxBytes = 2mb

function Initialize-DiagLog {
    try {
        if ((Test-Path $script:DiagFile) -and (Get-Item $script:DiagFile).Length -gt $script:DiagMaxBytes) {
            # One generation back is enough: this is a breadcrumb trail for "why
            # did the service misbehave last night", not an audit record.
            $old = Join-Path $PSScriptRoot 'server.1.log'
            if (Test-Path $old) { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue }
            Move-Item -LiteralPath $script:DiagFile -Destination $old -Force -ErrorAction SilentlyContinue
        }
    }
    catch { }
}

function Write-Diag {
    <#
      Says it on the console when there is one, and always writes it down.
      Under the Service Control Manager Write-Host goes nowhere, so without the
      file half the reason to look at a server would be missing.

      The session token is stripped on the way to disk. The console is fine -
      whoever is looking at it already has the token in their address bar - but
      this file lives at the root with ordinary inherited permissions, next to
      a session.json that is deliberately locked to three principals. Writing
      the token here in clear would hand back exactly what that ACL protects.
      Masked centrally rather than at each call site, so a line added later
      cannot reintroduce the leak.
    #>
    param([string]$Message, [string]$Colour = 'Gray', [switch]$NoConsole)

    if (-not $ServiceMode -and -not $NoConsole) {
        Write-Host $Message -ForegroundColor $Colour
    }
    try {
        # Two passes on purpose. The regex catches any ?t=... URL, including one
        # belonging to a DIFFERENT instance read out of its session file, which
        # an exact match on this process's token would sail straight past. The
        # exact match then catches a bare token printed without the ?t= prefix.
        $safe = [regex]::Replace($Message, '\?t=[0-9a-fA-F]{16,}', '?t=<withheld>')
        if ($script:Token -and $safe.Contains($script:Token)) {
            $safe = $safe.Replace($script:Token, '<withheld>')
        }
        $line = '[{0}] {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $safe.Trim()
        [IO.File]::AppendAllText($script:DiagFile, $line + "`r`n", [Text.Encoding]::UTF8)
    }
    catch { }
}

Initialize-DiagLog

# Trim run logs once at startup. Doing it here rather than on a timer keeps the
# single-threaded listener free, and a server that has just been started is
# exactly when nobody is waiting on it.
try { [void](Invoke-LogRetention -Settings (Get-TrackerSettings)) } catch { }

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
# Session file - how a headless server says where it is
# --------------------------------------------------------------------------- #
# Started from a console you read the URL off the screen. Started by the Service
# Control Manager there is no screen, so the port and token would be lost the
# moment the process began. This writes them down for "Open Tracker.bat".
#
# The token is still minted fresh every start rather than persisted. The only
# cost is that a browser tab does not survive a restart - and a restart is a
# reboot or a crash, after which you would reopen from the shortcut anyway.
# Persisting it would turn a per-run secret into a standing one for the sake of
# one click.

$script:SessionFile = Join-Path $script:JobsDir 'session.json'

function Set-SessionFileAcl {
    <#
      The file holds a token that grants full control of the API, so it must not
      be world-readable on a multi-user server. Inheritance is switched off and
      only SYSTEM, Administrators and the account running the server are put
      back - the same people who can already read secrets.xml directly.
    #>
    param([string]$Path)

    try {
        $acl = Get-Acl -Path $Path
        $acl.SetAccessRuleProtection($true, $false)   # explicit rules only
        foreach ($r in @($acl.Access)) { [void]$acl.RemoveAccessRule($r) }

        foreach ($who in @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators',
                           [Security.Principal.WindowsIdentity]::GetCurrent().Name)) {
            try {
                $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
                    $who, 'FullControl', 'Allow')))
            }
            catch { }   # a name that will not resolve must not stop the others
        }
        Set-Acl -Path $Path -AclObject $acl
    }
    catch { }
}

function Write-SessionFile {
    param([int]$ActualPort, [string]$Url)

    $payload = @{
        url       = $Url
        port      = $ActualPort
        token     = $script:Token
        pid       = $PID
        service   = [bool]$ServiceMode
        startedAt = (Get-Date).ToString('o')
        folder    = $PSScriptRoot
    }
    try {
        Write-TextFileAtomic -Path $script:SessionFile -Content ($payload | ConvertTo-Json)
        Set-SessionFileAcl -Path $script:SessionFile
    }
    catch {
        Write-Diag "Could not write the session file: $(($_.Exception.Message -split "`n")[0].Trim())" 'Yellow'
    }
}

function Get-RunningInstance {
    <#
      Returns the live instance described by the session file, or $null.

      Both parts matter: a stale file left by a crash names a pid that is gone,
      and a pid that has been recycled onto some unrelated program would answer
      nothing on the port. Requiring both keeps a leftover file from blocking a
      legitimate start.
    #>
    if (-not (Test-Path $script:SessionFile)) { return $null }

    $s = $null
    try { $s = [IO.File]::ReadAllText($script:SessionFile) | ConvertFrom-Json } catch { return $null }
    if (-not $s -or -not $s.pid -or -not $s.port) { return $null }

    try { $null = Get-Process -Id ([int]$s.pid) -ErrorAction Stop } catch { return $null }

    $listening = @(Get-NetTCPConnection -State Listen -LocalPort ([int]$s.port) -ErrorAction SilentlyContinue)
    if (-not $listening.Count) { return $null }

    return $s
}

# --------------------------------------------------------------------------- #
# Minimal HTTP
# --------------------------------------------------------------------------- #

$script:Mime = @{
    '.html' = 'text/html; charset=utf-8'
    '.js'   = 'application/javascript; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.png'  = 'image/png'
    '.svg'  = 'image/svg+xml'
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
        $bindings = @()
        if ($settings.certs -and $settings.certs.ContainsKey($c.certId)) {
            $bindings = Get-CertTargetBindings -CertConfig $settings.certs[$c.certId]
            $assigned = @($bindings | ForEach-Object { $_.id })
        }
        $last = $null
        $lastFile = Join-Path $script:JobsDir "deploy-$($c.certId).json"
        if (Test-Path $lastFile) {
            try { $last = (Get-Content $lastFile -Raw -Encoding UTF8) | ConvertFrom-Json } catch { }
        }
        # "targets" stays a flat id list so nothing that already reads it has to
        # change; "bindings" carries the overrides alongside it.
        $deployOut[$c.certId] = @{
            targets = $assigned
            bindings = @($bindings | ForEach-Object { @{ id = $_.id; overrides = $_.overrides } })
            last = $last
        }
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
            logs = (Get-LogSettings -Settings $settings)
            web  = (Get-WebSettings -Settings $settings)
        }
        # What this instance is ACTUALLY doing, which is not always what the
        # settings asked for - a certificate that would not load falls back to
        # HTTP, and the page has to be able to say so rather than showing a
        # padlock that is not there.
        serving = @{
            scheme = $(if ($script:TlsCert) { 'https' } else { 'http' })
            host   = $(if ($script:TlsCert) { $script:Web.hostname } else { '127.0.0.1' })
            certId = $(if ($script:TlsCertId) { $script:TlsCertId } else { '' })
            notAfter = $(if ($script:TlsCert) { $script:TlsCert.NotAfter.ToString('o') } else { $null })
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
            $removedKeys = @()
            foreach ($key in @($store.Keys)) {
                if ($key -notlike 'ca:*') { continue }
                $owner = ($key -split ':')[1]
                if ($liveCaIds -notcontains $owner) { $store.Remove($key); $removedKeys += $key }
            }
            if ($removedKeys.Count -gt 0) {
                Save-SecretStore $store
                Write-SecretAuditLog -Category 'certificate authority removed' -Keys $removedKeys
            }
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
            $removedKeys = @()
            foreach ($key in @($store.Keys)) {
                if ($key -like 'ca:*') { continue }
                $owner = ($key -split ':')[0]
                if ($knownProviderIds -notcontains $owner) { continue }
                if ($liveIds -notcontains $owner) { $store.Remove($key); $removedKeys += $key }
            }
            if ($removedKeys.Count -gt 0) {
                Save-SecretStore $store
                Write-SecretAuditLog -Category 'DNS profile removed' -Keys $removedKeys
            }
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
            $removedKeys = @()
            foreach ($key in @($store.Keys)) {
                if ($key -like 'ca:*') { continue }
                $owner = ($key -split ':')[0]
                # Only prune keys that clearly belong to a removed TARGET; DNS
                # provider secrets are pruned by their own branch above.
                $isTargetKey = @($settings.targets | ForEach-Object { $_.id }) -contains $owner
                if ($isTargetKey -and $liveTargetIds -notcontains $owner) { $store.Remove($key); $removedKeys += $key }
            }
            if ($removedKeys.Count -gt 0) {
                Save-SecretStore $store
                Write-SecretAuditLog -Category 'load balancer group removed' -Keys $removedKeys
            }
        }

        $settings.targets = $keptTargets
    }

    if ($Payload.PSObject.Properties['alerts'] -and $null -ne $Payload.alerts) {
        $al   = $Payload.alerts
        $smtp = $(if ($al.PSObject.Properties['smtp']) { $al.smtp } else { $null })

        # Must look like an address, not merely be non-empty. settings.json has
        # been found holding the literal string "[object Object]" here - an
        # object stringified somewhere on the way in, then round-tripped by
        # every save afterwards. [string] on an object always produces
        # SOMETHING, so "is it non-empty" was never going to catch it. Requiring
        # an @ costs nothing and makes the bad value unstorable.
        $toList = @()
        if ($smtp -and $smtp.PSObject.Properties['to']) {
            $toList = @(@($smtp.to) |
                ForEach-Object { ([string]$_).Trim() } |
                Where-Object { $_ -and $_.Contains('@') -and $_ -notmatch '^\[object' })
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

    # Retention lives here too, so changing the limits takes effect on save
    # rather than at the next restart.
    if ($Payload.PSObject.Properties['logs'] -and $null -ne $Payload.logs) {
        $days = 90; $mb = 200
        if ($Payload.logs.PSObject.Properties['retentionDays'] -and $Payload.logs.retentionDays) { $days = [int]$Payload.logs.retentionDays }
        if ($Payload.logs.PSObject.Properties['maxSizeMb']     -and $Payload.logs.maxSizeMb)     { $mb   = [int]$Payload.logs.maxSizeMb }
        if ($days -lt 1)    { $days = 1 }
        if ($mb   -lt 1)    { $mb   = 1 }
        if ($days -gt 3650) { $days = 3650 }
        if ($mb   -gt 51200){ $mb   = 51200 }
        $settings.logs = @{ retentionDays = $days; maxSizeMb = $mb }
    }

    # How this page is served. Validated hard, because every failure here is one
    # a person discovers by being unable to reach the tool that reports it.
    if ($Payload.PSObject.Properties['web'] -and $null -ne $Payload.web) {
        $w = $Payload.web

        $name = ''
        if ($w.PSObject.Properties['hostname'] -and $w.hostname) {
            $name = ([string]$w.hostname).Trim().TrimEnd('.').ToLowerInvariant()
        }
        $port = 0
        if ($w.PSObject.Properties['port'] -and $w.port) { $port = [int]$w.port }
        $https = [bool]($w.PSObject.Properties['https'] -and $w.https)

        if ($https) {
            if (-not $name) { throw "HTTPS needs a hostname for the tracker." }
            if ($name.StartsWith('*.')) { throw "A wildcard cannot be the address of a web page - give it one name." }
            if ($name -notmatch '^(?!-)[a-z0-9-]{1,63}(?<!-)(\.(?!-)[a-z0-9-]{1,63}(?<!-))+$') {
                throw "'$name' is not a valid hostname."
            }
            if ($port -lt 1 -or $port -gt 65535) {
                throw "HTTPS needs a fixed port. A hostname is no use on a port that changes every launch."
            }
            # Refuse to turn it on with nothing to serve. The server would fall
            # back to HTTP and say so in a log nobody is reading, which is a
            # worse outcome than the save failing here with the reason.
            if (-not (Find-CertificateForHost -HostName $name)) {
                throw "No certificate on disk covers $name yet. Add it to domains.txt and renew first."
            }
        }

        $settings.web = @{ https = $https; hostname = $name; port = $port }
    }

    Save-TrackerSettings -Settings $settings

    # Which sections were actually present in the payload, so the trail says
    # what changed rather than just "settings saved" on every keystroke of a
    # save. Never the values - some of them are credentials.
    $touched = @()
    foreach ($k in @('contact','cas','providers','targets','alerts','logs','web')) {
        if ($Payload.PSObject.Properties[$k] -and $null -ne $Payload.$k) { $touched += $k }
    }
    Write-AuditEvent -Event 'settings' -Object ($touched -join ', ') -Outcome 'ok' `
        -Detail "settings saved$(if ($touched.Count) { '' } else { ' (no sections present)' })"

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

    # Named for when and what, not for a random id. The old <guid>.log told you
    # nothing without opening it, which made a folder of them unreadable and
    # made history effectively lost once the in-memory job registry was gone.
    # The child does NOT also self-log: its stdout is redirected here, and two
    # writers on one file would interleave badly.
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHHmmssZ')
    $log = Join-Path $script:JobsDir "$stamp-$Kind.log"
    $err = Join-Path $script:JobsDir "$stamp-$Kind.err"
    $res = Join-Path $script:JobsDir "$id.result.json"

    # Start-Process refuses to point both streams at one file, so stderr gets
    # its own and the reader stitches them together.
    New-Item -ItemType File -Path $log -Force | Out-Null

    # Everything started from here was started by a person at the page, which is
    # what the audit trail records as the source.
    $argString = ConvertTo-ArgumentString (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File') + $ScriptArgs + @('-Source', 'ui'))

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
    #
    # An allow-list of exact names, never a pattern. The configured tracker
    # hostname joins it when one is set - it has to, or serving under a name
    # would be rejected by our own guard - and it is compared literally, so
    # widening this for HTTPS does not weaken what it was written to stop.
    #
    # A missing port is allowed only for the standard one, since a browser
    # omits :443 from the header on an https:// URL. Everything else must
    # carry the port it actually connected on.
    $hostHeader = ''
    if ($Request.Headers.ContainsKey('host')) { $hostHeader = $Request.Headers['host'] }

    $hostName = $hostHeader
    $hostPort = ''
    $colon = $hostHeader.LastIndexOf(':')
    if ($colon -ge 0 -and $hostHeader.IndexOf(']') -lt $colon) {
        $hostName = $hostHeader.Substring(0, $colon)
        $hostPort = $hostHeader.Substring($colon + 1)
    }

    $allowedHosts = @('127.0.0.1', 'localhost', '[::1]')
    if ($script:WebHost) { $allowedHosts += $script:WebHost }

    $hostOk = ($allowedHosts -contains $hostName.ToLowerInvariant()) -and
              ($hostPort -match '^\d+$' -or (-not $hostPort -and $script:TlsCert))

    if (-not $hostOk) {
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

        '^/api/targets/discover$' {
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
                            ok = $false; frontends = @(); error = $null }
                    try {
                        $api = Get-DataPlaneApiVersion -BaseUrl $n.url -User $user -Password $password -InsecureTls:$insecure
                        $r.frontends = @(Get-HAProxyFrontends -BaseUrl $n.url -User $user -Password $password `
                                            -ApiVersion $api -InsecureTls:$insecure)
                        $r.ok = $true
                    }
                    catch { $r.error = ($_.Exception.Message -split "`n")[0].Trim() }
                    $results += $r
                }
            }

            if (-not $results.Count) { Send-Error $Stream 400 'No deployment target to inspect.'; return }
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
                    $assigned = Get-CertTargetIds -CertConfig $settings.certs[$cl]
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

            # An entry is either a bare id (inherit everything from the group, the
            # only shape that used to exist) or an object with per-certificate
            # overrides. Stored in whichever shape it arrived in, so a settings
            # file only grows objects where someone actually asked for one.
            $store = @()
            foreach ($w in $wanted) {
                $id = $null
                $ov = @{}

                if ($w -is [string]) { $id = [string]$w }
                elseif ($w -and $w.PSObject.Properties['id']) {
                    $id = [string]$w.id
                    foreach ($p in $w.PSObject.Properties) {
                        if ($p.Name -eq 'id') { continue }
                        if ($null -eq $p.Value -or "$($p.Value)" -eq '') { continue }   # blank clears the override
                        $ov[$p.Name] = $p.Value
                    }
                }

                if (-not $id) { Send-Error $Stream 400 'A deployment target entry has no id.'; return }
                if ($known -notcontains $id) { Send-Error $Stream 400 "Unknown deployment target '$id'."; return }

                # Overrides may only name settings the target type actually has,
                # and never a secret - a credential belongs to the group, not to
                # one certificate's assignment.
                if ($ov.Keys.Count) {
                    $tp = Get-TargetProfile -Settings $settings -TargetId $id
                    $catalog = $(if ($tp -and $script:TargetCatalog.ContainsKey($tp.type)) { $script:TargetCatalog[$tp.type] } else { $null })
                    $allowed = @()
                    if ($catalog) { $allowed = @($catalog.Args | Where-Object { -not $_.Secret } | ForEach-Object { $_.Name }) }
                    foreach ($k in @($ov.Keys)) {
                        if ($allowed -notcontains $k) {
                            Send-Error $Stream 400 "'$k' is not an overridable setting for target '$id'."
                            return
                        }
                    }
                }

                if ($ov.Keys.Count) {
                    $entry = @{ id = $id }
                    foreach ($k in $ov.Keys) { $entry[$k] = $ov[$k] }
                    $store += $entry
                } else {
                    $store += $id
                }
            }

            if (-not $settings.certs) { $settings.certs = @{} }
            if (-not $settings.certs.ContainsKey($certKey)) { $settings.certs[$certKey] = @{} }
            $settings.certs[$certKey].targets = @($store)

            Save-TrackerSettings -Settings $settings
            Write-AuditEvent -Event 'assign' -Object $certKey -Outcome 'ok' `
                -Detail $(if (@($store).Count) {
                    "assigned to $(@($store | ForEach-Object { if ($_ -is [string]) { $_ } else { "$($_.id) (with overrides)" } }) -join ', ')"
                } else { 'assignment cleared' })
            Send-Json $Stream @{ ok = $true; certId = $certKey; targets = @($store) }
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
            Write-AuditEvent -Event 'ca' -Object $certKey -Outcome 'ok' `
                -Detail $(if ($wanted) { "issuer pinned to '$wanted'" } else { 'issuer set to follow the default' })
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
            Write-AuditEvent -Event 'external' -Object $certKey -Outcome 'ok' `
                -Detail $(if ($wanted) { 'marked as renewed by another system - will never be issued from here' }
                          else         { 'brought back under Cert Camel - will be issued from here again' })
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

        '^/api/web/preflight$' {
            if ($Request.Method -ne 'POST') { Send-Error $Stream 405 'Use POST.'; return }

            $name = ''
            $port = 0
            if ($payload) {
                if ($payload.PSObject.Properties['hostname']) { $name = [string]$payload.hostname }
                if ($payload.PSObject.Properties['port'] -and $payload.port) { $port = [int]$payload.port }
            }
            try {
                Send-Json $Stream (Get-TrackerAddressStatus -HostName $name -Port $port `
                    -Settings (Get-TrackerSettings) -ZoneCache (Get-ZoneCache) -CurrentPort $actualPort)
            }
            catch { Send-Error $Stream 400 $_.Exception.Message }
            return
        }

        '^/api/web/hosts$' {
            if ($Request.Method -ne 'POST') { Send-Error $Stream 405 'Use POST.'; return }
            if (-not $payload -or -not $payload.PSObject.Properties['hostname'] -or -not $payload.hostname) {
                Send-Error $Stream 400 'Missing "hostname".'
                return
            }
            if (-not (Test-Elevated)) {
                # Said plainly rather than attempted and failed with an access
                # error: the hosts file is administrator-writable by design, and
                # the page cannot elevate itself.
                Send-Error $Stream 403 'Editing the hosts file needs administrator. Copy the line and add it yourself, or restart the tracker from an elevated console.'
                return
            }
            try {
                $r = Add-HostsEntry -HostName ([string]$payload.hostname)
                Write-AuditEvent -Event 'settings' -Object 'hosts file' -Outcome 'ok' `
                    -Detail "$($r.line) $(if ($r.changed) { 'added' } else { 'already present' })"
                Send-Json $Stream $r
            }
            catch {
                Write-AuditEvent -Event 'settings' -Object 'hosts file' -Outcome 'fail' `
                    -Detail $_.Exception.Message
                Send-Error $Stream 400 $_.Exception.Message
            }
            return
        }

        '^/api/web/domains$' {
            if ($Request.Method -ne 'POST') { Send-Error $Stream 405 'Use POST.'; return }
            if (-not $payload -or -not $payload.PSObject.Properties['hostname'] -or -not $payload.hostname) {
                Send-Error $Stream 400 'Missing "hostname".'
                return
            }
            $port = 0
            if ($payload.PSObject.Properties['port'] -and $payload.port) { $port = [int]$payload.port }
            try {
                $r = Add-TrackerDomainEntry -HostName ([string]$payload.hostname) -Port $port
                Write-AuditEvent -Event 'domains' -Object $r.entry -Outcome 'ok' `
                    -Detail "tracker address $(if ($r.changed) { 'added to domains.txt' } else { 'already listed' })"
                Send-Json $Stream $r
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

        '^/api/automation$' {
            if ($Request.Method -ne 'GET') { Send-Error $Stream 405 'Use GET.'; return }

            # Its own endpoint rather than part of /api/state: the state load
            # runs on boot and after every job, and there is no reason to put
            # 200 ms of scheduler lookup on that path for a panel only Home
            # draws.
            $forecast = Get-RenewalForecast

            Send-Json $Stream @{
                automation = (Get-AutomationStatus)
                forecast   = $forecast
                folder     = $script:Root
            }
            return
        }

        '^/api/forecast$' {
            if ($Request.Method -ne 'POST') { Send-Error $Stream 405 'Use POST.'; return }

            # -WhatIfOnly is the existing, documented dry run: it works out what
            # WOULD renew and stops. Nothing is issued and no load balancer is
            # touched. No -ResultPath, so renew-due.ps1 writes its verdicts to
            # the shared sweep file the panel reads.
            $id = Start-ChildJob -Kind 'forecast' -ScriptArgs @(
                (Join-Path $PSScriptRoot 'renew-due.ps1'), '-WhatIfOnly')
            Send-Json $Stream @{ jobId = $id }
            return
        }

        '^/api/logs$' {
            if ($Request.Method -ne 'GET') { Send-Error $Stream 405 'Use GET.'; return }

            $settings = Get-TrackerSettings

            # Listed from the FILESYSTEM, not from the in-memory job registry.
            # That registry is lost on restart, which is why history used to
            # become unreachable the moment the server was restarted even though
            # the files were sitting there the whole time.
            $runs = @()
            if (Test-Path $script:JobsDir) {
                $runs = @(Get-ChildItem $script:JobsDir -File -Filter '*.log' -ErrorAction SilentlyContinue |
                          Sort-Object LastWriteTime -Descending | Select-Object -First 200 | ForEach-Object {
                    # "2026-08-05T032000Z-renew-due.log" -> kind and time.
                    $kind = 'run'
                    if ($_.BaseName -match '^\d{4}-\d{2}-\d{2}T\d{6}Z-(?<k>.+)$') { $kind = $Matches.k }
                    @{ name = $_.Name; kind = $kind
                       at = $_.LastWriteTime.ToString('o'); bytes = $_.Length }
                })
            }

            $auditBytes = 0
            $auditLines = 0
            if (Test-Path $script:AuditFile) {
                $auditBytes = (Get-Item $script:AuditFile).Length
                # Shared read: a job appending right now must not make this
                # report zero entries. Only the count leaves here, so the
                # Get-Content NoteProperty trap does not apply - but the lock does.
                try {
                    $fs = [IO.File]::Open($script:AuditFile, 'Open', 'Read', 'ReadWrite')
                    try {
                        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
                        $auditLines = @($sr.ReadToEnd() -split "`r?`n" | Where-Object { $_ -ne '' }).Count
                        $sr.Dispose()
                    }
                    finally { $fs.Dispose() }
                }
                catch { }
            }
            $archives = @(Get-ChildItem $script:Root -File -Filter 'audit-*.log' -ErrorAction SilentlyContinue |
                          Sort-Object Name -Descending | ForEach-Object { @{ name = $_.Name; bytes = $_.Length } })

            # Count what the size cap actually measures - every trimmable file in
            # the folder - not just the .log files listed above. The page reports
            # this against the limit, so summing a different set would show a
            # figure that never quite matches the one doing the trimming.
            #
            # Summed by hand: Measure-Object -Property reads object PROPERTIES,
            # and these are hashtable KEYS, which is not the same thing in 5.1.
            $totalBytes = 0
            Get-ChildItem $script:JobsDir -File -ErrorAction SilentlyContinue |
                Where-Object { ($_.Extension -in @('.log', '.err')) -or ($_.Name -like '*.result.json') } |
                ForEach-Object { $totalBytes += $_.Length }

            Send-Json $Stream @{
                runs      = @($runs)
                audit     = @{ lines = $auditLines; bytes = $auditBytes; archives = @($archives) }
                retention = (Get-LogSettings -Settings $settings)
                totalBytes = $totalBytes
            }
            return
        }

        '^/api/logs/run/(?<name>[^/]+)$' {
            if ($Request.Method -ne 'GET') { Send-Error $Stream 405 'Use GET.'; return }

            # A name from the client used to build a path: the exact shape that
            # needs a whitelist AND a resolve check, same as /api/download and
            # the assets route.
            $name = [string]$Matches.name
            if ($name -notmatch '^[A-Za-z0-9._\-]{1,120}$' -or $name -match '\.\.' -or
                ($name -notlike '*.log' -and $name -notlike '*.err')) {
                Send-Error $Stream 400 'Invalid log name.'
                return
            }

            $full = $null
            try { $full = [IO.Path]::GetFullPath((Join-Path $script:JobsDir $name)) } catch { }
            $rootFull = [IO.Path]::GetFullPath($script:JobsDir).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            if (-not $full -or -not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-Path -LiteralPath $full -PathType Leaf)) {
                Send-Error $Stream 404 'No such log.'
                return
            }

            # Shared read/write: a run in progress still has this file open.
            $text = ''
            try {
                $fs = [IO.File]::Open($full, 'Open', 'Read', 'ReadWrite')
                try { $sr = New-Object IO.StreamReader($fs); $text = $sr.ReadToEnd(); $sr.Dispose() }
                finally { $fs.Dispose() }
            }
            catch { Send-Error $Stream 500 "Could not read that log: $($_.Exception.Message)"; return }

            Send-Json $Stream @{ name = $name; content = $text }
            return
        }

        '^/api/logs/audit$' {
            if ($Request.Method -ne 'GET') { Send-Error $Stream 405 'Use GET.'; return }

            $wantEvent = Get-QueryValue -Query $Request.Query -Name 'event'
            $file = $script:AuditFile

            # An archive may be requested by name; same guard as the run logs.
            $archive = Get-QueryValue -Query $Request.Query -Name 'archive'
            if ($archive) {
                if ($archive -notmatch '^audit-[0-9\-]{1,32}\.log$') { Send-Error $Stream 400 'Invalid archive name.'; return }
                $file = Join-Path $script:Root $archive
            }

            if (-not (Test-Path $file)) { Send-Json $Stream @{ lines = @(); truncated = $false; total = 0 }; return }

            # ReadAllLines, NOT Get-Content - see the note under /api/domains
            # below. These strings go straight into Send-Json, and Get-Content's
            # PSDrive NoteProperty turns that into an unbounded walk of session
            # state that wedges this single-threaded server. Shared read as well,
            # because a job may be appending to the audit log right now.
            $all = @()
            try {
                $fs = [IO.File]::Open($file, 'Open', 'Read', 'ReadWrite')
                try {
                    $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
                    $all = @($sr.ReadToEnd() -split "`r?`n" | Where-Object { $_ -ne '' })
                    $sr.Dispose()
                }
                finally { $fs.Dispose() }
            }
            catch { Send-Error $Stream 500 "Could not read the audit log: $($_.Exception.Message)"; return }

            if ($wantEvent) {
                # The event column is the fourth whitespace-separated field.
                $all = @($all | Where-Object { ($_ -split '\s+')[3] -eq $wantEvent })
            }

            # Newest last in the file; hand back the tail, and say when it was cut
            # rather than silently showing a partial picture. `total` is the count
            # BEFORE trimming - reporting the trimmed count would make a truncated
            # view look complete.
            $max   = 500
            $total = $all.Count
            $truncated = ($total -gt $max)
            if ($truncated) { $all = @($all | Select-Object -Last $max) }

            Send-Json $Stream @{ lines = @($all); truncated = $truncated; total = $total }
            return
        }

        '^/api/domains$' {
            if ($Request.Method -eq 'GET') {
                # ReadAllText, NOT Get-Content -Raw. Get-Content attaches
                # NoteProperties (PSPath, PSDrive, PSProvider...) to the string
                # it returns, and PS 5.1's ConvertTo-Json serialises them -
                # PSDrive leads into the session-state object graph, and at
                # -Depth 10 that walk is effectively unbounded. The symptom is
                # Send-Json "hanging" on a one-line file, which wedges the whole
                # single-threaded server. ReadAllText returns a bare string.
                $content = if (Test-Path $script:DomainsFile) { [IO.File]::ReadAllText($script:DomainsFile, [Text.Encoding]::UTF8) } else { '' }
                Send-Json $Stream @{ content = $content }
                return
            }
            if ($Request.Method -eq 'POST') {
                if (-not $payload -or -not $payload.PSObject.Properties['content']) {
                    Send-Error $Stream 400 'Missing "content".'
                    return
                }
                $content = [string]$payload.content
                # Loopback-and-token protected already, so this is a size sanity
                # check rather than a security boundary - nothing legitimate
                # approaches this, and it catches a pasted-the-wrong-thing accident
                # before it overwrites the real list.
                if ($content.Length -gt 2mb) {
                    Send-Error $Stream 400 'That is far larger than a domain list should be.'
                    return
                }
                try { Write-TextFileAtomic -Path $script:DomainsFile -Content $content }
                catch { Send-Error $Stream 500 "Could not save domains.txt: $($_.Exception.Message)"; return }
                Send-Json $Stream @{ ok = $true }
                return
            }
            Send-Error $Stream 405 'Use GET or POST.'
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

# A second server is never what anyone wants. It was previously harmless because
# $Port = 0 handed each launch a different random port, so two instances simply
# coexisted unnoticed; once the startup task pins a port they collide. Point at
# the one already running instead of failing to bind.
$existing = Get-RunningInstance

# A hard kill - or a console window closed with the X - never runs a finally
# block, so a session file naming a dead process is the normal case rather than
# the exception. Clear it here so the folder does not accumulate stale tokens
# for servers that stopped weeks ago.
if (-not $existing -and (Test-Path $script:SessionFile)) {
    try { Remove-Item -LiteralPath $script:SessionFile -Force -ErrorAction SilentlyContinue } catch { }
}
if ($existing) {
    Write-Diag ""
    Write-Diag "  Cert Camel is already running (pid $($existing.pid), port $($existing.port))." 'Yellow'
    if ($existing.service) {
        Write-Diag "  It was started at boot by the 'Cert Camel Server' task, so it survives sign-out." 'DarkGray'
    }
    Write-Diag "  Open it with:" 'DarkGray'
    Write-Diag "  $($existing.url)" 'White'
    Write-Diag ""
    if (-not $NoBrowser -and -not $ServiceMode) {
        try { Start-Process $existing.url } catch { }
    }
    exit 0
}

# --------------------------------------------------------------------------- #
# How this instance is served
# --------------------------------------------------------------------------- #

$script:Web = Get-WebSettings -Settings (Get-TrackerSettings)

# An explicit -Port wins - the startup task passes one. Otherwise the configured
# port, if HTTPS gave us one to pin. Otherwise 0, and Windows picks.
if (-not $PSBoundParameters.ContainsKey('Port') -and $script:Web.port) {
    $Port = $script:Web.port
}

# The configured hostname is accepted by the Host guard whether or not TLS came
# up. That is deliberate: if the certificate fails to load and this falls back
# to plain HTTP, http://<name>:<port> has to keep working, or the recovery path
# is a URL the server itself rejects.
$script:WebHost = $script:Web.hostname

$script:TlsCert = $null
$tlsNote = $null

if ($script:Web.https -and -not $NoTls) {
    $match = Find-CertificateForHost -HostName $script:Web.hostname
    if (-not $match) {
        $tlsNote = "no certificate on disk covers $($script:Web.hostname) - serving plain HTTP"
    }
    else {
        try {
            # No PersistKeySet: without it the key container Windows materialises
            # for the PFX is removed when the certificate is disposed, so a
            # server restarted daily does not leave a key file behind every time.
            #
            # EphemeralKeySet would be tidier still and must NOT be used -
            # schannel cannot do server authentication with an ephemeral key, so
            # every handshake would fail.
            $flags = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::UserKeySet
            try {
                $script:TlsCert = New-Object Security.Cryptography.X509Certificates.X509Certificate2(
                    $match.pfx, $script:PfxPassword, $flags)
            }
            catch {
                # Under the startup task the logon is S4U and the user profile
                # may not be loaded, which leaves no per-user key store to write
                # into. MachineKeys needs no profile.
                $flags = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet
                $script:TlsCert = New-Object Security.Cryptography.X509Certificates.X509Certificate2(
                    $match.pfx, $script:PfxPassword, $flags)
            }

            if (-not $script:TlsCert.HasPrivateKey) {
                $script:TlsCert.Dispose()
                $script:TlsCert = $null
                $tlsNote = "$($match.certId) has no usable private key - serving plain HTTP"
            }
            else {
                $script:TlsCertPath  = $match.pfx
                $script:TlsCertId    = $match.certId
                # Remembered so a reload after renewal uses whichever of the two
                # key stores worked here, instead of rediscovering it.
                $script:TlsKeyFlags  = $flags
                # Watched so a renewal that replaces the file underneath us is
                # picked up. Without this the server keeps presenting the old
                # certificate until something restarts it, which looks exactly
                # like a renewal that did not happen.
                $script:TlsCertStamp = (Get-Item -LiteralPath $match.pfx).LastWriteTimeUtc
            }
        }
        catch {
            $tlsNote = "could not load $($match.certId): $(($_.Exception.Message -split "`n")[0].Trim()) - serving plain HTTP"
        }
    }
}
elseif ($script:Web.https -and $NoTls) {
    $tlsNote = "-NoTls given, so HTTPS is configured but not in use"
}

function Update-TlsCertificate {
    <#
      Pick up a renewal that replaced the certificate under us.

      Called per connection, which sounds extravagant and is one stat call on a
      local file. The alternatives are worse: a timer means a second thread in a
      deliberately single-threaded server, and "restart to pick it up" means the
      page presents an expired certificate until somebody notices.

      A renewal writing the .pfx is not atomic, so a load attempted mid-write
      fails. Keep serving the certificate we already have - it is still valid -
      and try again on the next connection, but only once per distinct
      timestamp, so a genuinely corrupt file cannot turn into a load attempt on
      every request forever.
    #>
    if (-not $script:TlsCert -or -not $script:TlsCertPath) { return }

    $stamp = $null
    try { $stamp = (Get-Item -LiteralPath $script:TlsCertPath).LastWriteTimeUtc } catch { return }

    if ($stamp -le $script:TlsCertStamp) { return }
    if ($script:TlsReloadFailed -and $stamp -eq $script:TlsReloadFailed) { return }

    try {
        $fresh = New-Object Security.Cryptography.X509Certificates.X509Certificate2(
            $script:TlsCertPath, $script:PfxPassword, $script:TlsKeyFlags)
        if (-not $fresh.HasPrivateKey) { $fresh.Dispose(); throw "no private key" }

        $old = $script:TlsCert
        $script:TlsCert      = $fresh
        $script:TlsCertStamp = $stamp
        $script:TlsReloadFailed = $null
        if ($old) { try { $old.Dispose() } catch { } }

        Write-Diag "  Reloaded $script:TlsCertId - now expires $($fresh.NotAfter.ToString('d MMM yyyy'))" 'Green'
    }
    catch {
        $script:TlsReloadFailed = $stamp
        Write-Diag "  ! Could not reload $script:TlsCertId : $(($_.Exception.Message -split "`n")[0].Trim())" 'Yellow'
    }
}

$scheme  = $(if ($script:TlsCert) { 'https' } else { 'http' })
$urlHost = $(if ($script:TlsCert) { $script:Web.hostname } else { '127.0.0.1' })

# IPAddress.Loopback, never IPAddress.Any: this must not be reachable from the
# network, only from this machine. A hostname in the URL changes nothing about
# that - it resolves to 127.0.0.1 through the hosts file and goes no further.
try {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port)
    $listener.Start()
}
catch {
    # Port 0 cannot collide, so this only happens once a port is pinned. Say
    # which and stop, rather than falling back to a random one - that would
    # silently undo the pinning the hostname depends on.
    Write-Diag ""
    Write-Diag "  Could not listen on port $Port." 'Red'
    Write-Diag "  $(($_.Exception.Message -split "`n")[0].Trim())" 'DarkGray'
    $owner = $null
    try {
        $conn = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)[0]
        if ($conn) { $owner = (Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue) }
    } catch { }
    if ($owner) { Write-Diag "  Port $Port is held by $($owner.ProcessName) (pid $($owner.Id))." 'Yellow' }
    Write-Diag "  Change the port under Settings > Tracker address, or stop whatever is using it." 'DarkGray'
    Write-Diag ""
    exit 1
}

$actualPort = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
$url = "${scheme}://${urlHost}:$actualPort/?t=$script:Token"

# Written before anything is served, so the launcher can find a service that
# started at boot with nobody watching.
Write-SessionFile -ActualPort $actualPort -Url $url

Write-Diag ""
Write-Diag "  SSL Certificate Tracker" 'Cyan'
Write-Diag "  $PSScriptRoot" 'DarkGray'
Write-Diag ""
Write-Diag "  Listening on 127.0.0.1:$actualPort (this PC only)" 'Green'

if ($script:TlsCert) {
    Write-Diag "  HTTPS as $($script:Web.hostname), using $script:TlsCertId (expires $($script:TlsCert.NotAfter.ToString('d MMM yyyy')))" 'Green'

    # A certificate that loaded is not the same as a URL that opens. If the name
    # does not resolve to this machine the browser never reaches us at all, and
    # the failure looks like the server being down rather than one missing line
    # in a file - so say the line.
    $entry = Get-HostsEntry -HostName $script:Web.hostname
    if (-not $entry.present) {
        Write-Diag "  ! $($script:Web.hostname) is not in the hosts file, so that URL will not resolve." 'Yellow'
        Write-Diag "    Add this line to $(Get-HostsFilePath) as administrator:" 'DarkGray'
        Write-Diag "      127.0.0.1  $($script:Web.hostname)" 'White'
    }
    elseif ($entry.address -ne '127.0.0.1') {
        Write-Diag "  ! $($script:Web.hostname) is in the hosts file pointing at $($entry.address), not 127.0.0.1." 'Yellow'
    }
}
elseif ($tlsNote) {
    # Never silent. Falling back to HTTP without saying so is how someone ends
    # up believing the page is encrypted when it is not.
    Write-Diag "  HTTPS is configured but NOT active: $tlsNote" 'Yellow'
    Write-Diag "  Settings > Tracker address explains which piece is missing." 'DarkGray'
}

if ($ServiceMode) {
    # No console read this, and no desktop to open a browser on. The session
    # file is the only way anyone finds the URL, so say where it is.
    Write-Diag "  Running as a service. Open it with 'Open Tracker.bat'." 'DarkGray'
    Write-Diag "  Session details: $script:SessionFile" 'DarkGray'
}
else {
    Write-Diag ""
    Write-Diag "  If your browser did not open, paste this in:" 'DarkGray'
    Write-Diag "  $url" 'White'
    Write-Diag ""
    Write-Diag "  Close this window to stop the server." 'DarkGray'
    Write-Diag ""
}

# Never in service mode: Start-Process on a URL from session 0 opens nothing a
# person can see, and can sit there holding the start-up sequence.
if (-not $NoBrowser -and -not $ServiceMode) {
    try { Start-Process $url } catch { Write-Diag "  Could not open the browser automatically." 'Yellow' }
}

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        $stream = $null
        try {
            $client.ReceiveTimeout = 15000
            $client.SendTimeout    = 30000
            $stream = $client.GetStream()

            if ($script:TlsCert) {
                # The renewal runs from the scheduled task, not from here, so the
                # file under us can be replaced while we hold the old one. Notice
                # and reload, or the page keeps serving a certificate that has
                # already been renewed - which reads exactly like a renewal that
                # never happened.
                Update-TlsCertificate

                $ssl = New-Object Net.Security.SslStream($stream, $false)
                try {
                    # checkCertificateRevocation is a CLIENT concern; this is the
                    # server side and there is no client certificate to revoke.
                    $ssl.AuthenticateAsServer($script:TlsCert, $false,
                        [Net.SecurityProtocolType]::Tls12, $false)
                }
                catch {
                    # Anything speaking plain HTTP to this port lands here, and so
                    # does a client with no TLS 1.2. Drop that one connection and
                    # carry on - an unhandled throw here would end the accept loop
                    # and take the server down with it.
                    try { $ssl.Dispose() } catch { }
                    throw
                }
                $stream = $ssl
            }

            $request = Read-HttpRequest -Stream $stream
            if ($request) {
                try { Invoke-Route -Request $request -Stream $stream }
                catch {
                    # A handler blowing up must not take the server down with
                    # it - report it and keep listening. Through Write-Diag so
                    # it survives having no console: under a service this file
                    # is the only evidence anything went wrong.
                    $msg = ($_.Exception.Message -split "`n")[0].Trim()
                    Write-Diag "  ! $($request.Method) $($request.Path) -> $msg" 'Red'
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

    # Disposing the certificate removes the key container Windows created when
    # the PFX was opened - it was loaded without PersistKeySet precisely so this
    # would clean up after itself. A server restarted daily would otherwise
    # leave one key file behind per start, forever.
    if ($script:TlsCert) { try { $script:TlsCert.Dispose() } catch { } }

    # Clear the session file on the way out so the next start is not told a
    # server is already running by a file describing a process that has gone.
    # Get-RunningInstance also checks the pid is alive, so this is belt and
    # braces - but a stale file naming a live-but-unrelated pid is exactly the
    # confusion worth avoiding.
    try { if (Test-Path $script:SessionFile) { Remove-Item -LiteralPath $script:SessionFile -Force } } catch { }
    Write-Diag "  Server stopped." 'DarkGray'
}
