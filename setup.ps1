<#
  setup.ps1 - first-time setup for the SSL Certificate Expiry Tracker.

  Safe to run more than once. It will not overwrite an existing domains.txt,
  and re-registering the scheduled task simply replaces the old definition.

  Run it by double-clicking "First Time Setup.bat".
#>

$ErrorActionPreference = 'Stop'

$root        = $PSScriptRoot
$domainList  = Join-Path $root 'domains.txt'
$domainSeed  = Join-Path $root 'domains.example.txt'
$checker     = Join-Path $root 'check-ssl.ps1'
$tracker     = Join-Path $root 'ssl-tracker.html'
$launcher    = Join-Path $root 'Open Tracker.bat'

. (Join-Path $root 'acme-lib.ps1')

# Task names come from the shared map in acme-lib.ps1 rather than being spelled
# out here. They used to be literals in both this file and nothing else; now
# serve.ps1 reports on the same tasks, and a name changed in one place but not
# the other would show as "not registered" on the Home page while the task ran
# perfectly well.
function Get-SetupTaskName {
    param([string]$Key)
    $def = @($script:ScheduledTaskNames) | Where-Object { $_.key -eq $Key }
    if (-not $def) { throw "No scheduled task is defined for '$Key'." }
    return $def.name
}

function Register-CamelTask {
    <#
      Registers a task that runs WHETHER OR NOT ANYONE IS LOGGED ON.

      Without an explicit principal, Register-ScheduledTask defaults to
      LogonType Interactive - the task runs only while this user has a session.
      On a workstation you log into daily that is invisible, and
      StartWhenAvailable quietly papers over it. On a server, where nobody stays
      logged in, it is silently fatal: the 03:20 renewal never fires, Task
      Scheduler still reports "Ready", the history stays empty, and the first
      symptom is an expired certificate.

      S4U ("service for user") needs no stored password, but it does need the
      "Log on as a batch job" right, which standard users do not hold. If
      Windows refuses, fall back to the old behaviour rather than leaving
      nothing registered at all - but say plainly what was given up.
    #>
    param(
        [string]$Name,
        $Action,
        $Trigger,
        $Settings,
        [string]$Description
    )

    $userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name

    try {
        $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType S4U `
            -RunLevel Limited -ErrorAction Stop
        Register-ScheduledTask -TaskName $Name -Action $Action -Trigger $Trigger `
            -Settings $Settings -Principal $principal -Description $Description `
            -Force -ErrorAction Stop | Out-Null
        return 'S4U'
    }
    catch {
        # "Access is denied" is what this looks like unelevated. Register it the
        # old way rather than leaving the user with no task at all.
        Register-ScheduledTask -TaskName $Name -Action $Action -Trigger $Trigger `
            -Settings $Settings -Description $Description -Force -ErrorAction Stop | Out-Null

        # Said once, not once per task - three identical paragraphs would train
        # people to skip past it, which is the opposite of the point.
        if (-not $script:WarnedAboutLogonType) {
            $script:WarnedAboutLogonType = $true
            Write-Host ""
            Write-Host "        Note: these tasks will only run while you are signed in." -ForegroundColor Yellow
            Write-Host "        Windows refused 'run whether logged on or not' (Access is denied)," -ForegroundColor DarkGray
            Write-Host "        which needs the 'Log on as a batch job' right. That is fine on a" -ForegroundColor DarkGray
            Write-Host "        PC you sign into daily." -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "        On an always-on server it is not: nothing would renew while" -ForegroundColor DarkGray
            Write-Host "        nobody is logged on. Re-run this as administrator there." -ForegroundColor DarkGray
        }
        return 'Interactive'
    }
}

$taskName = Get-SetupTaskName 'check'

Write-Host ""
Write-Host "  SSL Certificate Expiry Tracker - setup" -ForegroundColor Cyan
Write-Host "  $root" -ForegroundColor DarkGray
Write-Host ""

# --------------------------------------------------------------------------- #
# 1. Sanity check
# --------------------------------------------------------------------------- #

if (-not (Test-Path $checker)) {
    Write-Host "  check-ssl.ps1 is missing from this folder. Setup cannot continue." -ForegroundColor Red
    Write-Host ""
    Read-Host "  Press Enter to close"
    exit 1
}

# --------------------------------------------------------------------------- #
# 2. Make sure there is a domain list
# --------------------------------------------------------------------------- #

if (Test-Path $domainList) {
    Write-Host "  [1/4] domains.txt already exists - leaving it alone." -ForegroundColor Green
} elseif (Test-Path $domainSeed) {
    # Copied rather than generated so the example list lives in one place, and
    # so your domains.txt is yours - it is gitignored and never overwritten.
    Copy-Item -Path $domainSeed -Destination $domainList
    Write-Host "  [1/4] Created domains.txt from the example list." -ForegroundColor Green
    Write-Host "        Edit it to add your own domains." -ForegroundColor DarkGray
} else {
    $utf8 = New-Object Text.UTF8Encoding $false
    [IO.File]::WriteAllText($domainList, "# One domain per line.`r`nexample.com`r`n", $utf8)
    Write-Host "  [1/4] Created an empty domains.txt." -ForegroundColor Yellow
}

# --------------------------------------------------------------------------- #
# 3. Renewal support (optional)
# --------------------------------------------------------------------------- #
# Watching needs nothing installed. Renewing needs an ACME client, and
# Posh-ACME is fetched into lib\ inside this folder rather than installed
# system-wide, so the bundle stays self-contained.

Write-Host "  [2/4] Renewal support" -ForegroundColor Cyan

if (Get-VendoredPoshAcme) {
    Write-Host "        Posh-ACME is already in this folder." -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "        To renew certificates from the tracker page, this needs Posh-ACME"
    Write-Host "        (an ACME client). It is downloaded into the 'lib' folder here -"
    Write-Host "        nothing is installed system-wide, and it needs no admin rights."
    Write-Host ""
    Write-Host "        Skip this if you only want expiry monitoring." -ForegroundColor DarkGray
    Write-Host ""

    $wantAcme = Read-Host "        Download Posh-ACME now? (Y/N)"

    if ($wantAcme -match '^[Yy]') {
        try {
            Write-Host "        Downloading..." -ForegroundColor DarkGray
            $manifest = Install-PoshAcmeLocal
            Write-Host "        Installed: $manifest" -ForegroundColor Green
        }
        catch {
            Write-Host ""
            Write-Host "        Could not download it: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "        Monitoring still works. To retry later, run this setup again." -ForegroundColor Yellow
        }
    } else {
        Write-Host "        Skipped - monitoring only." -ForegroundColor Yellow
    }
}

# --------------------------------------------------------------------------- #
# 4. First check, so the page has something to show immediately
# --------------------------------------------------------------------------- #

Write-Host ""
Write-Host "  [3/4] Running the first check..." -ForegroundColor Cyan
& $checker

# --------------------------------------------------------------------------- #
# 5. Daily scheduled task (optional)
# --------------------------------------------------------------------------- #

Write-Host "  [4/4] Daily automatic check" -ForegroundColor Cyan
Write-Host ""
Write-Host "        This registers a Windows scheduled task named '$taskName' that"
Write-Host "        re-checks your domains every morning at 9:00 AM, so the page is"
Write-Host "        always current when you open it. Runs as you, no admin needed."
Write-Host ""

$answer = Read-Host "        Register the daily task? (Y/N)"

if ($answer -match '^[Yy]') {
    try {
        # The task stores an absolute path, which is why moving this folder
        # means running setup again.
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$checker`""

        $trigger  = New-ScheduledTaskTrigger -Daily -At 9:00am

        # StartWhenAvailable catches up after the PC was off, matching how the
        # existing "Organize Docs Hub" task behaves.
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
            -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries

        [void](Register-CamelTask -Name $taskName -Action $action -Trigger $trigger `
            -Settings $settings -Description 'Checks SSL certificate expiry for the domains in domains.txt.')

        Write-Host ""
        Write-Host "        Registered. It will run daily at 9:00 AM." -ForegroundColor Green
    }
    catch {
        Write-Host ""
        Write-Host "        Could not register the task: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "        No harm done - just run 'Check Now.bat' by hand instead." -ForegroundColor Yellow
    }
} else {
    Write-Host ""
    Write-Host "        Skipped. Run 'Check Now.bat' whenever you want to refresh." -ForegroundColor Yellow
}

# --------------------------------------------------------------------------- #
# 6. Unattended renewal (optional, and deliberately opt-in)
# --------------------------------------------------------------------------- #

$renewTask   = Get-SetupTaskName 'renew'
$renewScript = Join-Path $root 'renew-due.ps1'

Write-Host ""
Write-Host "  [+] Unattended renewal" -ForegroundColor Cyan
Write-Host ""
Write-Host "      Registers '$renewTask' to run daily. It renews only what the"
Write-Host "      certificate authority says is due, then pushes each certificate to"
Write-Host "      its load balancers and checks every node is really serving it."
Write-Host ""
Write-Host "      Only worth enabling on a machine that is always on. If this one"  -ForegroundColor DarkGray
Write-Host "      sleeps or gets shut down, nothing renews and the first you hear"  -ForegroundColor DarkGray
Write-Host "      of it is an expiry warning." -ForegroundColor DarkGray
Write-Host ""
Write-Host "      Set up load balancers in Settings first, or renewal will issue" -ForegroundColor DarkGray
Write-Host "      certificates that go nowhere." -ForegroundColor DarkGray
Write-Host ""

$wantRenew = Read-Host "      Register daily unattended renewal? (Y/N)"

if ($wantRenew -match '^[Yy]') {
    try {
        $rAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$renewScript`""

        # 03:20 rather than on the hour: ACME rate limits are per-CA and shared
        # by everyone, and the top of the hour is where every naive scheduler
        # piles up.
        $rTrigger = New-ScheduledTaskTrigger -Daily -At 3:20am

        $rSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
            -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Hours 2)

        [void](Register-CamelTask -Name $renewTask -Action $rAction -Trigger $rTrigger `
            -Settings $rSettings -Description 'Renews certificates the CA reports as due, deploys them, and verifies each load balancer is serving them.')

        Write-Host ""
        Write-Host "      Registered. Runs daily at 3:20 AM." -ForegroundColor Green
        Write-Host "      Try it safely first:" -ForegroundColor DarkGray
        Write-Host "        powershell -ExecutionPolicy Bypass -File `"$renewScript`" -WhatIfOnly" -ForegroundColor DarkGray
    }
    catch {
        Write-Host ""
        Write-Host "      Could not register it: $($_.Exception.Message)" -ForegroundColor Red
    }
} else {
    Write-Host ""
    Write-Host "      Skipped. Renew from the page, or run renew-due.ps1 by hand." -ForegroundColor Yellow
}

# --------------------------------------------------------------------------- #
# 7. Monthly summary email (optional)
# --------------------------------------------------------------------------- #
# Registered as a daily task, not a monthly one: New-ScheduledTaskTrigger has
# no monthly option in this PowerShell version, and monthly-report.ps1 already
# no-ops itself on every day but the 1st. A daily trigger that mostly does
# nothing is simpler to get right than reaching for the CIM trigger types the
# cmdlet does not expose.

$reportTask   = Get-SetupTaskName 'report'
$reportScript = Join-Path $root 'monthly-report.ps1'

Write-Host ""
Write-Host "  [+] Monthly summary email" -ForegroundColor Cyan
Write-Host ""
Write-Host "      Registers '$reportTask' to check every morning and send a summary" -ForegroundColor DarkGray
Write-Host "      email on the 1st of the month - only if the monthly summary alert" -ForegroundColor DarkGray
Write-Host "      is turned on and email is configured under Settings > Alerts." -ForegroundColor DarkGray
Write-Host ""

$wantReport = Read-Host "      Register the monthly summary task? (Y/N)"

if ($wantReport -match '^[Yy]') {
    try {
        $mAction  = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$reportScript`""
        $mTrigger = New-ScheduledTaskTrigger -Daily -At 8:00am
        $mSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
            -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries

        [void](Register-CamelTask -Name $reportTask -Action $mAction -Trigger $mTrigger `
            -Settings $mSettings -Description 'Sends the monthly certificate summary email, if enabled under Settings > Alerts.')

        Write-Host ""
        Write-Host "      Registered. Checks daily at 8:00 AM; only sends on the 1st." -ForegroundColor Green
        Write-Host "      Try it safely first:" -ForegroundColor DarkGray
        Write-Host "        powershell -ExecutionPolicy Bypass -File `"$reportScript`" -Force" -ForegroundColor DarkGray
    }
    catch {
        Write-Host ""
        Write-Host "      Could not register it: $($_.Exception.Message)" -ForegroundColor Red
    }
} else {
    Write-Host ""
    Write-Host "      Skipped. Run monthly-report.ps1 by hand whenever you want one." -ForegroundColor Yellow
}

# --------------------------------------------------------------------------- #
# Done
# --------------------------------------------------------------------------- #

Write-Host ""
Write-Host "  Setup complete." -ForegroundColor Cyan
Write-Host ""
Write-Host "    Add/remove domains .... edit domains.txt"
Write-Host "    Refresh now ........... Check Now.bat"
Write-Host "    Open the tracker ...... Open Tracker.bat"
Write-Host ""
Write-Host "    Always use 'Open Tracker.bat': it starts a small local server the page" -ForegroundColor DarkGray
Write-Host "    needs for everything, including just displaying what is tracked." -ForegroundColor DarkGray
Write-Host "    Opening ssl-tracker.html directly no longer works on its own." -ForegroundColor DarkGray
Write-Host ""
Write-Host "    Moved this folder? Run this setup again so the scheduled" -ForegroundColor DarkGray
Write-Host "    task points at the new location." -ForegroundColor DarkGray
Write-Host ""
Write-Host "    Remove the daily task:" -ForegroundColor DarkGray
Write-Host "      Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false" -ForegroundColor DarkGray
Write-Host ""

if (Test-Path $launcher) {
    $open = Read-Host "  Open the tracker now? (Y/N)"
    if ($open -match '^[Yy]') { Start-Process -FilePath $launcher }
}
elseif (Test-Path $tracker) {
    # No fallback to opening $tracker directly: ssl-tracker.html now requires
    # the session token serve.ps1 hands it and shows an explanatory error
    # without one, rather than the read-only page it used to fall back to.
    Write-Host "  'Open Tracker.bat' is missing, so there is nothing to launch." -ForegroundColor Yellow
    Write-Host "  Run serve.ps1 directly instead: powershell -ExecutionPolicy Bypass -File `"$(Join-Path $root 'serve.ps1')`"" -ForegroundColor DarkGray
}
