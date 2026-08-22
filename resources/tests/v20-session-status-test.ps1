<#
  Telling "nothing is running" apart from "I am not allowed to look".

  Get-RunningInstance used to answer $null for five different situations, and
  the caller treated all five the same: no live instance, so delete the session
  file as stale and start a server.

  Two of those five need the opposite handling. A file this account cannot open
  is not a leftover - it is somebody else's RUNNING server, and deleting it
  orphans them: the server keeps running, holding the port, while nothing on
  disk records the token or the pid any more. The next launcher then finds no
  session file, tries to bind a port that is already held, and fails with a
  socket error that says nothing about what happened.

  It never actually fired, and only because the session file's ACL denied the
  delete. The attempt was made on every launch by a non-owner. That is a
  hazard resting entirely on a permission, and permissions get loosened.

  Reads only. Nothing here touches the real session file - every case is built
  in a scratch folder with the module's paths pointed at it.

      powershell -ExecutionPolicy Bypass -File .\v20-session-status-test.ps1
#>

$ErrorActionPreference = 'Stop'
$repo    = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$appDir  = Join-Path $repo 'resources'
$serveSrc = Get-Content (Join-Path $appDir 'serve.ps1') -Raw -Encoding UTF8

$script:Failed = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    if ($Ok) { Write-Host "  ok   $Name" -ForegroundColor Green }
    else     { Write-Host "  FAIL $Name  -- $Detail" -ForegroundColor Red; $script:Failed++ }
}

# serve.ps1 starts a listener when run, so the function under test is lifted out
# by parsing rather than by dot-sourcing the script.
$errs = $null; $toks = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($serveSrc, [ref]$toks, [ref]$errs)
Check 'serve.ps1 parses' (-not $errs) 'cannot analyse a file that does not parse'

$fn = $ast.Find({ param($n)
    $n -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $n.Name -eq 'Get-SessionFileStatus' }, $true)
Check 'Get-SessionFileStatus exists' ($null -ne $fn) `
      'the five states collapsed back into one $null answer'

if (-not $fn) {
    Write-Host "`n1 CHECK(S) FAILED" -ForegroundColor Red; exit 1
}

# Run it against a scratch folder by defining it with $script:SessionFile
# pointed somewhere harmless.
$scratch = Join-Path $env:TEMP ('camel-sess-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
try {
    $script:SessionFile = Join-Path $scratch 'session.json'

    # Dot-sourced as a scriptblock rather than run through Invoke-Expression:
    # same effect, and it keeps PSAvoidUsingInvokeExpression quiet without a
    # suppression. The function is lifted out of the file at all because
    # dot-sourcing serve.ps1 would start a listener.
    . ([ScriptBlock]::Create($fn.Extent.Text))

    Write-Host "`nno file at all"
    Check "state is 'missing'" ((Get-SessionFileStatus).state -eq 'missing') `
          "got '$((Get-SessionFileStatus).state)'"

    Write-Host "`na file that is not a session file"
    Set-Content -LiteralPath $script:SessionFile -Value 'this is not json' -Encoding Ascii
    Check "state is 'malformed'" ((Get-SessionFileStatus).state -eq 'malformed') `
          "got '$((Get-SessionFileStatus).state)'"

    Set-Content -LiteralPath $script:SessionFile -Value '{"url":"http://x"}' -Encoding Ascii
    Check "valid JSON with no pid or port is 'malformed'" `
          ((Get-SessionFileStatus).state -eq 'malformed') `
          "got '$((Get-SessionFileStatus).state)'"

    Write-Host "`na file naming a process that is gone"
    # A pid that cannot be running: the highest value Windows will not have
    # issued, chosen over a random one so this never accidentally names a real
    # process and reports 'live' on somebody's busy machine.
    $deadPid = 0xFFFFFFF
    Set-Content -LiteralPath $script:SessionFile -Encoding Ascii `
        -Value ('{"pid":' + $deadPid + ',"port":65000,"url":"http://127.0.0.1:65000","token":"x"}')
    Check "state is 'stale'" ((Get-SessionFileStatus).state -eq 'stale') `
          "got '$((Get-SessionFileStatus).state)'"

    Write-Host "`na file naming this process, on a port nothing is listening on"
    # Alive pid, dead port - the recycled-pid case. Both halves have to be
    # checked or a pid reissued to an unrelated program reads as a live server.
    Set-Content -LiteralPath $script:SessionFile -Encoding Ascii `
        -Value ('{"pid":' + $PID + ',"port":1,"url":"http://127.0.0.1:1","token":"x"}')
    Check "a live pid on a dead port is still 'stale'" `
          ((Get-SessionFileStatus).state -eq 'stale') `
          "got '$((Get-SessionFileStatus).state)' - a recycled pid would read as a running server"

    Write-Host "`na file this account cannot read"
    # The case the whole refactor exists for. Built by denying read to everyone,
    # which an owner can still undo afterwards.
    $locked = Join-Path $scratch 'locked.json'
    Set-Content -LiteralPath $locked -Value '{"pid":1,"port":1}' -Encoding Ascii
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $sd = New-Object Security.AccessControl.FileSecurity
    $sd.SetAccessRuleProtection($true, $false)
    $sd.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        $me, 'FullControl', 'None', 'None', 'Deny')))
    $applied = $false
    try { Set-Acl -Path $locked -AclObject $sd; $applied = $true } catch { $null = $_ }

    if (-not $applied) {
        Write-Host "  --   could not deny read to this account, skipping" -ForegroundColor DarkGray
    }
    else {
        $script:SessionFile = $locked
        $state = (Get-SessionFileStatus).state
        Check "state is 'unreadable', not 'stale'" ($state -eq 'unreadable') `
              "got '$state' - an unreadable file would be deleted, orphaning a running server"

        # Put it back so the folder can be cleaned up.
        $undo = New-Object Security.AccessControl.FileSecurity
        $undo.SetAccessRuleProtection($true, $false)
        $undo.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            $me, 'FullControl', 'None', 'None', 'Allow')))
        try { Set-Acl -Path $locked -AclObject $undo } catch { $null = $_ }
    }
}
finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }

# --------------------------------------------------------------------------- #
Write-Host "`nthe startup path acts on the distinction"
Check 'deletion is limited to stale and malformed' `
      ($serveSrc -match "sessionStatus\.state -in @\('stale', 'malformed'\)") `
      'the cleanup deletes on any non-live answer again, including unreadable'
Check 'an unreadable file stops the start instead of racing it' `
      ($serveSrc -match "sessionStatus\.state -eq 'unreadable'") `
      'a launcher run by the wrong account would start a second server and collide on the port'

Write-Host ""
if ($script:Failed) { Write-Host "$script:Failed CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
