<#
  A DNS profile created by setup must be indistinguishable from one created in
  the browser.

  There are now two places that build a provider record: the settings page,
  whose payload is validated and stored by Save-SettingsPayload in serve.ps1,
  and setup.ps1, which asks the same questions at a console prompt because the
  credential has to exist before a certificate can be issued.

  Two writers, one reader. Everything downstream - Get-ProviderPluginArgs,
  Get-ProviderZones, Resolve-HostZone - reads whichever record it finds and
  cannot tell which produced it, so a difference between them does not fail at
  the point it is made. It fails later, as a renewal that cannot find its
  credential.

  So this pins the contract itself: the id pattern serve.ps1 enforces, the
  fields it keeps, and the secret key naming that Get-ProviderPluginArgs looks
  up. None of it is exercised by the page suites, which drive the browser.

  Reads only. Nothing here writes settings, secrets or zones.

      powershell -ExecutionPolicy Bypass -File .\v15-setup-provider-test.ps1
#>

$ErrorActionPreference = 'Stop'
$repo    = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$appDir  = Join-Path $repo 'resources'
. (Join-Path $appDir 'acme-lib.ps1')

$script:Failed = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    if ($Ok) { Write-Host "  ok   $Name" -ForegroundColor Green }
    else     { Write-Host "  FAIL $Name  -- $Detail" -ForegroundColor Red; $script:Failed++ }
}

$setupSrc = Get-Content (Join-Path $appDir 'setup.ps1') -Raw -Encoding UTF8
$serveSrc = Get-Content (Join-Path $appDir 'serve.ps1') -Raw -Encoding UTF8

# --------------------------------------------------------------------------- #
Write-Host "`nthe id setup generates passes the validation serve.ps1 applies"

# Lifted from serve.ps1 rather than retyped, so tightening it there fails here
# instead of silently letting setup produce ids the save path would reject.
$m = [regex]::Match($serveSrc, "id\s+-notmatch\s+'(?<p>\^[^']+)'")
Check 'found the id pattern in serve.ps1' $m.Success `
      'the validation moved or changed shape - this test is no longer checking anything'

if ($m.Success) {
    $pattern = $m.Groups['p'].Value

    # Exactly the expression setup.ps1 uses. Generated 200 times because it
    # embeds a timestamp and a random suffix, and a pattern violation that
    # depends on either would otherwise show up on somebody's machine and not
    # on mine.
    $bad = @()
    for ($i = 0; $i -lt 200; $i++) {
        $id = 'p' + [Convert]::ToString([DateTimeOffset]::UtcNow.ToUnixTimeSeconds(), 16) +
              (Get-Random -Minimum 100 -Maximum 999)
        if ($id -notmatch $pattern) { $bad += $id }
    }
    Check "200 generated ids all match $pattern" ($bad.Count -eq 0) "rejected: $(($bad | Select-Object -First 3) -join ', ')"
}

Check 'setup builds its id the documented way' `
      ($setupSrc -match "ToUnixTimeSeconds\(\),\s*16") `
      'the id expression changed - check it still matches the pattern above'

# --------------------------------------------------------------------------- #
Write-Host "`nthe record setup saves carries the fields serve.ps1 keeps"
foreach ($field in @('id', 'label', 'plugin', 'args')) {
    Check "sets '$field'" ($setupSrc -match "(?m)^\s*$field\s*=") "a provider with no $field is not readable downstream"
}

# --------------------------------------------------------------------------- #
Write-Host "`nsecrets are keyed the way Get-ProviderPluginArgs looks them up"
# The reader does Get-TrackerSecret -Key "$($Provider.id):$($a.Name)". Setup must
# produce that exact shape - id, colon, argument name - or the credential is
# stored under a key nothing ever reads, and renewal fails with a missing
# credential while settings.json looks completely correct.
Check 'setup writes "<id>:<argName>"' `
      ($setupSrc -match 'Set-TrackerSecret -Key \("\{0\}:\{1\}" -f \$providerId, \$a\.Name\)') `
      'the secret key format drifted from what Get-ProviderPluginArgs reads'

$libSrc = Get-Content (Join-Path $appDir 'acme-lib.ps1') -Raw -Encoding UTF8
Check 'the reader still looks up that shape' `
      ($libSrc -match 'Get-TrackerSecret -Key "\$\(\$Provider\.id\)\:\$\(\$a\.Name\)"') `
      'Get-ProviderPluginArgs changed how it builds the key; setup must match'

# --------------------------------------------------------------------------- #
Write-Host "`nevery catalog plugin can actually be set up"
foreach ($name in @($script:PluginCatalog.Keys)) {
    $cat = $script:PluginCatalog[$name]
    Check "$name has a label to show in the menu" ([bool]$cat.Label) 'the picker would show a blank line'

    $fields = @($cat.Args)
    Check "$name declares at least one field" ($fields.Count -ge 1) 'nothing to prompt for'

    $named = @($fields | Where-Object { $_.Name })
    Check "$name has a Name on every field" ($named.Count -eq $fields.Count) `
          'a field with no Name cannot be stored or read back'

    $typed = @($fields | Where-Object { $_.Secret -or $_.Type -in @('text', 'bool') })
    Check "$name has a promptable type on every field" ($typed.Count -eq $fields.Count) `
          'setup only knows how to prompt for secret, text and bool'

    # Zone discovery is what setup uses to prove the credential immediately. A
    # catalog plugin without it would be accepted and then report no zones,
    # which reads as a scoping problem rather than an unimplemented one.
    Check "$name supports zone discovery" `
          ($libSrc -match "(?m)^\s*'$name'\s*\{") `
          'Get-ProviderZones has no branch for it, so setup cannot verify the credential it just collected'
}

# --------------------------------------------------------------------------- #
Write-Host "`nmonitoring-only is really gone"
Check 'the Posh-ACME step no longer offers to skip' `
      ($setupSrc -notmatch 'only want expiry monitoring') `
      'the skip prompt is still there, so setup can still finish with no ACME client'
Check 'a failed download no longer says monitoring still works' `
      ($setupSrc -notmatch 'Monitoring still works') `
      'a failed download is still treated as survivable'

Write-Host ""
if ($script:Failed) { Write-Host "$script:Failed CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
