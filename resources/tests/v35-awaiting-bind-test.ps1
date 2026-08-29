<#
  Standing up a new domain is not a failed deployment.

  HAProxy will not reload against a bind line naming a certificate that does not
  exist, so a new frontend has to be built the other way round: push the
  certificate first, then write the bind, then reload. Cert Camel supports that
  properly - it uploads the certificate, creates the crt-list containing it, and
  prints the exact bind line and reload commands.

  Then it called the run a failure. Nothing served the certificate, so T3 could
  not pass; $t.ok went false, $entry.ok went false, the log said "did NOT fully
  succeed", and Send-RenewalOutcomeAlert emailed the team - one line after the
  same run printed "expected - the crt-list was created this run and no bind
  line references it yet".

  That is an alarm firing on the documented happy path of a first setup, which
  is precisely how people learn to ignore deployment alerts. So there is a third
  outcome now: deployed, waiting for a bind line.

  THE GUARD THAT MATTERS is that it must not swallow a real failure. A rejected
  upload, a wrong serial, a certificate that does not cover its names - all of
  those still fail hard and still alert. Half this file exists to hold that
  line, because a state that forgives one thing is one bad edit away from
  forgiving everything.

  Source and logic checks only. No node is contacted and nothing is deployed.

      powershell -ExecutionPolicy Bypass -File .\v35-awaiting-bind-test.ps1
#>

$ErrorActionPreference = 'Stop'
$repo   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
# Not $appDir - acme-lib.ps1 sets $script:AppDir and PowerShell names are
# case-insensitive, so that would silently repoint at wherever it was loaded.
$srcDir = Join-Path $repo 'resources'
. (Join-Path $srcDir 'acme-lib.ps1')

$script:Failed = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    if ($Ok) { Write-Host "  ok   $Name" -ForegroundColor Green }
    else     { Write-Host "  FAIL $Name  -- $Detail" -ForegroundColor Red; $script:Failed++ }
}

$deploySrc = Get-Content (Join-Path $srcDir 'deploy.ps1') -Raw -Encoding UTF8
$renewSrc  = Get-Content (Join-Path $srcDir 'renew.ps1')  -Raw -Encoding UTF8
$libSrc    = Get-Content (Join-Path $srcDir 'acme-lib.ps1') -Raw -Encoding UTF8

# --------------------------------------------------------------------------- #
# The rule, run rather than read. The predicate deploy.ps1 uses is reproduced
# here against hand-built node records, so the cases below are decided by logic
# and not by whether a regex still matches.
function Test-Awaiting {
    param($Node, [int]$Proved = 0)
    return [bool]($Node.push -and $Node.push.ok -and
                  $Node.ContainsKey('crtList') -and $Node.crtList -and
                  $Node.crtList.ok -and $Node.crtList.needsBind -and
                  $Proved -eq 0)
}
# NOT named Node. PSScriptAnalyzer's PSAvoidOverwritingBuiltInCmdlets compares
# against a per-edition list of built-ins, and the CI runner's list is not this
# machine's - so a name that looks free locally is flagged there. Same family as
# Dir, which is an alias for Get-ChildItem and silently won every call in v31.
function NewNodeResult {
    param([bool]$PushOk = $true, $CrtList = $null)
    $n = @{ name = 'n1'; push = @{ ok = $PushOk }; verify = @() }
    if ($null -ne $CrtList) { $n.crtList = $CrtList }
    return $n
}

Write-Host "`nthe bootstrap: pushed, listed, nothing reading it yet"
$boot = NewNodeResult -CrtList @{ ok = $true; needsBind = $true; path = '/certs/example.com-crt-list.txt' }
Check 'it is recognised as waiting for a bind' (Test-Awaiting $boot) `
      'the run reports a failed deployment on the documented way to add a domain'

Write-Host "`nand once the operator adds the bind line"
$bound = NewNodeResult -CrtList @{ ok = $true; needsBind = $false; runtimeLoaded = $true }
Check 'it is an ordinary deployment again' (-not (Test-Awaiting $bound)) `
      'the state would stick, and a genuinely unserved certificate would be forgiven forever'

Write-Host "`na node that is already serving it, through a list nobody changed"
# Found by a real deployment, not by this file. Pointing a group's crt-list
# setting somewhere new leaves the frontend reading the OLD file - which still
# references the certificate, so the node serves it perfectly well while the new
# list sits unread. Both test nodes reported "awaiting bind" while an identity
# probe had just matched the serial against the running process.
#
# The state means "nothing could verify it", not "some list is unread".
$live = NewNodeResult -CrtList @{ ok = $true; needsBind = $true; path = '/certs/new-list.txt' }
Check 'a proved node is not waiting for anything' (-not (Test-Awaiting $live -Proved 1)) `
      'a live deployment was reported as waiting for a bind line it did not need'
Check 'and the same node with nothing proved still is' (Test-Awaiting $live -Proved 0) `
      'the guard must not swallow the case the state exists for'

Check 'deploy requires that nothing proved it' `
      ($deploySrc -match '\$n\.crtList\.ok -and \$n\.crtList\.needsBind -and[\s\S]{0,60}\$proved -eq 0\)') `
      'without it the state under-claims, which is its own kind of wrong report'

# --------------------------------------------------------------------------- #
Write-Host "`nwhat it must NOT forgive"
Check 'a rejected upload is still a failure' `
      (-not (Test-Awaiting (NewNodeResult -PushOk $false -CrtList @{ ok = $true; needsBind = $true }))) `
      'T1 failed, so nothing was pushed - forgiving this hides a node that took nothing'
Check 'a crt-list that could not be written is still a failure' `
      (-not (Test-Awaiting (NewNodeResult -CrtList @{ ok = $false; needsBind = $true; error = 'HTTP 500' }))) `
      'the sync itself failed, which is not the same as it having nothing to read it'
Check 'no crt-list configured at all is not this state' `
      (-not (Test-Awaiting (NewNodeResult))) `
      'without a crt-list a human must edit a bind line for every certificate - a different problem, already warned about'
Check 'a served node is not waiting for anything' `
      (-not (Test-Awaiting (NewNodeResult -CrtList @{ ok = $true; needsBind = $false }))) `
      'this would forgive a wrong serial or an uncovered name on every node'

# --------------------------------------------------------------------------- #
Write-Host "`nthe predicate in deploy.ps1 is the one tested above"
Check 'it requires the push to have succeeded' `
      ($deploySrc -match '\$awaiting = \[bool\]\(\$n\.push -and \$n\.push\.ok -and') `
      'a rejected upload leaves crtList unset, but relying on that is luck rather than a guard'
Check 'it requires the crt-list sync to have succeeded' `
      ($deploySrc -match '\$n\.crtList\.ok -and \$n\.crtList\.needsBind') `
      'a failed sync with needsBind set would be forgiven'
Check 'and it skips the hard-fail rule only for that node' `
      ($deploySrc -match 'if \(\$awaiting\) \{ \$t\.awaitingBind = \$true; continue \}') `
      'a pair where one node is waiting and the other genuinely failed must still fail'

# --------------------------------------------------------------------------- #
Write-Host "`nit is a third outcome, not a shade of failure"
# Declared in each record's literal, not only assigned when true: a field that
# appears only on the runs that set it is absent from every JSON that did not,
# and every reader then has to guess whether absent means false or means old.
foreach ($r in @(
    @{ what = 'the certificate record'; rx = '\$entry  = @\{ certId = \$certId; name = \$cert\.displayName; ok = \$false[\s\S]{0,120}awaitingBind = \$false' },
    @{ what = 'the target record';      rx = '\$tResult = @\{ targetId = \$tid[\s\S]{0,120}awaitingBind = \$false' },
    @{ what = 'the run record';         rx = '\$outcome = @\{[\s\S]{0,400}awaitingBind = \$false' })) {
    Check "$($r.what) declares the field" ($deploySrc -match $r.rx) `
          'absent-when-false makes every reader guess whether absent means false or means old'
}
Check 'the entry rolls up from its targets' `
      ($deploySrc -match '\$entry\.awaitingBind = \[bool\]\(@\(\$entry\.targets \| Where-Object \{ \$_\.awaitingBind \}\)\.Count\)') `
      'the run would know per node and forget by the time it reported'

Write-Host "`nnothing claims verification it did not do"
Check 'the certificate line says waiting, not verified' `
      ($deploySrc -match 'deployed - waiting for a bind line before it can serve') `
      '"deployed and verified" is a claim no probe backed'
Check 'the run summary says it too' `
      ($deploySrc -match 'waiting for a bind line before serving') `
      'the per-certificate line is easy to miss in a run over several'
Check 'the audit trail records the node state' `
      ($deploySrc -match "elseif \(\`$n\.awaitingBind\)            \{ 'awaiting bind' \}") `
      "'not serving' is true and useless - it is the reason that gets looked up later"

Write-Host "`nrenewal does not report it as live either"
Check 'renew reads the outcome rather than only the exit code' `
      ($renewSrc -match '\$deployAwaiting = \[bool\]\(@\(\$dr\.results \| Where-Object \{ \$_\.awaitingBind \}\)\.Count\)') `
      'exit code alone cannot tell serving from pushed-but-unread, so both read as "issued and deployed"'
Check 'and says so in its own words' `
      ($renewSrc -match 'issued and deployed - waiting for a bind line') `
      'a renewal mail would report a certificate as live while nothing served it'
Check 'an unreadable outcome file falls back quietly' `
      ($renewSrc -match "catch \{ \`$null = \`$_ \}   # unreadable: fall back to the plainer wording") `
      'a missing file must not turn a good renewal into an error'

# --------------------------------------------------------------------------- #
Write-Host "`nno alert on the happy path, and still one on a real failure"
Check 'the alert is unchanged and keyed on ok' `
      ($deploySrc -match 'if \(-not \$entry\.ok -and -not \$CalledFromRenew\) \{') `
      'the condition moved, and the reason awaitingBind does not alert moved with it'
Check 'and why it no longer fires is written down' `
      ($deploySrc -match 'awaitingBind does not reach here: it leaves \$entry\.ok true, on') `
      'the next person to touch $entry.ok reintroduces the email without knowing'

# --------------------------------------------------------------------------- #
Write-Host "`nthe bind line handed over is a usable one"
Check 'needsBind carries the line to add' `
      ($libSrc -match 'bind <address>:443 ssl crt-list \$\(\$out\.path\) alpn h2,http/1\.1') `
      'telling somebody a bind is missing without saying what to write is half an answer'
Check 'and it names the path the API actually filed' `
      ($libSrc -match '\$out\.bindLine  = "bind <address>:443 ssl crt-list \$\(\$out\.path\)') `
      'the API rewrites dots in filenames, so the requested path is not always the real one'

Write-Host ""
if ($script:Failed) { Write-Host "$script:Failed CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
