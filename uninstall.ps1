<#
  uninstall.ps1 - undo the changes Cert Camel made outside its own folder.

      powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -DryRun
      powershell -ExecutionPolicy Bypass -File .\uninstall.ps1

  RUN THIS BEFORE DELETING THE FOLDER, not after. Everything it needs to know -
  which tasks are this install's, which hostname is in the hosts file, which
  certificates it issued - is read from the folder. Once the folder is gone
  those answers are gone with it, and what is left behind stays behind:

    four scheduled tasks, still registered, now pointing at nothing
    a hosts file entry for a name that no longer resolves to anything
    a private certificate authority still TRUSTED by your Windows account
    a desktop shortcut to a folder that is not there

  WHAT IT DOES NOT DO

  It does not delete the install folder. That folder holds unencrypted private
  keys, and a script that erases key material as a side effect of tidying up is
  a script that will one day erase the wrong folder. It tells you the path and
  leaves the decision, and the certificates in it are the ones your load
  balancers may still be serving.

  It also cannot reach into your browser. If HSTS was ever enabled, the browser
  still refuses plain HTTP for that name until the policy expires - up to a
  year. sos-plain-http.ps1 explains how to clear it; the note at the end repeats
  the short version.

  SAFETY

  Only things this tool created are touched, and each is identified rather than
  guessed: a scheduled task must run a script inside THIS folder, a hosts line
  must carry the comment Cert Camel wrote above it, and a certificate must be
  the private CA this tool generates or something that CA signed. Anything else
  sharing a name is left exactly where it is.
#>

[CmdletBinding()]
param(
    # Report what would be removed and change nothing. Worth running first.
    [switch]$DryRun,

    # Skip the confirmation prompt. For an unattended teardown.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'resources\acme-lib.ps1')

function Say { param([string]$T, [string]$C = 'Gray') Write-Host $T -ForegroundColor $C }

$root = $PSScriptRoot
$app  = Join-Path $root 'resources'

Say ""
Say "  Cert Camel - uninstall" -ForegroundColor Cyan
Say "  $root" 'DarkGray'
Say ""

# --------------------------------------------------------------------------- #
# Work out what belongs to this install
# --------------------------------------------------------------------------- #
$plan = [ordered]@{ tasks = @(); hosts = @(); hostsMaybe = @(); certs = @(); shortcuts = @(); processes = @() }

# --- scheduled tasks ------------------------------------------------------- #
# Matched by the path they run, not by name. The names are fixed, so a task of
# the same name could belong to a DIFFERENT copy of Cert Camel on this machine -
# and unregistering that one would break an install this script was never
# pointed at.
foreach ($def in @($script:ScheduledTaskNames)) {
    $t = Get-ScheduledTask -TaskName $def.name -ErrorAction SilentlyContinue
    if (-not $t) { continue }

    $runs = $null
    foreach ($a in @($t.Actions)) {
        $p = Get-TaskScriptPath -Arguments ([string]$a.Arguments)
        if ($p) { $runs = $p; break }
    }

    $mine = $false
    if ($runs) {
        try {
            $full = [IO.Path]::GetFullPath($runs)
            $mine = $full.StartsWith(([IO.Path]::GetFullPath($app).TrimEnd('\') + '\'),
                                     [StringComparison]::OrdinalIgnoreCase)
        }
        catch { $mine = $false }   # unparseable path: not provably ours, so left alone
    }

    if ($mine) { $plan.tasks += @{ name = $def.name; state = [string]$t.State; path = $runs } }
    else       { Say ("  leaving '{0}' alone - it runs {1}" -f $def.name, $(if ($runs) { $runs } else { 'something unreadable' })) 'DarkGray' }
}

# --- running server -------------------------------------------------------- #
foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue)) {
    if ($p.CommandLine -and $p.CommandLine -match 'serve\.ps1' -and $p.ProcessId -ne $PID) {
        # Same rule as the tasks: only a server running THIS folder's script.
        if ($p.CommandLine -match [regex]::Escape($app)) {
            $plan.processes += @{ pid = $p.ProcessId }
        }
    }
}

# --- hosts file ------------------------------------------------------------ #
# Only lines Cert Camel wrote, which it marks with a comment directly above.
# Everything else in that file belongs to the machine and may matter to things
# far outside this tool.
$hostsPath  = Get-HostsFilePath
$hostsLines = @()
if (Test-Path $hostsPath) { $hostsLines = @([IO.File]::ReadAllLines($hostsPath)) }
$marker = '# Added by Cert Camel'
$tagged = @{}
for ($i = 0; $i -lt $hostsLines.Count; $i++) {
    if ($hostsLines[$i].TrimStart().StartsWith($marker)) {
        $entry = $(if ($i + 1 -lt $hostsLines.Count) { $hostsLines[$i + 1] } else { '' })
        $plan.hosts += @{ index = $i; comment = $hostsLines[$i]; line = $entry }
        $tagged[$i + 1] = $true
    }
}

# Lines that mention the tracker's name but carry no marker: added by hand, or
# by a version that did not write one. Reported, never removed.
#
# Acting on them would mean matching a hostname inside a file that belongs to
# the machine, and a name can appear in a line that has nothing to do with this
# tool. But saying nothing leaves somebody with a name still resolving to
# loopback after the thing it pointed at is gone, wondering why. So: remove what
# is provably ours, mention what is probably ours.
$plan.hostsMaybe = @()
$trackerName = ''
try { $trackerName = (Get-WebSettings -Settings (Get-TrackerSettings)).hostname } catch { $trackerName = '' }
if ($trackerName) {
    for ($i = 0; $i -lt $hostsLines.Count; $i++) {
        if ($tagged.ContainsKey($i)) { continue }
        $l = $hostsLines[$i]
        if ($l.TrimStart().StartsWith('#')) { continue }
        if ($l -match ('(^|\s)' + [regex]::Escape($trackerName) + '(\s|$)')) {
            $plan.hostsMaybe += @{ index = $i; line = $l }
        }
    }
}

# --- certificates in the Windows store ------------------------------------- #
# The private CA new-lb-api-cert.ps1 generates, and anything it signed. The
# console's own ACME certificate never enters the store - it is loaded straight
# from the .pfx without PersistKeySet - so there is nothing to clean up for it.
$caSubject = 'CN=Cert Camel Load Balancer CA'
foreach ($loc in @('Cert:\CurrentUser\My', 'Cert:\CurrentUser\Root',
                   'Cert:\LocalMachine\My', 'Cert:\LocalMachine\Root')) {
    foreach ($c in @(Get-ChildItem $loc -ErrorAction SilentlyContinue)) {
        if ($c.Subject -eq $caSubject -or $c.Issuer -eq $caSubject) {
            $plan.certs += @{ store = $loc; subject = $c.Subject; thumbprint = $c.Thumbprint
                              trusted = ($loc -like '*\Root') }
        }
    }
}

# --- shortcuts ------------------------------------------------------------- #
foreach ($s in @(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Cert Camel.lnk'),
    (Join-Path $env:USERPROFILE 'Desktop\Cert Camel.lnk'),
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Cert Camel.lnk'))) {
    if (Test-Path -LiteralPath $s) {
        # A shortcut of the same name could point anywhere; only remove one that
        # points into this folder.
        $target = ''
        try { $target = (New-Object -ComObject WScript.Shell).CreateShortcut($s).TargetPath } catch { $target = '' }
        $mine = $target -and ($target -like "$root*")
        if ($mine -and ($plan.shortcuts | Where-Object { $_.path -eq $s }).Count -eq 0) {
            $plan.shortcuts += @{ path = $s; target = $target }
        }
    }
}

# --------------------------------------------------------------------------- #
# Show the plan
# --------------------------------------------------------------------------- #
Say ""
Say "  This will remove:" 'Cyan'
Say ""

$nothing = $true

if ($plan.processes.Count) {
    $nothing = $false
    Say "    Running server" 'White'
    foreach ($p in $plan.processes) { Say ("      pid {0}" -f $p.pid) }
}
if ($plan.tasks.Count) {
    $nothing = $false
    Say "    Scheduled tasks" 'White'
    foreach ($t in $plan.tasks) { Say ("      {0,-28} ({1})" -f $t.name, $t.state) }
}
if ($plan.hosts.Count) {
    $nothing = $false
    Say "    Hosts file entries" 'White'
    foreach ($h in $plan.hosts) { Say ("      {0}" -f $h.line.Trim()) }
}
if ($plan.certs.Count) {
    $nothing = $false
    Say "    Certificates in the Windows store" 'White'
    foreach ($c in $plan.certs) {
        Say ("      {0,-26} {1}{2}" -f $c.store.Replace('Cert:\',''), $c.subject,
             $(if ($c.trusted) { '   <- currently TRUSTED' } else { '' })) `
            $(if ($c.trusted) { 'Yellow' } else { 'Gray' })
    }
}
if ($plan.shortcuts.Count) {
    $nothing = $false
    Say "    Shortcuts" 'White'
    foreach ($s in $plan.shortcuts) { Say ("      {0}" -f $s.path) }
}

if ($nothing -and -not $plan.hostsMaybe.Count) {
    Say "    nothing - this install has made no changes outside its folder." 'Green'
    Say ""
    Say ("  Delete the folder when you are ready: {0}" -f $root) 'DarkGray'
    Say ""
    exit 0
}

if ($nothing) {
    Say "    nothing - every change this install made outside its folder is already gone." 'Green'
}

if ($plan.hostsMaybe.Count) {
    Say ""
    Say "  NOT removed - hosts file lines mentioning that name with no Cert Camel" 'Yellow'
    Say "  marker above them. Added by hand, or by a version that wrote none." 'Yellow'
    foreach ($m in $plan.hostsMaybe) { Say ("      {0}" -f $m.line.Trim()) 'White' }
    Say ("  in {0}" -f $hostsPath) 'DarkGray'
    Say "  Left alone because a hostname can appear in a line that has nothing to" 'DarkGray'
    Say "  do with this tool. Remove them yourself if they were for this." 'DarkGray'
}

Say ""
Say "  It will NOT delete the folder itself. That is where the private keys are," 'DarkGray'
Say "  and the certificates your load balancers may still be serving." 'DarkGray'
Say ""

if ($DryRun) {
    Say "  -DryRun: nothing was changed." 'Yellow'
    Say ""
    exit 0
}

# Checked here rather than at the top, so -DryRun works without it. Looking at
# what would be removed changes nothing, and requiring administrator to look
# means the preview gets skipped rather than read.
if (-not (Test-Elevated)) {
    Say "  Removing any of this needs administrator: the scheduled tasks and the" 'Yellow'
    Say "  hosts file are both writable only by one." 'Yellow'
    Say ""
    Say "  Right-click PowerShell, Run as administrator, then run this again." 'DarkGray'
    Say "  Nothing has been changed." 'DarkGray'
    Say ""
    exit 1
}

if (-not $Force) {
    $go = Read-Host "  Go ahead? (y/N)"
    if ($go -notmatch '^[Yy]') { Say ""; Say "  Stopped. Nothing was changed." 'Yellow'; Say ""; exit 1 }
}

# --------------------------------------------------------------------------- #
# Do it, reporting each step rather than failing the whole run on one
# --------------------------------------------------------------------------- #
Say ""
$failed = 0

foreach ($p in $plan.processes) {
    try { Stop-Process -Id $p.pid -Force -ErrorAction Stop; Say ("  stopped pid {0}" -f $p.pid) 'Green' }
    catch { Say ("  could not stop pid {0}: {1}" -f $p.pid, ($_.Exception.Message -split "`n")[0].Trim()) 'Red'; $failed++ }
}

foreach ($t in $plan.tasks) {
    try {
        # Stopped first: unregistering a running task leaves the process behind,
        # still holding files in the folder about to be deleted.
        try { Stop-ScheduledTask -TaskName $t.name -ErrorAction Stop } catch { $null = $_ }   # not running, which is fine
        Unregister-ScheduledTask -TaskName $t.name -Confirm:$false -ErrorAction Stop
        Say ("  unregistered {0}" -f $t.name) 'Green'
    }
    catch { Say ("  could not unregister {0}: {1}" -f $t.name, ($_.Exception.Message -split "`n")[0].Trim()) 'Red'; $failed++ }
}

if ($plan.hosts.Count) {
    try {
        # Rebuilt by index rather than by matching text again, so a hostname that
        # also appears in an unrelated line cannot take that line with it.
        $drop = @{}
        foreach ($h in $plan.hosts) { $drop[$h.index] = $true; $drop[$h.index + 1] = $true }
        $kept = @()
        for ($i = 0; $i -lt $hostsLines.Count; $i++) {
            if (-not $drop.ContainsKey($i)) { $kept += $hostsLines[$i] }
        }
        [IO.File]::WriteAllLines($hostsPath, $kept, (New-Object Text.UTF8Encoding($false)))
        Say ("  removed {0} hosts file entr{1}" -f $plan.hosts.Count, $(if ($plan.hosts.Count -eq 1) { 'y' } else { 'ies' })) 'Green'
    }
    catch { Say ("  could not edit the hosts file: {0}" -f ($_.Exception.Message -split "`n")[0].Trim()) 'Red'; $failed++ }
}

foreach ($c in $plan.certs) {
    try {
        Remove-Item -LiteralPath (Join-Path $c.store $c.thumbprint) -Force -ErrorAction Stop
        Say ("  removed {0} from {1}" -f $c.subject, $c.store.Replace('Cert:\','')) 'Green'
    }
    catch { Say ("  could not remove {0}: {1}" -f $c.subject, ($_.Exception.Message -split "`n")[0].Trim()) 'Red'; $failed++ }
}

foreach ($s in $plan.shortcuts) {
    try { Remove-Item -LiteralPath $s.path -Force -ErrorAction Stop; Say ("  removed {0}" -f $s.path) 'Green' }
    catch { Say ("  could not remove {0}: {1}" -f $s.path, ($_.Exception.Message -split "`n")[0].Trim()) 'Red'; $failed++ }
}

# --------------------------------------------------------------------------- #
# What is left, and what this could not reach
# --------------------------------------------------------------------------- #
Say ""
if ($failed) { Say ("  {0} step(s) failed - see above." -f $failed) 'Red'; Say "" }

Say "  Still on disk, for you to delete when you are ready:" 'Cyan'
Say ("      {0}" -f $root) 'White'
Say ""
Say "  It contains unencrypted private keys, so delete it rather than leaving it" 'DarkGray'
Say "  somewhere - and do not move it into OneDrive on the way out." 'DarkGray'

$web = Get-WebSettings -Settings (Get-TrackerSettings)
if ($web.hostname) {
    Say ""
    Say "  Your browser may still refuse plain HTTP for:" 'Yellow'
    Say ("      {0}" -f $web.hostname) 'White'
    Say "  HSTS is stored in the browser, not here, and outlives this uninstall by" 'DarkGray'
    Say "  up to a year. To clear it now:" 'DarkGray'
    Say "      Chrome / Edge   chrome://net-internals/#hsts -> Delete domain security policies"
    Say "      Firefox         Forget About This Site, from the history entry"
}

Say ""
Say "  Certificates issued for your domains are still valid and still known to" 'DarkGray'
Say "  the certificate authority. Nothing here revokes them, and anything already" 'DarkGray'
Say "  deployed to a load balancer keeps serving until it expires." 'DarkGray'
Say ""
exit $(if ($failed) { 1 } else { 0 })
