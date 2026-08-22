<#
  sos-plain-http.ps1 - get back into the console when HTTPS is the problem.

      powershell -ExecutionPolicy Bypass -File .\sos-plain-http.ps1

  Clears the tracker hostname and turns HSTS off in settings.json, then stops the
  running server, so the next start serves plain HTTP on 127.0.0.1. Touches
  nothing else - no certificate is deleted and no domain is unwatched.

  The hostname is what gets cleared because the hostname IS the HTTPS switch:
  set a name and the console serves HTTPS on it, clear it and it serves plain
  HTTP. There is no separate flag to turn off. The name is printed before it
  goes, and recorded in the audit trail, because putting it back is how you
  restore HTTPS afterwards.

  THE THING TO UNDERSTAND FIRST

  HSTS lives in the BROWSER, not here. Once a browser has been told that
  tracker.example.com is HTTPS-only, it enforces that itself: it will not send a
  plain HTTP request to that name, and it will not offer "continue anyway" on a
  certificate error. Turning the header off at this end does not reach into the
  browser and undo it - the policy stays until it expires, up to a year later.

  So this script cannot un-break the NAME. What it does is get the console
  serving again, and the way back in is an address that never carried the policy:

      http://127.0.0.1:<port>

  HSTS is keyed by hostname, and 127.0.0.1 is a different one. That address
  works even while the name is locked, which is why the server always keeps
  answering on it.

  Clearing the name in the browser, if you want it back before it expires:

      Chrome / Edge   chrome://net-internals/#hsts  (edge://net-internals/#hsts)
                      "Delete domain security policies", enter the hostname
      Firefox         History > Clear Recent History > Site settings
                      or: Forget About This Site, from the history entry
#>

[CmdletBinding()]
param(
    # Stop the running server as well. On by default: leaving the old process up
    # means the settings change has not taken effect and the console is still
    # doing exactly what you ran this to stop.
    [switch]$NoStop
)

$ErrorActionPreference = 'Stop'
# This one script stays at the folder root rather than moving into resources\
# with the rest: it is the way back in when the console will not serve, and a
# recovery tool you have to go looking for is not much of one. So unlike its
# siblings it has to reach DOWN into resources\ for the library.
. (Join-Path $PSScriptRoot 'resources\acme-lib.ps1')

function Say { param([string]$T, [string]$C = 'Gray') Write-Host $T -ForegroundColor $C }

Say ""
Say "  Cert Camel - back to plain HTTP" 'Cyan'
Say ""

$settings = Get-TrackerSettings
$web = Get-WebSettings -Settings $settings
$port = $web.port

if (-not $web.https -and -not $web.hsts) {
    Say "  HTTPS is already off. Nothing to change." 'Yellow'
}
else {
    $wasName = $web.hostname
    Say ("  was: https={0}  hsts={1}  name={2}  port={3}" -f $web.https, $web.hsts, $wasName, $web.port)

    # The HOSTNAME is what gets cleared, not an https flag.
    #
    # This used to write https=false and deliberately keep the name. That worked
    # until the settings page started deriving https from the hostname: the name
    # survived, so the next time anything was saved in Settings - anything at all
    # - https was recomputed as true and quietly re-armed. Somebody who ran this
    # to escape a broken certificate would find it broken again after changing an
    # unrelated setting.
    #
    # The name is the switch now, so turning it off means clearing the name. The
    # port is kept, because that is the address you come back on.
    if (-not $settings.ContainsKey('web') -or -not $settings.web) { $settings.web = @{} }
    $settings.web.hostname = ''
    $settings.web.https    = $false   # kept in the file for older readers; nothing derives from it
    $settings.web.hsts     = $false
    Save-TrackerSettings -Settings $settings

    try {
        Write-AuditEvent -Event 'settings' -Object 'web' -Outcome 'ok' `
            -Detail ("sos-plain-http.ps1: cleared the tracker hostname '$wasName' and turned HSTS off")
        } catch { $null = $_ }   # the emergency switch already worked; auditing it is secondary

    Say "  now: serving plain HTTP on 127.0.0.1 (hostname cleared, port kept)" 'Green'
    if ($wasName) {
        Say ""
        Say "  WRITE THIS DOWN - it is what you put back to restore HTTPS:" 'Yellow'
        Say ("      {0}" -f $wasName) 'White'
        Say "  It is also in audit.log, and certs\$wasName\ is still on disk." 'DarkGray'
    }
}

# --------------------------------------------------------------------------- #
# Stop the running server, or the change has not taken effect yet
# --------------------------------------------------------------------------- #
if (-not $NoStop) {
    $stopped = 0
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue)) {
        if ($p.CommandLine -and $p.CommandLine -match 'serve\.ps1' -and $p.ProcessId -ne $PID) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; $stopped++ } catch { $null = $_ }   # already gone, or not ours to stop
        }
    }
    if ($stopped) { Say ("  stopped {0} running server process(es)." -f $stopped) 'Green' }
    else          { Say "  no running server found - it may be under a scheduled task." 'Yellow' }
}

Say ""
Say "  Start it again, then open:" 'Cyan'
if ($port) { Say ("      http://127.0.0.1:{0}" -f $port) 'White' }
else       { Say  "      http://127.0.0.1:<port shown at startup>" 'White' }
Say ""
Say "  Use 127.0.0.1, not the name. HSTS is stored per hostname in the browser," 'DarkGray'
Say "  so a name you have already visited over HTTPS will refuse plain HTTP no" 'DarkGray'
Say "  matter what this server sends. 127.0.0.1 never carried the policy." 'DarkGray'
Say ""
Say "  To clear the name in the browser before the policy expires:" 'DarkGray'
Say "      Chrome / Edge   chrome://net-internals/#hsts -> Delete domain security policies"
Say "      Firefox         Forget About This Site, from the history entry"
Say ""
Say "  Then fix whatever the certificate problem was. To restore HTTPS, put the" 'DarkGray'
Say "  name back under Settings > Tracker address - there is no separate switch," 'DarkGray'
Say "  the name IS the switch - and restart the console." 'DarkGray'
Say ""
