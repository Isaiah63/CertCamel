<#
  Reading the path out of a scheduled task, and noticing when it names another
  copy of Cert Camel.

  The task names are fixed, so a machine has exactly one "Cert Camel Renew"
  however many copies of the folder exist. Running setup from a second copy does
  not add a second set - it repoints the existing ones. The first copy then goes
  on looking perfectly healthy on its own Home page while nothing it owns ever
  runs again, renewal included.

  All of that rests on one regex, and that regex was wrong. It anchored the
  -File argument to the end of the string:

      -File\s+"?([^"]+)"?\s*$

  Three of the four tasks end with their script path, so three matched. The
  server task carries "-Port 8787 -ServiceMode" afterwards and matched nothing -
  and pathMatches then kept its optimistic default of $true, so a server task
  left pointing at a deleted folder reported as healthy indefinitely.

  Measured against the real registered tasks before the fix, not reasoned about.

  Reads only. Registers, modifies and deletes nothing.

      powershell -ExecutionPolicy Bypass -File .\v22-foreign-tasks-test.ps1
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

$libSrc   = Get-Content (Join-Path $appDir 'acme-lib.ps1') -Raw -Encoding UTF8
$setupSrc = Get-Content (Join-Path $appDir 'setup.ps1')    -Raw -Encoding UTF8

# --------------------------------------------------------------------------- #
Write-Host "`nreading the script path out of a task's arguments"
$cases = @(
    @{ label = 'plain, path last'
       args  = '-NoProfile -ExecutionPolicy Bypass -File "C:\CertCamel\resources\renew-due.ps1"'
       want  = 'C:\CertCamel\resources\renew-due.ps1' },
    @{ label = 'arguments after the path (the server task)'
       args  = '-NoProfile -ExecutionPolicy Bypass -File "C:\CertCamel\resources\serve.ps1" -Port 8787 -ServiceMode'
       want  = 'C:\CertCamel\resources\serve.ps1' },
    @{ label = 'unquoted path with no spaces'
       args  = '-NoProfile -File C:\CertCamel\resources\check-ssl.ps1'
       want  = 'C:\CertCamel\resources\check-ssl.ps1' },
    @{ label = 'a path containing spaces'
       args  = '-NoProfile -File "C:\Program Files\Cert Camel\resources\serve.ps1" -ServiceMode'
       want  = 'C:\Program Files\Cert Camel\resources\serve.ps1' },
    @{ label = 'spaces, nothing after it'
       args  = '-NoProfile -File "D:\Cert Camel\resources\check-ssl.ps1"'
       want  = 'D:\Cert Camel\resources\check-ssl.ps1' }
)
foreach ($c in $cases) {
    $got = Get-TaskScriptPath -Arguments $c.args
    Check $c.label ($got -eq $c.want) "got '$got', wanted '$($c.want)'"
}

foreach ($empty in @('', '   ', '-NoProfile -ExecutionPolicy Bypass')) {
    Check "no -File argument returns nothing ('$empty')" `
          ($null -eq (Get-TaskScriptPath -Arguments $empty)) `
          "got '$(Get-TaskScriptPath -Arguments $empty)'"
}

# Two readers that disagree is what produced the bug in the first place: the
# status page said the server task was fine while the repair path could see it
# was not.
Check 'both callers use the one reader' `
      (($libSrc -match 'Get-TaskScriptPath -Arguments') -and ($setupSrc -match 'Get-TaskScriptPath -Arguments')) `
      'the path is being parsed in more than one place again, so the two can drift apart'

# --------------------------------------------------------------------------- #
Write-Host "`na registered task whose path cannot be read is not 'matching'"
Check 'pathMatches is cleared before the actions are inspected' `
      ($libSrc -match '(?m)^\s*\$entry\.pathMatches = \$false\s*$') `
      'an unparseable action leaves the optimistic default, which is how the server task went unnoticed'

# --------------------------------------------------------------------------- #
Write-Host "`nthis install does not report itself as foreign"
$status = Get-AutomationStatus
if (-not $status.available) {
    Write-Host "  --   the scheduler could not be read, skipping" -ForegroundColor DarkGray
}
else {
    $registered = @($status.tasks | Where-Object { $_.registered })
    if (-not $registered.Count) {
        Write-Host "  --   no Cert Camel tasks registered here, skipping" -ForegroundColor DarkGray
    }
    else {
        foreach ($t in $registered) {
            Check "$($t.name) reports a path" ([bool]$t.commandPath) `
                  'the path could not be read, so a mismatch could never be detected'
        }
        Check 'no task from this folder is reported as foreign' `
              (@(Get-ForeignCamelTasks | Where-Object { $_.path -like "$appDir*" }).Count -eq 0) `
              'setup would warn about its own tasks and refuse to continue'
    }
}

Check 'an unreadable scheduler reports nothing rather than "all clear"' `
      ($libSrc -match 'if \(-not \$status\.available\) \{ return @\(\) \}') `
      'a scheduler that cannot be read must not be reported as having no other install'

# --------------------------------------------------------------------------- #
Write-Host "`nsetup asks before taking the tasks over"
Check 'setup checks for another install' ($setupSrc -match 'Get-ForeignCamelTasks') `
      'a second install silently repoints the first one'
Check 'and stops unless told to take over' `
      ($setupSrc -match "takeOver -notmatch '\^\[Yy\]'") `
      'taking over another install should not be the default answer'

Write-Host ""
if ($script:Failed) { Write-Host "$script:Failed CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
