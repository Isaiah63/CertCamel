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
$taskName    = 'SSL Cert Check'

. (Join-Path $root 'acme-lib.ps1')

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

        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
            -Settings $settings -Description 'Checks SSL certificate expiry for the domains in domains.txt.' `
            -Force | Out-Null

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

$renewTask   = 'Cert Camel Renew'
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

        Register-ScheduledTask -TaskName $renewTask -Action $rAction -Trigger $rTrigger `
            -Settings $rSettings -Description 'Renews certificates the CA reports as due, deploys them, and verifies each load balancer is serving them.' `
            -Force | Out-Null

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
# Done
# --------------------------------------------------------------------------- #

Write-Host ""
Write-Host "  Setup complete." -ForegroundColor Cyan
Write-Host ""
Write-Host "    Add/remove domains .... edit domains.txt"
Write-Host "    Refresh now ........... Check Now.bat"
Write-Host "    View + renew .......... Open Tracker.bat"
Write-Host "    View only ............. ssl-tracker.html"
Write-Host ""
Write-Host "    Renewing needs 'Open Tracker.bat': it starts a small local server" -ForegroundColor DarkGray
Write-Host "    so the page's buttons have something to talk to. Opening the HTML" -ForegroundColor DarkGray
Write-Host "    directly still works, it is just read-only." -ForegroundColor DarkGray
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
    $open = Read-Host "  Open the dashboard now? (Y/N)"
    if ($open -match '^[Yy]') { Start-Process $tracker }
}
