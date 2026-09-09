<#
  The status summary: how often it goes out, and what it says.

  This email exists so nobody has to sign in to a server to find out that
  nothing is wrong, and two of its properties are load-bearing:

  1. THE VERDICT IS IN THE SUBJECT LINE. A daily mail that must be OPENED to
     learn nothing is wrong has moved the chore rather than removed it. So a
     clear day says "all clear" in the subject, and a bad one names the worst
     thing found.

  2. A HEARTBEAT THAT ONLY EVER SAYS "FINE" IS UNTESTED. The check that matters
     is that something genuinely broken flips the verdict - so this breaks a
     scheduled task on purpose and insists the subject changes.

  The nastiest case is the third one below: Get-AutomationStatus reports whether
  it could read the scheduler AT ALL, separately from whether each task is
  registered. Reporting "could not look" as "nothing is registered" would claim
  automation is dead while it runs perfectly - a lie in the dangerous direction,
  and one this composer made on its first run.

      powershell -ExecutionPolicy Bypass -File .\v42-status-digest-test.ps1
#>

$ErrorActionPreference = 'Stop'
$repo   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$srcDir = Join-Path $repo 'resources'
. (Join-Path $srcDir 'acme-lib.ps1')

$script:Failed = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    if ($Ok) { Write-Host "  ok   $Name" -ForegroundColor Green }
    else     { Write-Host "  FAIL $Name  -- $Detail" -ForegroundColor Red; $script:Failed++ }
}

function New-Settings {
    param([string]$Cadence = 'daily', [string]$WeeklyDay = 'Monday', [int]$MonthDay = 1)
    return @{
        contact = 'me@example.com'
        alerts  = @{
            smtp      = @{ host = 'localhost'; port = 1025; encryption = 'none'
                           from = 'c@example.com'; to = @('me@example.com')
                           authRequired = $false; username = '' }
            htmlEmail = @{ enabled = $true }
            summary   = @{ cadence = $Cadence; weeklyDay = $WeeklyDay; monthDay = $MonthDay }
        }
    }
}

function New-Task {
    param([string]$Key, [string]$Label, [bool]$Registered = $true,
          [bool]$Enabled = $true, $LastResult = 0)
    return @{
        key = $Key; name = "Cert Camel $Label"; label = $Label
        registered = $Registered; enabled = $Enabled; state = 'ready'
        lastRun = (Get-Date).AddHours(-6).ToString('o')
        nextRun = (Get-Date).AddHours(18).ToString('o')
        lastResult = $LastResult
    }
}

function New-Automation {
    param([array]$Tasks, [bool]$Available = $true, [string]$ErrorText = $null)
    return @{ available = $Available; error = $ErrorText; tasks = @($Tasks); isServer = $false }
}

function New-Checker {
    param([array]$Results)
    return @{ generated = (Get-Date).ToString('o'); results = @($Results) }
}
function New-Host {
    param([string]$Name, [bool]$Ok = $true, [int]$DaysLeft = 60, [string]$ErrorText = $null)
    return @{ host = $Name; ok = $Ok
              notAfter = $(if ($Ok) { (Get-Date).AddDays($DaysLeft).ToString('o') } else { $null })
              error = $ErrorText }
}

# The healthy baseline every "and now break one thing" case is measured against.
$goodTasks = @(
    (New-Task 'renew'  'Renew and deploy'),
    (New-Task 'check'  'Expiry check'),
    (New-Task 'report' 'Status summary email'),
    (New-Task 'server' 'Web page' -Registered $false)   # optional, absent on a PC
)
$goodChecker = New-Checker @(
    (New-Host 'a.example.com' -DaysLeft 60),
    (New-Host 'b.example.com' -DaysLeft 75),
    (New-Host 'c.example.com' -DaysLeft 90)
)

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("cc-v42-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $sandbox
$script:SettingsFile = Join-Path $sandbox 'settings.json'
$script:SecretsFile  = Join-Path $sandbox 'secrets.xml'
Write-Host "sandbox: $sandbox"

try {
    # ----------------------------------------------------------------------- #
    Write-Host "`nhow often it goes out"
    $mon = Get-Date '2026-09-07'   # a Monday
    $tue = Get-Date '2026-09-08'
    Check 'off never sends'    (-not (Test-SummaryDue -Settings (New-Settings 'off')   -Now $mon)) 'sent while off'
    Check 'daily always sends' (Test-SummaryDue -Settings (New-Settings 'daily') -Now $tue) 'did not send'
    Check 'weekly sends on its day' (Test-SummaryDue -Settings (New-Settings 'weekly' 'Monday') -Now $mon) 'missed its day'
    Check 'weekly stays quiet otherwise' (-not (Test-SummaryDue -Settings (New-Settings 'weekly' 'Monday') -Now $tue)) 'sent on the wrong day'
    Check 'monthly sends on the 1st' (Test-SummaryDue -Settings (New-Settings 'monthly') -Now (Get-Date '2026-09-01')) 'missed the 1st'
    Check 'monthly stays quiet otherwise' (-not (Test-SummaryDue -Settings (New-Settings 'monthly') -Now $tue)) 'sent mid-month'
    Check 'an unrecognised cadence sends nothing' `
          (-not (Test-SummaryDue -Settings (New-Settings 'hourly') -Now $tue)) `
          'a stale client must not be able to schedule mail'

    Write-Host "`nand a day that does not exist in a short month still fires"
    # 31 asked for in February would otherwise skip seven months a year.
    Check 'the 31st falls back to the last day of February' `
          (Test-SummaryDue -Settings (New-Settings 'monthly' 'Monday' 31) -Now (Get-Date '2026-02-28')) `
          'the summary would never send in February, April, June, September or November'
    Check 'and does not also fire on the 1st' `
          (-not (Test-SummaryDue -Settings (New-Settings 'monthly' 'Monday' 31) -Now (Get-Date '2026-02-01'))) `
          'fired twice'

    Write-Host "`nand it can say when the next one is due"
    $next = Get-NextSummaryDate -Settings (New-Settings 'weekly' 'Monday') -Now $mon
    Check 'the next weekly one is seven days on' ($next.DayOfWeek -eq 'Monday' -and $next -gt $mon) "got $next"
    Check 'off has no next date' ($null -eq (Get-NextSummaryDate -Settings (New-Settings 'off') -Now $mon)) 'invented one'

    # ----------------------------------------------------------------------- #
    Write-Host "`na healthy install"
    $good = New-StatusSummaryMessage -Settings (New-Settings 'daily') -Now (Get-Date) `
        -Automation (New-Automation $goodTasks) -Checker $goodChecker -Deployments @()
    Check 'the verdict is ok'          ($good.verdict -eq 'ok') "got $($good.verdict)"
    Check 'THE SUBJECT SAYS SO'        ($good.subject -match 'all clear') $good.subject
    Check 'and it counts the hosts'    ($good.subject -match '3 host') $good.subject
    Check 'and names the soonest expiry' ($good.subject -match 'soonest expiry in 59|soonest expiry in 60') $good.subject

    $goodText = Format-AlertText -Message $good.message
    Check 'healthy hosts are counted, not listed one by one' `
          ($goodText -match '3 other host\(s\) valid') $goodText
    Check 'an optional task that was never set up is not a problem' `
          (($good.verdict -eq 'ok') -and ($goodText -match 'Web page')) `
          'the web page task is only offered on Windows Server; absence is a fact, not a fault'

    # ----------------------------------------------------------------------- #
    Write-Host "`nbreak a scheduled task on purpose"
    <#
      The check the whole feature rests on. A heartbeat that only ever says
      "fine" has never demonstrated it can say anything else.
    #>
    $brokenTasks = @(
        (New-Task 'renew'  'Renew and deploy'),
        (New-Task 'check'  'Expiry check' -Registered $false),
        (New-Task 'report' 'Status summary email'),
        (New-Task 'server' 'Web page' -Registered $false)
    )
    $bad = New-StatusSummaryMessage -Settings (New-Settings 'daily') -Now (Get-Date) `
        -Automation (New-Automation $brokenTasks) -Checker $goodChecker -Deployments @()
    Check 'the verdict turns bad'    ($bad.verdict -eq 'bad') "got $($bad.verdict)"
    Check 'THE SUBJECT CHANGES'      ($bad.subject -notmatch 'all clear') $bad.subject
    Check 'and names what broke'     ($bad.subject -match 'Expiry check') $bad.subject
    Check 'it reads as singular'     ($bad.subject -match '1 thing needs attention') $bad.subject

    Write-Host "`na task that is registered but switched off"
    $offTasks = @((New-Task 'renew' 'Renew and deploy' -Enabled $false), (New-Task 'check' 'Expiry check'))
    $offMsg = New-StatusSummaryMessage -Settings (New-Settings 'daily') -Now (Get-Date) `
        -Automation (New-Automation $offTasks) -Checker $goodChecker -Deployments @()
    Check 'is a warning, not a failure' ($offMsg.verdict -eq 'warn') "got $($offMsg.verdict)"
    Check 'and says which' ($offMsg.subject -match 'switched off') $offMsg.subject

    Write-Host "`na task whose last run failed"
    <#
      Both shapes of failure code, and the first one is not academic. An HRESULT
      like 0x80070001 is 2147942401 unsigned, which OVERFLOWS Int32 - casting it
      with [int] throws, and a swallowed cast reports a broken task as healthy.
      That is the one direction this must never fail in, and it is exactly what
      the first version of this composer did. COM hands the value back signed,
      so the negative form is what a real machine produces.
    #>
    foreach ($code in @(2147942401, -2147024894)) {
        $failTasks = @((New-Task 'renew' 'Renew and deploy' -LastResult $code), (New-Task 'check' 'Expiry check'))
        $failMsg = New-StatusSummaryMessage -Settings (New-Settings 'daily') -Now (Get-Date) `
            -Automation (New-Automation $failTasks) -Checker $goodChecker -Deployments @()
        Check "is reported (code $code)"   ($failMsg.verdict -eq 'bad') "got $($failMsg.verdict)"
        Check "with the code ($code)" `
              ((Format-AlertText -Message $failMsg.message) -match ([regex]::Escape([string]$code))) 'code not shown'
    }

    Write-Host "`na task registered today that has not run yet is not a failure"
    $newTasks = @((New-Task 'renew' 'Renew and deploy' -LastResult 267011), (New-Task 'check' 'Expiry check'))
    $newMsg = New-StatusSummaryMessage -Settings (New-Settings 'daily') -Now (Get-Date) `
        -Automation (New-Automation $newTasks) -Checker $goodChecker -Deployments @()
    Check 'stays all clear' ($newMsg.verdict -eq 'ok') "got $($newMsg.verdict)"
    Check 'and says it plainly' `
          ((Format-AlertText -Message $newMsg.message) -match 'has not run yet') 'wording missing'

    # ----------------------------------------------------------------------- #
    Write-Host "`nwhen the scheduler itself cannot be read"
    <#
      "Could not look" and "nothing is registered" are different answers and the
      response to each differs. Reporting the first as the second says automation
      is dead when it may be running perfectly - and this composer did exactly
      that on its first run, by iterating the wrapper object as if it were the
      task list.
    #>
    $blind = New-StatusSummaryMessage -Settings (New-Settings 'daily') -Now (Get-Date) `
        -Automation (New-Automation @() $false 'RPC server unavailable') `
        -Checker $goodChecker -Deployments @()
    $blindText = Format-AlertText -Message $blind.message
    Check 'it says it could not read the scheduler' `
          ($blindText -match 'Could not read the Windows scheduler') $blindText
    Check 'it passes on the reason' ($blindText -match 'RPC server unavailable') $blindText
    Check 'it does NOT claim tasks are unregistered' `
          ($blindText -notmatch 'NOT REGISTERED') `
          'that would report automation as dead while it ran'
    Check 'and it is a warning rather than a failure' ($blind.verdict -eq 'warn') "got $($blind.verdict)"

    # ----------------------------------------------------------------------- #
    Write-Host "`ncertificates"
    $expiring = New-Checker @(
        (New-Host 'soon.example.com'  -DaysLeft 3),
        (New-Host 'later.example.com' -DaysLeft 20),
        (New-Host 'fine.example.com'  -DaysLeft 200),
        (New-Host 'dead.example.com'  -Ok $false -ErrorText 'connection actively refused')
    )
    $certMsg = New-StatusSummaryMessage -Settings (New-Settings 'daily') -Now (Get-Date) `
        -Automation (New-Automation $goodTasks) -Checker $expiring -Deployments @()
    $certText = Format-AlertText -Message $certMsg.message
    Check 'an unreachable host is reported' ($certText -match 'dead\.example\.com') $certText
    Check 'with the reason'                 ($certText -match 'actively refused') $certText
    Check 'one expiring within a week is a failure' ($certText -match '\[FAIL\]\s+soon\.example\.com') $certText
    Check 'one expiring within a month is a warning' ($certText -match '\[!\]\s+later\.example\.com') $certText
    Check 'and the healthy remainder is a count' ($certText -match '1 other host\(s\) valid') `
          'the count must exclude the three rows already printed'
    Check 'the verdict is bad'  ($certMsg.verdict -eq 'bad') "got $($certMsg.verdict)"

    # ----------------------------------------------------------------------- #
    Write-Host "`ndeployments"
    $depMsg = New-StatusSummaryMessage -Settings (New-Settings 'daily') -Now (Get-Date) `
        -Automation (New-Automation $goodTasks) -Checker $goodChecker `
        -Deployments @(@{ name = 'certcamel.com'; ok = $false; error = 'crt-list FAILED' },
                       @{ name = 'other.com';     ok = $true;  error = $null })
    $depText = Format-AlertText -Message $depMsg.message
    Check 'a failed deployment is reported' ($depText -match 'certcamel\.com') $depText
    Check 'with its error'                  ($depText -match 'crt-list FAILED') $depText
    Check 'a successful one is not'         ($depText -notmatch 'other\.com') $depText

    # ----------------------------------------------------------------------- #
    Write-Host "`nthe footer makes a missing email noticeable"
    Check 'it says when the next one is due' `
          ((Format-AlertText -Message $good.message) -match 'next summary is due') 'no next-due line'
    Check 'and says what silence means' `
          ((Format-AlertText -Message $good.message) -match 'if it does not arrive') 'the heartbeat is not explained'

    # ----------------------------------------------------------------------- #
    Write-Host "`nan install that had the monthly summary on keeps getting it"
    Save-TrackerSettings -Settings @{
        version = 1
        alerts  = @{
            smtp = @{ host = 'localhost'; port = 1025; encryption = 'none'
                      from = 'a@b.c'; to = @('d@e.f'); authRequired = $false; username = '' }
            monthlySummary = @{ enabled = $true }
        }
    }
    $migrated = Get-TrackerSettings
    Check 'monthlySummary became a monthly cadence' `
          ([string]$migrated.alerts.summary.cadence -eq 'monthly') `
          "got '$($migrated.alerts.summary.cadence)' - somebody's summary would have stopped arriving"
    Check 'and it still sends on the 1st' `
          (Test-SummaryDue -Settings $migrated -Now (Get-Date '2026-10-01')) 'no longer sends'

    Write-Host "`nand one that had it off stays off"
    Remove-Item $script:SettingsFile -Force
    Save-TrackerSettings -Settings @{
        version = 1
        alerts  = @{
            smtp = @{ host = ''; port = 587; encryption = 'starttls'
                      from = ''; to = @(); authRequired = $false; username = '' }
            monthlySummary = @{ enabled = $false }
        }
    }
    $migratedOff = Get-TrackerSettings
    Check 'off stays off' ([string]$migratedOff.alerts.summary.cadence -eq 'off') `
          "got '$($migratedOff.alerts.summary.cadence)' - an upgrade must not start sending mail"
}
finally {
    Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:Failed) { Write-Host "$script:Failed CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
