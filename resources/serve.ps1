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

$script:DiagFile    = Join-Path $script:Root 'server.log'
$script:DiagMaxBytes = 2mb

function Initialize-DiagLog {
    try {
        if ((Test-Path $script:DiagFile) -and (Get-Item $script:DiagFile).Length -gt $script:DiagMaxBytes) {
            # One generation back is enough: this is a breadcrumb trail for "why
            # did the service misbehave last night", not an audit record.
            $old = Join-Path $script:Root 'server.1.log'
            if (Test-Path $old) { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue }
            Move-Item -LiteralPath $script:DiagFile -Destination $old -Force -ErrorAction SilentlyContinue
        }
    }
    catch { $null = $_ }   # rotation failing must not stop the line being written
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
    catch { $null = $_ }   # redaction is best effort; a locked file is retried on the next write
}

Initialize-DiagLog

# Trim run logs once at startup. Doing it here rather than on a timer keeps the
# single-threaded listener free, and a server that has just been started is
# exactly when nobody is waiting on it.
try { [void](Invoke-LogRetention -Settings (Get-TrackerSettings)) } catch { $null = $_ }   # housekeeping must never stop the server starting

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
            catch { $null = $_ }   # a name that will not resolve must not stop the others
        }
        Set-Acl -Path $Path -AclObject $acl
    }
    catch { $null = $_ }   # Get-Acl/Set-Acl unavailable or refused; the file keeps inherited permissions
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
        # The FOLDER, not resources\ - this is what a person is told to look at
        # when two installs are running and they need to know which is which.
        folder    = $script:Root
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

    # HSTS, but ONLY when actually serving over TLS, and deliberately without
    # includeSubDomains or preload.
    #
    # Sent over plain HTTP it is meaningless - browsers ignore the header on a
    # non-TLS response - so guarding on $script:TlsCert is not caution, it is
    # the specification.
    #
    # The omissions matter more than the header. includeSubDomains would apply
    # this policy to every sibling name under the same domain, which for a
    # console named tracker.example.com means the whole of example.com - a
    # setting made here would break unrelated sites elsewhere. preload is worse
    # and close to irreversible: it asks browser vendors to ship the policy, and
    # getting back off that list takes months.
    #
    # And the thing to know before turning this on: once a browser holds an HSTS
    # policy for this name, a certificate error becomes a hard failure with NO
    # "proceed anyway" option. That is the entire point of it, and it is also
    # how you lock yourself out of your own console if the certificate lapses.
    # Cert Camel renews the certificate it serves, and the Renewal row under
    # Settings > Tracker address says whether it really is doing so - check that
    # is green before leaving this on.
    # Opt-in, because of that last paragraph: a policy nobody asked for that can
    # lock them out of their own console is not a safe default. Settings >
    # Tracker address turns it on, and sos-plain-http.ps1 is the way back.
    if ($script:TlsCert -and $script:HstsEnabled) {
        [void]$sb.AppendLine("Strict-Transport-Security: max-age=31536000")
    }
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

function Send-HttpsRedirect {
    <#
      Answer a plain-HTTP request that arrived on the TLS port.

      Without this the handshake fails on a byte it cannot parse and the
      connection is dropped, so a stale http:// bookmark - or anyone's habit of
      typing 127.0.0.1 - produces a forcible close and a browser saying the
      connection was reset. Nothing on screen says the page moved to https, and
      the server looks broken.

      302, never 301. A permanent redirect is cached by the browser, so turning
      HTTPS back off later would leave it still redirecting to a scheme this
      server no longer speaks, with nothing to explain why. Same shape of trap
      as HSTS, smaller blast radius.

      The query string carries over, so a bookmarked ?t= arrives at the other
      side. It is almost certainly a stale token - they are minted per launch -
      but landing on "reopen from Open Tracker.bat" is a better place to be
      than a dead connection.
    #>
    param([IO.Stream]$Stream, $Request, [int]$Port)

    $target = "https://$($script:Web.hostname):$Port$($Request.Path)"
    if ($Request.Query) { $target += "?$($Request.Query)" }

    $html = '<!doctype html><meta charset="utf-8"><title>Cert Camel has moved to HTTPS</title>' +
            '<p>This page is now served over HTTPS: <a href="' + $target + '">' + $target + '</a>'

    Send-Response -Stream $Stream -Status 302 -StatusText 'Found' `
        -ContentType 'text/html; charset=utf-8' `
        -Body ([Text.Encoding]::UTF8.GetBytes($html)) `
        -ExtraHeaders @{ 'Location' = $target }
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
            try { $last = (Get-Content $lastFile -Raw -Encoding UTF8) | ConvertFrom-Json } catch { $null = $_ }   # unreadable: treated as no previous run
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
            # Both the setting and the machine's own zone: the page warns when
            # they differ, because the schedule fires in machine time regardless
            # and that mismatch is exactly what makes a time in an email wrong.
            timeZone     = $(if ($settings.ContainsKey('timeZone')) { [string]$settings.timeZone } else { '' })
            machineZone  = [TimeZoneInfo]::Local.Id
            timeZones    = @(@([TimeZoneInfo]::GetSystemTimeZones()) | ForEach-Object { @{ id = $_.Id; label = $_.DisplayName } })
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
                # Missing from a settings.json written before this alert existed,
                # and Get-TrackerSettings only backfills defaults at the TOP level -
                # so an absent sub-key stays absent. [bool] on $null is $false,
                # which is the right answer for "never turned on".
                scheduledRenewal   = @{ enabled = [bool]$settings.alerts.scheduledRenewal.enabled }
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
        tally         = (Get-RenewalTally)
        catalog       = $catalogOut
        targetCatalog = $targetCatalogOut
        deployment    = $deployOut
        acmeReady     = [bool](Get-VendoredPoshAcme)
        # Read off disk, never from the gallery: the app makes no outbound
        # request on load and this must not become the first one. Answers "what
        # am I running" without anyone having to look inside lib\.
        acmeVersion   = $(
            $v = @(Get-PoshAcmeVersions)
            if ($v.Count) { $v[0].version.ToString() } else { $null }
        )
        # Which copy of Cert Camel this is, and where it lives.
        #
        # Both were already known here and shown nowhere: Get-CamelVersion fed
        # only the update check, and the folder appeared only in the startup
        # banner, which nobody has open. Two installs on one machine - a working
        # copy and an older one opened by mistake - look identical in the browser
        # once the page has rendered, and the way that ends is twenty minutes of
        # debugging a bug that was fixed in the other folder.
        install       = @{
            version = (Get-CamelVersion)
            folder  = $script:Root
        }
    }
}

function Invoke-SaveSettings {
    param($Payload)

    $settings = Get-TrackerSettings

    # Credential keys written during this save. The trail already records a
    # credential being REMOVED (Write-SecretPruneAudit), and the Logs view
    # already offers a "credential changes" filter - but nothing recorded one
    # being SET, so on a normal install that filter was permanently empty and a
    # Cloudflare token being replaced looked exactly like a timezone change.
    #
    # Key names only, never values, which is the same rule the prune audit and
    # Write-AuditEvent itself already follow.
    $secretsSet = @()

    if ($null -ne $Payload.contact) { $settings.contact = [string]$Payload.contact }

    # Display only - see Get-DisplayTimeZone. Validated against the machine's own
    # zone list, because a typo here would otherwise surface much later as every
    # email silently falling back to local time with nothing saying why.
    if ($Payload.PSObject.Properties['timeZone']) {
        $tz = [string]$Payload.timeZone
        if ($tz) {
            try { [void][TimeZoneInfo]::FindSystemTimeZoneById($tz) }
            catch { throw "'$tz' is not a timezone this machine knows about." }
        }
        $settings.timeZone = $tz
    }

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
                $secretsSet += "ca:$id`:eabHmacKey"
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
                    if ($val) {
                        Set-TrackerSecret -Key "$id`:$($a.Name)" -Value ([string]$val)
                        $secretsSet += "$id`:$($a.Name)"
                    }
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
                # Parses AND is one of the two schemes this can actually speak.
                # [Uri] alone accepts file://, ftp:// and anything else with a
                # colon in it, and Invoke-DataPlaneRequest would hand whatever
                # came back to HttpWebRequest::Create. Nobody wants a file:// load
                # balancer, so the narrow check costs nothing and removes the
                # question entirely.
                # IsAbsoluteUri as well as the scheme, because a bare "lb1" casts
                # to a RELATIVE Uri quite happily rather than failing the cast.
                # The scheme test alone would reject it, but on the relative type
                # that property is not meaningfully defined - so this says what is
                # actually wrong with it, which is that it is not a full address.
                $parsed = $null
                try { $parsed = [Uri]$n.url } catch { throw "'$($n.url)' is not a valid URL." }
                if (-not $parsed.IsAbsoluteUri -or $parsed.Scheme -notin @('http', 'https')) {
                    throw "'$($n.url)' must be a full http:// or https:// address."
                }
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
                    if ($val) {
                        Set-TrackerSecret -Key "$id`:$($a.Name)" -Value ([string]$val)
                        $secretsSet += "$id`:$($a.Name)"
                    }
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
        $schedOn   = [bool]($al.PSObject.Properties['scheduledRenewal']  -and $al.scheduledRenewal.enabled)
        $renewOn   = [bool]($al.PSObject.Properties['renewalSuccess']    -and $al.renewalSuccess.enabled)
        $failOn    = [bool]($al.PSObject.Properties['deploymentFailure'] -and $al.deploymentFailure.enabled)
        $monthlyOn = [bool]($al.PSObject.Properties['monthlySummary']    -and $al.monthlySummary.enabled)
        $anyOn     = $expiryOn -or $schedOn -or $renewOn -or $failOn -or $monthlyOn

        if ($anyOn -and (-not $smtp -or -not $smtp.host)) { throw "An SMTP host is required to send any alert." }
        if ($anyOn -and -not $toList.Count)                { throw "At least one alert recipient is required to send any alert." }

        # Blank means "keep what is stored", same rule as every other credential
        # here. This key is fixed rather than per-id (there is only ever one SMTP
        # profile), so unlike CAs, DNS profiles and targets it has nothing to
        # prune - there is no list an id can fall out of.
        if ($smtp -and $smtp.PSObject.Properties['password'] -and $smtp.password) {
            Set-TrackerSecret -Key 'alerts:smtpPassword' -Value ([string]$smtp.password)
            $secretsSet += 'alerts:smtpPassword'
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
            scheduledRenewal   = @{ enabled = $schedOn }
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

        # Derived from the hostname, never read from the payload. HTTPS is not a
        # separate thing to switch on: a name means HTTPS on that name, no name
        # means loopback HTTP. The settings page derives it the same way, and
        # this does not trust it to - a payload asking for https with no
        # hostname would otherwise produce a server that announces HTTPS and
        # falls back to plain HTTP with the reason in a log nobody reads.
        $https = [bool]$name

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

        # HSTS is opt-in and separate from https, because it is the one setting
        # here that can lock somebody out of their own console - see the note in
        # Send-Response. Turning HTTPS off does NOT clear it from a browser that
        # already holds the policy, so it is stored, and cleared, on its own.
        $hsts = [bool]($w.PSObject.Properties['hsts'] -and $w.hsts)
        $settings.web = @{ https = $https; hostname = $name; port = $port; hsts = $hsts }
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

    # Its own line rather than folded into the one above, so "show me every time
    # a credential changed" is one filter rather than a read of every settings
    # save. Deliberately after the save: this records what was stored, not what
    # was attempted.
    if ($secretsSet.Count) {
        Write-AuditEvent -Event 'secret' -Object (($secretsSet | Sort-Object -Unique) -join ', ') `
            -Outcome 'ok' `
            -Detail "stored $(@($secretsSet | Sort-Object -Unique).Count) credential(s) from a settings save"
    }

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
        # Whether the finished log has been masked in place - see
        # Clear-JobLogSecrets, which runs once rather than on every poll.
        swept      = $false
    }

    return $id
}

function Clear-JobLogSecrets {
    <#
      Mask any stored credential in a finished job's log files, once.

      A job started from the page does not self-log: Start-ChildJob redirects the
      child's stdout and stderr straight to disk, so Write-RunLog - and with it
      Protect-LogLine - never sees a word of it. Only the scheduled runs, which
      DO self-log, were ever redacted. That asymmetry made a documented promise
      untrue: a debug line added to a child was supposed to be caught on the way
      in, and instead landed in clear.

      Reading is masked separately, so nothing unredacted can reach the page.
      This is the other half - the bytes on disk, which outlive the session and
      sit in jobs\ under log retention for ninety days.

      Only once the child has EXITED. Rewriting a file it still has an open
      handle on would either fail or race its next write, and the reader already
      covers the window in between.
    #>
    param($Job)

    if ($Job.swept) { return }

    foreach ($f in @($Job.log, $Job.err)) {
        if (-not $f -or -not (Test-Path $f)) { continue }
        try {
            $raw = [IO.File]::ReadAllText($f)
            if (-not $raw) { continue }
            $clean = Protect-LogLine $raw
            # Only rewrite when something actually changed: the common case is a
            # clean log, and this runs for every job that finishes.
            if ($clean -ne $raw) {
                [IO.File]::WriteAllText($f, $clean, [Text.Encoding]::UTF8)
            }
        }
        catch { $null = $_ }   # a locked or vanished log is not worth failing a poll over
    }

    $Job.swept = $true
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

    # The child has let go of its handles, so the files can be cleaned in place.
    if (-not $running) { Clear-JobLogSecrets -Job $j }

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
            } catch { $null = $_ }
        }
    }

    # Masked on the way out as well as on disk. While a job is still running its
    # file has not been swept yet, and this is what stands between a credential
    # echoed by a child and the panel somebody is watching it in.
    $log = Protect-LogLine $log

    $result = $null
    if (-not $running -and (Test-Path $j.result)) {
        try { $result = (Get-Content $j.result -Raw -Encoding UTF8) | ConvertFrom-Json } catch { $null = $_ }   # half-written or corrupt: the job simply reports no result
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

    # Guard against DNS rebinding: a hostile page can point a name it controls
    # at 127.0.0.1, but it cannot make the browser send our Host header.
    #
    # ABOVE the static routes, not inside the API branch where this started.
    # The token gate is no help against rebinding, because rebinding goes for
    # what needs no token - and /ssl-data.js is the entire estate: every
    # hostname, issuer, expiry and serial, readable by any script that has
    # made itself same-origin with us. This is what covers it.
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

    # Now that this runs in front of the pages too, the rejection can land in
    # front of a person rather than only in an XHR - so it says what to do, the
    # same way the token gate below does. It gives nothing away: an address this
    # server answers to is not a secret from whoever just typed one.
    if (-not $hostOk) {
        Send-Error $Stream 403 'This server does not answer to that address. Open the tracker from "Open Tracker.bat".'
        return
    }

    # --- static ------------------------------------------------------------ #
    # Served from BOTH roots, and which one is not arbitrary. The app shell and
    # its assets ship with the program, so they are under resources\ with the
    # scripts. The guides and ssl-data.js sit in the folder itself - the guides
    # because someone is meant to find and open them without going hunting, and
    # ssl-data.js because it is generated output like every other file up there.

    if ($path -eq '/' -or $path -eq '/index.html' -or $path -eq '/ssl-tracker.html') {
        $file = Join-Path $script:AppDir 'ssl-tracker.html'
        if (-not (Test-Path $file)) { Send-Error $Stream 404 'ssl-tracker.html is missing.'; return }
        $html = Get-Content $file -Raw -Encoding UTF8
        Send-Response -Stream $Stream -ContentType $script:Mime['.html'] -Body ([Text.Encoding]::UTF8.GetBytes($html))
        return
    }

    # The guides. One route rather than three near-identical ones: they are
    # shipped files handed back verbatim, and nothing here rewrites them any
    # more. That changed when their mastheads stopped linking back to the app -
    # the link needed this launch's token pasted into it, which is why the
    # rewriting existed at all, and why it kept having to be reasoned about
    # every time the token rules moved. They link to each other now, and the
    # way back to the tracker is the tab it was opened from.
    #
    # An allow-list, not a directory: these four are the whole set, so a
    # membership test does the job a traversal guard would otherwise have to.
    #
    # It has to match what the Docs view offers. windows-server-setup.html was
    # added to that list and not to this one, so the app linked to a guide the
    # server refused to serve - a 404 from a link the page itself drew.
    $docPages = @('readme.html', 'haproxy-setup.html', 'security.html',
                  'windows-server-setup.html')
    if ($docPages -contains $path.TrimStart('/')) {
        $name = $path.TrimStart('/')
        $file = Join-Path $script:Root $name
        if (-not (Test-Path $file)) { Send-Error $Stream 404 "$name is missing."; return }
        $html = Get-Content $file -Raw -Encoding UTF8
        Send-Response -Stream $Stream -ContentType $script:Mime['.html'] -Body ([Text.Encoding]::UTF8.GetBytes($html))
        return
    }

    if ($path -eq '/ssl-data.js') {
        $file = Join-Path $script:Root 'ssl-data.js'
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
        $assetsRoot = Join-Path $script:AppDir 'assets'
        $relative   = $path.Substring('/assets/'.Length) -replace '/', '\'
        $requested  = Join-Path $assetsRoot $relative

        $full = $null
        # A path this malformed cannot be inside the web root, which is the only
        # question being asked. Leaving $full empty makes the check below refuse it.
        try { $full = [IO.Path]::GetFullPath($requested) } catch { $null = $_ }
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
    # Read here rather than at the top of the router: the API is the only thing
    # that wants it now. The doc pages used to need to know whether the caller
    # held one, back when they were handed a link with the token in it.
    #
    # WHICH of the two forms carried it is kept, not merely that one of them
    # did: /api/download hands back a private key and takes the header form
    # only, so no URL on its own is ever enough to fetch one. See that route.
    $headerToken = $null
    if ($Request.Headers.ContainsKey('x-tracker-token')) { $headerToken = $Request.Headers['x-tracker-token'] }
    $supplied = $headerToken
    if (-not $supplied) { $supplied = Get-QueryValue -Query $Request.Query -Name 't' }
    $hasToken       = Test-Token $supplied
    $tokenViaHeader = $hasToken -and -not [string]::IsNullOrEmpty($headerToken)

    if (-not $hasToken) {
        Send-Error $Stream 403 'Missing or invalid session token. Reopen the tracker from "Open Tracker.bat".'
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

        <#
          The checker's output as data.

          ssl-data.js reaches the browser as a <script> tag at page load, which
          is why every expiry date on the page was frozen at whatever it said
          when the tab opened - a renewal could land and the page went on
          showing the old date until somebody pressed reload. A script tag
          cannot be re-read; this can.

          Same content, parsed rather than executed. The file stays exactly as
          it is: it is what makes ssl-tracker.html work from disk with no server
          at all, and that is worth keeping.
        #>
        '^/api/checker$' {
            Send-Json $Stream (Get-CheckerResults)
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
            # Comma-joined, not appended one per element: -File binds a single
            # token per parameter, so a second bare value would slide into the
            # next free positional slot. See Expand-ListArgument.
            $scriptArgs = @((Join-Path $PSScriptRoot 'deploy.ps1'), '-ResultPath', $resultPath, '-Cert', ($certIds -join ','))
            if ($chosen.Count) { $scriptArgs += @('-TargetList', ($chosen -join ',')) }

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

        '^/api/loadbalancers$' {
            if ($Request.Method -ne 'GET') { Send-Error $Stream 405 'Use GET.'; return }

            # Cache only. This must never touch the network: an unreachable node
            # takes ten seconds to fail and this server handles one connection
            # at a time, so probing here would freeze every other view for as
            # long as it took - precisely when someone is trying to find out
            # what is broken. /api/loadbalancers/refresh does the probing, out
            # of process.
            $cache = Get-LoadBalancerCache

            # Whether the panel should appear at all is a question about
            # configuration, not about the cache - a fresh install with targets
            # but no sweep yet still wants the panel, saying "not checked yet".
            $settings = Get-TrackerSettings

            # Reconciliation is pure computation over the cache and settings -
            # no network - so it is safe here even though the sweep that filled
            # the cache is not.
            $recon = @()
            $reconError = $null
            try {
                $checker = Get-CheckerResults
                $groups  = Get-CertificateGroups -Results @($checker.results) -Settings $settings `
                                -ZoneCache (Get-ZoneCache)
                $recon = @(Get-CrtListReconciliation -Settings $settings -Cache $cache -Groups @($groups.certs))
            }
            catch { $reconError = ($_.Exception.Message -split "`n")[0].Trim() }

            Send-Json $Stream @{
                checkedAt   = $cache.checkedAt
                targets     = @($cache.targets)
                haveTargets = [bool](@($settings.targets).Count -gt 0)
                groups      = $recon
                groupError  = $reconError
            }
            return
        }

        '^/api/loadbalancers/refresh$' {
            if ($Request.Method -ne 'POST') { Send-Error $Stream 405 'Use POST.'; return }
            $id = Start-ChildJob -Kind 'lb' -ScriptArgs @((Join-Path $PSScriptRoot 'check-lb.ps1'))
            Send-Json $Stream @{ jobId = $id }
            return
        }

        '^/api/update$' {
            # GET reports, POST applies. Split so that looking is always safe -
            # the page checks on render, and nothing should change because
            # somebody opened Settings.
            if ($Request.Method -eq 'GET') {
                $status = Get-UpdateStatus -Fetch
                # A copy with no .git - a ZIP download, or a machine without git
                # at all - cannot answer the question by fetching, so ask GitHub
                # for the newest published release instead. Only on this path: a
                # clone already has a better answer and should not be waiting on
                # a second network call to get it.
                if (-not $status.isRepo) { $status.release = (Get-LatestRelease) }
                # A check that could not complete left no trace anywhere before -
                # only the POST that applies an update was written down. On an
                # unattended box the log is the only witness there was.
                if (-not $status.ok) { Write-Diag "  Update check could not complete: $($status.reason)" 'Yellow' }
                Send-Json $Stream $status
                return
            }
            if ($Request.Method -ne 'POST') { Send-Error $Stream 405 'Use GET or POST.'; return }

            $r = Invoke-TrackerUpdate
            Write-AuditEvent -Event 'settings' -Object 'update' `
                -Outcome $(if ($r.ok) { 'ok' } else { 'fail' }) `
                -Detail $(if ($r.ok) { "$($r.applied) commit(s): $($r.from) -> $($r.to)" } else { $r.error })
            if (-not $r.ok) { Send-Error $Stream 400 $r.error; return }
            Send-Json $Stream $r
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

            # Reads settings.json FROM DISK, not from whatever is typed into the
            # form. Testing an unsaved profile would report on the previous one
            # and mean nothing, so the page saves before calling this.
            $subject = 'Cert Camel test email'
            try {
                $settings = Get-TrackerSettings
                $receipt = Send-AlertEmail -Settings $settings -Subject $subject `
                    -Body "This is a test message from Cert Camel, sent $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')).`r`n`r`nIf this arrived, alerts are configured correctly."

                Write-EmailAuditEvent -Receipt $receipt -Subject $subject

                # The receipt goes back so the page can say what was actually
                # established - accepted by this server, for these recipients,
                # under this id - rather than the word "sent", which claims
                # something nobody here can know.
                Send-Json $Stream @{ ok = $true; receipt = $receipt }
            }
            catch {
                $why = ($_.Exception.Message -split "`n")[0].Trim()
                Write-EmailAuditEvent -ErrorMessage $why -Subject $subject
                Send-Error $Stream 400 $why
            }
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
                catch { $null = $_ }   # an unreadable audit file must not take the page down
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
            try { $full = [IO.Path]::GetFullPath((Join-Path $script:JobsDir $name)) } catch { $null = $_ }   # unparseable name: $full stays empty and the request is refused
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

            # Masked on the way out. Run logs from the page are the child's own
            # stdout, captured by Start-ChildJob and never passed through
            # Write-RunLog, so this is the only thing standing between a
            # credential a child echoed and the Logs page. Finished logs are also
            # cleaned on disk by Clear-JobLogSecrets; this covers the ones still
            # being written, and any that predate that sweep.
            $text = Protect-LogLine $text

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

            # Comma-joined - see the deploy handler above and Expand-ListArgument.
            $scriptArgs = @((Join-Path $PSScriptRoot 'renew.ps1'), '-ResultPath', $resultPath, '-Zone', ($zones -join ','))
            if ($null -ne $deployTargets) {
                if ($deployTargets.Count) { $scriptArgs += @('-TargetList', ($deployTargets -join ',')) }
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
            # The header form of the token only, never ?t=.
            #
            # This is the one route that hands a secret BACK. Everything else
            # the API knows is write-only: a stored credential returns as a
            # boolean saying it exists, never as itself. A GET whose whole
            # credential rides in the URL breaks that rule, because a URL is
            # the leakiest place a live token can sit - browser history, a
            # synced profile, the download list, any screenshot of the window.
            # None of that would matter for a secret that died with the tab,
            # but the server task starts at boot and mints one token for the
            # machine's whole uptime, so an address copied out of history weeks
            # later still spends. The page fetches this over XHR and saves the
            # blob itself, so no address that can produce a private key exists.
            if (-not $tokenViaHeader) {
                Send-Error $Stream 403 'Download this from the tracker page rather than by opening its address.'
                return
            }

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
    try { Remove-Item -LiteralPath $script:SessionFile -Force -ErrorAction SilentlyContinue } catch { $null = $_ }
}
if ($existing) {
    $opened = $false
    if (-not $NoBrowser -and -not $ServiceMode) {
        try { Start-Process $existing.url; $opened = $true } catch { $null = $_ }   # $opened stays false and the URL is printed instead
    }

    # Exit 10 means "there was already a server, the browser is open, this window
    # did nothing". 'Open Tracker.bat' checks for it and closes without the
    # usual message and keypress - there is nothing here to read, and making
    # someone dismiss a window to get at a page that is already in front of them
    # is friction for its own sake.
    #
    # Only when the running copy is the BOOT TASK. A second console hosting it
    # is a more surprising thing to find, and worth a window that says so rather
    # than one that vanishes.
    #
    # And only when the browser actually launched: if Start-Process threw, this
    # window is the sole remaining evidence of the URL, so it stays open and
    # prints it.
    if ($existing.service -and $opened) { exit 10 }

    Write-Diag ""
    Write-Diag "  Cert Camel is already running (pid $($existing.pid), port $($existing.port))." 'Yellow'
    if ($existing.service) {
        Write-Diag "  It was started at boot by the 'Cert Camel Server' task, so it survives sign-out." 'DarkGray'
    }
    Write-Diag "  Open it with:" 'DarkGray'
    Write-Diag "  $($existing.url)" 'White'
    Write-Diag ""
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

# How often the running server re-asks which certificate covers its own name,
# when the file it pinned has not itself changed. Two minutes: the case it
# exists for - a certificate issued into a folder we were not watching - follows
# an ACME round trip somebody is already waiting on, so it does not need to be
# instant, and a scan of certs\ is cheap but not free.
$script:TlsResolveEvery = 120
$script:TlsResolvedAt   = $null
$script:TlsReloadFailed = $null

# A single failed handshake is normally a browser opening a speculative
# connection and hanging up, which is why the accept loop swallows it. A RUN of
# them with no success in between is a different thing entirely: a certificate
# that loaded and cannot serve. Counted so that case can reach the log, since
# nothing else in it would say so.
$script:TlsHandshakeFails    = 0
$script:TlsHandshakeLoggedAt = $null
$script:TlsHandshakeAlertAt  = 5

# Read once at startup rather than per response. -NoTls implicitly disables it
# too: that switch exists to get the console back when TLS is the problem, and a
# recovery mode that still sent HSTS would be no recovery at all.
$script:HstsEnabled = [bool]($script:Web.hsts) -and -not $NoTls

function Test-TlsServerHandshake {
    <#
      Prove a certificate can complete a server handshake, rather than trusting
      that it loaded.

      HasPrivateKey is not that proof. A PFX can load, report a private key, and
      still be unusable by schannel - which is what a boot-time S4U start
      produces when no user profile has been loaded. The startup line then
      announces HTTPS while every connection dies mid-handshake, and the
      connection-level catch in the accept loop swallows the reason, so the log
      of a server that cannot serve one page is identical to a healthy one.

      So: one real handshake against ourselves on a throwaway loopback port.
      Milliseconds, once per candidate certificate.

      The client half accepts any certificate deliberately. It is not a trust
      decision - both ends are this process, and the question is whether the key
      can be used at all, not whether the name matches.

      The client half also has to stay on THIS thread. Its validation callback
      is a script block, and a script block invoked on a .NET thread-pool thread
      has no runspace to run in. So the server half is the one that goes async.
    #>
    # The validation callback below declares four parameters and uses none of
    # them, which PSReviewUnusedParameter reports four times. The signature is
    # not ours to shorten - it is .NET's RemoteCertificateValidationCallback -
    # and ignoring every argument is the entire point: both ends of that socket
    # are this process, so there is no peer to make a trust decision about.
    #
    # Suppressed here rather than excluded in PSScriptAnalyzerSettings.psd1, so
    # the rule keeps reporting genuinely unused parameters everywhere else.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Fixed RemoteCertificateValidationCallback signature; the callback exists to ignore its arguments.')]
    param([Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)

    $listener = $null; $client = $null; $server = $null
    $serverSsl = $null; $clientSsl = $null
    try {
        $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
        $listener.Start()

        $client = New-Object Net.Sockets.TcpClient
        if (-not $client.ConnectAsync('127.0.0.1', $listener.LocalEndpoint.Port).Wait(5000)) {
            return $false
        }
        # The peer has to be the client this function created. The listener sits
        # on an ephemeral loopback port for only a few milliseconds, but any
        # local process could reach it first, and a handshake against somebody
        # else's socket answers a different question than the one being asked:
        # it would report a working certificate as unusable and drop the server
        # to plain HTTP. Anything that is not our own client is closed and the
        # accept retried, bounded so a process connecting in a loop cannot hold
        # startup here. Our own connection is already queued by the time
        # ConnectAsync has completed, so a bounded retry always reaches it.
        $server = $null
        for ($attempt = 0; $attempt -lt 4 -and -not $server; $attempt++) {
            $accepted = $listener.AcceptTcpClient()
            if ($accepted.Client.RemoteEndPoint.ToString() -eq $client.Client.LocalEndPoint.ToString()) {
                $server = $accepted
            }
            else {
                try { $accepted.Close() } catch { $null = $_ }   # not our client, and the retry is what matters
            }
        }
        if (-not $server) { return $false }

        # Both sockets get a deadline before either end starts a handshake.
        # AuthenticateAsClient takes no timeout and blocks on a read, so when the
        # server half cannot authenticate - the exact case this function exists
        # to detect - the client would otherwise wait forever and hang startup,
        # which is a worse failure than the one being tested for. The underlying
        # NetworkStream honours these and throws, which the catch turns into the
        # $false this is asking about. Three seconds is enormous for a handshake
        # between two sockets in one process on loopback.
        $client.ReceiveTimeout = 3000
        $client.SendTimeout    = 3000
        $server.ReceiveTimeout = 3000
        $server.SendTimeout    = 3000

        $serverSsl  = New-Object Net.Security.SslStream($server.GetStream(), $false)
        $serverTask = $serverSsl.AuthenticateAsServerAsync(
            $Certificate, $false, [Net.SecurityProtocolType]::Tls12, $false)

        $clientSsl = New-Object Net.Security.SslStream(
            $client.GetStream(), $false, { param($a, $b, $c, $d) $true })
        $clientSsl.AuthenticateAsClient('localhost')

        # Wait throws if the server half faulted, and the catch turns that into
        # $false - which is the answer either way.
        return $serverTask.Wait(5000)
    }
    catch { return $false }
    finally {
        # Teardown of a throwaway test rig: a failure closing any of it says
        # nothing about whether the handshake worked, which is already decided.
        if ($clientSsl) { try { $clientSsl.Dispose() } catch { $null = $_ } }
        if ($serverSsl) { try { $serverSsl.Dispose() } catch { $null = $_ } }
        if ($client)    { try { $client.Close()      } catch { $null = $_ } }
        if ($server)    { try { $server.Close()      } catch { $null = $_ } }
        if ($listener)  { try { $listener.Stop()     } catch { $null = $_ } }
    }
}

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
            #
            # Each store is made to prove itself with a real handshake instead of
            # being chosen by whether loading threw. Loading is not the step that
            # fails: under a boot-time S4U start there is no loaded user profile,
            # and UserKeySet can hand back a certificate that reports a private
            # key and still cannot serve, so a fallback keyed on a load exception
            # never fires. Testing the capability is also indifferent to WHY a
            # store does not work, including reasons not anticipated here.
            $rejected = @()
            foreach ($flags in @(
                [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::UserKeySet,
                [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet)) {

                $candidate = $null
                try {
                    $candidate = New-Object Security.Cryptography.X509Certificates.X509Certificate2(
                        $match.pfx, $script:PfxPassword, $flags)
                }
                catch {
                    $rejected += "$flags could not load ($(($_.Exception.Message -split "`n")[0].Trim()))"
                    continue
                }

                if ($candidate.HasPrivateKey -and (Test-TlsServerHandshake -Certificate $candidate)) {
                    $script:TlsCert      = $candidate
                    $script:TlsCertPath  = $match.pfx
                    $script:TlsCertId    = $match.certId
                    # Remembered so a reload after renewal uses the store proven
                    # to work here, instead of rediscovering it.
                    $script:TlsKeyFlags  = $flags
                    # Named in the startup line because otherwise a start that
                    # fell back to the second store reads exactly like one that
                    # did not, and which store answered is the single most
                    # useful fact about a start nobody watched.
                    $script:TlsKeyStore  = $(
                        if ($flags -eq [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet) {
                            'machine key store'
                        } else {
                            'user key store'
                        })
                    # Watched so a renewal that replaces the file underneath us is
                    # picked up. Without this the server keeps presenting the old
                    # certificate until something restarts it, which looks exactly
                    # like a renewal that did not happen.
                    $script:TlsCertStamp = (Get-Item -LiteralPath $match.pfx).LastWriteTimeUtc
                    # Startup IS a resolve, so the interval runs from here rather
                    # than firing a redundant scan on the first connection.
                    $script:TlsResolvedAt = Get-Date
                    break
                }

                $rejected += $(if ($candidate.HasPrivateKey) {
                    "$flags loaded but could not complete a handshake"
                } else {
                    "$flags has no usable private key"
                })
                # A candidate that cannot serve is of no further use, and the
                # next one is what decides the outcome.
                try { $candidate.Dispose() } catch { $null = $_ }
            }

            if (-not $script:TlsCert) {
                # Plain HTTP is the right failure. The page stays reachable on
                # loopback and this line says why, where a listener that accepts
                # every connection and closes it mid-handshake says nothing at
                # all - and leaves no way in to read the explanation.
                $tlsNote = "$($match.certId) cannot serve TLS - $($rejected -join '; ') - serving plain HTTP"
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
      Pick up a renewal that replaced the certificate under us - and, just as
      importantly, one that landed somewhere else entirely.

      Startup asks Find-CertificateForHost which certificate a client would
      accept for this name. That answer is not permanent: split the console's
      name out of a SAN certificate and the file we pinned stops covering it,
      and issuing the console its own certificate puts the right one in a folder
      we were never watching. Pinning one certId at startup and refreshing only
      that file forever is what made a restart the only way to pick either up.

      So re-ASK rather than re-read, on two triggers:

        - the pinned file changed, which is a renewal landing on it. Immediate,
          because if that renewal dropped our name we are already serving a
          certificate the browser will warn about.
        - otherwise every $script:TlsResolveEvery seconds, which is what catches
          a certificate appearing in a folder we are not watching. Nothing
          cheaper can see that: a new folder is not a change to any file we
          know about yet.

      Called per connection, which sounds extravagant and is one stat call on a
      local file. Re-resolving is dearer - it reads and parses every cert.cer
      under certs\ - so it is what the two triggers gate, not the stat. The
      alternatives are worse: a timer means a second thread in a deliberately
      single-threaded server, and "restart to pick it up" is the bug.

      A renewal writing the .pfx is not atomic, so a load attempted mid-write
      fails. Keep serving the certificate we already have - it is still valid -
      and try again later, but only once per distinct file and timestamp, so a
      genuinely corrupt file cannot turn into a load attempt on every request
      forever.
    #>
    if (-not $script:TlsCert -or -not $script:TlsCertPath) { return }

    $stamp = $null
    try { $stamp = (Get-Item -LiteralPath $script:TlsCertPath).LastWriteTimeUtc } catch { $null = $_ }   # unreadable: treated as 'changed', so the next pass reloads

    # A missing file deliberately does NOT count as changed. Mid-renewal the pfx
    # can briefly not exist, and treating that as a trigger would re-resolve on
    # every connection until it came back. The interval below catches it anyway.
    $changed = $stamp -and ($stamp -gt $script:TlsCertStamp)
    $due     = (-not $script:TlsResolvedAt) -or
               (((Get-Date) - $script:TlsResolvedAt).TotalSeconds -ge $script:TlsResolveEvery)

    if (-not $changed -and -not $due) { return }
    $script:TlsResolvedAt = Get-Date

    $match = $null
    try { $match = Find-CertificateForHost -HostName $script:Web.hostname } catch { $null = $_ }   # no match: falls through to plain HTTP

    # Nothing on disk covers the name any more. Keep what we have: it is still a
    # working handshake, and there is no dropping back to plain HTTP once the
    # listener is up.
    if (-not $match) { return }

    $switching = ($match.certId -ne $script:TlsCertId)

    $target  = $match.pfx
    $tstamp  = $null
    try { $tstamp = (Get-Item -LiteralPath $target).LastWriteTimeUtc } catch { return }

    # Same certificate, same file, nothing new to load.
    if (-not $switching -and $tstamp -le $script:TlsCertStamp) { return }

    # Keyed on file AND timestamp, because the thing that failed may not be the
    # file we were watching last time round.
    $key = "$target|$($tstamp.Ticks)"
    if ($script:TlsReloadFailed -eq $key) { return }

    try {
        $fresh = New-Object Security.Cryptography.X509Certificates.X509Certificate2(
            $target, $script:PfxPassword, $script:TlsKeyFlags)
        if (-not $fresh.HasPrivateKey) { $fresh.Dispose(); throw "no private key" }

        # A renewal has to clear the same bar as the certificate we started with.
        # Without this a renewed file that loads but cannot handshake would be
        # swapped in unattended and take the page down with nobody watching -
        # the failure this tool exists to catch, happening to the tool. Throwing
        # here keeps the current certificate serving, which is still valid.
        if (-not (Test-TlsServerHandshake -Certificate $fresh)) {
            $fresh.Dispose()
            throw "loaded but could not complete a handshake"
        }

        $old = $script:TlsCert
        $script:TlsCert      = $fresh
        $script:TlsCertPath  = $target
        $script:TlsCertId    = $match.certId
        $script:TlsCertStamp = $tstamp
        $script:TlsReloadFailed = $null
        # The superseded certificate is being dropped either way, and a failure
        # disposing it would mask the reload that just succeeded.
        if ($old) { try { $old.Dispose() } catch { $null = $_ } }

        if ($switching) {
            Write-Diag "  Now serving $($match.certId) for $($script:Web.hostname) - expires $($fresh.NotAfter.ToString('d MMM yyyy'))" 'Green'
        }
        else {
            Write-Diag "  Reloaded $script:TlsCertId - now expires $($fresh.NotAfter.ToString('d MMM yyyy'))" 'Green'
        }
    }
    catch {
        $script:TlsReloadFailed = $key
        Write-Diag "  ! Could not load $($match.certId) : $(($_.Exception.Message -split "`n")[0].Trim())" 'Yellow'
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
    } catch { $null = $_ }   # cannot name the process holding the port; the port check still reports it is taken
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
# The folder, not resources\ - this line exists so somebody reading the console
# knows WHICH install is talking, and they know it by the folder they opened.
Write-Diag "  $script:Root" 'DarkGray'
Write-Diag ""
Write-Diag "  Listening on 127.0.0.1:$actualPort (this PC only)" 'Green'

if ($script:TlsCert) {
    Write-Diag "  HTTPS as $($script:Web.hostname), using $script:TlsCertId ($script:TlsKeyStore, expires $($script:TlsCert.NotAfter.ToString('d MMM yyyy')))" 'Green'

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

# Checked on every start, not only at setup. Setup can say this folder is local
# and be perfectly right, and then somebody moves the folder into OneDrive six
# months later, or turns on Known Folder Move, and nothing asks again. This line
# goes to server.log, so a start nobody watched still records it.
$syncedHere = Test-SyncedLocation -Path $script:Root
if ($syncedHere) {
    Write-Diag "  ! This folder is inside $($syncedHere.provider) ($($syncedHere.evidence))." 'Red'
    Write-Diag "    Unencrypted private keys are being copied off this machine." 'Yellow'
    Write-Diag "    Move the folder somewhere local, or exclude it from syncing." 'DarkGray'
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

            $plainOnTls = $false

            if ($script:TlsCert) {
                # The renewal runs from the scheduled task, not from here, so the
                # file under us can be replaced while we hold the old one. Notice
                # and reload, or the page keeps serving a certificate that has
                # already been renewed - which reads exactly like a renewal that
                # never happened.
                Update-TlsCertificate

                # Every TLS record starts 0x16 (handshake). Anything else is a
                # client that came in over plain HTTP, and it gets a redirect
                # rather than a failed handshake.
                #
                # Peeked, not read: SslStream needs the stream positioned at the
                # very first byte, so consuming one here would break every real
                # handshake. SocketFlags.Peek leaves it on the socket.
                $first  = New-Object byte[] 1
                $peeked = 0
                # Peek fails when the client has already gone. Treated as 'no bytes
                # to look at', which is what the caller does with it anyway.
                try { $peeked = $client.Client.Receive($first, 0, 1, [Net.Sockets.SocketFlags]::Peek) } catch { $null = $_ }

                # Nothing arrived before the receive timeout, or the client hung
                # up. Drop it here rather than handing it to the handshake, which
                # would sit through the SAME timeout again - this server is
                # single-threaded, so one silent client costing 30 seconds
                # instead of 15 is a real doubling of the worst case.
                if ($peeked -ne 1) { continue }

                if ($first[0] -ne 0x16) {
                    $plainOnTls = $true
                }
                else {
                    $ssl = New-Object Net.Security.SslStream($stream, $false)
                    try {
                        # checkCertificateRevocation is a CLIENT concern; this is
                        # the server side and there is no client certificate to
                        # revoke.
                        $ssl.AuthenticateAsServer($script:TlsCert, $false,
                            [Net.SecurityProtocolType]::Tls12, $false)
                        $script:TlsHandshakeFails = 0
                    }
                    catch {
                        # A client with no TLS 1.2, or one that hung up mid
                        # handshake. Drop that one connection and carry on - an
                        # unhandled throw here would end the accept loop and take
                        # the server down with it.
                        $why = ($_.Exception.Message -split "`n")[0].Trim()

                        # One failure is noise and stays unlogged. A run of them
                        # with no success in between is a certificate that loaded
                        # and cannot serve, which is otherwise invisible: the
                        # startup line reads identically either way. Rate-limited
                        # so a sustained outage cannot itself flood the log.
                        $script:TlsHandshakeFails++
                        if ($script:TlsHandshakeFails -ge $script:TlsHandshakeAlertAt -and
                            ((-not $script:TlsHandshakeLoggedAt) -or
                             ((Get-Date) - $script:TlsHandshakeLoggedAt).TotalMinutes -ge 10)) {
                            $script:TlsHandshakeLoggedAt = Get-Date
                            Write-Diag "  ! $($script:TlsHandshakeFails) TLS handshakes in a row have failed - $($script:TlsCertId) loaded but cannot serve. Latest: $why" 'Red'
                        }

                        try { $ssl.Dispose() } catch { $null = $_ }   # already failing; the throw below carries the real error
                        throw
                    }
                    $stream = $ssl
                }
            }

            $request = Read-HttpRequest -Stream $stream
            if ($request) {
                if ($plainOnTls) {
                    Send-HttpsRedirect -Stream $stream -Request $request -Port $actualPort
                    continue
                }
                try { Invoke-Route -Request $request -Stream $stream }
                catch {
                    # A handler blowing up must not take the server down with
                    # it - report it and keep listening. Through Write-Diag so
                    # it survives having no console: under a service this file
                    # is the only evidence anything went wrong.
                    $msg = ($_.Exception.Message -split "`n")[0].Trim()
                    Write-Diag "  ! $($request.Method) $($request.Path) -> $msg" 'Red'
                    # Best effort: the connection that caused the fault is often gone
                    # already, and failing to deliver a 500 is not worth a second
                    # error stacked on the one just reported.
                    try { Send-Error $stream 500 $msg } catch { $null = $_ }
                }
            }
        }
        catch {
            # Connection-level faults, not handler faults: a client that vanished
            # mid-request, an aborted TLS handshake, a socket reset. Browsers open
            # speculative connections and drop them constantly, so reporting these
            # would bury the lines that matter. Anything a route throws is already
            # caught and written to the diagnostic log above.
            $null = $_
        }
        finally {
            if ($stream) { try { $stream.Dispose() } catch { $null = $_ } }
            try { $client.Close() } catch { $null = $_ }
        }
    }
}
finally {
    $listener.Stop()

    # Disposing the certificate removes the key container Windows created when
    # the PFX was opened - it was loaded without PersistKeySet precisely so this
    # would clean up after itself. A server restarted daily would otherwise
    # leave one key file behind per start, forever.
    if ($script:TlsCert) { try { $script:TlsCert.Dispose() } catch { $null = $_ } }

    # Clear the session file on the way out so the next start is not told a
    # server is already running by a file describing a process that has gone.
    # Get-RunningInstance also checks the pid is alive, so this is belt and
    # braces - but a stale file naming a live-but-unrelated pid is exactly the
    # confusion worth avoiding.
    # Shutdown housekeeping. A file left behind is untidy rather than harmful, and
    # the next start clears it anyway.
    try { if (Test-Path $script:SessionFile) { Remove-Item -LiteralPath $script:SessionFile -Force } } catch { $null = $_ }
    Write-Diag "  Server stopped." 'DarkGray'
}
