<#
  One fact, one place: the hostname decides whether the console serves HTTPS.

  Removing the "Serve this page over HTTPS" tick-box moved that decision to the
  hostname - but only on the WRITE path. Save-SettingsPayload derived it, while
  Get-WebSettings went on trusting the `https` field stored in settings.json.
  Two sources of truth for one fact, which is exactly what removing the tick-box
  was meant to end.

  It was not merely untidy. sos-plain-http.ps1 - the script you run when HTTPS
  is what is broken - wrote https=false and deliberately KEPT the hostname, on
  the reasoning that the name is what you turn back on with. Under the derived
  write path that name was a live switch: the recovery held until the next time
  anything at all was saved in Settings, at which point https was recomputed as
  true from the surviving name and silently re-armed. Somebody who ran the
  emergency script to escape a broken certificate would find it broken again
  after changing an unrelated setting, with nothing on screen connecting the two.

  So: the read path derives, and the recovery script clears the NAME.

  Reads only. Nothing here writes settings.

      powershell -ExecutionPolicy Bypass -File .\v26-https-single-source-test.ps1
#>

$ErrorActionPreference = 'Stop'
$repo   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$appDir = Join-Path $repo 'resources'
. (Join-Path $appDir 'acme-lib.ps1')

$script:Failed = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    if ($Ok) { Write-Host "  ok   $Name" -ForegroundColor Green }
    else     { Write-Host "  FAIL $Name  -- $Detail" -ForegroundColor Red; $script:Failed++ }
}

function Web { param([hashtable]$W) return (Get-WebSettings -Settings @{ web = $W }) }

# --------------------------------------------------------------------------- #
Write-Host "`na name and a port mean HTTPS"
$r = Web @{ hostname = 'tracker.example.com'; port = 8787 }
Check 'https is on'          $r.https "got $($r.https)"
Check 'the name is kept'     ($r.hostname -eq 'tracker.example.com') "got $($r.hostname)"
Check 'the port is kept'     ($r.port -eq 8787) "got $($r.port)"

Write-Host "`nno name means plain HTTP, whatever the stored flag says"
# The exact shape sos-plain-http.ps1 used to leave behind, and the shape an
# older settings.json can still hold.
$r = Web @{ hostname = ''; port = 8787; https = $true }
Check 'https is off with no name' (-not $r.https) `
      'a stored https=true resurrected HTTPS without a name to serve it on'

Write-Host "`nand a stored flag cannot override the name either way"
$r = Web @{ hostname = 'tracker.example.com'; port = 8787; https = $false }
Check 'https is on despite https=false' $r.https `
      'the stored flag is still being read, so there are two sources of truth again'

$r = Web @{ hostname = 'tracker.example.com'; port = 8787 }
$r2 = Web @{ hostname = 'tracker.example.com'; port = 8787; https = $true }
Check 'the flag makes no difference at all' ($r.https -eq $r2.https) `
      'present and absent https fields produced different answers'

Write-Host "`na name with no fixed port is not a half-state"
# It would pin nothing and fail the handshake on every request, so it reads as
# plain HTTP rather than as something broken.
$r = Web @{ hostname = 'tracker.example.com'; port = 0; https = $true }
Check 'https is off without a fixed port' (-not $r.https) "got $($r.https)"

Write-Host "`nHSTS cannot outlive HTTPS"
# The header is ignored on a plain response, so honouring it would only mean it
# re-arms the moment HTTPS comes back - the opposite of what somebody clearing
# the name is asking for.
$r = Web @{ hostname = ''; port = 8787; hsts = $true }
Check 'hsts is off when there is no name' (-not $r.hsts) `
      'HSTS survived the name being cleared, so the recovery re-arms itself'

Write-Host "`nnothing at all is a working default"
foreach ($case in @(@{}, $null)) {
    $r = Get-WebSettings -Settings $(if ($null -eq $case) { @{} } else { @{ web = $case } })
    Check 'empty settings give plain HTTP on a free port' `
          ((-not $r.https) -and (-not $r.hostname) -and ($r.port -eq 0)) `
          "got https=$($r.https) name='$($r.hostname)' port=$($r.port)"
}

# --------------------------------------------------------------------------- #
Write-Host "`nthe read path really is deriving, not reading"
$libSrc = Get-Content (Join-Path $appDir 'acme-lib.ps1') -Raw -Encoding UTF8
$fn = [regex]::Match($libSrc, 'function Get-WebSettings \{(?<b>[\s\S]*?)\n\}').Groups['b'].Value
Check 'found Get-WebSettings to inspect' ([bool]$fn) 'the function shape changed'
if ($fn) {
    Check 'it does not read the stored https field' `
          ($fn -notmatch '\$out\.https\s*=\s*\[bool\]\$w\.https') `
          'the stored flag is being read again'
    Check 'it derives from hostname and port' `
          ($fn -match '\$out\.https\s*=\s*\[bool\]\(\$out\.hostname\s*-and\s*\$out\.port\)') `
          'the derivation is gone'
}

# --------------------------------------------------------------------------- #
Write-Host "`nthe recovery script clears the name, not a flag"
$sosSrc = Get-Content (Join-Path $repo 'sos-plain-http.ps1') -Raw -Encoding UTF8
Check 'it clears the hostname' ($sosSrc -match "\`$settings\.web\.hostname\s*=\s*''") `
      'it still only writes https=false, which nothing reads - so it does nothing at all now'
Check 'it prints the name before removing it' ($sosSrc -match 'WRITE THIS DOWN') `
      'the name is gone with no way to get it back'
Check 'it records the name in the audit trail' `
      ($sosSrc -match "cleared the tracker hostname") `
      'no durable record of what the name was'
Check 'it no longer says to turn HTTPS back on' ($sosSrc -notmatch 'turn HTTPS back on') `
      'points at a control that no longer exists'

Write-Host ""
if ($script:Failed) { Write-Host "$script:Failed CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
