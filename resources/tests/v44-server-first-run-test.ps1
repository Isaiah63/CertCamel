<#
  A server install must not serve its first session from a console window.

  THE BUG. Install-CamelServerTask registers 'Cert Camel Server' with an
  -AtStartup trigger and does not start it. So from setup finishing until the
  next reboot, the task exists and nothing runs - and setup then offers to open
  the tracker, the launcher finds no live session, and serve.ps1 starts a server
  in THAT CONSOLE: service = $false, tied to the signed-in session, gone at
  sign-out. On a server that is the wrong shape entirely, and it looks perfectly
  healthy until somebody signs out. A reboot "fixes" it because the task finally
  runs and wins.

  The same shape arrives by a second route that has nothing to do with a first
  install: stop the server, re-run setup, answer Y to "Keep it?", then Y to
  "Open the tracker now?". Keeping a task does not start it.

  Most of the logic worth testing is in Get-LiveCamelSession, which decides
  whether anything is already serving. Its failure modes are all "say a server
  is running when one is not", because that is the answer that SKIPS the start
  and reproduces the bug.

  Reads only. Registers, starts, stops and deletes nothing - the decision
  function is exercised through -WhatIfOnly.

      powershell -ExecutionPolicy Bypass -File .\v44-server-first-run-test.ps1
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

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("cc-v44-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $sandbox
$script:JobsDir = $sandbox        # every session read below lands here, not in the real jobs\
$sessionFile = Join-Path $sandbox 'session.json'
Write-Host "sandbox: $sandbox"

function Write-Session {
    # NOT -Pid: $PID is a read-only automatic variable and binding to it throws.
    param($ProcessId, [bool]$Service = $true)
    @{ pid = $ProcessId; port = 8787; service = $Service; folder = 'C:\CertCamel'
       token = 'x'; startedAt = (Get-Date).ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $sessionFile -Encoding UTF8
}

try {
    # ----------------------------------------------------------------------- #
    Write-Host "`nis anything already serving?"

    Check 'no session file means no' ($null -eq (Get-LiveCamelSession)) 'invented a server'

    Set-Content -LiteralPath $sessionFile -Value 'not json at all' -Encoding UTF8
    Check 'an unparseable file means no' ($null -eq (Get-LiveCamelSession)) `
          'a corrupt file must not read as a running server'

    '{"port":8787}' | Set-Content -LiteralPath $sessionFile -Encoding UTF8
    Check 'a file with no pid means no' ($null -eq (Get-LiveCamelSession)) 'no pid to check'

    # A pid that is certainly gone. Very high values are not in use, and this is
    # the ordinary case after a crash or a hard kill.
    Write-Session -ProcessId 999999
    Check 'a pid that has gone means no' ($null -eq (Get-LiveCamelSession)) `
          'a stale file would skip the start and reproduce the bug'

    <#
      The subtle one. Windows recycles pids, so a stale session file can name a
      pid that IS alive and belongs to something else entirely. Believing it
      would skip the start - the exact failure this function exists to prevent -
      so the process has to look like PowerShell too. Pid 4 is System, always
      running and never PowerShell.
    #>
    Write-Session -ProcessId 4
    Check 'a recycled pid on another program means no' ($null -eq (Get-LiveCamelSession)) `
          'pid 4 is System; treating it as the server would skip the start'

    # This test IS a live PowerShell, so it stands in for a running server.
    Write-Session -ProcessId $PID
    $live = Get-LiveCamelSession
    Check 'a live PowerShell pid means yes' ($null -ne $live) 'did not recognise a running server'
    Check 'and the session comes back' ($live -and [int]$live.pid -eq $PID) "got $($live.pid)"

    # ----------------------------------------------------------------------- #
    Write-Host "`nthe decision, without starting anything"
    <#
      Whether the task is registered depends on the machine - it is offered only
      on Windows Server - so this asserts against reality rather than assuming
      one. What must hold either way: -WhatIfOnly never reports 'started'.
    #>
    $def = @($script:ScheduledTaskNames) | Where-Object { $_.key -eq 'server' }
    $registered = [bool](Get-ScheduledTask -TaskName $def.name -ErrorAction SilentlyContinue)
    Write-Host "  ('$($def.name)' is $(if ($registered) { 'registered' } else { 'not registered' }) on this machine)"

    # Session still names this process, so anything registered reads as running.
    $r = Start-CamelServerTaskIfIdle -WhatIfOnly
    Check 'it never claims to have started under -WhatIfOnly' ($r.action -ne 'started') $r.action
    Check 'it names the task it would act on' ($r.taskName -eq $def.name) $r.taskName

    if ($registered) {
        Check 'a live session means leave it alone' ($r.action -eq 'already-running') $r.action
        Check 'and it reports ready' ([bool]$r.ready) 'ready should be true when one is serving'

        Remove-Item -LiteralPath $sessionFile -Force
        $r2 = Start-CamelServerTaskIfIdle -WhatIfOnly
        Check 'registered but nothing running is the case that needs a start' `
              ($r2.action -eq 'would-start') `
              "$($r2.action) - this is the state after setup registers the task, and the bug"
        Check 'and it does not claim to be ready' (-not $r2.ready) 'nothing is serving'
    }
    else {
        Check 'no task means do nothing' ($r.action -eq 'not-registered') $r.action
        Check 'and it does not claim to be ready' (-not $r.ready) `
              'a console-hosted server is the right answer with no boot task'
    }

    # ----------------------------------------------------------------------- #
    Write-Host "`nsetup calls it BEFORE launching the tracker"
    <#
      Order is the whole fix. Starting the task after Start-Process would leave
      the launcher racing a server that has not written its session file yet,
      which is the bug with extra steps. Checked against the source, the way
      v27 reads setup.ps1, because the alternative is running an interactive
      wizard.
    #>
    $setupSrc = Get-Content (Join-Path $appDir 'setup.ps1') -Raw -Encoding UTF8
    $callAt   = $setupSrc.IndexOf('Start-CamelServerTaskIfIdle')
    $launchAt = $setupSrc.LastIndexOf('Start-Process -FilePath $launcher')
    Check 'setup calls it at all' ($callAt -ge 0) 'the fix is not wired in'
    Check 'and does so before launching the tracker' `
          ($callAt -ge 0 -and $launchAt -ge 0 -and $callAt -lt $launchAt) `
          "call at $callAt, launch at $launchAt - starting the task afterwards fixes nothing"
}
finally {
    Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:Failed) { Write-Host "$script:Failed CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
