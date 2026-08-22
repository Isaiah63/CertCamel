<#
  Answering "can this server use this port" by trying, rather than by asking
  the OS who is listening.

  The check used to run Get-NetTCPConnection and decide free-versus-held from
  whether it could name a holder. Two things were wrong with that.

  SPEED. The cmdlet is CIM-backed: measured at 1651 ms on its first call in a
  process and ~140 ms after. The first call is the one somebody waits for,
  because a freshly started server sits on a random port - so the very first
  preflight after typing a real port always took the slow path, on a server
  that answers requests one at a time.

  CORRECTNESS, which matters more. The old code reported "free" whenever it
  could not name a holder, and it cannot name one running as SYSTEM. A port
  genuinely held by a service therefore came back as available, and the failure
  landed later as a server that would not start. It also matched a listener on
  ANY interface, so a port held only on an external address was called taken
  when it would not have blocked a loopback bind at all.

  A bind attempt answers the question being asked. The name lookup still runs,
  but only once the port is known to be held, and only to decorate the message.

  Binds and releases a high port on loopback. Nothing else is touched.

      powershell -ExecutionPolicy Bypass -File .\v25-port-check-test.ps1
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

$settings = Get-TrackerSettings
$zones    = Get-ZoneCache
function Status { param([int]$Port, [int]$Current = 0)
    return Get-TrackerAddressStatus -HostName 'probe.example.com' -Port $Port `
              -Settings $settings -ZoneCache $zones -CurrentPort $Current
}

# A port high enough to be unassigned, checked rather than assumed - a test that
# quietly measures somebody's running service proves nothing.
$freePort = 0
foreach ($p in 59990..59999) {
    $l = $null
    try {
        $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $p)
        $l.Start(); $l.Stop(); $freePort = $p; break
    }
    catch { $null = $_ }   # in use by something else; try the next
    finally { if ($l) { try { $l.Stop() } catch { $null = $_ } } }
}

if (-not $freePort) {
    Write-Host "  --   no free port in 59990-59999 to test with, skipping" -ForegroundColor DarkGray
    exit 0
}

# --------------------------------------------------------------------------- #
Write-Host "`na port nothing is holding"
$r = Status -Port $freePort
Check 'reports it as usable'  $r.portCheck.ok "said: $($r.portCheck.detail)"
Check 'and says so in words'  ($r.portCheck.detail -match 'free') "said: $($r.portCheck.detail)"

# --------------------------------------------------------------------------- #
Write-Host "`na port this process is holding"
$held = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $freePort)
$held.Start()
try {
    $r = Status -Port $freePort
    Check 'reports it as unusable' (-not $r.portCheck.ok) `
          "said it was usable while a listener held it: $($r.portCheck.detail)"
    Check 'names the process holding it' ($r.portCheck.detail -match 'held by') `
          "said: $($r.portCheck.detail)"

    # The regression that matters. Whether the port can be bound is settled by
    # the bind, so even with no name available the answer stays "held" - the old
    # code called that "free" and let a server be configured onto a port it
    # could never have.
    Check 'the verdict does not depend on naming the holder' `
          ($r.portCheck.detail -notmatch 'is free') `
          'a port that is demonstrably held was reported free'
}
finally { try { $held.Stop() } catch { $null = $_ } }

Write-Host "`nand it is released again afterwards"
$r = Status -Port $freePort
Check 'free once the listener stops' $r.portCheck.ok `
      "the probe did not release the port: $($r.portCheck.detail)"

# --------------------------------------------------------------------------- #
Write-Host "`nthe port the server is already on is not a conflict"
# Without this the console reports its own port as taken - by itself - and the
# Tracker address panel shows a permanent failure on a working install.
$busy = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $freePort)
$busy.Start()
try {
    $r = Status -Port $freePort -Current $freePort
    Check 'reported as usable when it is this server' $r.portCheck.ok `
          "said: $($r.portCheck.detail)"
    Check 'and says why'  ($r.portCheck.detail -match 'this server') "said: $($r.portCheck.detail)"
}
finally { try { $busy.Stop() } catch { $null = $_ } }

# --------------------------------------------------------------------------- #
Write-Host "`nnonsense ports are refused without probing"
foreach ($bad in @(0, -1, 65536, 99999)) {
    $r = Status -Port $bad
    Check "port $bad is rejected" (-not $r.portCheck.ok) "said: $($r.portCheck.detail)"
}

# --------------------------------------------------------------------------- #
Write-Host "`nthe expensive lookup is not on the common path"
$libSrc = Get-Content (Join-Path $appDir 'acme-lib.ps1') -Raw -Encoding UTF8
$m = [regex]::Match($libSrc, '# --- port -+ #(?<b>[\s\S]*?)# --- hosts')
Check 'found the port section to inspect' $m.Success `
      'the section markers changed, so this is checking nothing'

if ($m.Success) {
    $block = $m.Groups['b'].Value

    # The CALL, not the word. The comment above the code explains why
    # Get-NetTCPConnection is no longer on the fast path, and naming it there
    # made a plain substring search report the mention as the call - which
    # failed while the code was correct.
    $bindAt = $block.IndexOf('New-Object Net.Sockets.TcpListener')
    $cimAt  = $block.IndexOf('@(Get-NetTCPConnection')

    Check 'the bind attempt is present' ($bindAt -ge 0) 'the cheap check is gone'
    Check 'the bind attempt comes first' `
          ($bindAt -ge 0 -and $cimAt -ge 0 -and $bindAt -lt $cimAt) `
          "bind at $bindAt, lookup at $cimAt - every free-port check pays for the lookup again"
}

Write-Host ""
if ($script:Failed) { Write-Host "$script:Failed CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
