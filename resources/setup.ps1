<#
  setup.ps1 - first-time setup for the SSL Certificate Expiry Tracker.

  Safe to run more than once. It will not overwrite an existing domains.txt,
  and re-registering the scheduled task simply replaces the old definition.

  Run it by double-clicking "First Time Setup.bat".

  WHAT IS HERE AND WHY IT IS NOT IN THE BROWSER

  Worth writing down, because "move this into the app" is an obvious-looking
  improvement that has already been half-attempted once, and everything left
  here is here for a reason:

    elevation, permissions, foreign tasks   only an elevated process can do it
    Posh-ACME                               writes into a folder the step above
                                            has just restricted
    contact address, DNS credential         must exist before a certificate can
                                            be issued, and the browser cannot be
                                            served over HTTPS until one is
    scheduled tasks                         S4U registration needs the
                                            "Log on as a batch job" right
    hosts file entry                        administrator, always

  Two steps could move and deliberately do not. Seeding domains.txt and running
  the first check are both things the app can do - the domains editor and the
  Check button already exist - but moving them means setup finishes and hands
  over a console with nothing in it. They stay so that the first thing anybody
  sees is a page with data on it.

  Everything else already lives in the app: alerts, load balancers, log
  retention, and editing the domain list afterwards. Home carries a checklist
  of what a new install still needs.
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
    [switch]$RepairTasks,

    # Set only by the elevation relaunch below, never by hand: the account that
    # started setup before Windows asked for approval. The elevated instance
    # compares it against its own identity, which is the one reliable way to
    # notice that UAC was satisfied with a DIFFERENT administrator's credentials
    # - and that matters because it silently decides who owns the install.
    [string]$ExpectedOwner
)

$ErrorActionPreference = 'Stop'

# Two roots, matching acme-lib: $appDir is resources\, where the scripts and the
# app shell ship; $root is the folder itself, which holds the operator's files
# and the things they double-click. Registering a task against the wrong one is
# the mistake this split exists to make obvious.
$appDir      = $PSScriptRoot
$root        = Split-Path $PSScriptRoot -Parent
$domainList  = Join-Path $root 'domains.txt'
$checker     = Join-Path $appDir 'check-ssl.ps1'
$tracker     = Join-Path $appDir 'ssl-tracker.html'
$launcher    = Join-Path $root 'Open Tracker.bat'

. (Join-Path $appDir 'acme-lib.ps1')

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
      "Log on as a batch job" right, which standard users do not hold.

      This used to fall back to an Interactive registration when Windows refused
      S4U, reasoning that some task beats none. It does not. The fallback
      produces a task that reports Ready in Task Scheduler and never fires,
      which is the one outcome nobody can see - and it announced itself in a
      warning printed halfway down a wall of setup text, sixty days before the
      expired certificate that is the real first symptom.

      So: S4U or an error, matching Install-CamelServerTask, which has always
      worked this way. Setup requires administrator now (see the gate below the
      banner), which is what makes that a reasonable demand rather than a dead
      end. A task that is missing is at least visible on the Home page.
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
        # Rethrown, never downgraded. Every caller wraps this in a try/catch that
        # reports the step as failed, which is the outcome wanted: nothing
        # registered, and a reason on screen.
        $reason = ($_.Exception.Message -split "`n")[0].Trim()
        throw ("could not register it to run whether or not $userId is signed in ($reason). " +
               "That needs the 'Log on as a batch job' right for $userId - grant it under " +
               "secpol.msc, Local Policies, User Rights Assignment, then run setup again. " +
               "Nothing was registered: a task that runs only while you are signed in would " +
               "report Ready in Task Scheduler and quietly renew nothing.")
    }
}

$taskName = Get-SetupTaskName 'check'

# --------------------------------------------------------------------------- #
# -RepairTasks: fix the principals and get out
# --------------------------------------------------------------------------- #
# Re-registers each EXISTING task with its own trigger and settings preserved,
# fixing two things: the principal, and the path to the script it runs.
# Deliberately not rebuilt from scratch: whatever schedule or limits are already
# there stay exactly as they are, and a task that was never registered is not
# conjured into being.
#
# The PATH half exists because a task stores an absolute one. Copy the folder
# somewhere else, or take an update that moves the scripts - as the move into
# resources\ did - and every task still names where the script used to be. The
# task keeps reporting healthy and renewal silently stops, which is the failure
# Get-AutomationStatus flags as pathMatches=false. This is the repair for it,
# and it is why the principal check below cannot short-circuit the loop: a task
# can be correctly S4U and still point at nothing.

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
        $principalOk = ($t.Principal.LogonType -eq 'S4U' -or $t.Principal.LogonType -eq 'Password')

        # Rewrite only the -File argument, keeping everything after it: the
        # server task carries "-Port 8787 -ServiceMode" and losing that would
        # start it on a random port that "Open Tracker.bat" cannot predict.
        $expected = Join-Path $appDir $def.script
        $actions  = @($t.Actions)
        $pathOk   = $true
        foreach ($a in $actions) {
            # Shared with Get-AutomationStatus rather than matched again here.
            # There used to be two patterns, they disagreed about the server
            # task, and both got a path with spaces in it wrong - so a repair
            # run against C:\Program Files\Cert Camel\... rewrote the wrong
            # substring of its own argument string.
            $current = Get-TaskScriptPath -Arguments ([string]$a.Arguments)
            if (-not $current) { continue }
            $same = $false
        try { $same = ([IO.Path]::GetFullPath($current) -eq [IO.Path]::GetFullPath($expected)) } catch { $null = $_ }   # unparseable: treated as different, so the task is re-pointed
            if ($same) { continue }
            $pathOk = $false
            $a.Arguments = [string]$a.Arguments -replace [regex]::Escape($current), $expected.Replace('$', '$$')
        }

        if ($principalOk -and $pathOk) {
            Write-Host ("  {0,-28} already correct" -f $def.name) -ForegroundColor Green
            $already++
            continue
        }
        try {
            $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType S4U -RunLevel Limited
            Register-ScheduledTask -TaskName $def.name -Action $actions -Trigger $t.Triggers `
                -Settings $t.Settings -Principal $principal -Force -ErrorAction Stop | Out-Null
            $what = @()
            if (-not $principalOk) { $what += 'principal' }
            if (-not $pathOk)      { $what += 'script path' }
            Write-Host ("  {0,-28} fixed ({1})" -f $def.name, ($what -join ' and ')) -ForegroundColor Green
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
# 0. Administrator, and the RIGHT administrator
# --------------------------------------------------------------------------- #
# Setup needs elevation for three separate things, and every one of them fails
# quietly without it: S4U task registration, the hosts file entry, and the
# permissions applied to the folder holding the private keys. Asking once, here,
# beats three different failures spread across ten minutes of prompts.
#
# WHICH account elevates matters as much as whether one does. Secrets are
# encrypted by Export-Clixml, which is DPAPI scoped to the USER. Normal UAC
# elevation keeps the same identity and is fine. Elevating by typing a DIFFERENT
# administrator's credentials does not: secrets.xml would be re-encrypted as
# that account, the tasks registered for that account, and the console run as
# the original one could no longer decrypt anything it had saved.
#
# So there are two checks below, and they cover different ways in: -ExpectedOwner
# catches a relaunch that came back as somebody else, and Get-SecretStore catches
# a window that was already elevated as somebody else before setup ever ran.

$whoAmI = [Security.Principal.WindowsIdentity]::GetCurrent().Name

# Deliberately NOT gated on "is this user in the Administrators group", which
# cannot be answered from the token that asks. Measured on a machine where the
# signed-in account IS a local administrator: net localgroup lists it, and
# WindowsIdentity.Groups does not contain S-1-5-32-544 at all - a filtered token
# drops the SID rather than carrying it as deny-only. Gating on that check
# refused setup to precisely the people meant to run it.
#
# So the relaunch is offered to anyone, and the identity question is answered
# AFTER elevation, where it is a fact rather than an inference: the elevated
# instance is told which account asked, and compares.
if (-not (Test-Elevated)) {
    Write-Host "  Setup needs to run as administrator." -ForegroundColor Yellow
    Write-Host "  Windows will ask you to approve it." -ForegroundColor DarkGray
    Write-Host ""
    $goUp = Read-Host "  Relaunch elevated now? (Y/N)"
    if ($goUp -match '^[Yy]') {
        try {
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass',
                '-File', ('"{0}"' -f $PSCommandPath),
                '-ExpectedOwner', ('"{0}"' -f $whoAmI)) -ErrorAction Stop
            exit 0
        }
        catch {
            Write-Host ""
            Write-Host "  Elevation was declined or cancelled. Nothing has been changed." -ForegroundColor Yellow
        }
    }
    Write-Host ""
    Write-Host "  Right-click 'First Time Setup.bat' and choose Run as administrator." -ForegroundColor DarkGray
    Write-Host "  Elevate as the account that will own this install - approving with a" -ForegroundColor DarkGray
    Write-Host "  different administrator's credentials makes that account the owner instead." -ForegroundColor DarkGray
    Write-Host ""
    exit 1
}

# The relaunch above says who asked. If UAC was satisfied with somebody else's
# credentials, this is where that shows up - before anything has been written.
if ($ExpectedOwner -and $ExpectedOwner -ne $whoAmI) {
    Write-Host "  Elevation changed which account is running setup." -ForegroundColor Red
    Write-Host ""
    Write-Host ("    setup was started by : {0}" -f $ExpectedOwner) -ForegroundColor Gray
    Write-Host ("    but is now running as: {0}" -f $whoAmI)        -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Carrying on would make $whoAmI the owner of this install: the tasks would" -ForegroundColor DarkGray
    Write-Host "  be registered for that account and the DNS credentials encrypted for it, so" -ForegroundColor DarkGray
    Write-Host "  nothing would work when you signed back in as $ExpectedOwner." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Sign in as an administrator account and run setup from there." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

# Already elevated, but possibly as somebody else - "Run as administrator" on a
# machine where your daily account is not one lands here with a different
# identity entirely.
#
# Asked by DECRYPTING rather than by inspecting the file's owner. Ownership is a
# poor proxy: a file created by an administrator is often owned by
# BUILTIN\Administrators, which says nothing about which user's DPAPI key
# encrypted the contents. Get-SecretStore answers the question that actually
# matters, because it is the same call everything else makes.
try { [void](Get-SecretStore) }
catch {
    Write-Host "  This install already belongs to a different account." -ForegroundColor Red
    Write-Host ""
    Write-Host ("    setup is running as : {0}" -f $whoAmI) -ForegroundColor Gray
    Write-Host ("    secrets.xml says    : {0}" -f (($_.Exception.Message -split "`n")[0].Trim())) -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Carrying on would register the scheduled tasks for $whoAmI and encrypt" -ForegroundColor DarkGray
    Write-Host "  anything saved from here for $whoAmI, while the existing credentials" -ForegroundColor DarkGray
    Write-Host "  stayed unreadable - so renewal would keep failing with nothing obviously" -ForegroundColor DarkGray
    Write-Host "  wrong on the page." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Sign in as the account that owns this install and run setup there." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

Write-Host "  Running as $whoAmI (administrator)." -ForegroundColor DarkGray
Write-Host ""

# --------------------------------------------------------------------------- #
# 0a. Is another copy of Cert Camel already running this machine?
# --------------------------------------------------------------------------- #
# The task names are fixed, so there is one "Cert Camel Renew" on a machine no
# matter how many copies of the folder exist. Setting up a second copy does not
# add a second set - it repoints the existing ones at the new folder, and the
# first copy carries on looking perfectly healthy while nothing it owns ever
# runs again. Nothing on either page says so.
#
# Asked before anything is written, and answerable: a task records the absolute
# path of the script it runs.

$foreign = @(Get-ForeignCamelTasks)
if ($foreign.Count) {
    $folders = @($foreign | ForEach-Object { $_.folder } | Where-Object { $_ } | Sort-Object -Unique)

    Write-Host "  Another copy of Cert Camel is already set up on this machine." -ForegroundColor Yellow
    Write-Host ""
    foreach ($f in $foreign) {
        Write-Host ("    {0,-28} runs from {1}" -f $f.name, $f.path) -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "  Those task names are fixed, so continuing here does not add a second set" -ForegroundColor DarkGray
    Write-Host "  - it points the existing ones at this folder. The other copy would keep" -ForegroundColor DarkGray
    Write-Host "  looking healthy on its own page while nothing it owns ever ran again," -ForegroundColor DarkGray
    Write-Host "  including renewal." -ForegroundColor DarkGray
    Write-Host ""

    if ($folders.Count -eq 1 -and (Test-Path -LiteralPath $folders[0])) {
        Write-Host "  If that folder is the one you actually use, stop and run setup there" -ForegroundColor Yellow
        Write-Host "  instead:" -ForegroundColor Yellow
        Write-Host ("    {0}" -f $folders[0]) -ForegroundColor White
    }
    else {
        # A path that no longer exists is the other common shape of this: the
        # folder was moved or renamed, and the tasks are pointing at nothing.
        # Taking them over is then exactly the right thing to do.
        Write-Host "  That folder no longer exists, so those tasks currently run nothing." -ForegroundColor DarkGray
        Write-Host "  Taking them over here is the repair." -ForegroundColor DarkGray
    }
    Write-Host ""

    $takeOver = Read-Host "  Take the tasks over for this folder? (y/N)"
    if ($takeOver -notmatch '^[Yy]') {
        Write-Host ""
        Write-Host "  Stopped. Nothing was changed." -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
    Write-Host ""
}

# --------------------------------------------------------------------------- #
# 0b. Lock the folder down before anything sensitive goes into it
# --------------------------------------------------------------------------- #
# Deliberately here, ahead of every other step: this is the run that creates
# secrets.xml and the first certificate, and permissions applied afterwards
# would leave a window where both sat under whatever the parent folder happened
# to allow. The directories are created first for the same reason - an
# unprotected folder that appears later inherits from a root that is already
# correct.
#
# Not a prompt. There is no sensible answer other than yes, and the one thing
# the security review was most right about was that this had been left manual.

New-TrackerDirectories

# Asked BEFORE the permissions are applied, because if this folder is being
# copied somewhere else then the permissions below are theatre: the ACLs do not
# travel with the copy, and the destination is somebody else's infrastructure.
$synced = Test-SyncedLocation -Path $root
if ($synced) {
    Write-Host "  This folder is inside $($synced.provider)." -ForegroundColor Red
    Write-Host ""
    Write-Host ("    detected from : {0}" -f $synced.evidence) -ForegroundColor Gray
    if (-not $synced.certain) {
        Write-Host "    matched on the folder name, so this may be a false alarm" -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "  Cert Camel keeps unencrypted private keys here. That is normal for an" -ForegroundColor DarkGray
    Write-Host "  ACME client and safe while they stay on one machine behind one account." -ForegroundColor DarkGray
    Write-Host "  A sync client removes both of those at once: the permissions applied" -ForegroundColor DarkGray
    Write-Host "  below are not copied, and the keys land somewhere you do not control." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Move this folder somewhere local - C:\CertCamel is fine - and run setup" -ForegroundColor Yellow
    Write-Host "  again. Nothing has been written yet." -ForegroundColor Yellow
    Write-Host ""

    $anyway = Read-Host "  Continue here anyway? (y/N)"
    if ($anyway -notmatch '^[Yy]') { Write-Host ""; exit 1 }
    Write-Host ""
    Write-Host "  Continuing. Exclude this folder from $($synced.provider) if you can." -ForegroundColor Yellow
    Write-Host ""
}

Write-Host "  Permissions" -ForegroundColor Cyan
$aclResults = Protect-CamelInstall
foreach ($r in $aclResults) {
    if ($r.skipped)  { Write-Host ("        {0,-16} not created yet - will inherit" -f $r.label) -ForegroundColor DarkGray }
    elseif ($r.ok)   { Write-Host ("        {0,-16} restricted to you, SYSTEM and Administrators" -f $r.label) -ForegroundColor Green }
    else             { Write-Host ("        {0,-16} FAILED: {1}" -f $r.label, $r.error) -ForegroundColor Red }
}

if (@($aclResults | Where-Object { -not $_.ok }).Count) {
    Write-Host ""
    Write-Host "  Some permissions could not be applied. Private keys written here would be" -ForegroundColor Yellow
    Write-Host "  readable by anyone who can read the folder, so this is worth fixing before" -ForegroundColor Yellow
    Write-Host "  going further rather than after." -ForegroundColor Yellow
    Write-Host ""
    $carryOn = Read-Host "  Continue anyway? (Y/N)"
    if ($carryOn -notmatch '^[Yy]') { Write-Host ""; exit 1 }
}
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
    Write-Host "  [1/6] domains.txt already exists - leaving it alone." -ForegroundColor Green
} else {
    # Created with its explanation and NO hostnames.
    #
    # This used to be a copy of domains.example.txt, which carries example.com
    # and www.example.com. The first check three steps later then went out and
    # measured somebody else's domain, and the page opened showing two
    # certificates that had nothing to do with this install. Worse, the setup
    # checklist on Home reads "watch some certificates" as DONE the moment any
    # result exists - so a brand new install reported that step finished on the
    # strength of placeholder data.
    #
    # Deriving names from the zones step 3 discovers was considered and
    # rejected: a zone is not a hostname. Guessing www.<zone> produces a name
    # that may not exist, which is then checked, fails, and greets somebody with
    # a red row on a console they have just installed.
    #
    # domains.example.txt stays exactly where it is as the worked example. It
    # simply stops being copied over a fresh install as though it were yours.
    $seedText =
        "# One hostname per line. Add the names you want watched." + "`r`n" +
        "#" + "`r`n" +
        "# Group them with [Category] headings, give a non-standard port as" + "`r`n" +
        "# name:port, and see domains.example.txt beside this file for a worked" + "`r`n" +
        "# example of both." + "`r`n" +
        "#" + "`r`n" +
        "# The Certificates page edits this file, so there is no need to come" + "`r`n" +
        "# back here by hand." + "`r`n"

    [IO.File]::WriteAllText($domainList, $seedText, (New-Object Text.UTF8Encoding $false))
    Write-Host "  [1/6] Created domains.txt, with nothing in it yet." -ForegroundColor Green
    Write-Host "        Names get added on the Certificates page once this finishes." -ForegroundColor DarkGray
}

# --------------------------------------------------------------------------- #
# 3. Renewal support (required)
# --------------------------------------------------------------------------- #
# Posh-ACME is fetched into lib\ inside this folder rather than installed
# system-wide, so the bundle stays self-contained.
#
# This used to be optional, on the basis that watching certificates without
# renewing them was a supported way to run Cert Camel. It is not any more:
# watching-without-renewing becomes its own tool rather than a branch inside
# this one, and every install here issues and renews.
#
# That removal is what makes the rest of setup straightforward. While the mode
# existed, the DNS credential had to stay optional too - which is why setup
# never asked for one, which is why the HTTPS step's very first check could
# never pass on a first run.

Write-Host "  [2/6] Renewal support" -ForegroundColor Cyan

if (Get-VendoredPoshAcme) {
    Write-Host "        Posh-ACME is already in this folder." -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "        Cert Camel renews certificates through Posh-ACME (an ACME client)."
    Write-Host "        It is downloaded into the 'lib' folder here - nothing is installed"
    Write-Host "        system-wide."
    Write-Host ""
    Write-Host "        Downloading..." -ForegroundColor DarkGray

    try {
        $manifest = Install-PoshAcmeLocal
        Write-Host "        Installed: $manifest" -ForegroundColor Green
    }
    catch {
        # A stop, not a warning. Everything after this point - the DNS
        # credential, the console's own certificate, renewal itself - needs an
        # ACME client, so carrying on would produce an install that looks set up
        # and cannot issue anything.
        Write-Host ""
        Write-Host "        Could not download it: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "        Setup cannot continue without it. Nothing else here works" -ForegroundColor Yellow
        Write-Host "        without an ACME client, so stopping now is better than leaving" -ForegroundColor Yellow
        Write-Host "        an install that looks finished and cannot issue a certificate." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "        If this machine has no route to the PowerShell Gallery, copy a" -ForegroundColor DarkGray
        Write-Host "        Posh-ACME module folder into $($script:LibDir) by hand and run" -ForegroundColor DarkGray
        Write-Host "        setup again - it is picked up as-is." -ForegroundColor DarkGray
        Write-Host ""
        exit 1
    }
}

# --------------------------------------------------------------------------- #
# 3b. Contact address and DNS automation
# --------------------------------------------------------------------------- #
# Collected HERE, at a console prompt, and this is the step whose absence broke
# the whole HTTPS path.
#
# Both of these used to be entered in the browser, which meant the first run had
# neither. The HTTPS step further down opens by asking Get-TrackerAddressStatus
# whether any configured DNS credential covers the console's name - and zones
# are discovered by ASKING a provider. With no provider, that check cannot pass,
# so every first-time user was routed into the manual-DNS-record branch
# immediately after a screen promising the certificate would be issued and
# renewed automatically.
#
# The order is the fix. Secrecy is a side benefit and a small one: the browser
# was only ever reachable on loopback, and anything able to read that traffic
# can read secrets.xml directly.

Write-Host ""
Write-Host "  [3/6] Certificate authority and DNS automation" -ForegroundColor Cyan

$trackerSettings = Get-TrackerSettings

# --- contact address ------------------------------------------------------- #
# The CA requires one, and it is where expiry warnings from the CA itself go.
if ($trackerSettings.contact) {
    Write-Host "        Contact address: $($trackerSettings.contact)" -ForegroundColor Green
}
else {
    Write-Host ""
    Write-Host "        The certificate authority requires an email address. It is used for"
    Write-Host "        their own expiry warnings and account recovery, and it is sent to"
    Write-Host "        them - not stored only here."
    Write-Host ""
    # Every required prompt in this step takes 'q' as a way out. Setup is one of
    # the few places somebody has to go and fetch something mid-task - open the
    # Cloudflare dashboard, mint a token - and a required field with no escape
    # leaves Ctrl+C as the only exit, halfway through a run that has already
    # written settings and permissions.
    Write-Host "        Enter q to stop setup here and come back to it." -ForegroundColor DarkGray
    Write-Host ""
    do {
        $contact = (Read-Host "        Contact email").Trim()
        if ($contact -eq 'q') { Write-Host ""; Write-Host "  Stopped. Run setup again when you are ready." -ForegroundColor Yellow; Write-Host ""; exit 1 }
        if ($contact -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
            Write-Host "        That does not look like an email address." -ForegroundColor Yellow
            $contact = ''
        }
    } while (-not $contact)

    $trackerSettings.contact = $contact
    Save-TrackerSettings -Settings $trackerSettings
    Write-Host "        Saved." -ForegroundColor Green
}

# --- DNS provider ---------------------------------------------------------- #
$haveProvider = @($trackerSettings.providers).Count -gt 0

if ($haveProvider) {
    # The inner parentheses are load-bearing: -f binds tighter than -join, so
    # without them the format string consumes the array and prints only the
    # first label, with the -join applied to the finished string.
    $names = ((@($trackerSettings.providers) | ForEach-Object { $_.label }) -join ', ')
    Write-Host ("        DNS profile: {0}" -f $names) -ForegroundColor Green
}
else {
    Write-Host ""
    Write-Host "        Cert Camel proves it controls a domain by writing a DNS TXT record,"
    Write-Host "        so it needs an API credential for whoever hosts your DNS. This is"
    Write-Host "        also what lets it renew the console's own certificate."
    Write-Host ""

    # Driven off the shared catalog rather than a list written out here. The
    # catalog already carries the label, the per-field hint and which fields are
    # secret, and duplicating any of that would let the two drift - the console
    # asking for a field the settings page does not save, or vice versa.
    $plugins = @($script:PluginCatalog.Keys | Sort-Object)
    for ($i = 0; $i -lt $plugins.Count; $i++) {
        Write-Host ("          {0}) {1}" -f ($i + 1), $script:PluginCatalog[$plugins[$i]].Label)
    }
    Write-Host ""

    $choice = 0
    do {
        $pick = (Read-Host ("        Which one? (1-{0}, or q to stop)" -f $plugins.Count)).Trim()
        if ($pick -eq 'q') { Write-Host ""; Write-Host "  Stopped. Run setup again when you have the credential." -ForegroundColor Yellow; Write-Host ""; exit 1 }
        if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $plugins.Count) {
            $choice = [int]$pick
        }
        else { Write-Host "        Pick a number from the list." -ForegroundColor Yellow }
    } while (-not $choice)

    $pluginName = $plugins[$choice - 1]
    $catalog    = $script:PluginCatalog[$pluginName]

    # Same shape the settings page produces, so a profile created here is
    # indistinguishable from one created in the browser - including the id
    # pattern the save path validates against.
    $providerId = 'p' + [Convert]::ToString([DateTimeOffset]::UtcNow.ToUnixTimeSeconds(), 16) +
                  (Get-Random -Minimum 100 -Maximum 999)

    Write-Host ""
    Write-Host ("        {0}" -f $catalog.Label) -ForegroundColor Cyan

    $plainArgs = @{}
    foreach ($a in $catalog.Args) {
        $label = $(if ($a.Label) { $a.Label } else { $a.Name })

        if ($a.Hint) {
            Write-Host ""
            # Wrapped rather than printed as one long line: some of these hints
            # are a paragraph, and a paragraph that runs off the right edge of a
            # console window is a paragraph nobody reads.
            $words = @($a.Hint -split '\s+')
            $line  = ''
            foreach ($w in $words) {
                if (($line + ' ' + $w).Trim().Length -gt 68) {
                    Write-Host ("          {0}" -f $line.Trim()) -ForegroundColor DarkGray
                    $line = $w
                }
                else { $line = ($line + ' ' + $w).Trim() }
            }
            if ($line) { Write-Host ("          {0}" -f $line) -ForegroundColor DarkGray }
        }

        if ($a.Type -eq 'bool') {
            $yn = Read-Host ("        {0}? (Y/N)" -f $label)
            if ($yn -match '^[Yy]') { $plainArgs[$a.Name] = $true }
            else { $plainArgs[$a.Name] = $false }
            continue
        }

        if ($a.Secret) {
            # Read as a SecureString so the token is not echoed. It is converted
            # straight back for Set-TrackerSecret, which re-encrypts it under
            # DPAPI - so this is about what appears on screen, not about what
            # reaches disk. That matters more than it sounds: this console gets
            # demonstrated, and screen-shared.
            do {
                $secure = Read-Host ("        {0} (or q to stop)" -f $label) -AsSecureString
                $plain  = ConvertFrom-SecureStringPlain $secure
                if ($plain -eq 'q') {
                    Write-Host ""
                    Write-Host "  Stopped before the credential was saved. Nothing was written for" -ForegroundColor Yellow
                    Write-Host "  this DNS profile - run setup again when you have it." -ForegroundColor Yellow
                    Write-Host ""
                    exit 1
                }
                if (-not $plain) { Write-Host "        Required." -ForegroundColor Yellow }
            } while (-not $plain)

            Set-TrackerSecret -Key ("{0}:{1}" -f $providerId, $a.Name) -Value $plain
            $plain = $null
            continue
        }

        do {
            $val = (Read-Host ("        {0} (or q to stop)" -f $label)).Trim()
            if ($val -eq 'q') { Write-Host ""; Write-Host "  Stopped. Run setup again when you have it." -ForegroundColor Yellow; Write-Host ""; exit 1 }
            if (-not $val) { Write-Host "        Required." -ForegroundColor Yellow }
        } while (-not $val)
        $plainArgs[$a.Name] = $val
    }

    $profileLabel = (Read-Host ("        A name for this profile [{0}]" -f $catalog.Label)).Trim()
    if (-not $profileLabel) { $profileLabel = $catalog.Label }

    $trackerSettings.providers = @(@($trackerSettings.providers) + @(@{
        id     = $providerId
        label  = $profileLabel
        plugin = $pluginName
        args   = $plainArgs
    }))
    Save-TrackerSettings -Settings $trackerSettings
    Write-Host ""
    Write-Host "        Saved." -ForegroundColor Green
}

# --- prove it works, now, rather than three steps later -------------------- #
# The credential is not verified by being typed. A token scoped to one zone, or
# missing Zone:Read, fails in exactly the same way as a correct one until
# something asks it a question - and the next thing to ask is the HTTPS step,
# by which point the reason is several screens back.
Write-Host ""
Write-Host "        Checking the credential..." -ForegroundColor DarkGray

$zoneCache = $null
try { $zoneCache = Update-ZoneCache -Settings (Get-TrackerSettings) }
catch {
    Write-Host ("        Could not reach the DNS provider: {0}" -f (($_.Exception.Message -split "`n")[0].Trim())) -ForegroundColor Red
}

if ($zoneCache) {
    foreach ($e in @($zoneCache.errors)) {
        Write-Host ("        {0}: {1}" -f $e.providerLabel, $e.error) -ForegroundColor Red
    }

    $zoneNames = @(@($zoneCache.zones) | ForEach-Object { $_.zone } | Sort-Object -Unique)
    if ($zoneNames.Count) {
        Write-Host ("        {0} zone(s) visible:" -f $zoneNames.Count) -ForegroundColor Green
        foreach ($z in ($zoneNames | Select-Object -First 12)) { Write-Host "          $z" -ForegroundColor Gray }
        if ($zoneNames.Count -gt 12) { Write-Host ("          ...and {0} more" -f ($zoneNames.Count - 12)) -ForegroundColor DarkGray }
    }
    elseif (-not @($zoneCache.errors).Count) {
        # Credential accepted, nothing behind it. Almost always a token scoped
        # to a single zone, which is the one failure that looks like success.
        Write-Host "        The credential was accepted but no zones came back." -ForegroundColor Yellow
        Write-Host "        That usually means the token is scoped to zones it cannot list." -ForegroundColor DarkGray
        Write-Host "        Widen it and run setup again, or fix it later under Settings." -ForegroundColor DarkGray
    }

    # --- prove it can WRITE, not just read ---------------------------------- #
    # Listing zones proves read access and nothing else. A token with Zone:Read
    # but not DNS:Edit lists everything perfectly and then dies partway through
    # an order, after an account has been registered and a certificate ordered -
    # which is the `403 Forbidden right after "Adding _acme-challenge..."` case
    # in the troubleshooting table.
    #
    # This is also what makes it safe to issue from production rather than
    # staging. Staging used to be the guard against spending rate limit on an
    # unproven configuration; proving the configuration directly is a better
    # guard, and it does not leave somebody with a certificate no browser
    # trusts.
    #
    # Test-ProviderWriteAccess writes a real challenge record through the
    # plugin's own Add-DnsTxt and removes it again, so it exercises the exact
    # code path a renewal takes.
    if ($zoneNames.Count) {
        Write-Host ""
        Write-Host "        Checking it can write records too..." -ForegroundColor DarkGray

        $writeProv = @(@(Get-TrackerSettings).providers)[0]
        $writeZone = @(@($zoneCache.zones) |
                       Where-Object { $_.providerId -eq $writeProv.id } |
                       ForEach-Object { $_.zone })[0]
        if (-not $writeZone) { $writeZone = $zoneNames[0] }

        $wr = $null
        try { $wr = Test-ProviderWriteAccess -Provider $writeProv -Zone $writeZone }
        catch { $wr = @{ wrote = $false; cleaned = $false; error = ($_.Exception.Message -split "`n")[0].Trim() } }

        if ($wr.wrote) {
            Write-Host ("        Wrote and removed a test record in {0}." -f $writeZone) -ForegroundColor Green
            if (-not $wr.cleaned) {
                # Harmless - a CA looks for a matching value among the TXT
                # records, so a spare one is ignored - but never left unsaid.
                Write-Host ("        Could not remove it again. A stray _acme-challenge.{0} TXT" -f $writeZone) -ForegroundColor Yellow
                Write-Host "        record is harmless, but worth deleting when convenient." -ForegroundColor DarkGray
            }
        }
        else {
            Write-Host "        The token can list zones but NOT write records." -ForegroundColor Red
            if ($wr.error) { Write-Host ("        {0}" -f $wr.error) -ForegroundColor DarkGray }
            Write-Host ""
            Write-Host "        Renewal writes a _acme-challenge TXT record to prove you control" -ForegroundColor DarkGray
            Write-Host "        the domain, so nothing can be issued until this works. On" -ForegroundColor DarkGray
            Write-Host "        Cloudflare it means the DNS permission is set to Read rather than" -ForegroundColor DarkGray
            Write-Host "        Edit." -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "        Fix the token and run setup again. Continuing now would order a" -ForegroundColor Yellow
            Write-Host "        certificate that cannot complete." -ForegroundColor Yellow
            Write-Host ""

            $carryOn = Read-Host "        Continue anyway? (y/N)"
            if ($carryOn -notmatch '^[Yy]') { Write-Host ""; exit 1 }
        }
    }
}

# --------------------------------------------------------------------------- #
# 4. First check, so the page has something to show immediately
# --------------------------------------------------------------------------- #

Write-Host ""

# Nothing to check is not the same as a check that found nothing.
#
# domains.txt starts empty now, so on a first run there is genuinely nothing to
# measure - and running the checker anyway produces an empty ssl-data.js, prints
# a summary of zero hosts, and reads as though something failed.
#
# The same line rules the checker itself uses: blanks and # comments skipped,
# [Category] headers skipped. A file of nothing but the explanatory header
# counts as empty, which is exactly what step 1 just wrote.
$hasNames = $false
if (Test-Path $domainList) {
    foreach ($line in (Get-Content $domainList -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        $entry = $line.Trim()
        if (-not $entry -or $entry.StartsWith('#')) { continue }
        if ($entry -match '^\[(.+)\]$')            { continue }
        $hasNames = $true
        break
    }
}

if ($hasNames) {
    Write-Host "  [4/6] Running the first check..." -ForegroundColor Cyan
    & $checker
}
else {
    Write-Host "  [4/6] Nothing to check yet" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "        domains.txt has no hostnames in it, so there is nothing to measure." -ForegroundColor DarkGray
    Write-Host "        Add the names you want watched on the Certificates page once this" -ForegroundColor DarkGray
    Write-Host "        finishes - the Home page lists it as the first thing to do." -ForegroundColor DarkGray
}

# --------------------------------------------------------------------------- #
# 5. Daily scheduled task (optional)
# --------------------------------------------------------------------------- #

Write-Host "  [5/6] Daily automatic check" -ForegroundColor Cyan
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
# 5b. Serve this page over HTTPS
# --------------------------------------------------------------------------- #
# Walked through here rather than left to Settings because the four
# preconditions fail in four different places, and someone meeting the tool for
# the first time has no way to know which one bit them. Every check reuses
# Get-TrackerAddressStatus, so this says exactly what the Settings page says.
#
# This step used to be a dead end on a first run. Its opening question is
# whether a configured DNS credential covers the name, and until step 3 existed
# there was never one, so the answer was always no and the manual-DNS-record
# branch was the only path anyone reached. That branch is still here, and it is
# still legitimate, but it is now the exception it was always written to be.
#
# The manual branch matters for one case: a name whose zone the collected
# credential cannot see. Issuing by hand works and Cert Camel takes over at
# renewal - renew-due.ps1 has an explicit "never issued here" branch - but only
# once some provider covers the zone, because renewal validates through the DNS
# API. Until then Get-CertificateGroups files the name under `unmapped` and
# renew.ps1 throws "The DNS profile for this zone is no longer configured".

Write-Host ""
Write-Host "  [6/6] Serve this page over HTTPS" -ForegroundColor Cyan
Write-Host ""
Write-Host "        Give this page a name and it gets a real certificate, issued and"
Write-Host "        renewed like every other one Cert Camel manages. 127.0.0.1 keeps"
Write-Host "        working either way, which is the way back in if the name ever stops"
Write-Host "        resolving or the certificate lapses."
Write-Host ""
Write-Host "        Skipping leaves the console on plain HTTP on this machine only." -ForegroundColor DarkGray
Write-Host ""

$wantHttps = Read-Host "        Set this up now? (Y/n)"

# Empty means yes. This is the expected outcome of a setup run, not a side
# feature, and the person who genuinely wants to defer can still type n.
if ($wantHttps -notmatch '^[Nn]') {
    . (Join-Path $appDir 'acme-lib.ps1')

    # Offer a name built from a zone the credential can actually see. Asking
    # cold invites a name in a zone this install cannot issue for, which fails
    # four checks later with a message about DNS credentials that reads as a
    # credential problem rather than a typo.
    $suggested = ''
    $knownZones = @(@((Get-ZoneCache).zones) | ForEach-Object { $_.zone } | Sort-Object -Unique)
    if ($knownZones.Count) {
        $suggested = "tracker.$($knownZones[0])"
        Write-Host ""
        if ($knownZones.Count -gt 1) {
            Write-Host ("        Zones this install can issue for: {0}" -f ($knownZones -join ', ')) -ForegroundColor DarkGray
        }
    }

    $prompt = $(if ($suggested) { "        Hostname for this page [$suggested]" }
                else            { "        Hostname for this page (e.g. tracker.example.com)" })
    $webName = (Read-Host $prompt).Trim()
    if (-not $webName -and $suggested) { $webName = $suggested }

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
            # The credential collected in step 3 exists but cannot see this
            # zone. Said that way round on purpose: "no DNS credential covers
            # that name" reads as "you never gave me one", which was true before
            # step 3 existed and is now misleading - it sends somebody off to
            # re-enter a credential that is already correct, when the likely
            # causes are a typo in the name or a token scoped to another zone.
            Write-Host "        The DNS credential you gave does not cover that name, so this" -ForegroundColor Yellow
            Write-Host "        step cannot issue and renew it for you automatically." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "        Usually that means a typo in the hostname, or an API token scoped" -ForegroundColor Gray
            Write-Host "        to zones that do not include this one. Both are worth checking" -ForegroundColor Gray
            Write-Host "        before going further - re-running setup is cheap." -ForegroundColor Gray
            Write-Host ""
            Write-Host "        Otherwise you can get HTTPS working now by creating one DNS record" -ForegroundColor Gray
            Write-Host "        by hand. The certificate is real and lasts about 90 days." -ForegroundColor Gray
            Write-Host ""
            Write-Host "        It will NOT renew itself until some provider covers this zone," -ForegroundColor DarkGray
            Write-Host "        because renewal validates through the API. Widen the token or add" -ForegroundColor DarkGray
            Write-Host "        another profile under Settings > DNS Automation and this" -ForegroundColor DarkGray
            Write-Host "        certificate gets picked up automatically - renewal handles" -ForegroundColor DarkGray
            Write-Host "        certificates it did not issue." -ForegroundColor DarkGray
            Write-Host ""

            $manual = Read-Host "        Issue it now with a manual DNS record? (Y/N)"
            if ($manual -match '^[Yy]') {
                Write-Host ""
                & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                    -File (Join-Path $appDir 'issue-tracker-cert.ps1') -HostName $webName -Port $webPort
                Write-Host ""
                $st = Get-TrackerAddressStatus -HostName $webName -Port $webPort `
                        -Settings (Get-TrackerSettings) -ZoneCache (Get-ZoneCache)

                # No elevation branch: setup refuses to start without it, so the
                # "add this line yourself" fallback that used to live here was
                # unreachable by the time this ran.
                if (-not $st.hosts.ok) {
                    $addHost2 = Read-Host "        Add $webName to the hosts file? (Y/N)"
                    if ($addHost2 -match '^[Yy]') {
                        try { [void](Add-HostsEntry -HostName $webName); Write-Host "        Added." -ForegroundColor Green }
                        catch { Write-Host "        Could not: $($_.Exception.Message)" -ForegroundColor Yellow }
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
                        -File (Join-Path $appDir 'renew.ps1') -Zone $zoneForCert -Source 'cli'
                    Write-Host ""
                    $st = Get-TrackerAddressStatus -HostName $webName -Port $webPort `
                            -Settings (Get-TrackerSettings) -ZoneCache (Get-ZoneCache)
                }
            }

            if (-not $st.hosts.ok) {
                $addHost = Read-Host "        Add $webName to the hosts file? (Y/N)"
                if ($addHost -match '^[Yy]') {
                    try { [void](Add-HostsEntry -HostName $webName); Write-Host "        Added." -ForegroundColor Green }
                    catch { Write-Host "        Could not: $($_.Exception.Message)" -ForegroundColor Yellow }
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
$renewScript = Join-Path $appDir 'renew-due.ps1'

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

$wantRenew = Read-Host "      Register unattended renewal, every six hours? (Y/N)"

if ($wantRenew -match '^[Yy]') {
    try {
        $rAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$renewScript`""

        # 03:20 rather than on the hour: ACME rate limits are per-CA and shared
        # by everyone, and the top of the hour is where every naive scheduler
        # piles up. The repeats inherit those twenty past.
        #
        # Every six hours rather than once a day, for one reason above the
        # others: a run that fails has to be able to try again. A DNS provider
        # blip or an unreachable load balancer at 03:20 used to mean the next
        # attempt was twenty-four hours later; now it is six, and a certificate
        # gets four chances a day instead of one.
        #
        # It also renews closer to the moment the authority's window opens.
        # Renewal is refused before that moment, so a daily sweep waits an
        # average of twelve hours after the window opens for no reason - and
        # certificate lifetimes are getting shorter, which makes that lag
        # matter more, not less. Nothing here polls the CA harder: the renewal
        # check is an unauthenticated ARI request, which is not rate limited,
        # and no order is placed until a certificate is genuinely due.
        #
        # PowerShell 5.1's New-ScheduledTaskTrigger has no -RepetitionInterval
        # on a -Daily trigger, so the repetition is lifted off a throwaway
        # -Once trigger. This is the documented way to do it, not a trick.
        $rTrigger = New-ScheduledTaskTrigger -Daily -At 3:20am
        $rTrigger.Repetition = (New-ScheduledTaskTrigger -Once -At 3:20am `
            -RepetitionInterval (New-TimeSpan -Hours 6) `
            -RepetitionDuration (New-TimeSpan -Hours 24)).Repetition

        $rSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
            -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries `
            -ExecutionTimeLimit (New-TimeSpan -Hours 2)

        [void](Register-CamelTask -Name $renewTask -Action $rAction -Trigger $rTrigger `
            -Settings $rSettings -Description 'Renews certificates the CA reports as due, deploys them, and verifies each load balancer is serving them.')

        Write-Host ""
        Write-Host "      Registered. Runs every 6 hours, from 3:20 AM." -ForegroundColor Green
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
$reportScript = Join-Path $appDir 'monthly-report.ps1'

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
        try { $isServer = ([int](Get-CimInstance Win32_OperatingSystem).ProductType -ne 1) } catch { $null = $_ }   # cannot tell: treated as a workstation

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
    Write-Host "  Run serve.ps1 directly instead: powershell -ExecutionPolicy Bypass -File `"$(Join-Path $appDir 'serve.ps1')`"" -ForegroundColor DarkGray
}
