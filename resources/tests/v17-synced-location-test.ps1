<#
  Noticing that the private keys are being copied off this machine.

  Cert Camel keeps unencrypted private keys on disk. That is normal for an ACME
  client - whatever terminates TLS has to read the key - and it is survivable
  because they stay on one machine, behind one Windows account, under the
  permissions Protect-CamelInstall applies.

  A sync client removes both of those at once and says nothing. The ACLs are not
  copied, the destination is somebody else's infrastructure, and the running
  tool looks identical. Of everything in the security review this is the most
  realistic way the keys actually escape.

  The trap this pins is the prefix match. "Is this path under OneDrive" is a
  string comparison, and the naive version says yes to C:\Users\x\OneDriveNotes
  - the same mistake a bare StartsWith("...\assets") makes for assets-evil, which
  the asset routes in serve.ps1 already guard against with a trailing separator.
  Getting it wrong in this direction is merely annoying; getting it wrong the
  other way is silent.

  Reads only. Nothing here writes files or touches the real install.

      powershell -ExecutionPolicy Bypass -File .\v17-synced-location-test.ps1
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

function Synced { param([string]$P) return (Test-SyncedLocation -Path $P) }

# --------------------------------------------------------------------------- #
Write-Host "`nOneDrive, which is the one signal that is authoritative"
$od = [Environment]::GetEnvironmentVariable('OneDrive')
if ($od) {
    $r = Synced (Join-Path $od 'Desktop\CertCamel')
    Check 'a folder under the real OneDrive root is caught' `
          ($null -ne $r -and $r.provider -eq 'OneDrive') `
          'private keys under OneDrive would not be reported'
    Check 'and it is reported as certain, not a guess' `
          ($null -ne $r -and $r.certain) `
          'the environment variable is authoritative; reporting it as a heuristic understates it'

    Check 'the OneDrive root itself counts' ($null -ne (Synced $od)) 'the root was not matched'

    # The whole point of the trailing separator.
    Check 'a sibling that merely starts with the same name does not' `
          ($null -eq (Synced ($od.TrimEnd('\') + 'Notes\camel'))) `
          "$($od)Notes matched as OneDrive - the prefix check is missing its separator"
}
else {
    Write-Host "  --   no OneDrive on this machine, skipping the authoritative case" -ForegroundColor DarkGray
}

# --------------------------------------------------------------------------- #
Write-Host "`nname-based heuristics for the providers with no readable root"
foreach ($case in @(
    @{ path = 'D:\Data\My Drive\certcamel';        provider = 'Google Drive' },
    @{ path = 'C:\Users\x\Google Drive\camel';     provider = 'Google Drive' },
    @{ path = 'C:\Users\x\iCloudDrive\camel';      provider = 'iCloud Drive' },
    @{ path = 'C:\Users\x\Box\camel';              provider = 'Box' },
    @{ path = 'C:\Users\x\Nextcloud\camel';        provider = 'Nextcloud' }
)) {
    $r = Synced $case.path
    Check "$($case.provider): $($case.path)" `
          ($null -ne $r -and $r.provider -eq $case.provider) `
          "reported $(if ($r) { $r.provider } else { 'local' })"
    Check "  ...and admits it is a guess" ($null -ne $r -and -not $r.certain) `
          'a folder-name match is not certain and should not claim to be'
}

# --------------------------------------------------------------------------- #
Write-Host "`nplaces that are genuinely local stay quiet"
# A false positive here costs one extra confirmation at setup. It also trains
# people to type y without reading, which is worse than it sounds.
foreach ($p in @(
    'C:\CertCamel',
    'C:\Users\x\certcamel-v2',
    'D:\apps\cert-camel',
    'C:\Users\x\Boxing\camel',
    'C:\Users\x\Nextcloudy\camel',
    'C:\Users\x\Documents\My Driveway\camel'
)) {
    Check "local: $p" ($null -eq (Synced $p)) "reported as $((Synced $p).provider)"
}

# --------------------------------------------------------------------------- #
Write-Host "`nthe real install"
$here = Synced $repo
if ($here) {
    Write-Host ("  --   this install IS inside $($here.provider) - that is a finding, not a test failure") -ForegroundColor Yellow
}
else {
    Check 'this install is not in a synced folder' $true ''
}

# --------------------------------------------------------------------------- #
Write-Host "`nbad input is not a crash"
foreach ($p in @('', '   ', 'not:a:path', "C:\nope`0bad")) {
    $threw = $false
    try { [void](Synced $p) } catch { $threw = $true }
    Check "survives '$($p -replace "`0", '\0')'" (-not $threw) 'threw instead of returning null'
}

# --------------------------------------------------------------------------- #
Write-Host "`nboth places that ask are still asking"
$setupSrc = Get-Content (Join-Path $appDir 'setup.ps1') -Raw -Encoding UTF8
$serveSrc = Get-Content (Join-Path $appDir 'serve.ps1') -Raw -Encoding UTF8
Check 'setup checks before applying permissions' `
      ($setupSrc -match 'Test-SyncedLocation') `
      'setup no longer checks, so a synced install is set up without a word'
Check 'the server checks on every start' `
      ($serveSrc -match 'Test-SyncedLocation') `
      'a folder moved into OneDrive after setup would never be noticed again'

Write-Host ""
if ($script:Failed) { Write-Host "$script:Failed CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
