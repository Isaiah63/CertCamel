<#
  sos-plain-http.ps1 - get back into the console when HTTPS is the problem.

      powershell -ExecutionPolicy Bypass -File .\sos-plain-http.ps1

  Turns HTTPS and HSTS off in settings.json and stops the running server, so the
  next start serves plain HTTP. Touches nothing else - no certificate is deleted,
  no domain is unwatched, and the settings it changes are the two you can turn
  straight back on.

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
. (Join-Path $PSScriptRoot 'acme-lib.ps1')

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
    Say ("  was: https={0}  hsts={1}  name={2}  port={3}" -f $web.https, $web.hsts, $web.hostname, $web.port)

    # The hostname and port are LEFT ALONE. They are what you turn back on with,
    # and someone running this at 2am should not also have to remember them.
    if (-not $settings.ContainsKey('web') -or -not $settings.web) { $settings.web = @{} }
    $settings.web.https = $false
    $settings.web.hsts  = $false
    Save-TrackerSettings -Settings $settings

    try {
        Write-AuditEvent -Event 'settings' -Object 'web' -Outcome 'ok' `
            -Detail 'sos-plain-http.ps1: HTTPS and HSTS turned off'
    } catch { }

    Say "  now: https=False  hsts=False   (hostname and port kept)" 'Green'
}

# --------------------------------------------------------------------------- #
# Stop the running server, or the change has not taken effect yet
# --------------------------------------------------------------------------- #
if (-not $NoStop) {
    $stopped = 0
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue)) {
        if ($p.CommandLine -and $p.CommandLine -match 'serve\.ps1' -and $p.ProcessId -ne $PID) {
            try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; $stopped++ } catch { }
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
Say "  Then fix whatever the certificate problem was - Settings > Tracker address" 'DarkGray'
Say "  shows what is serving the console and whether it is still being renewed -" 'DarkGray'
Say "  and turn HTTPS back on. The hostname and port are still saved." 'DarkGray'
Say ""
