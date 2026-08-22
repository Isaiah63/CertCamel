<#
  Cloudflare needs THREE permissions, and the third is the one everybody misses.

  Adding a challenge record is not one API call. Posh-ACME's Cloudflare plugin
  does three things in order:

      Find-CFZone                  Zone : Read
      GET  .../dns_records         DNS  : Read     <- the one people leave off
      POST .../dns_records         DNS  : Edit

  That middle GET - "check for an existing record" - is unconditional and
  rethrows on failure, so a token with DNS Edit but not DNS Read dies on the
  lookup and never reaches the write. It then presents as a write-permission
  problem, which is exactly what it is not.

  Every piece of guidance shipped said "Zone:Read + DNS:Edit", and the
  troubleshooting row went further and said to tick Edit "not just Read" -
  telling somebody to add the permission they already had while the missing one
  went unmentioned. This is what stops that coming back.

  The old three-part spelling is also gone: Cloudflare's dashboard is a policy
  builder now, with a scope and Read/Edit pairs per row, and Zone:Zone:Read
  matches nothing visible on it.

  Reads only.

      powershell -ExecutionPolicy Bypass -File .\v28-cloudflare-permissions-test.ps1
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

# --------------------------------------------------------------------------- #
Write-Host "`nthe plugin really does read before it writes"
# Checked against the vendored plugin rather than asserted from memory. If a
# future Posh-ACME stops doing the lookup, the guidance below becomes wrong in
# the other direction and this is where that shows up.
$plugin = @(Get-ChildItem -Path (Join-Path $appDir 'lib') -Recurse -Filter 'Cloudflare.ps1' -ErrorAction SilentlyContinue)
if (-not $plugin.Count) {
    Write-Host "  --   Posh-ACME is not vendored here, skipping the plugin check" -ForegroundColor DarkGray
    Write-Host "       (lib\ is gitignored, so this is expected on a fresh clone)" -ForegroundColor DarkGray
}
else {
    $src = Get-Content $plugin[0].FullName -Raw -Encoding UTF8
    $add = [regex]::Match($src, 'function Add-DnsTxt[\s\S]*?function Remove-DnsTxt').Value
    Check 'Add-DnsTxt looks for an existing record first' `
          ($add -match 'check for an existing record') `
          'the read-before-write step is gone, so DNS Read may no longer be required'
    $getAt  = $add.IndexOf('check for an existing record')
    $postAt = $add.IndexOf("Method = 'Post'")
    Check 'and does so before the POST' `
          ($getAt -ge 0 -and $postAt -ge 0 -and $getAt -lt $postAt) `
          "lookup at $getAt, post at $postAt"
}

# --------------------------------------------------------------------------- #
Write-Host "`nthe hint names all three, and says why the third matters"
$hint = $script:PluginCatalog['Cloudflare'].Args[0].Hint
foreach ($perm in @('Zone-Read', 'DNS-Read', 'DNS-Edit')) {
    Check "hint names $perm" ($hint -match [regex]::Escape($perm)) "hint says: $hint"
}
Check 'the hint explains why Edit alone is not enough' `
      ($hint -match 'looks for an existing one first') `
      'without the reason, DNS-Read reads as belt-and-braces and gets skipped'
Check 'the hint does not use the retired three-part spelling' `
      ($hint -notmatch 'Zone:Zone:Read|Zone:DNS:Edit') `
      'that naming matches nothing on the current dashboard'
Check 'the hint still warns off the Global API Key' `
      ($hint -match 'Global API Key') `
      'the global key can do anything to the whole account'

# --------------------------------------------------------------------------- #
Write-Host "`nthe rejection message says which permission is missing"
$libSrc = Get-Content (Join-Path $appDir 'acme-lib.ps1') -Raw -Encoding UTF8
$throwLine = [regex]::Match($libSrc, 'It must be a scoped API token[^"]*').Value
Check 'found the rejection message' ([bool]$throwLine) 'the message moved'
if ($throwLine) {
    Check 'it names DNS-Read' ($throwLine -match 'DNS-Read') "says: $throwLine"
    Check 'and says it is the one usually missing' `
          ($throwLine -match 'usually missing') `
          'naming three permissions without saying which one fails is a list, not a diagnosis'
}

# --------------------------------------------------------------------------- #
Write-Host "`nsetup diagnoses it rather than guessing"
$setupSrc = Get-Content (Join-Path $appDir 'setup.ps1') -Raw -Encoding UTF8
Check 'setup names DNS Read on a write failure' `
      ($setupSrc -match 'missing DNS Read') `
      'the failure said "can list zones but not write", which points at the wrong permission'
Check 'and prints the provider error in full' `
      ($setupSrc -match '\$wr\.error\) -ForegroundColor White') `
      'the provider''s own words are the only line that says what actually happened'

# --------------------------------------------------------------------------- #
Write-Host "`na rejected credential can be retyped without restarting setup"
# The dead end this replaces: setup saved the bad token, the write test failed,
# declining exited - and the next run saw a provider already configured, skipped
# the prompt, and hit the same failure with no way to enter a different one.
Check 'the credential step can repeat' ($setupSrc -match '\} while \(\$retryCredential\)') `
      'a rejected credential still strands the operator on every subsequent run'
Check 'retyping is offered by name' ($setupSrc -match 'enter a different credential and try again') `
      'the only options were continue or stop, neither of which fixes a bad token'
Check 'and the bad profile is removed first' `
      ($setupSrc -match '\$sDrop\.providers = @\(\)') `
      'a profile left on disk makes the next pass skip the prompt again - the original dead end'
Check 'along with its stored secret' `
      ($setupSrc -match 'Save-SecretStore -Store \$store -AllowEmpty') `
      'the token stays in secrets.xml under an id nothing references'

# --------------------------------------------------------------------------- #
Write-Host "`nthe guides agree with the code"
foreach ($doc in @('readme.html', 'security.html')) {
    $d = Get-Content (Join-Path $repo $doc) -Raw -Encoding UTF8
    Check "$doc names DNS Read" ($d -match 'DNS(&nbsp;| &rarr; )Read') 'the third permission is missing from the guide'
    Check "$doc does not use the retired spelling" `
          ($d -notmatch 'Zone:Zone:Read|Zone:DNS:Edit') `
          'names a dashboard layout that no longer exists'
}
$readme = Get-Content (Join-Path $repo 'readme.html') -Raw -Encoding UTF8
Check 'the troubleshooting row no longer says to tick Edit "not just Read"' `
      ($readme -notmatch 'not just Read') `
      'it told somebody to add the permission they already had, and never mentioned the missing one'

Write-Host ""
if ($script:Failed) { Write-Host "$script:Failed CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
