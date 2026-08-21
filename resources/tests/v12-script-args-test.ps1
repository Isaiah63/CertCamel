<#
  Every parameter one script passes to another must exist on the script it is
  passed to.

  This exists because it did not. renew-due.ps1 called renew.ps1 with -Cert for
  as long as renew-due.ps1 existed. -Cert is the parameter deploy.ps1 takes;
  renew.ps1 takes -ZoneList, aliased -Zone. Both scripts are launched the same
  way and take a similar-looking value under a different name, so the wrong
  spelling read as correct. It bound to nothing, and the first unattended
  renewal that actually had work to do died with:

      A parameter cannot be found that matches

  Nothing caught it. The suites beside this one drive the PAGE, not PowerShell.
  Parse checks pass, because the call is syntactically fine. And
  renew-due.ps1 -WhatIfOnly, the documented safe check, stops before the call -
  so the one path that would have run it is the one nobody runs on purpose.

  Two things make this more than a restatement of the fix:

    - Call sites are READ OUT OF THE SOURCE, never listed in this file. A list
      here would pass forever no matter what the program started doing, which is
      the failure this file exists to prevent.
    - Both halves come from PowerShell rather than from pattern matching: the
      AST says what is a parameter and what is an operator, a cmdlet name or a
      word in a comment, and Get-Command says which names and aliases bind.

  Run it:
      powershell -ExecutionPolicy Bypass -File .\v12-script-args-test.ps1

  Exits non-zero on failure.
#>

$ErrorActionPreference = 'Stop'
$src = Split-Path $PSScriptRoot -Parent
$failed = 0

function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if (-not $Ok) { $script:failed++ }
    $line = $(if ($Ok) { '  ok   ' } else { '  FAIL ' }) + $Name
    if (-not $Ok) { $line += '  -- ' + $Detail }
    Write-Host $line -ForegroundColor $(if ($Ok) { 'DarkGray' } else { 'Red' })
}

# powershell.exe takes these itself, and Start-ChildJob takes these two. They
# are never what a call site is trying to hand the script it launches.
$hostParams = @('NoProfile','ExecutionPolicy','File','WindowStyle','Command','Kind','ScriptArgs')

function Get-ValidNames([string]$Leaf) {
    $path = Join-Path $src $Leaf
    if (-not (Test-Path $path)) { throw "No such script: $path" }
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in (Get-Command $path).Parameters.Values) {
        [void]$set.Add($p.Name)
        foreach ($a in $p.Aliases) { [void]$set.Add($a) }
    }
    return $set
}

function Get-Ast([string]$Leaf) {
    [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $src $Leaf), [ref]$null, [ref]$null)
}

<#
  What a variable holds at the moment a launch uses it: the dash-prefixed string
  literals assigned to it, and any .ps1 path.

  Scoped to the nearest preceding plain assignment rather than to every
  assignment in the file. serve.ps1 builds BOTH the deploy launch and the renew
  launch in a variable called $scriptArgs, so taking the whole file merged the
  two and reported -Cert being passed to renew.ps1 - inventing the exact bug
  this suite exists to catch, in a place where it is not happening.

  The += that follows a plain assignment does belong to it, which is how
  -TargetList and -NoDeploy get added after the fact.
#>
function Get-VarContentsBefore($Ast, [string]$VarName, [int]$BeforeLine) {
    $assigns = @($Ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $n.Left.VariablePath.UserPath -eq $VarName
    }, $true) | Where-Object { $_.Extent.StartLineNumber -lt $BeforeLine } |
        Sort-Object { $_.Extent.StartLineNumber })

    $names  = New-Object System.Collections.Generic.List[string]
    $target = $null
    if (-not $assigns.Count) { return [pscustomobject]@{ Names = $names; Target = $target } }

    $lastPlain = @($assigns | Where-Object { $_.Operator -eq 'Equals' })
    $from = if ($lastPlain.Count) { $lastPlain[-1].Extent.StartLineNumber } else { 0 }

    foreach ($a in ($assigns | Where-Object { $_.Extent.StartLineNumber -ge $from })) {
        foreach ($s in $a.Right.FindAll({
            param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst]
        }, $true)) {
            if ($s.Value -like '*.ps1') { $target = $s.Value }
            elseif ($s.Value -match '^-([A-Za-z][A-Za-z0-9]*)$') { [void]$names.Add($Matches[1]) }
        }
    }
    return [pscustomobject]@{ Names = $names; Target = $target }
}

<#
  Find every launch of one script by another, and what it passes.

  Keyed on the LAUNCH rather than on the script name appearing somewhere in the
  file, because the two shapes put the name in different places: serve.ps1 puts
  the path and the arguments in one array, while renew-due.ps1 holds the path in
  a variable and splats the arguments in separately.
#>
function Get-LaunchSites([string]$Leaf) {
    $ast = Get-Ast $Leaf
    $sites = New-Object System.Collections.Generic.List[object]

    foreach ($cmd in $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.CommandAst]
    }, $true)) {
        $name = $cmd.GetCommandName()
        if ($name -ne 'Start-ChildJob' -and $name -notlike 'powershell*') { continue }

        $target = $null
        $names  = New-Object System.Collections.Generic.List[string]

        # Bare parameters written directly on the command line.
        foreach ($e in $cmd.CommandElements) {
            if ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
                if ($hostParams -notcontains $e.ParameterName) { [void]$names.Add($e.ParameterName) }
            }
        }

        # A .ps1 named anywhere inside the command, or reached through a
        # variable holding it.
        foreach ($s in $cmd.FindAll({
            param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst]
        }, $true)) {
            if ($s.Value -like '*.ps1') { $target = $s.Value }
            elseif ($s.Value -match '^-([A-Za-z][A-Za-z0-9]*)$' -and
                    $hostParams -notcontains $Matches[1]) { [void]$names.Add($Matches[1]) }
        }

        # A variable used by the launch may hold the target path, the argument
        # list, or both. Read as of this launch, not as of the whole file.
        foreach ($v in $cmd.FindAll({
            param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst]
        }, $true)) {
            $held = Get-VarContentsBefore $ast $v.VariablePath.UserPath $cmd.Extent.StartLineNumber
            if ($held.Target) { $target = $held.Target }
            foreach ($n in $held.Names) {
                if ($hostParams -notcontains $n) { [void]$names.Add($n) }
            }
        }

        if (-not $target) { continue }

        # Start-ChildJob appends -Source itself, so those targets must accept it
        # even though no call site names it.
        if ($name -eq 'Start-ChildJob' -and $names -notcontains 'Source') { [void]$names.Add('Source') }

        $sites.Add([pscustomobject]@{
            From = $Leaf
            To   = $target
            Args = ($names | Sort-Object -Unique)
            Line = $cmd.Extent.StartLineNumber
        })
    }
    return $sites
}

Write-Host ''
Write-Host 'every parameter a call site passes exists on the script it calls' -ForegroundColor Cyan

$all = New-Object System.Collections.Generic.List[object]
foreach ($f in (Get-ChildItem -Path $src -Filter '*.ps1' -File)) {
    foreach ($s in (Get-LaunchSites $f.Name)) { $all.Add($s) }
}

Check 'launch sites were found at all' ($all.Count -gt 0) 'the shapes changed, so this suite is checking nothing'

foreach ($s in $all) {
    $valid = Get-ValidNames $s.To
    $bad   = @($s.Args | Where-Object { -not $valid.Contains($_) })
    Check ("{0,-14}:{1,-5} -> {2,-14} {3}" -f $s.From, $s.Line, $s.To, ($s.Args -join ' ')) ($bad.Count -eq 0) ('no such parameter: ' + ($bad -join ', '))
}

# The specific confusion that caused this, pinned so the two names cannot
# quietly converge later.
Write-Host ''
Write-Host 'the two scripts keep taking different names' -ForegroundColor Cyan
$r = Get-ValidNames 'renew.ps1'
$d = Get-ValidNames 'deploy.ps1'
Check 'renew.ps1 takes -Zone'    ($r.Contains('Zone'))      'alias lost'
Check 'renew.ps1 refuses -Cert'  (-not $r.Contains('Cert')) 'now ambiguous with deploy.ps1'
Check 'deploy.ps1 takes -Cert'   ($d.Contains('Cert'))      'alias lost'
Check 'deploy.ps1 refuses -Zone' (-not $d.Contains('Zone')) 'now ambiguous with renew.ps1'

Write-Host ''
if ($failed) { Write-Host "$failed CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
