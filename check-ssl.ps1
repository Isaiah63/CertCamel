<#
  check-ssl.ps1 - read the TLS certificate expiry for every host in domains.txt
  and write ssl-data.js for ssl-tracker.html to display.

  Everything resolves from $PSScriptRoot, so this folder can be copied anywhere
  (another PC, a USB stick) and still work.

  Hosts are checked in parallel. A sequential pass spends the full timeout on
  every unreachable host in turn, which is fine for three domains and painful
  for a hundred.

  Run it by double-clicking "Check Now.bat", or directly:
      powershell -ExecutionPolicy Bypass -File .\check-ssl.ps1
#>

[CmdletBinding()]
param(
    # Seconds to wait on a connect / handshake before giving up on a host.
    [int]$TimeoutSeconds = 8,

    # How many hosts to check at once. These are idle socket waits rather than
    # CPU work, so the useful number is well above the core count.
    [int]$Concurrency = 12
)

$ErrorActionPreference = 'Stop'

$root       = $PSScriptRoot
$domainList = Join-Path $root 'domains.txt'
$outFile    = Join-Path $root 'ssl-data.js'
$tmpFile    = "$outFile.tmp"

# --------------------------------------------------------------------------- #
# Read the domain list
# --------------------------------------------------------------------------- #

if (-not (Test-Path $domainList)) {
    Write-Host "No domains.txt found next to this script." -ForegroundColor Red
    Write-Host "Run 'First Time Setup.bat' once to create it." -ForegroundColor Red
    exit 1
}

# One host per line. Blank lines and #-comments are ignored. An optional
# ":port" suffix lets you watch mail/IMAP/whatever as well as plain https.
#
# A line like "[Example Product]" opens a category: every domain after it belongs to
# that category until the next header. Domains listed before any header fall
# into $UNCATEGORIZED, so an old flat list keeps working untouched.
$UNCATEGORIZED = 'Uncategorized'

$targets  = @()
$category = $UNCATEGORIZED

# -Encoding UTF8 explicitly: Get-Content otherwise decodes using the ANSI code
# page on PS 5.1, which silently mangles an accented category name or an
# internationalised domain.
foreach ($line in Get-Content $domainList -Encoding UTF8) {
    $entry = $line.Trim()
    if (-not $entry -or $entry.StartsWith('#')) { continue }

    if ($entry -match '^\[(?<c>.+)\]$') {
        $name = $Matches.c.Trim()
        # An empty header "[]" would produce a nameless group; treat it as a
        # return to the default bucket instead.
        $category = if ($name) { $name } else { $UNCATEGORIZED }
        continue
    }

    # A wildcard is a renewal instruction, not something to watch: there is no
    # host called "*.example.com" to open a socket to. It is carried through so
    # the renewal side can build a wildcard certificate for the zone, and is
    # skipped by the checker rather than reported as an unreachable host.
    if ($entry.StartsWith('*.')) {
        $targets += [pscustomobject]@{
            Host = $entry.ToLowerInvariant(); Port = 443
            Category = $category; RenewOnly = $true
        }
        continue
    }

    $port = 443
    if ($entry -match '^(?<h>[^:]+):(?<p>\d+)$') {
        $entry = $Matches.h
        $port  = [int]$Matches.p
    }
    $targets += [pscustomobject]@{ Host = $entry; Port = $port; Category = $category; RenewOnly = $false }
}

if ($targets.Count -eq 0) {
    Write-Host "domains.txt has no domains in it yet - add one per line." -ForegroundColor Yellow
    exit 1
}

# --------------------------------------------------------------------------- #
# The per-host check
# --------------------------------------------------------------------------- #
# This runs inside a runspace, which inherits nothing from this session - no
# functions, no variables, no preferences. Everything it needs is therefore
# defined inside the block, and it takes only primitives as arguments.

$worker = {
    param([string]$HostName, [int]$Port, [string]$Category, [int]$Timeout)

    $ErrorActionPreference = 'Stop'

    function Get-RemoteCertificate {
        param([string]$HostName, [int]$Port, [int]$Timeout)

        $client = $null
        $stream = $null
        try {
            $client = New-Object Net.Sockets.TcpClient
            $client.ReceiveTimeout = $Timeout * 1000
            $client.SendTimeout    = $Timeout * 1000

            # ConnectAsync + Wait so an unroutable host fails on our clock rather
            # than sitting on the OS default of ~20 seconds.
            $connect = $client.ConnectAsync($HostName, $Port)

            # Wait() wraps any failure in an AggregateException whose message is
            # the unhelpful "One or more errors occurred." GetBaseException()
            # digs out the real SocketException, so the page can say
            # "host not found".
            $completed = $false
            try   { $completed = $connect.Wait($Timeout * 1000) }
            catch { throw $_.Exception.GetBaseException() }

            if (-not $completed) { throw "Timed out connecting to ${HostName}:$Port" }

            # Accept any certificate: the whole point is to INSPECT certificates,
            # including expired or otherwise broken ones. We never send data over
            # this connection, so trusting it costs nothing.
            $validate = [Net.Security.RemoteCertificateValidationCallback] { $true }
            $stream = New-Object Net.Security.SslStream($client.GetStream(), $false, $validate)

            # AuthenticateAsClient sends SNI, so shared-IP hosts return their own
            # certificate rather than whatever the default vhost serves.
            $stream.AuthenticateAsClient($HostName)

            New-Object Security.Cryptography.X509Certificates.X509Certificate2 $stream.RemoteCertificate
        }
        finally {
            if ($stream) { $stream.Dispose() }
            if ($client) { $client.Close() }
        }
    }

    # Pull one field (CN, O, ...) out of an X.500 name.
    function Get-DnField {
        param([string]$DistinguishedName, [string]$Field)
        if ($DistinguishedName -match "$Field=([^,]+)") { return $Matches[1].Trim() }
        return $null
    }

    # A readable issuer. Many CAs use a cryptic intermediate CN ("R11", "YE1"),
    # so prefer the organization and keep the CN as a qualifier:
    # "Let's Encrypt (R11)".
    function Get-IssuerLabel {
        param([string]$DistinguishedName)
        $cn = Get-DnField $DistinguishedName 'CN'
        $o  = Get-DnField $DistinguishedName 'O'

        if ($o -and $cn) {
            if ($cn -like "*$o*") { return $cn }   # CN already names the org
            return "$o ($cn)"
        }
        if ($o)  { return $o }
        if ($cn) { return $cn }
        return $DistinguishedName
    }

    function Get-CertificateSans {
        <#
          Every name the certificate actually covers, so a renewal can reproduce
          the live certificate instead of only the names that happen to be
          listed in domains.txt.

          .NET Framework has no typed SAN extension class (that arrived in
          .NET 7), so the extension is formatted to text and parsed. The label
          on each line is localised - "DNS Name=" in English, something else
          elsewhere - so match on the value after the "=" rather than the label,
          then keep only the values shaped like hostnames. That drops IP,
          email and URI entries, and any label wording we did not anticipate.
        #>
        param($Certificate)

        $found = @()
        $ext = $Certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' }
        if (-not $ext) { return $found }

        foreach ($line in (($ext.Format($true)) -split "`r?`n")) {
            if ($line -notmatch '=\s*(?<v>\S+)\s*$') { continue }
            $v = $Matches.v.Trim().TrimEnd('.').ToLowerInvariant()

            # A hostname, optionally wildcarded, with an alphabetic TLD. The TLD
            # test is what keeps "IP Address=10.0.0.1" out.
            if ($v -match '^(\*\.)?([a-z0-9]([a-z0-9\-]*[a-z0-9])?\.)+[a-z]{2,}$') {
                if ($found -notcontains $v) { $found += $v }
            }
        }

        return $found
    }

    try {
        $cert = Get-RemoteCertificate -HostName $HostName -Port $Port -Timeout $Timeout

        [pscustomobject]@{
            host      = $HostName
            port      = $Port
            category  = $Category
            ok        = $true
            notAfter  = $cert.NotAfter.ToString('o')
            notBefore = $cert.NotBefore.ToString('o')
            issuer    = Get-IssuerLabel $cert.Issuer
            subject   = Get-DnField $cert.Subject 'CN'
            sans      = @(Get-CertificateSans $cert)
            # The serial is unique per issuance, which makes it the only value
            # that proves a specific certificate is the one being served. Expiry
            # dates cannot do that: two certificates issued the same day look
            # identical by date, so "days remaining went up" is reassurance
            # rather than evidence. Deployment verification compares serials.
            serial     = $cert.SerialNumber
            thumbprint = $cert.Thumbprint
            renewOnly = $false
            error     = $null
        }
    }
    catch {
        # Keep only the first line - some socket errors are several lines long
        # and would make both the console and the page unreadable.
        $msg = ($_.Exception.Message -split "`n")[0].Trim()

        [pscustomobject]@{
            host      = $HostName
            port      = $Port
            category  = $Category
            ok        = $false
            notAfter  = $null
            notBefore = $null
            issuer    = $null
            subject   = $null
            sans      = @()
            serial     = $null
            thumbprint = $null
            renewOnly = $false
            error     = $msg
        }
    }
}

# --------------------------------------------------------------------------- #
# Check every host, in parallel
# --------------------------------------------------------------------------- #

$wildcardCount = @($targets | Where-Object { $_.RenewOnly }).Count
$hostCount     = $targets.Count - $wildcardCount

Write-Host ""
Write-Host ("Checking $hostCount domain$(if ($hostCount -ne 1) {'s'})" +
            $(if ($wildcardCount) { " (plus $wildcardCount wildcard entr$(if ($wildcardCount -ne 1) {'ies'} else {'y'}) for renewal)" }) +
            '...') -ForegroundColor Cyan
Write-Host ""

$now = Get-Date

# Only real hosts get probed; wildcard entries are recorded as-is.
$probeTargets = @($targets | Where-Object { -not $_.RenewOnly })

$poolSize = [Math]::Max(1, [Math]::Min($Concurrency, [Math]::Max(1, $probeTargets.Count)))
$pool = [runspacefactory]::CreateRunspacePool(1, $poolSize)
$pool.Open()

$running = @()
try {
    foreach ($t in $probeTargets) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($worker).
                  AddArgument($t.Host).
                  AddArgument($t.Port).
                  AddArgument($t.Category).
                  AddArgument($TimeoutSeconds)

        $running += [pscustomobject]@{
            Shell  = $ps
            Handle = $ps.BeginInvoke()
            Target = $t
        }
    }

    # A single rewritten line rather than a line per host: with results landing
    # out of order, a running tally is the only honest live progress.
    #
    # Only when a real console is attached, though. Redirected output (a log
    # file, the scheduled task) does not act on the carriage return, so the
    # counter would pile up as one long line of repeated tallies.
    $showProgress = -not [Console]::IsOutputRedirected

    while ($true) {
        $done = @($running | Where-Object { $_.Handle.IsCompleted }).Count
        if ($showProgress) {
            Write-Host ("`r  {0} of {1} checked" -f $done, $running.Count) -NoNewline -ForegroundColor DarkGray
        }
        if ($done -eq $running.Count) { break }
        Start-Sleep -Milliseconds 150
    }

    # Wipe the counter so the results start on a clean line.
    if ($showProgress) { Write-Host "`r$(' ' * 32)`r" -NoNewline }

    # Keyed by host:port so the console and the payload can be re-emitted in
    # domains.txt order, which is the order the person who wrote the file
    # expects to read them back in.
    $byKey = @{}
    foreach ($r in $running) {
        $key = "$($r.Target.Host):$($r.Target.Port)"
        try {
            $out = $r.Shell.EndInvoke($r.Handle)
            if ($out -and $out.Count -gt 0) { $byKey[$key] = $out[0] }
        }
        catch {
            # The worker catches its own failures, so reaching here means the
            # runspace itself fell over. Record it rather than lose the host.
            $byKey[$key] = [pscustomobject]@{
                host = $r.Target.Host; port = $r.Target.Port; category = $r.Target.Category
                ok = $false; notAfter = $null; notBefore = $null; issuer = $null
                subject = $null; sans = @(); serial = $null; thumbprint = $null; renewOnly = $false
                error = ($_.Exception.Message -split "`n")[0].Trim()
            }
        }
        finally { $r.Shell.Dispose() }
    }
}
finally {
    $pool.Close()
    $pool.Dispose()
}

$results = @()
foreach ($t in $targets) {
    if ($t.RenewOnly) {
        # Carried through with nothing measured: there is no certificate to read
        # from a name that does not resolve. The page keeps these out of the
        # expiry table and the renewal side turns them into a wildcard cert.
        $results += [pscustomobject]@{
            host = $t.Host; port = $t.Port; category = $t.Category
            ok = $false; notAfter = $null; notBefore = $null; issuer = $null
            subject = $null; sans = @(); serial = $null; thumbprint = $null; renewOnly = $true; error = $null
        }
        continue
    }
    $key = "$($t.Host):$($t.Port)"
    if ($byKey.ContainsKey($key)) { $results += $byKey[$key] }
}

# --------------------------------------------------------------------------- #
# Print the results
# --------------------------------------------------------------------------- #
# Printed after the fact rather than as each host lands: in parallel the
# completion order is arbitrary, and a console that jumps between categories is
# harder to read than one that waits and prints the list the way it was written.

$usesCategories = @($targets | Where-Object { $_.Category -ne $UNCATEGORIZED }).Count -gt 0
$lastCategory   = $null
$pad = if ($usesCategories) { '    ' } else { '  ' }

foreach ($r in $results) {
    if ($usesCategories -and $r.category -ne $lastCategory) {
        if ($null -ne $lastCategory) { Write-Host "" }
        Write-Host "  $($r.category)" -ForegroundColor White
        $lastCategory = $r.category
    }

    $label = if ($r.port -eq 443) { $r.host } else { "$($r.host):$($r.port)" }

    if ($r.renewOnly) {
        Write-Host ("$pad{0,-34} {1,-8}       {2}" -f $label, 'WILDCARD', 'renewal only - nothing to measure') -ForegroundColor DarkCyan
    }
    elseif ($r.ok) {
        $days = [math]::Floor((([datetime]$r.notAfter) - $now).TotalDays)
        # Colour the console line the same way the page colours the row.
        $color = if ($days -lt 0) { 'Red' } elseif ($days -le 30) { 'Yellow' } else { 'Green' }
        $state = if ($days -lt 0) { 'EXPIRED' } elseif ($days -le 30) { 'RENEW' } else { 'OK' }
        Write-Host ("$pad{0,-34} {1,-8} {2,4}d  {3}" -f $label, $state, $days, ([datetime]$r.notAfter).ToString('yyyy-MM-dd')) -ForegroundColor $color
    }
    else {
        Write-Host ("$pad{0,-34} {1,-8}       {2}" -f $label, 'ERROR', $r.error) -ForegroundColor Magenta
    }
}

# --------------------------------------------------------------------------- #
# Write ssl-data.js
# --------------------------------------------------------------------------- #

# This is deliberately a .js file, not .json. The tracker is opened straight
# from disk (file://), where fetch() of a sibling file is blocked by CORS even
# though the file is right there. A <script src> tag has no such restriction,
# so assigning to a global is the one approach that works offline.

$payload = [pscustomobject]@{
    generated = $now.ToString('o')
    results   = @($results)
}

# -Depth guards against PS 5.1's default of 2 silently flattening the array.
# Results now nest a SAN array, so this needs headroom beyond the old value.
$json = $payload | ConvertTo-Json -Depth 6

$js = @"
/* Generated by check-ssl.ps1 - do not edit by hand. */
/* Last run: $($now.ToString('yyyy-MM-dd HH:mm:ss')) */
window.SSL_DATA = $json;
"@

# Write BOM-less UTF-8: Set-Content -Encoding utf8 adds a BOM on PS 5.1.
# Via .tmp + move so an interrupted run can't leave a half-written file.
$utf8 = New-Object Text.UTF8Encoding $false
[IO.File]::WriteAllText($tmpFile, $js, $utf8)
Move-Item -Path $tmpFile -Destination $outFile -Force

# Expired and expiring are counted separately - an already-dead certificate is
# a different (worse) problem than one that needs renewing soon.
$live     = @($results | Where-Object { $_.ok })
$expired  = @($live | Where-Object { ([datetime]$_.notAfter - $now).TotalDays -lt 0 }).Count
$expiring = @($live | Where-Object {
                 $d = ([datetime]$_.notAfter - $now).TotalDays
                 $d -ge 0 -and $d -le 30
             }).Count
$failed   = @($results | Where-Object { -not $_.ok -and -not $_.renewOnly }).Count

Write-Host ""
if ($expired -gt 0) {
    Write-Host "  $expired certificate$(if ($expired -ne 1) {'s have'} else {' has'}) ALREADY EXPIRED." -ForegroundColor Red
}
if ($expiring -gt 0) {
    Write-Host "  $expiring domain$(if ($expiring -ne 1) {'s'}) need$(if ($expiring -eq 1) {'s'}) renewal within 30 days." -ForegroundColor Yellow
}
if ($failed -gt 0) {
    Write-Host "  $failed domain$(if ($failed -ne 1) {'s'}) could not be reached." -ForegroundColor Magenta
}
if ($expired -eq 0 -and $expiring -eq 0 -and $failed -eq 0) {
    Write-Host "  All certificates healthy." -ForegroundColor Green
}
Write-Host ""
Write-Host "  Wrote ssl-data.js - open ssl-tracker.html to view." -ForegroundColor Cyan
Write-Host ""
