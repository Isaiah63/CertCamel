<#
  Putting a certificate where the console will actually find it.

  certs\<name>\ has two files that must both be present or the folder is
  invisible: cert.cer, which is the only file Find-CertificateForHost reads, and
  fullchain.pfx, which is what the server loads. The .pfx must also open with
  the one password the server uses. Miss any of that and a perfectly good
  certificate sits in the right folder being silently ignored, while the console
  falls back to plain HTTP and says so in a log nobody has open.

  import-console-cert.ps1 exists so nobody has to know that, and this is what
  stops the knowledge quietly leaving it again.

  The other half is refusing to make things worse. Replacing a working
  certificate with one that does not cover the name, or has expired, or has no
  private key, takes the console down - and the console is the thing that would
  have explained why. Every check has to happen before anything on disk moves.

  Uses a hostname under .invalid, which is reserved and can never be a real
  certificate here, and removes the folder afterwards.

      powershell -ExecutionPolicy Bypass -File .\v21-import-console-cert-test.ps1
#>

$ErrorActionPreference = 'Stop'
$repo   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$appDir = Join-Path $repo 'resources'

# Run against a COPY of the two scripts, in a scratch folder.
#
# acme-lib derives every path from the folder above itself, so a copy in
# scratch\resources\ puts certs\, audit.log and the rest under scratch\ - and
# this suite stops touching the operator's install at all.
#
# It used to run the real script in place, which wrote a genuine audit entry per
# import. Those are correct entries - the tool audits what it does - but
# Get-RenewalTally counts every renew/ok line, so each run of this suite quietly
# added to the lifetime "certificates renewed" figure in the sidebar. A test
# that changes a number the operator reads is a test that lies to them.
$sandbox    = Join-Path $env:TEMP ('camel-import-sandbox-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$sandboxRes = Join-Path $sandbox 'resources'
New-Item -ItemType Directory -Path $sandboxRes -Force | Out-Null
foreach ($f in @('acme-lib.ps1', 'import-console-cert.ps1')) {
    Copy-Item -LiteralPath (Join-Path $appDir $f) -Destination (Join-Path $sandboxRes $f) -Force
}

$script:ImportScript = Join-Path $sandboxRes 'import-console-cert.ps1'
. (Join-Path $sandboxRes 'acme-lib.ps1')

$script:Failed = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    if ($Ok) { Write-Host "  ok   $Name" -ForegroundColor Green }
    else     { Write-Host "  FAIL $Name  -- $Detail" -ForegroundColor Red; $script:Failed++ }
}

$tag      = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$testHost = "import-$tag.invalid"
$otherHost = "other-$tag.invalid"
$destDir  = Join-Path $script:CertsDir $testHost
$scratch  = Join-Path $env:TEMP "camel-import-$tag"

function New-TestPfx {
    param([string]$Subject, [string]$Pass = '', [int]$Days = 30)
    # -NotBefore is supplied explicitly and always. Without it, it defaults to
    # now, so a negative $Days inverts the window and New-SelfSignedCertificate
    # refuses with PEER_E_INVALID_TIME_PERIOD rather than producing the expired
    # certificate the refusal cases need.
    $notBefore = $(if ($Days -lt 0) { (Get-Date).AddDays($Days - 30) } else { (Get-Date).AddMinutes(-5) })
    $c = New-SelfSignedCertificate -Subject "CN=$Subject" -DnsName $Subject `
            -KeyExportPolicy Exportable -KeyLength 2048 -KeyAlgorithm RSA -HashAlgorithm SHA256 `
            -NotBefore $notBefore -NotAfter (Get-Date).AddDays($Days) `
            -CertStoreLocation 'Cert:\CurrentUser\My'
    $file = Join-Path $scratch ("$Subject-" + [Guid]::NewGuid().ToString('N').Substring(0,4) + '.pfx')
    $bytes = $(if ($Pass) { $c.Export('Pfx', $Pass) } else { $c.Export('Pfx', '') })
    [IO.File]::WriteAllBytes($file, $bytes)
    # Out of the store immediately: these are throwaway keys and leaving them in
    # a personal certificate store is litter that outlives the test run.
    Remove-Item -LiteralPath ('Cert:\CurrentUser\My\' + $c.Thumbprint) -Force -ErrorAction SilentlyContinue
    return $file
}

function Invoke-Import {
    param([string[]]$ArgList)
    # Native stderr is a TERMINATING error under $ErrorActionPreference = 'Stop'
    # in Windows PowerShell 5.1, so a run that correctly refuses something and
    # explains why on stderr would abort this harness instead of being measured
    # - and the failures below are half the point of the suite. Relaxed only
    # around the call.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:ImportScript @ArgList 2>&1
        return @{ code = $LASTEXITCODE; text = ($out | Out-String) }
    }
    finally { $ErrorActionPreference = $prev }
}

New-Item -ItemType Directory -Path $scratch -Force | Out-Null
try {
    # ----------------------------------------------------------------------- #
    Write-Host "`na good certificate lands in a shape the server can find"
    $good = New-TestPfx -Subject $testHost
    $r = Invoke-Import @('-HostName', $testHost, '-Path', $good)
    Check 'the import succeeded' ($r.code -eq 0) $r.text

    Check 'cert.cer was written' (Test-Path (Join-Path $destDir 'cert.cer')) `
          'without it the folder is invisible to Find-CertificateForHost however good the pfx is'
    Check 'fullchain.pfx was written' (Test-Path (Join-Path $destDir 'fullchain.pfx')) `
          'the server has nothing to load'

    # The whole point of re-exporting rather than copying.
    $opened = $null
    try {
        $opened = New-Object Security.Cryptography.X509Certificates.X509Certificate2(
            (Join-Path $destDir 'fullchain.pfx'), $script:PfxPassword)
    } catch { $opened = $null }
    Check 'the pfx opens with the password the server uses' ($null -ne $opened) `
          'the server would skip this certificate silently and serve plain HTTP'
    if ($opened) {
        Check 'and it has its private key' $opened.HasPrivateKey 'exported without the key, so it cannot serve TLS'
        try { $opened.Dispose() } catch { $null = $_ }
    }

    # The real acceptance test: the function the server actually asks.
    $found = Find-CertificateForHost -HostName $testHost
    Check 'Find-CertificateForHost now returns it' ($null -ne $found) `
          'everything was written and the server still cannot see it'
    if ($found) {
        Check 'and it is the folder we wrote' ($found.certId -eq $testHost) "got $($found.certId)"
    }

    # ----------------------------------------------------------------------- #
    Write-Host "`na password on the source file is handled"
    $withPass = New-TestPfx -Subject $testHost -Pass 'correct horse'
    $r = Invoke-Import @('-HostName', $testHost, '-Path', $withPass, '-Password', 'correct horse')
    Check 'imports with the right password' ($r.code -eq 0) $r.text

    $r = Invoke-Import @('-HostName', $testHost, '-Path', $withPass, '-Password', 'wrong')
    Check 'refuses with the wrong password' ($r.code -ne 0) 'a bad password was accepted'
    Check 'and says to pass one' ($r.text -match '-Password') "message was: $($r.text)"

    # ----------------------------------------------------------------------- #
    Write-Host "`nrefusals happen before anything on disk moves"
    $before = (Get-Item -LiteralPath (Join-Path $destDir 'fullchain.pfx')).LastWriteTimeUtc

    $wrongName = New-TestPfx -Subject $otherHost
    $r = Invoke-Import @('-HostName', $testHost, '-Path', $wrongName)
    Check 'a certificate for another name is refused' ($r.code -ne 0) 'installed a certificate that does not cover the name'
    Check 'and it says what it does cover' ($r.text -match 'it covers') "message was: $($r.text)"

    $expired = New-TestPfx -Subject $testHost -Days -5
    $r = Invoke-Import @('-HostName', $testHost, '-Path', $expired)
    Check 'an expired certificate is refused' ($r.code -ne 0) 'installed an expired certificate as though it were a repair'
    Check 'and -Force is offered' ($r.text -match '-Force') "message was: $($r.text)"

    $after = (Get-Item -LiteralPath (Join-Path $destDir 'fullchain.pfx')).LastWriteTimeUtc
    Check 'the working certificate was left untouched by all three refusals' `
          ($after -eq $before) `
          'a refused import still modified the folder - a bad certificate cost the console its working one'

    $r = Invoke-Import @('-HostName', $testHost, '-Path', $expired, '-Force')
    Check '-Force installs it anyway' ($r.code -eq 0) $r.text

    # ----------------------------------------------------------------------- #
    Write-Host "`na PEM is turned away with instructions, not a stack trace"
    $pem = Join-Path $scratch 'cert.pem'
    Set-Content -LiteralPath $pem -Value '-----BEGIN CERTIFICATE-----' -Encoding Ascii
    $r = Invoke-Import @('-HostName', $testHost, '-Path', $pem)
    Check 'a .pem is refused' ($r.code -ne 0) 'tried to open a PEM as a PFX'
    Check 'and the conversion command is given' ($r.text -match 'openssl pkcs12') "message was: $($r.text)"

    # ----------------------------------------------------------------------- #
    Write-Host "`nreplacing a certificate archives the one it replaced"
    $historyDir = Join-Path $destDir 'history'
    $countBefore = @(if (Test-Path $historyDir) { Get-ChildItem -LiteralPath $historyDir -Directory }).Count
    $fresh = New-TestPfx -Subject $testHost -Days 60
    $r = Invoke-Import @('-HostName', $testHost, '-Path', $fresh)
    Check 'the replacement imported' ($r.code -eq 0) $r.text
    $countAfter = @(if (Test-Path $historyDir) { Get-ChildItem -LiteralPath $historyDir -Directory }).Count
    Check 'the previous certificate was archived' ($countAfter -gt $countBefore) `
          "history went from $countBefore to $countAfter - the replaced certificate is gone for good"

    # ----------------------------------------------------------------------- #
    Write-Host "`nrestoring from history needs nothing from outside"
    $r = Invoke-Import @('-HostName', $testHost, '-List')
    Check '-List runs' ($r.code -eq 0) $r.text
    Check '-List shows an archive' ($r.text -match '\d{4}-\d{2}-\d{2}_\d{6}') "output was: $($r.text)"

    # The newest archive at this point is the expired certificate that -Force
    # installed a moment ago, and it must NOT be what "restore the newest"
    # picks. Reaching for -FromHistory means the live certificate has stopped
    # working; handing back the one that just expired is not a recovery.
    $r = Invoke-Import @('-HostName', $testHost, '-FromHistory')
    Check '-FromHistory restores the newest USABLE one, not the newest' ($r.code -eq 0) $r.text

    $restored = Find-CertificateForHost -HostName $testHost
    Check 'and the server can find it afterwards' ($null -ne $restored) `
          'the restore left the folder in a state the server cannot read'
    Check 'what was restored is not expired' `
          ($null -ne $restored -and -not $restored.expired) `
          'restored an expired certificate, which cannot make the console reachable'

    # An explicit -Stamp still means exactly what it says: the skip-expired rule
    # decides what "newest" means, it does not override a direct instruction.
    $expiredStamp = @(Get-ChildItem -LiteralPath $historyDir -Directory | Sort-Object Name -Descending |
                      Where-Object {
                          $c = Join-Path $_.FullName 'cert.cer'
                          if (-not (Test-Path $c)) { return $false }
                          try {
                              $x = New-Object Security.Cryptography.X509Certificates.X509Certificate2 (,[IO.File]::ReadAllBytes($c))
                              return ($x.NotAfter -lt (Get-Date))
                          } catch { return $false }
                      }) | Select-Object -First 1
    if ($expiredStamp) {
        $r = Invoke-Import @('-HostName', $testHost, '-FromHistory', '-Stamp', $expiredStamp.Name)
        Check 'a named expired archive is still refused without -Force' ($r.code -ne 0) `
              'an explicit -Stamp bypassed the expiry check'
        $r = Invoke-Import @('-HostName', $testHost, '-FromHistory', '-Stamp', $expiredStamp.Name, '-Force')
        Check 'and restored with -Force' ($r.code -eq 0) $r.text
    }

    # ----------------------------------------------------------------------- #
    Write-Host "`na name with nothing archived says so"
    $r = Invoke-Import @('-HostName', "empty-$tag.invalid", '-FromHistory')
    Check 'refuses cleanly' ($r.code -ne 0) 'claimed to restore something from an empty history'
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

# Proved rather than assumed: this test writes into the real certs\ folder, and
# a leftover .invalid certificate would show up on the operator's Certificates
# page as a name they have never heard of.
Write-Host "`nthe test left the real install alone"
Check 'the sandbox is gone' (-not (Test-Path $sandbox)) "$sandbox is still there"
Check 'the scratch folder is gone' (-not (Test-Path $scratch)) "$scratch is still there"
# The point of the sandbox, asserted rather than assumed: nothing was written
# into the operator's certs\ folder or their append-only audit trail.
Check 'no test certificate reached the real certs folder' `
      (-not (Test-Path (Join-Path (Join-Path $repo 'certs') $testHost))) `
      'the sandbox is not isolating writes'
Check 'no test entry reached the real audit trail' `
      (-not ((Test-Path (Join-Path $repo 'audit.log')) -and
             ((Get-Content -LiteralPath (Join-Path $repo 'audit.log') -Raw -ErrorAction SilentlyContinue) -match [regex]::Escape($testHost)))) `
      'this run added lines to the operator audit log, inflating the renewal tally'

Write-Host ""
if ($script:Failed) { Write-Host "$script:Failed CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
