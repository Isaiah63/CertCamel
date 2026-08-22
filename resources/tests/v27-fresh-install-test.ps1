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

  THE CONSOLE CERTIFICATE CAME FROM STAGING. The built-in authority shipped with
  staging on, guarding against a first run burning real rate limit on a
  configuration nobody had proven - Let's Encrypt allows five identical
  certificates a week. But setup now issues the console's own certificate and
  turns HTTPS on, and a staging certificate is real yet publicly untrusted, so
  setup finished by announcing HTTPS and handing over a page the browser warns
  about. The worst possible first impression, and one that reads as a fault
  rather than as a setting somebody chose.

  Asking which to use was the first attempt and was worse: every prompt is a
  chance to answer wrong, and only one answer is right for this certificate.
  The guard moved instead. Setup proves the credential directly before anything
  is ordered - it lists the zones, then writes a real challenge record and
  removes it again - which catches the read-but-not-write token that listing
  alone sails past, and is a better guard than staging ever was.

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
Write-Host "`nthere is no staging question, because there is no staging certificate"
Check 'setup does not ask about staging' `
      ($setupSrc -notmatch 'Switch to production') `
      'a prompt is a chance to answer wrong, and only one answer is right for this certificate'
Check 'and does not flip the authority behind your back' `
      ($setupSrc -notmatch '\$c\.useStaging = \$false') `
      'setup is silently rewriting a certificate authority setting'

Write-Host "`nthe credential is proved before anything is ordered"
Check 'setup tests write access' ($setupSrc -match 'Test-ProviderWriteAccess') `
      'listing zones proves read only, and a read-only token dies partway through an order'
Check 'a failure shows the provider''s own error' `
      ($setupSrc -match '\$wr\.error\) -ForegroundColor White') `
      'without it the operator sees a verdict and no reason, and guesses at the permission'
# Which permission to name is provider-specific and lives in v28; what matters
# here is that the failure is diagnosed rather than merely reported.
Check 'a stray probe record is reported rather than left silently' `
      ($setupSrc -match 'stray _acme-challenge') `
      'cleanup is best-effort, so a failure to remove it must be said'
Check 'and it refuses to carry on by default' `
      ($setupSrc -match 'Continue anyway\? \(y/N\)') `
      'continuing would order a certificate that cannot complete'

# Proving write access is only useful before the order.
$writeAt = $setupSrc.IndexOf('Test-ProviderWriteAccess')
$manual  = $setupSrc.IndexOf('issue-tracker-cert.ps1')
$auto    = $setupSrc.IndexOf("-File (Join-Path `$appDir 'renew.ps1')")
Check 'the write test runs before the manual issuing path' `
      ($writeAt -ge 0 -and $manual -ge 0 -and $writeAt -lt $manual) "test at $writeAt, manual issue at $manual"
Check 'and before the automatic one' `
      ($writeAt -ge 0 -and $auto -ge 0 -and $writeAt -lt $auto) "test at $writeAt, auto issue at $auto"

# --------------------------------------------------------------------------- #
Write-Host "`nsetup reads the fields the write test actually returns"
# The bug this exists for: Test-ProviderWriteAccess uses wrote/cleaned inside
# its own scriptblock and RENAMES them to canWrite/cleanedUp on the way out.
# setup read the inner names, got $null every time, and reported every
# credential as unable to write - correct ones included - with an empty error
# line underneath, because nothing had actually failed. Confirmed against a
# live token: canWrite=True while setup insisted it could not write.
#
# Compared against the source rather than hardcoded, so renaming a field in the
# function fails here instead of silently breaking the caller again.
$libSrc = Get-Content (Join-Path $appDir 'acme-lib.ps1') -Raw -Encoding UTF8
$ret = [regex]::Match($libSrc,
    'function Test-ProviderWriteAccess[\s\S]*?return @\{(?<b>[\s\S]*?)
    \}').Groups['b'].Value
Check 'found the return contract' ([bool]$ret) 'the function shape changed'

if ($ret) {
    $returned = @([regex]::Matches($ret, '(?m)^\s*(?<k>\w+)\s*=') | ForEach-Object { $_.Groups['k'].Value })
    Check ("it returns: {0}" -f ($returned -join ', ')) ($returned.Count -ge 3) 'no fields parsed'

    $used = @([regex]::Matches($setupSrc, '\$wr\.(?<k>\w+)') |
              ForEach-Object { $_.Groups['k'].Value } | Sort-Object -Unique)
    $bogus = @($used | Where-Object { $returned -notcontains $_ })
    Check 'every field setup reads is one the function returns' ($bogus.Count -eq 0) `
          ("setup reads {0}, which the function does not return" -f ($bogus -join ', '))

    Check 'and the fallback on an exception uses the same names' `
          ($setupSrc -match 'canWrite = \$false; cleanedUp = \$false') `
          'the catch builds the inner shape, so a thrown error reports the same lie'
}

# --------------------------------------------------------------------------- #
Write-Host "`nthe scheduled time is asked for, and parsed the way it is typed"
Check 'setup asks when the tasks should run' ($setupSrc -match 'Time, as HH:MM') `
      'the times are hardcoded again, so nobody can choose them'
Check 'it defaults to midnight' ($setupSrc -match "\[00:00\]") 'the default changed'
Check 'and all three tasks use the answer' `
      (([regex]::Matches($setupSrc, '-At \$taskAt')).Count -ge 3) `
      ("only {0} trigger(s) use it - one of the tasks kept a hardcoded time" -f ([regex]::Matches($setupSrc, '-At \$taskAt')).Count)
Check 'no hardcoded clock times remain' `
      ($setupSrc -notmatch '-At \d+:\d+(am|pm)') `
      'a trigger still has its old fixed time'

# The parser, exercised rather than eyeballed. Without the [string[]] cast
# PowerShell binds the single-format overload of TryParseExact, hands it the
# array stringified, and rejects EVERY input - which would make the prompt an
# infinite loop for anybody who ran it.
Check 'the format list is cast to [string[]]' `
      ($setupSrc -match '\[string\[\]\]@\(.HH:mm.') `
      'uncast, the overload silently rejects every time typed and the loop never ends'

$fmts = [string[]]@('HH:mm', 'H:mm', 'h:mm tt', 'hh:mm tt')
$ci   = [Globalization.CultureInfo]::InvariantCulture
$none = [Globalization.DateTimeStyles]::None
foreach ($case in @(
    @{ in = '00:00';    want = '00:00' },
    @{ in = '00:20';    want = '00:20' },
    @{ in = '3:20';     want = '03:20' },
    @{ in = '22:45';    want = '22:45' },
    @{ in = '9:00 AM';  want = '09:00' },
    @{ in = '11:59 PM'; want = '23:59' }
)) {
    $d = [datetime]::MinValue
    $ok = [datetime]::TryParseExact($case.in, $fmts, $ci, $none, [ref]$d)
    $got = $(if ($ok) { (Get-Date).Date.AddHours($d.Hour).AddMinutes($d.Minute).ToString('HH:mm') } else { 'rejected' })
    Check ("'{0}' parses to {1}" -f $case.in, $case.want) ($got -eq $case.want) "got $got"
}
foreach ($bad in @('5', '25:00', 'abc', '12:60', 'noon')) {
    $d = [datetime]::MinValue
    Check ("'{0}' is refused" -f $bad) `
          (-not [datetime]::TryParseExact($bad, $fmts, $ci, $none, [ref]$d)) `
          'a loose parse would register a task at a time nobody asked for'
}

# --------------------------------------------------------------------------- #
Write-Host "`nthe first renewal has checker data to work from"
# renew.ps1 refuses without it, and step 4 no longer runs the checker on a
# fresh install - so issuing the console certificate died on "There is no
# certificate data yet" for an install that had done nothing wrong.
Check 'setup checks before the first renewal' `
      ($setupSrc -match 'Checking \$webName first')   # single-quoted: double quotes would interpolate $webName away `
      'renew.ps1 throws without checker output, which is the state a fresh install is in'
Check 'and again at the end if a name was added but never checked' `
      ($setupSrc -match 'Running a check, so the page has something to show') `
      'a scheduled sweep would throw at its first run and email about it'

# --------------------------------------------------------------------------- #
Write-Host "`na fresh install orders from production"
$fresh = New-DefaultSettings
$ca = Get-CaProfile -Settings $fresh
Check 'staging is off by default' (-not $ca.useStaging) `
      'a fresh install would issue the console a certificate no browser trusts'
Check 'and the order goes to the production directory' `
      ((Get-ActiveDirectoryUrl -Ca $ca) -notmatch 'staging') `
      ("got {0}" -f (Get-ActiveDirectoryUrl -Ca $ca))

# Still available to anybody who wants to rehearse - the default moved, the
# capability did not.
$ca.useStaging = $true
Check 'staging still works when explicitly asked for' `
      ((Get-ActiveDirectoryUrl -Ca $ca) -match 'staging') `
      'the staging directory is unreachable, so testing against it is impossible'

Write-Host ""
if ($script:Failed) { Write-Host "$script:Failed CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
