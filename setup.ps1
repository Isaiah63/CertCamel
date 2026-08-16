<#
  setup.ps1 - first-time setup for the SSL Certificate Expiry Tracker.

  Safe to run more than once. It will not overwrite an existing domains.txt,
  and re-registering the scheduled task simply replaces the old definition.

  Run it by double-clicking "First Time Setup.bat".
#>

[CmdletBinding()]
param(
    # Re-register the existing scheduled tasks so they run whether or not
    # anyone is signed in, then exit. No prompts, no downloads, no certificate
    # check.
    #
    # Exists because the repair otherwise means walking the entire interactive
    # setup - domains, the Posh-ACME prompt, a full check run, then three Y/N
    # questions - which is a lot of ceremony for a ten-second fix, and is
    # exactly why it is easy to miss that setup needed administrator.
    [switch]$RepairTasks
)

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

# --------------------------------------------------------------------------- #
# -RepairTasks: fix the principals and get out
# --------------------------------------------------------------------------- #
# Re-registers each EXISTING task with its own action, trigger and settings
# preserved, changing only the principal. Deliberately not rebuilt from
# scratch: whatever schedule or limits are already there stay exactly as they
# are, and a task that was never registered is not conjured into being.

if ($RepairTasks) {
    Write-Host ""
    Write-Host "  Cert Camel - repair scheduled tasks" -ForegroundColor Cyan
    Write-Host ""

    $elevated = (New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $elevated) {
        Write-Host "  This needs administrator." -ForegroundColor Yellow
        Write-Host "  Right-click 'First Time Setup.bat' and choose Run as administrator," -ForegroundColor DarkGray
        Write-Host "  or run this from an elevated PowerShell." -ForegroundColor DarkGray
        Write-Host ""
        exit 1
    }

    $userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $fixed = 0; $already = 0; $missing = 0

    foreach ($def in @($script:ScheduledTaskNames)) {
        $t = Get-ScheduledTask -TaskName $def.name -ErrorAction SilentlyContinue
        if (-not $t) {
            Write-Host ("  {0,-28} not registered - skipped" -f $def.name) -ForegroundColor DarkGray
            $missing++
            continue
        }
        if ($t.Principal.LogonType -eq 'S4U' -or $t.Principal.LogonType -eq 'Password') {
            Write-Host ("  {0,-28} already runs signed-out" -f $def.name) -ForegroundColor Green
            $already++
            continue
        }
        try {
            $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType S4U -RunLevel Limited
            Register-ScheduledTask -TaskName $def.name -Action $t.Actions -Trigger $t.Triggers `
                -Settings $t.Settings -Principal $principal -Force -ErrorAction Stop | Out-Null
            Write-Host ("  {0,-28} fixed" -f $def.name) -ForegroundColor Green
            $fixed++
        }
        catch {
            Write-Host ("  {0,-28} FAILED: {1}" -f $def.name, ($_.Exception.Message -split "`n")[0].Trim()) -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host "  $fixed fixed, $already already correct, $missing not registered." -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

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
    Write-Host "  [1/5] domains.txt already exists - leaving it alone." -ForegroundColor Green
} elseif (Test-Path $domainSeed) {
    # Copied rather than generated so the example list lives in one place, and
    # so your domains.txt is yours - it is gitignored and never overwritten.
    Copy-Item -Path $domainSeed -Destination $domainList
    Write-Host "  [1/5] Created domains.txt from the example list." -ForegroundColor Green
    Write-Host "        Edit it to add your own domains." -ForegroundColor DarkGray
} else {
    $utf8 = New-Object Text.UTF8Encoding $false
    [IO.File]::WriteAllText($domainList, "# One domain per line.`r`nexample.com`r`n", $utf8)
    Write-Host "  [1/5] Created an empty domains.txt." -ForegroundColor Yellow
}

# --------------------------------------------------------------------------- #
# 3. Renewal support (optional)
# --------------------------------------------------------------------------- #
# Watching needs nothing installed. Renewing needs an ACME client, and
# Posh-ACME is fetched into lib\ inside this folder rather than installed
# system-wide, so the bundle stays self-contained.

Write-Host "  [2/5] Renewal support" -ForegroundColor Cyan

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
Write-Host "  [3/5] Running the first check..." -ForegroundColor Cyan
& $checker

# --------------------------------------------------------------------------- #
# 5. Daily scheduled task (optional)
# --------------------------------------------------------------------------- #

Write-Host "  [4/5] Daily automatic check" -ForegroundColor Cyan
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
# 5b. Serve this page over HTTPS (optional)
# --------------------------------------------------------------------------- #
# Walked through here rather than left to Settings because the four
# preconditions fail in four different places, and someone meeting the tool for
# the first time has no way to know which one bit them. Every check reuses
# Get-TrackerAddressStatus, so this says exactly what the Settings page says.
#
# A DNS provider is required here, and the reason is NOT that a hand-issued
# certificate could never be renewed - it could. renew-due.ps1 has an explicit
# "never issued here" branch that picks up any watched certificate once the live
# one is close enough to expiry, whoever issued it.
#
# The reason is narrower: renewal itself validates through the DNS API, so a
# provider has to cover the zone by the time renewal comes due. Without one the
# name never even reaches the renewable set - Get-CertificateGroups files it
# under `unmapped` and skips it - and renew.ps1 throws "The DNS profile for this
# zone is no longer configured".
#
# So issuing by hand first and adding the provider afterwards is a legitimate
# bootstrap, and Cert Camel takes over at renewal. It is just not something this
# step can drive, because everything below depends on the provider existing.

Write-Host ""
Write-Host "  [5/5] Serve this page over HTTPS" -ForegroundColor Cyan
Write-Host ""
Write-Host "        Optional. By default the page is served over plain HTTP at"
Write-Host "        127.0.0.1 on a free port - nothing to set up, and it never leaves"
Write-Host "        this PC. Giving it a name means a real certificate, issued and"
Write-Host "        renewed by this tool like any other."
Write-Host ""
Write-Host "        You can do this later under Settings > General instead." -ForegroundColor DarkGray
Write-Host ""

$wantHttps = Read-Host "        Set up HTTPS for this page now? (Y/N)"

if ($wantHttps -match '^[Yy]') {
    . (Join-Path $root 'acme-lib.ps1')

    $webName = (Read-Host "        Hostname for this page (e.g. tracker.example.com)").Trim()
    $webPort = 0
    $portIn  = (Read-Host "        Fixed port [8787]").Trim()
    if (-not $portIn) { $webPort = 8787 } else { [void][int]::TryParse($portIn, [ref]$webPort) }

    if (-not $webName -or $webPort -lt 1 -or $webPort -gt 65535) {
        Write-Host "        Need a hostname and a fixed port. Skipping - do it in Settings." -ForegroundColor Yellow
    }
    else {
        $st = Get-TrackerAddressStatus -HostName $webName -Port $webPort `
                -Settings (Get-TrackerSettings) -ZoneCache (Get-ZoneCache)

        function Show-Check { param($Ok, $Label, $Detail)
            $mark = $(if ($Ok) { 'ok  ' } else { 'FAIL' })
            Write-Host ("        [{0}] {1,-12} {2}" -f $mark, $Label, $Detail) `
                -ForegroundColor $(if ($Ok) { 'Green' } else { 'Yellow' })
        }
        Write-Host ""
        Show-Check $st.zone.ok        'DNS zone'    $st.zone.detail
        Show-Check $st.certificate.ok 'Certificate' $st.certificate.detail
        Show-Check $st.portCheck.ok   'Port'        $st.portCheck.detail
        Show-Check $st.hosts.ok       'Hosts file'  $st.hosts.detail
        Write-Host ""

        if (-not $st.zone.ok) {
            # Stopped here on purpose. Without a DNS credential that covers the
            # zone, nothing below can succeed, and adding the name to
            # domains.txt would leave an entry that can never renew.
            Write-Host "        No configured DNS credential covers that name, so this step" -ForegroundColor Yellow
            Write-Host "        cannot issue and renew it for you automatically." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "        You can still get HTTPS working now by creating one DNS record" -ForegroundColor Gray
            Write-Host "        by hand. The certificate is real and lasts about 90 days." -ForegroundColor Gray
            Write-Host ""
            Write-Host "        It will NOT renew itself until a DNS provider covers this zone," -ForegroundColor DarkGray
            Write-Host "        because renewal validates through the API. Add one under Settings" -ForegroundColor DarkGray
            Write-Host "        > DNS Automation whenever you have the credential and this" -ForegroundColor DarkGray
            Write-Host "        certificate gets picked up automatically - renewal handles" -ForegroundColor DarkGray
            Write-Host "        certificates it did not issue." -ForegroundColor DarkGray
            Write-Host ""

            $manual = Read-Host "        Issue it now with a manual DNS record? (Y/N)"
            if ($manual -match '^[Yy]') {
                Write-Host ""
                & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                    -File (Join-Path $root 'issue-tracker-cert.ps1') -HostName $webName -Port $webPort
                Write-Host ""
                $st = Get-TrackerAddressStatus -HostName $webName -Port $webPort `
                        -Settings (Get-TrackerSettings) -ZoneCache (Get-ZoneCache)

                if (-not $st.hosts.ok) {
                    if (Test-Elevated) {
                        $addHost2 = Read-Host "        Add $webName to the hosts file? (Y/N)"
                        if ($addHost2 -match '^[Yy]') {
                            try { [void](Add-HostsEntry -HostName $webName); Write-Host "        Added." -ForegroundColor Green }
                            catch { Write-Host "        Could not: $($_.Exception.Message)" -ForegroundColor Yellow }
                        }
                    } else {
                        Write-Host "        The hosts file needs administrator. Add this line yourself:" -ForegroundColor Yellow
                        Write-Host ("            127.0.0.1  {0}" -f $webName) -ForegroundColor White
                    }
                }

                if ($st.certificate.ok) {
                    $sNow = Get-TrackerSettings
                    if (-not $sNow.ContainsKey('web') -or -not $sNow.web) { $sNow.web = @{} }
                    $sNow.web.https = $true; $sNow.web.hostname = $webName
                    $sNow.web.port = $webPort; $sNow.web.hsts = $false
                    Save-TrackerSettings -Settings $sNow
                    Write-Host ""
                    Write-Host ("        HTTPS is on. Next start: https://{0}:{1}" -f $webName, $webPort) -ForegroundColor Green
                }
            }
            else {
                Write-Host "        Skipped. Settings > General will pick this up later." -ForegroundColor DarkGray
            }
        }
        else {
            if (-not $st.certificate.covered -and -not $st.certificate.watched) {
                $addIt = Read-Host "        Add $webName to domains.txt so it gets a certificate? (Y/N)"
                if ($addIt -match '^[Yy]') {
                    try {
                        $r = Add-TrackerDomainEntry -HostName $webName -Port $webPort
                        Write-Host ("        {0}" -f $(if ($r.changed) { "Added $($r.entry)." } else { $r.note })) -ForegroundColor Green
                    } catch { Write-Host "        Could not update domains.txt: $($_.Exception.Message)" -ForegroundColor Yellow }
                }
            }

            if (-not $st.certificate.covered) {
                Write-Host ""
                Write-Host "        The certificate has to be issued before HTTPS can be turned on." -ForegroundColor DarkGray
                Write-Host "        This takes a few minutes while the DNS record propagates." -ForegroundColor DarkGray
                $issue = Read-Host "        Issue it now? (Y/N)"
                if ($issue -match '^[Yy]') {
                    $zoneForCert = $(if ($st.zone.zone) { $st.zone.zone } else { $webName })
                    Write-Host ""
                    & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                        -File (Join-Path $root 'renew.ps1') -Zone $zoneForCert -Source 'cli'
                    Write-Host ""
                    $st = Get-TrackerAddressStatus -HostName $webName -Port $webPort `
                            -Settings (Get-TrackerSettings) -ZoneCache (Get-ZoneCache)
                }
            }

            if (-not $st.hosts.ok) {
                if (Test-Elevated) {
                    $addHost = Read-Host "        Add $webName to the hosts file? (Y/N)"
                    if ($addHost -match '^[Yy]') {
                        try { [void](Add-HostsEntry -HostName $webName); Write-Host "        Added." -ForegroundColor Green }
                        catch { Write-Host "        Could not: $($_.Exception.Message)" -ForegroundColor Yellow }
                    }
                } else {
                    Write-Host "        The hosts file needs administrator. Add this line yourself:" -ForegroundColor Yellow
                    Write-Host ("            127.0.0.1  {0}" -f $webName) -ForegroundColor White
                }
            }

            if ($st.certificate.ok) {
                $settingsNow = Get-TrackerSettings
                if (-not $settingsNow.ContainsKey('web') -or -not $settingsNow.web) { $settingsNow.web = @{} }
                $settingsNow.web.https    = $true
                $settingsNow.web.hostname = $webName
                $settingsNow.web.port     = $webPort
                # HSTS stays off. It is the one setting here that can lock
                # somebody out of their own console, and a first run is the worst
                # possible moment to turn it on - see Settings > General, and
                # sos-plain-http.ps1 for the way back.
                $settingsNow.web.hsts     = $false
                Save-TrackerSettings -Settings $settingsNow
                Write-Host ""
                Write-Host ("        HTTPS is on. Next start: https://{0}:{1}" -f $webName, $webPort) -ForegroundColor Green
                Write-Host "        127.0.0.1 keeps working too, which is the way back in if the" -ForegroundColor DarkGray
                Write-Host "        name ever stops resolving or the certificate lapses." -ForegroundColor DarkGray
            }
            else {
                Write-Host "        Not turning HTTPS on yet - there is no usable certificate for" -ForegroundColor Yellow
                Write-Host "        that name. Settings > General will show what is still missing." -ForegroundColor Yellow
            }
        }
    }
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
# 8. Keep the page running across reboots (server installs)
# --------------------------------------------------------------------------- #
# Offered only on Windows Server. On a PC you open the tracker when you want it
# and close it when you are done, so a background copy is clutter; on a server
# nobody is signed in to open anything.

$isServer = $false
try { $isServer = ([int](Get-CimInstance Win32_OperatingSystem).ProductType -ne 1) } catch { }

$serverTask = Get-SetupTaskName 'server'
$serverTaskExists = [bool](Get-ScheduledTask -TaskName $serverTask -ErrorAction SilentlyContinue)

if ($isServer -or $serverTaskExists) {
    Write-Host ""
    Write-Host "  [+] Keep the page running" -ForegroundColor Cyan
    Write-Host ""

    if ($serverTaskExists) {
        Write-Host "      Already installed: '$serverTask' starts the page at boot." -ForegroundColor Green
        Write-Host ""
        $keep = Read-Host "      Keep it? (Y/N)"
        if ($keep -notmatch '^[Yy]') {
            try {
                $r = Uninstall-CamelServerTask
                Write-Host ""
                Write-Host "      Removed$(if ($r.stoppedRunning) { ', and stopped the running server' })." -ForegroundColor Yellow
            }
            catch {
                Write-Host ""
                Write-Host "      Could not remove it: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
    else {
        Write-Host "      Right now the page runs only while 'Open Tracker.bat' is open, and"
        Write-Host "      stops when you sign out. On a server that means it is gone after"
        Write-Host "      every reboot until somebody signs in and starts it again."
        Write-Host ""
        Write-Host "      This registers '$serverTask' to start it at boot instead. It stays"
        Write-Host "      on 127.0.0.1 - reachable from this machine only, over RDP - and" -ForegroundColor DarkGray
        Write-Host "      nothing is exposed to the network." -ForegroundColor DarkGray
        Write-Host ""

        $wantServer = Read-Host "      Start the page at boot? (Y/N)"
        if ($wantServer -match '^[Yy]') {
            $portAnswer = Read-Host "      Port [8787]"
            $serverPort = 8787
            if ($portAnswer -match '^\d+$' -and [int]$portAnswer -ge 1 -and [int]$portAnswer -le 65535) {
                $serverPort = [int]$portAnswer
            }
            try {
                $r = Install-CamelServerTask -Port $serverPort
                Write-Host ""
                Write-Host "      Registered. It starts at boot on 127.0.0.1:$serverPort." -ForegroundColor Green
                Write-Host "      Start it now without rebooting:" -ForegroundColor DarkGray
                Write-Host "        Start-ScheduledTask -TaskName '$serverTask'" -ForegroundColor DarkGray
                Write-Host ""
                Write-Host "      It lives in Task Scheduler, not services.msc - a scheduled task" -ForegroundColor DarkGray
                Write-Host "      needs no stored password, where a Windows service would have to" -ForegroundColor DarkGray
                Write-Host "      keep yours and would break when it next changed." -ForegroundColor DarkGray
            }
            catch {
                Write-Host ""
                Write-Host "      Could not register it: $(($_.Exception.Message -split "`n")[0].Trim())" -ForegroundColor Red
                Write-Host "      Registering it to run signed-out needs administrator." -ForegroundColor DarkGray
            }
        }
        else {
            Write-Host ""
            Write-Host "      Skipped. Open the page with 'Open Tracker.bat' when you need it." -ForegroundColor Yellow
        }
    }
}

# --------------------------------------------------------------------------- #
# 9. A shortcut with the camel on it
# --------------------------------------------------------------------------- #
# Always made, never asked about: it is one file in the folder it belongs to,
# it replaces nothing, and re-running setup repairs it after the folder moves.
# The desktop copy is the one worth asking about, since that is someone else's
# desktop.

$folderLnk = $null
try {
    $folderLnk = New-TrackerShortcut -Where 'Folder'
}
catch {
    Write-Host ""
    Write-Host "  Could not create the shortcut: $(($_.Exception.Message -split "`n")[0].Trim())" -ForegroundColor Yellow
    Write-Host "  'Open Tracker.bat' still works exactly as before." -ForegroundColor DarkGray
}

if ($folderLnk) {
    Write-Host ""
    Write-Host "  [+] Desktop shortcut" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "      Made 'Cert Camel' in this folder - same launcher, with the camel"
    Write-Host "      on it. A .bat cannot carry its own icon, so the shortcut does."   -ForegroundColor DarkGray
    Write-Host ""

    $wantDesktop = Read-Host "      Put one on the desktop too? (Y/N)"
    if ($wantDesktop -match '^[Yy]') {
        try {
            $d = New-TrackerShortcut -Where 'Desktop'
            Write-Host ""
            Write-Host "      Created $d" -ForegroundColor Green
        }
        catch {
            Write-Host ""
            Write-Host "      Could not create it: $(($_.Exception.Message -split "`n")[0].Trim())" -ForegroundColor Red
        }
    }
    else {
        Write-Host ""
        Write-Host "      Skipped. The one in this folder is still there." -ForegroundColor Yellow
    }
}

# --------------------------------------------------------------------------- #
# Done
# --------------------------------------------------------------------------- #

Write-Host ""
Write-Host "  Setup complete." -ForegroundColor Cyan
Write-Host ""
Write-Host "    Add/remove domains .... edit domains.txt"
Write-Host "    Refresh now ........... Check Now.bat"
Write-Host "    Open the tracker ...... Cert Camel, or Open Tracker.bat"
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
