<#
  Two things a real first run got wrong, both found by doing one.

  THE FIRST CHECK MEASURED SOMEBODY ELSE'S DOMAIN. Step 1 copied
  domains.example.txt over a fresh domains.txt, so the check three steps later
  went out and read the certificate on example.com and www.example.com. The
  console then opened showing two certificates belonging to nobody here.

  Worse than untidy: the setup checklist on Home marks "watch some
  certificates" as DONE the moment any result exists, so a brand new install
  reported that step finished on the strength of placeholder data. Measured on
  the live install - ssl-data.js held real expiry dates for example.com.

  THE CONSOLE CERTIFICATE CAME FROM STAGING. The built-in authority ships with
  staging on, for a good reason: a first run against production burns real rate
  limit on a configuration nobody has proven, and Let's Encrypt allows five
  identical certificates a week. But setup now issues the console's own
  certificate and turns HTTPS on, and a staging certificate is not publicly
  trusted - so setup finished by announcing HTTPS and handing over a console
  the browser warns about. Two sound decisions that are wrong together.

  Reads only, and runs nothing that touches the network or the live install.

      powershell -ExecutionPolicy Bypass -File .\v27-fresh-install-test.ps1
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

$setupSrc = Get-Content (Join-Path $appDir 'setup.ps1') -Raw -Encoding UTF8

# --------------------------------------------------------------------------- #
Write-Host "`na fresh domains.txt has no hostnames in it"
Check 'the example list is no longer copied over it' `
      ($setupSrc -notmatch 'Copy-Item -Path \$domainSeed') `
      'domains.example.txt is being installed as though it were yours, so the first check measures example.com'
Check 'and example.com is not written in by hand either' `
      ($setupSrc -notmatch '"# One domain per line.`r`nexample\.com') `
      'the fallback branch still seeds a hostname'
Check 'domains.example.txt is still shipped as the worked example' `
      (Test-Path (Join-Path $repo 'domains.example.txt')) `
      'the example was deleted rather than merely stopped being copied'

# The header setup writes must itself parse as "no hostnames", by the checker's
# own rules. A stray line here would put the install straight back where it was.
$seed = [regex]::Match($setupSrc, '\$seedText\s*=(?<b>[\s\S]*?)\[IO\.File\]::WriteAllText\(\$domainList').Groups['b'].Value
Check 'found the seed text to inspect' ([bool]$seed) 'the seeding shape changed'
if ($seed) {
    $lines = @([regex]::Matches($seed, '"(?<t>[^"]*)"') | ForEach-Object { $_.Groups['t'].Value })
    $names = @($lines | ForEach-Object { $_.Trim() } |
               Where-Object { $_ -and $_ -ne '`r`n' -and -not $_.StartsWith('#') -and $_ -notmatch '^\[.+\]$' })
    Check 'every seeded line is a comment' ($names.Count -eq 0) `
          ("these would be read as hostnames: {0}" -f ($names -join ', '))
    Check 'it points at the Certificates page' ($seed -match 'Certificates page') `
          'nothing tells a new operator where names get added'
}

# --------------------------------------------------------------------------- #
Write-Host "`nan empty list means the check is skipped, not run and reported empty"
Check 'the check is conditional' ($setupSrc -match '\$hasNames') `
      'the checker runs regardless, producing an empty result that reads like a failure'
Check 'and it says why rather than printing nothing' `
      ($setupSrc -match 'Nothing to check yet') `
      'a silent skip is indistinguishable from a step that did not run'

# The skip test has to agree with the checker, or one of them is wrong about
# what counts as a hostname.
$checkSrc = Get-Content (Join-Path $appDir 'check-ssl.ps1') -Raw -Encoding UTF8
foreach ($rule in @('StartsWith(''#'')', '^\[')) {
    Check "setup and the checker share the rule $rule" `
          (($setupSrc -match [regex]::Escape($rule)) -and ($checkSrc -match [regex]::Escape($rule))) `
          'the two disagree about which lines are hostnames'
}

# --------------------------------------------------------------------------- #
Write-Host "`nstaging is caught before a certificate is ordered"
Check 'setup checks the authority' ($setupSrc -match 'askCa') `
      'nothing notices that the console certificate would come from staging'
Check 'it says the browser will not trust it' `
      ($setupSrc -match 'no browser trusts it') `
      'the consequence is the whole point and has to be stated'
Check 'it says the switch is not just for this certificate' `
      ($setupSrc -match 'applies to every') `
      'useStaging is a property of the authority, so flipping it affects everything'
Check 'declining still explains how to fix it later' `
      ($setupSrc -match 'untick staging under Settings') `
      'somebody who says no is left with a warning and no route out of it'

# Before both issuing branches, or it is asked too late to matter.
$askAt   = $setupSrc.IndexOf('$askCa = $null')
$manual  = $setupSrc.IndexOf('issue-tracker-cert.ps1')
$auto    = $setupSrc.IndexOf("-File (Join-Path `$appDir 'renew.ps1')")
Check 'the question comes before the manual issuing path' `
      ($askAt -ge 0 -and $manual -ge 0 -and $askAt -lt $manual) "ask at $askAt, manual issue at $manual"
Check 'and before the automatic one' `
      ($askAt -ge 0 -and $auto -ge 0 -and $askAt -lt $auto) "ask at $askAt, auto issue at $auto"

# --------------------------------------------------------------------------- #
Write-Host "`nthe flip actually reaches the certificate authority"
# A settings object in the exact state a fresh install is in.
$fresh = New-DefaultSettings
$ca = Get-CaProfile -Settings $fresh
Check 'a fresh install really does default to staging' ([bool]$ca.useStaging) `
      'the premise changed - this whole prompt may no longer be needed'
Check 'and would order from the staging directory' `
      ((Get-ActiveDirectoryUrl -Ca $ca) -match 'staging') `
      ("got {0}" -f (Get-ActiveDirectoryUrl -Ca $ca))

# The loop setup runs when the answer is yes.
foreach ($c in @($fresh.cas)) { if ($c.id -eq $ca.id) { $c.useStaging = $false } }
$after = Get-CaProfile -Settings $fresh
Check 'answering yes clears the flag' (-not $after.useStaging) 'the profile was not updated'
Check 'and the order would go to production' `
      ((Get-ActiveDirectoryUrl -Ca $after) -notmatch 'staging') `
      ("still {0}" -f (Get-ActiveDirectoryUrl -Ca $after))

# It has to survive being written and read back, or the next run reverts to
# staging and nobody knows why.
$tmp = Join-Path $env:TEMP ('camel-ca-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
try {
    $fresh | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tmp -Encoding UTF8
    $back = ConvertTo-HashtableDeep ((Get-Content $tmp -Raw -Encoding UTF8) | ConvertFrom-Json)
    Check 'and survives a save and reload' (-not (Get-CaProfile -Settings $back).useStaging) `
          'the setting reverts on the next run'
}
finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }

Write-Host ""
if ($script:Failed) { Write-Host "$script:Failed CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
