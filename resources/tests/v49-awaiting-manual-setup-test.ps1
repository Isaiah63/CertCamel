<#
  A first deployment to a node that cannot edit crt-lists is waiting for setup,
  not failed - and says exactly what to paste.

  THE ROUTINE IT REPLACES. On HAPEE nodes whose Data Plane API answers 404 to the
  crt-list listing, standing a certificate up went: issue, download, copy the file
  to the node by hand, write the crt-list, edit the bind, reload, deploy again.
  Hand-copied files carried names the API never produces, which is how a real
  crt-list ended up naming wildcard.test.jurystatus.com.pem when the API would
  have stored wildcard_test_jurystatus_com.pem.

  It happened because the push-first order - certificate, then bind, then reload,
  since HAProxy will not reload against a bind naming a missing file - was only
  honoured on nodes Cert Camel could edit (awaitingBind, v35). A not-editable node
  never reached that state, so T3's "on disk but not in use" failed the run.

  What has to hold:

  1. THE STEPS ARE HANDED BACK READY TO PASTE: the crt-list line naming the file
     as the node stores it, and the bind line.
  2. THE ADDRESS IS FILLED ONLY FROM A CONFIGURED VERIFY ADDRESS. A guessed
     address pasted into a bind line listens somewhere nobody meant.
  3. "WAITING" IS AS NARROW AS AWAITING-BIND. Every other failure still fails.
  4. A CERTIFICATE THAT WAS SERVED BEFORE AND HAS STOPPED STILL FAILS. That is a
     broken deployment and must alert.

  Reads only. The node is a double, as in v31 and v48.

      powershell -ExecutionPolicy Bypass -File .\v49-awaiting-manual-setup-test.ps1
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

$script:Reply = @{}
$script:Seen  = @()
function Invoke-DataPlaneRequest {
    param(
        [string]$BaseUrl, [string]$User, [string]$Password,
        [string]$Method = 'GET', [string]$Path, $Body = $null,
        [string]$ContentType = 'application/json',
        [switch]$InsecureTls, [int]$TimeoutSeconds = 30
    )
    $null = $BaseUrl, $User, $Password, $Body, $ContentType, $InsecureTls, $TimeoutSeconds
    $script:Seen += "$Method $Path"
    foreach ($k in $script:Reply.Keys) {
        if ($Path -like "*$k*") {
            $v = $script:Reply[$k]
            if ($v -is [string]) { throw $v }
            return $v
        }
    }
    throw "$Method $Path -> HTTP 404: endpoint not found - check the URL and API version"
}

$list    = '/etc/hapee-3.3/ssl/wildcard.jurystatus.com-crt-list.txt'
$stored  = 'wildcard_test_jurystatus_com.pem'
$node404 = 'GET /v3/services/haproxy/storage/ssl_crt_lists -> HTTP 404: endpoint not found - check the URL and API version'
$info    = @{ api = @{ version = 'v3.3.8-ee1 480485d7' } }

# ----------------------------------------------------------------------- #
Write-Host "`nthe steps come back ready to paste"
$script:Reply = @{
    'storage/ssl_crt_lists'   = $node404
    'storage/ssl_certificates' = @(@{ storage_name = $stored; file = "/etc/hapee-3.3/ssl/$stored" })
    '/info'                   = $info
}
$s = Sync-HAProxyCrtList -BaseUrl 'https://node:5555' -User 'u' -Password 'p' -ApiVersion 'v3' `
         -CrtListPath $list -CertStorageName $stored
Check 'still not-editable, still ok' ($s.ok -and $s.action -eq 'not-editable') "ok=$($s.ok) action=$($s.action)"
Check 'the crt-list line is the file as the node stores it' ($s.entryLine -eq "/etc/hapee-3.3/ssl/$stored") `
      "got '$($s.entryLine)' - a hand-typed name is how a list points at a missing file"
Check 'the bind line reads that crt-list' ($s.bindLine -eq "bind <address>:443 ssl crt-list $list alpn h2,http/1.1") `
      "got '$($s.bindLine)'"
Check 'and nothing was written to get them' `
      (-not ($script:Seen | Where-Object { $_ -notmatch '^GET ' })) "calls: $($script:Seen -join ' | ')"

$script:Reply = @{ 'storage/ssl_crt_lists' = $node404; 'storage/ssl_certificates' = @(); '/info' = $info }
$f = Sync-HAProxyCrtList -BaseUrl 'https://node:5555' -User 'u' -Password 'p' -ApiVersion 'v3' `
         -CrtListPath $list -CertStorageName $stored
Check 'with no storage record it falls back to the list directory' ($f.entryLine -eq "/etc/hapee-3.3/ssl/$stored") `
      "got '$($f.entryLine)'"

# ----------------------------------------------------------------------- #
Write-Host "`nthe bind line's address"
$line = "bind <address>:443 ssl crt-list $list alpn h2,http/1.1"
Check 'filled from a configured verify address' `
      ((Format-BindLineAddress -BindLine $line -VerifyHost '10.199.77.24' -VerifyPort 443) -eq "bind 10.199.77.24:443 ssl crt-list $list alpn h2,http/1.1") `
      (Format-BindLineAddress -BindLine $line -VerifyHost '10.199.77.24' -VerifyPort 443)
Check 'with its port' `
      ((Format-BindLineAddress -BindLine $line -VerifyHost '10.0.0.5' -VerifyPort '8443') -match '^bind 10\.0\.0\.5:8443 ') `
      (Format-BindLineAddress -BindLine $line -VerifyHost '10.0.0.5' -VerifyPort '8443')
Check 'left as a placeholder with no verify address' `
      ((Format-BindLineAddress -BindLine $line -VerifyHost '' -VerifyPort 443) -eq $line) `
      'a guessed address pasted into a bind line listens somewhere nobody meant'
Check 'left as a placeholder for IPv6, rather than guess its bind syntax' `
      ((Format-BindLineAddress -BindLine $line -VerifyHost '2001:db8::1' -VerifyPort 443) -eq $line) `
      (Format-BindLineAddress -BindLine $line -VerifyHost '2001:db8::1' -VerifyPort 443)

# ----------------------------------------------------------------------- #
Write-Host "`nwhen a first deployment counts as waiting for setup"
function Node {
    param([bool]$Pushed = $true, [string]$Action = 'not-editable', [array]$Errors = @('on disk but not in use (status Unused)'))
    @{
        push    = @{ ok = $Pushed }
        crtList = @{ ok = $true; action = $Action; needsBind = $false }
        verify  = @($Errors | ForEach-Object { @{ ok = $false; role = 'identity'; error = $_ } })
    }
}

Check 'first time, not editable, on disk but not in use: waiting' `
      (Test-AwaitingManualSetup -Node (Node) -Proved 0 -PreviousTarget $null) 'the documented setup order reads as failed'
Check 'still waiting while a previous run was also only waiting' `
      (Test-AwaitingManualSetup -Node (Node) -Proved 0 -PreviousTarget ([pscustomobject]@{ ok = $false; awaitingBind = $true })) `
      'deploying again before finishing setup must not turn into a failure'

$mustFail = @(
    @('A CERTIFICATE SERVED BEFORE THAT HAS STOPPED', (Node), 0, ([pscustomobject]@{ ok = $true })),
    @('a wrong serial',                   (Node -Errors @('loaded serial 01, expected 02')), 0, $null),
    @('a certificate not present',        (Node -Errors @('not present in the API')), 0, $null),
    @('one not covering its names',       (Node -Errors @('loaded certificate does not cover test.jurystatus.com')), 0, $null),
    @('a wire probe served another cert', (Node -Errors @('10.199.77.24:443 served CN=other, not this')), 0, $null),
    @('one unused check beside a wrong serial', (Node -Errors @('on disk but not in use (status Unused)', 'loaded serial 01, expected 02')), 0, $null),
    @('a rejected upload',                (Node -Pushed $false), 0, $null),
    @('something proved it served',       (Node), 1, $null),
    @('a node Cert Camel CAN edit',       (Node -Action 'added'), 0, $null)
)
foreach ($case in $mustFail) {
    Check "still a failure: $($case[0])" `
          (-not (Test-AwaitingManualSetup -Node $case[1] -Proved $case[2] -PreviousTarget $case[3])) `
          'a state that forgives one thing is one bad edit away from forgiving everything'
}
Check 'still a failure: a previous record that could not be read' `
      (-not (Test-AwaitingManualSetup -Node (Node) -Proved 0 -PreviousTarget $null -PreviousUnreadable)) `
      'an unreadable record must make a first deployment fail loudly, never make a broken one quiet'
$noChecks = Node; $noChecks.verify = @()
Check 'and nothing is waiting when nothing was checked' `
      (-not (Test-AwaitingManualSetup -Node $noChecks -Proved 0 -PreviousTarget $null)) 'no evidence at all'

# ----------------------------------------------------------------------- #
Write-Host "`ndeploy.ps1 wires it in"
$src = Get-Content (Join-Path $appDir 'deploy.ps1') -Raw -Encoding UTF8
$readAt   = $src.IndexOf('$prevByTarget = @{}')
$decideAt = $src.IndexOf('Test-AwaitingManualSetup')
Check 'reads the previous deployment record' ($readAt -ge 0) 'the first-time guard has nothing to go on'
Check 'before deciding whether a node is waiting' ($readAt -ge 0 -and $decideAt -ge 0 -and $readAt -lt $decideAt) `
      "record read at $readAt, decision at $decideAt"
Check 'fills both printed bind lines through one helper' `
      (([regex]::Matches($src, 'Format-BindLineAddress')).Count -ge 2) 'the two bind lines would drift apart'
Check 'and prints the crt-list line to add' ($src -match 'entryLine') 'the step that is easiest to get wrong is missing'

Write-Host ""
if ($script:Failed) { Write-Host "$script:Failed CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
