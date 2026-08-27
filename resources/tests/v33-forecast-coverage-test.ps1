<#
  A renewal forecast goes out of date when the work changes, not on a clock.

  renew-due.ps1 writes jobs/renew-due-sweep.json; the Home card renders it and
  offers "Work it out now" only when it looks stale. Staleness was 36 hours and
  nothing else. So: three hostnames were added to domains.txt five hours after
  the last sweep, the forecast counted as fresh, the button stayed hidden, and
  the card listed ONE certificate as the whole schedule while two of those hosts
  were a day from expiry. The card was not merely quiet - it was confidently
  incomplete.

  COVERAGE IS COMPARED ON NAMES, NEVER ON CERTIFICATES, and that distinction is
  the point of this file. Get-CertificateGroups files one SAN certificate per
  DNS zone, so a hostname added to a zone already in the forecast changes
  nothing at certificate level - the certId is already there. Measured that way
  the check reports "nothing missing" for the case it will meet most often.
  Measured on names it reports the host. Both predicates are exercised below so
  the weaker one cannot quietly come back.

  Also here: the two things a coverage check cannot see, and why the old age
  test is KEPT rather than replaced - a sweep that died partway and stamped a
  fresh timestamp over a truncated list, and a manual renewal that rewrites the
  CA's renewal window without touching the sweep file at all.

  Pure function tests plus source checks. Nothing is written and no node,
  certificate authority or scheduled task is contacted.

      powershell -ExecutionPolicy Bypass -File .\v33-forecast-coverage-test.ps1
#>

$ErrorActionPreference = 'Stop'
$repo   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
# Not $appDir - acme-lib.ps1 sets $script:AppDir and PowerShell names are
# case-insensitive, so that would silently repoint at wherever it was loaded.
$srcDir = Join-Path $repo 'resources'
. (Join-Path $srcDir 'acme-lib.ps1')

$script:Failed = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    if ($Ok) { Write-Host "  ok   $Name" -ForegroundColor Green }
    else     { Write-Host "  FAIL $Name  -- $Detail" -ForegroundColor Red; $script:Failed++ }
}

function Sweep {
    param([object[]]$Considered, [double]$AgeHours = 5, $Complete = $true)
    $o = @{ finishedAt = (Get-Date).AddHours(-1 * $AgeHours).ToString('o')
            mode = 'run'; considered = @($Considered) }
    if ($null -ne $Complete) { $o.complete = $Complete }
    return [pscustomobject]$o
}
function Entry {
    param([string]$CertId, [string[]]$Names)
    $e = @{ certId = $CertId; due = $false; reason = $null }
    if ($null -ne $Names) { $e.names = @($Names) }
    return [pscustomobject]$e
}
function State { param($Forecast, [string[]]$Watched = @(), $Certs = @())
    return Get-RenewalForecastState -Forecast $Forecast -WatchedHosts $Watched -Certs $Certs
}

# --------------------------------------------------------------------------- #
Write-Host "`nthe incident, reproduced"
# Sweep knows one certificate. domains.txt has since gained three hosts.
$s = State (Sweep @(Entry -CertId 'console.example.com' -Names @('console.example.com'))) `
           @('console.example.com', 'lbtest.example.com', 'lbprod.example.com', 'lbprod2.example.com')
Check 'it is not called current' ($s.state -ne 'current') "said '$($s.state)'"
Check 'the state is uncovered'   ($s.state -eq 'uncovered') "said '$($s.state)'"
Check 'and it names all three hosts' (@($s.uncovered).Count -eq 3) `
      "named: $(@($s.uncovered) -join ', ')"
Check 'the certificate it DOES know about is not named' `
      (@($s.uncovered) -notcontains 'console.example.com') `
      "named: $(@($s.uncovered) -join ', ')"
Check 'age alone would have called this fresh' `
      ($s.ageHours -lt 36) "ageHours=$($s.ageHours) - the fixture no longer reproduces the bug"

# --------------------------------------------------------------------------- #
Write-Host "`nthe case a certificate-level check is blind to"
# This is the one that will happen most often from here: a host added to a zone
# whose SAN certificate is ALREADY in the forecast. certId is unchanged, so
# "which certificates are missing" answers nothing. The NAME is what is new.
$fc  = Sweep @(Entry -CertId 'example.com' -Names @('example.com', 'a.example.com'))
$live = @([pscustomobject]@{ certId = 'example.com'
                             names  = @('example.com', 'a.example.com', 'justadded.example.com') })

$certLevelMissing = @(@($live | Where-Object { @($fc.considered | ForEach-Object { $_.certId }) -notcontains $_.certId }))
Check 'a certificate-level check finds nothing wrong' ($certLevelMissing.Count -eq 0) `
      'the fixture does not reproduce the blind spot'

$s = State $fc @('example.com', 'a.example.com') $live
Check 'the name-level check finds the new host' ($s.state -eq 'uncovered') "said '$($s.state)'"
Check 'and names it' (@($s.uncovered) -contains 'justadded.example.com') `
      "named: $(@($s.uncovered) -join ', ')"

# --------------------------------------------------------------------------- #
Write-Host "`na wildcard in the forecast really does cover a new subdomain"
# The opposite error: crying wolf. A zone with a wildcard entry already speaks
# for anything one label deep, and flagging those would make the line noise.
$s = State (Sweep @(Entry -CertId 'wildcard.example.com' -Names @('*.example.com', 'example.com'))) `
           @('anything.example.com', 'example.com')
Check 'nothing is reported uncovered' ($s.state -eq 'current') `
      "said '$($s.state)': $(@($s.uncovered) -join ', ')"

Write-Host "`nbut RFC 6125 is not stretched to fit"
$s = State (Sweep @(Entry -CertId 'wildcard.example.com' -Names @('*.example.com', 'example.com'))) `
           @('a.b.example.com')
Check 'a two-label name is still uncovered' (@($s.uncovered) -contains 'a.b.example.com') `
      "said '$($s.state)': $(@($s.uncovered) -join ', ')"

# --------------------------------------------------------------------------- #
Write-Host "`nwildcards are not themselves things to watch"
# *.example.com arrives on a live certificate's name list. It is what does the
# covering, not a host anybody waits on, and reporting it as uncovered would
# put an unfixable line on the card forever.
$s = State (Sweep @(Entry -CertId 'example.com' -Names @('example.com'))) @() `
           @([pscustomobject]@{ certId = 'wildcard.example.com'; names = @('*.example.com', 'example.com') })
Check 'a wildcard name is never reported uncovered' (@($s.uncovered) -notcontains '*.example.com') `
      "named: $(@($s.uncovered) -join ', ')"

# --------------------------------------------------------------------------- #
Write-Host "`nwhat is NOT a gap, and would otherwise never clear"
# Both of these pin an amber warning nothing can lift, which is the exact
# failure this check was built to stop: an alarm that cannot be cleared is one
# people learn to scroll past.
$fcx = Sweep @(Entry -CertId 'example.com' -Names @('example.com', 'a.example.com'))

# domains.txt can carry a *.zone line. Nothing in a forecast ever contains that
# literal string, so a wildcard would read as uncovered on every load.
$s = State $fcx @('example.com', 'a.example.com', '*.example.com')
Check 'a wildcard line in domains.txt is not a gap' ($s.state -eq 'current') `
      "said '$($s.state)': $(@($s.uncovered) -join ', ') - a wildcard is what does the covering"

# "Managed elsewhere" means somebody else renews it. renew-due.ps1 filters those
# out, so no sweep can ever cover them - by design, not by omission.
$foreign = @([pscustomobject]@{ certId = 'theirs'; external = $true
                                names = @('theirs.example.com') })
$s = State $fcx @('example.com', 'a.example.com', 'theirs.example.com') $foreign
Check 'a host managed elsewhere is not a gap' ($s.state -eq 'current') `
      "said '$($s.state)': $(@($s.uncovered) -join ', ') - watching what somebody else renews is the point of that setting"

# And the guard: neither exclusion may swallow a real one.
$s = State $fcx @('example.com', 'a.example.com', 'brandnew.example.com') $foreign
Check 'but a genuinely new host still is' (@($s.uncovered) -contains 'brandnew.example.com') `
      "said '$($s.state)': $(@($s.uncovered) -join ', ')"

# --------------------------------------------------------------------------- #
Write-Host "`nthe two things coverage cannot see, which is why age stays"
$s = State (Sweep -Considered @(Entry -CertId 'example.com' -Names @('example.com')) -AgeHours 0.03 -Complete $false) `
           @('example.com')
Check 'a sweep that died partway is not current' ($s.state -eq 'incomplete') "said '$($s.state)'"
Check 'even though it finished two minutes ago' ($s.ageHours -lt 1) "ageHours=$($s.ageHours)"
Check 'and nothing is reported as uncovered' (-not @($s.uncovered).Count) `
      "named: $(@($s.uncovered) -join ', ') - the list is short, not wrong"

$s = State (Sweep -Considered @(Entry -CertId 'example.com' -Names @('example.com')) -AgeHours 40) @('example.com')
Check 'the 36-hour backstop still fires' ($s.state -eq 'stale') "said '$($s.state)'"

# --------------------------------------------------------------------------- #
Write-Host "`na forecast from before names was recorded says so"
# Reporting its hosts as uncovered would be the safe direction and the wrong
# words: they may well be covered, the file just cannot answer.
$s = State (Sweep @(Entry -CertId 'example.com' -Names $null)) @('example.com')
Check 'it is not called current'  ($s.state -ne 'current')  "said '$($s.state)'"
Check 'the state is unknown'      ($s.state -eq 'unknown')  "said '$($s.state)'"
Check 'and it accuses no host'    (-not @($s.uncovered).Count) `
      "named: $(@($s.uncovered) -join ', ')"
Check 'the reason says why'       ($s.reason -match 'cannot say what it covers') "said: $($s.reason)"

# --------------------------------------------------------------------------- #
Write-Host "`nnothing to go on at all"
$s = State $null @('example.com')
Check 'a missing forecast is missing, not current' ($s.state -eq 'missing') "said '$($s.state)'"
$s = State (Sweep @()) @()
Check 'an empty forecast on a fresh install is not an accusation' `
      ($s.state -in @('missing', 'current')) "said '$($s.state)'"
Check 'and names nobody' (-not @($s.uncovered).Count) "named: $(@($s.uncovered) -join ', ')"

# --------------------------------------------------------------------------- #
Write-Host "`nthe age is read without a timezone error"
# finishedAt is written as (Get-Date).ToString('o') - local wall clock with an
# offset. Parsed as [datetime] it comes back Kind=Local and comparing it against
# anything UTC is silently wrong by the offset. Four hours, here.
$s = State (Sweep -Considered @(Entry -CertId 'x.example.com' -Names @('x.example.com')) -AgeHours 6) @('x.example.com')
Check 'six hours reads as about six hours' `
      ($s.ageHours -gt 5.5 -and $s.ageHours -lt 6.5) `
      "ageHours=$($s.ageHours) - an offset-sized error means [datetime] crept back in"

# --------------------------------------------------------------------------- #
Write-Host "`ndomains.txt is parsed once, in one place"
$libSrc = Get-Content (Join-Path $srcDir 'acme-lib.ps1') -Raw -Encoding UTF8
Check 'Get-WatchedHostNames exists' ($libSrc -match 'function Get-WatchedHostNames') `
      'the parse is inlined again somewhere'
Check 'the tracker-address check uses it rather than its own copy' `
      ($libSrc -match '\$out\.certificate\.watched = \[bool\]\(@\(Get-WatchedHostNames\)') `
      'two copies of the same three rules drift, and then "is this watched" depends on who asked'

# --------------------------------------------------------------------------- #
Write-Host "`nthe sweep records whether it finished"
$dueSrc = Get-Content (Join-Path $srcDir 'renew-due.ps1') -Raw -Encoding UTF8
Check 'it records what it set out to consider' ($dueSrc -match '\$outcome\.expected = @\(\$renewable\)\.Count') `
      'without it, a truncated list cannot be told from a complete one'
Check 'completeness is derived inside Save-Outcome' `
      ($dueSrc -match '\$outcome\.complete = \(\$null -ne \$outcome\.expected -and') `
      'set by hand at each exit, the next exit added will forget it'

Write-Host "`nthe sweep re-checks when domains.txt has moved on"
Check 'it compares domains.txt against ssl-data.js' `
      ($dueSrc -match '\(Get-Item \$script:DomainsFile\)\.LastWriteTimeUtc -gt \(Get-Item \$sslData\)\.LastWriteTimeUtc') `
      'the automatic edge belongs here, downstream of the edit, not on a domains.txt watcher'
$recheckAt = $dueSrc.IndexOf('domains.txt changed since the last check')
$readAt    = $dueSrc.IndexOf('$checker = Get-CheckerResults')
Check 'and does so BEFORE reading the checker' `
      ($recheckAt -ge 0 -and $readAt -ge 0 -and $recheckAt -lt $readAt) `
      "recheck at $recheckAt, read at $readAt - Get-CheckerResults throws on a fresh install, which is the case this exists to get past"
Check 'both sides of the comparison are UTC' `
      ($dueSrc -notmatch 'LastWriteTime -gt') `
      'LastWriteTime is local and LastWriteTimeUtc is not; mixing them is an offset-sized bug'

Write-Host "`na preview does not email about work nobody scheduled"
Check 'the catch-path alert is mode-guarded' `
      ($dueSrc -match 'if \(\$settings -and -not \$WhatIfOnly\) \{') `
      'a -WhatIfOnly run that throws sends "the unattended renewal run did not complete", and the daily dedup then swallows the real failure'

# --------------------------------------------------------------------------- #
Write-Host "`nthe page asks the server, and still works when it cannot"
$srvSrc = Get-Content (Join-Path $srcDir 'serve.ps1') -Raw -Encoding UTF8
Check 'state carries the verdict' ($srvSrc -match 'forecastState = \$\(') `
      'the page would have to recompute coverage in JavaScript'
Check 'and a failure there does not take the page down' `
      ($srvSrc -match "catch \{ \`$null \}   # a page that renders without this") `
      'an unguarded throw here removes the panel holding the recovery button'

$uiSrc = Get-Content (Join-Path $srcDir 'assets/views/home.js') -Raw -Encoding UTF8
Check 'the button follows the verdict' ($uiSrc -match "return fs\.state !== 'current';") `
      'still gated on the clock'
Check 'and falls back to the age test when there is no verdict' `
      ($uiSrc -match 'if \(!fs \|\| !fs\.state\) \{ return isStale\(f\); \}') `
      'an older server or a grouping failure would lose the button entirely'
Check 'the uncovered hosts are named on the card' ($uiSrc -match 'not in this forecast yet') `
      'a button nobody knew to press is what caused this'
Check 'the amber class it uses exists' `
      ((Get-Content (Join-Path $srcDir 'assets/app.css') -Raw -Encoding UTF8) -match '\.mini\.warnline\{') `
      'the line renders as ordinary body text and reads as a footnote'

Write-Host ""
if ($script:Failed) { Write-Host "$script:Failed CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
