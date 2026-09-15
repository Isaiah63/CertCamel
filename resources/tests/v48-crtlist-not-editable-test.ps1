<#
  A crt-list Cert Camel cannot edit is still a crt-list it can verify.

  THE CONTRADICTION. DRTESTHAPEE - HAPEE, Data Plane v3.3.8-ee1 - answers 404 to
  GET storage/ssl_crt_lists. Cert Camel read that as "no crt-list API", and the
  one group setting it depends on meant two things at once:

    - WHICH crt-list a certificate is served from, which the Load balancers
      page needs to match a frontend, and
    - an instruction to EDIT that list on every deploy, which that node cannot.

  So the operator could have one of two wrong outcomes:

    crt-list set    deploy tries to edit, gets the 404, and reports the whole
                    deployment FAILED - though T1 uploaded it and T3 proved the
                    serial loaded and in use.
    "Not used"      deploys pass, but the page loses track: the certificate reads
                    UNKNOWN and the frontend serving it is filed under "Not
                    managed here".

  What has to hold now:

  1. A 404 LISTING IS A NOTE, NOT A FAILURE. Sync-HAProxyCrtList returns ok with
     action 'not-editable', carrying what the node said, and writes nothing.
  2. A REAL ERROR IS STILL AN ERROR. Only the 404 is reinterpreted.
  3. THE 404's OWN WORDS ARE KEPT, not replaced with a guess about versions.
  4. THE PAGE IS RIGHT ON SUCH A NODE once the crt-list is set: matching reads the
     frontend's bind from the configuration API, which works there, so the
     certificate is served and the frontend is not "not managed here".
  5. DEPLOY NEVER CALLS IT "ALREADY REFERENCED". That wording sits in the branch
     a not-editable result would otherwise fall into.

  Reads only. The node is a double: Invoke-DataPlaneRequest redefined after the
  dot-source, as v31 does, answering from a table.

      powershell -ExecutionPolicy Bypass -File .\v48-crtlist-not-editable-test.ps1
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

# What the stubbed node answers, keyed by a fragment of the path. A string reply
# means "fail this way", exactly as Invoke-DataPlaneRequest itself throws.
$script:Reply = @{}
$script:Seen  = @()

# Defined after the dot-source, so this is the one the library resolves to.
# Binds -Method, -Body and -ContentType as well as what v31's double takes:
# Sync-HAProxyCrtList sends them, and a double that cannot bind its caller's
# arguments fails before it ever answers.
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

$crtList = '/etc/hapee-3.3/ssl/wildcard.myflecitationtest.com-crt-list.txt'
$node404 = "GET /v3/services/haproxy/storage/ssl_crt_lists -> HTTP 404: endpoint not found - check the URL and API version (path /v3/services/haproxy/storage/ssl_crt_lists was not found)"
$info    = @{ api = @{ version = 'v3.3.8-ee1 480485d7' } }

# ----------------------------------------------------------------------- #
Write-Host "`nthe listing answers 404"
$why = $null
$script:Reply = @{ 'storage/ssl_crt_lists' = $node404; '/info' = $info }
$lists = Get-DataPlaneCrtLists -BaseUrl 'https://node:5555' -User 'u' -Password 'p' -ApiVersion 'v3' -Detail ([ref]$why)
Check 'it is reported as unavailable, not as an empty list' ($null -eq $lists) "got $(@($lists).Count) list(s)"
Check "and the node's own words come back" ($why -match 'HTTP 404' -and $why -match 'was not found') "got '$why'"

$quiet = Get-DataPlaneCrtLists -BaseUrl 'https://node:5555' -User 'u' -Password 'p' -ApiVersion 'v3'
Check 'callers that do not ask for the detail are unaffected' ($null -eq $quiet) 'the optional -Detail changed the default'

# ----------------------------------------------------------------------- #
Write-Host "`nsyncing to a node that cannot edit crt-lists"
$script:Seen = @()
$sync = Sync-HAProxyCrtList -BaseUrl 'https://node:5555' -User 'u' -Password 'p' -ApiVersion 'v3' `
            -CrtListPath $crtList -CertStorageName 'wildcard_myflecitationtest_com.pem'
Check 'IS NOT A FAILED DEPLOYMENT' ($sync.ok -eq $true) "ok = $($sync.ok), error = $($sync.error)"
Check 'says exactly what it was' ($sync.action -eq 'not-editable') "action = '$($sync.action)'"
Check 'carries no error' ([string]::IsNullOrEmpty([string]$sync.error)) "error = '$($sync.error)'"
Check 'quotes what the node said' ([string]$sync.note -match 'HTTP 404') "note = '$($sync.note)'"
Check 'names the build, without inventing a version rule' `
      (([string]$sync.note -match 'v3\.3\.8-ee1') -and ([string]$sync.note -notmatch '3\.1 does not')) "note = '$($sync.note)'"
Check 'and writes nothing to the node' `
      (-not ($script:Seen | Where-Object { $_ -notmatch '^GET ' -or $_ -match '/entries' })) `
      "calls made: $($script:Seen -join ' | ')"

# ----------------------------------------------------------------------- #
Write-Host "`na real error is still an error"
$script:Reply = @{ 'storage/ssl_crt_lists' = 'GET /v3/services/haproxy/storage/ssl_crt_lists -> HTTP 500: internal server error'; '/info' = $info }
$broken = Sync-HAProxyCrtList -BaseUrl 'https://node:5555' -User 'u' -Password 'p' -ApiVersion 'v3' `
              -CrtListPath $crtList -CertStorageName 'wildcard_myflecitationtest_com.pem'
Check 'a 500 still fails' ($broken.ok -eq $false) "ok = $($broken.ok)"
Check 'and is not dressed up as not-editable' ($broken.action -ne 'not-editable') "action = '$($broken.action)'"
Check 'and says why' ([string]$broken.error -match 'HTTP 500') "error = '$($broken.error)'"

# ----------------------------------------------------------------------- #
Write-Host "`nthe Load balancers page on such a node"
function New-Recon {
    param([string]$CrtListSetting)
    $target = @{ id = 'tDR'; label = 'DR-TEST Haproxy'; type = 'haproxy-dataplane'
                 nodes = @(@{ name = 'DRTESTHAPEE'; url = 'https://10.199.77.21:5555'; verifyHost = '' })
                 args = @{ user = 'certcamel'; insecureTls = $true; crtList = $CrtListSetting; verifyPort = '443'; remoteName = '' } }
    $settings = @{ targets = @($target)
                   certs   = @{ 'wildcard.myflecitationtest.com' = @{ targets = @('tDR') } } }
    # What check-lb.ps1 records for DRTESTHAPEE: the configuration API answers,
    # so the frontend and its bind are known - the storage crt-list API does not.
    $cache = @{ targets = @(@{ id = 'tDR'; nodes = @(@{
        name = 'DRTESTHAPEE'; reachable = $true; frontendError = $null
        crtLists = @(); crtListApi = $false
        frontends = @(@{ name = 'http_front_drmyflecitationtest'; binds = @(@{
            ssl = $true; address = '10.199.77.24'; port = 443; crtList = $crtList; crtDir = $null }) })
    }) }) }
    $groups = @(@{ certId = 'wildcard.myflecitationtest.com'; displayName = '*.myflecitationtest.com'; wildcard = $true })
    return @(Get-CrtListReconciliation -Settings $settings -Cache $cache -Groups $groups)[0]
}

$set = New-Recon -CrtListSetting '/etc/hapee-3.3/ssl/{certId}-crt-list.txt'
$c   = @($set.certificates)[0]
Check 'with the crt-list set, the certificate is SERVED' ($c -and $c.state -eq 'served') "state = '$($c.state)', note = '$($c.note)'"
Check 'through the frontend that actually binds it' `
      ($c -and @($c.frontends | Where-Object { $_.frontend -eq 'http_front_drmyflecitationtest' }).Count -eq 1) `
      "frontends: $(@($c.frontends | ForEach-Object { $_.frontend }) -join ', ')"
Check 'and that frontend is not "not managed here"' (@($set.unmanaged).Count -eq 0) `
      "unmanaged: $(@($set.unmanaged | ForEach-Object { $_.frontend }) -join ', ')"
Check 'none of which needed the crt-list API' ($c -and $c.crtList -eq $crtList) "resolved path = '$($c.crtList)'"

$unset = New-Recon -CrtListSetting ''
$u     = @($unset.certificates)[0]
Check '"Not used" is what loses track of it (the reason to set it back)' `
      ($u -and $u.state -eq 'unknown' -and @($unset.unmanaged).Count -eq 1) `
      "state = '$($u.state)', unmanaged = $(@($unset.unmanaged).Count)"

# ----------------------------------------------------------------------- #
Write-Host "`ndeploy handles it before it can say `"already referenced`""
$deploySrc = Get-Content (Join-Path $appDir 'deploy.ps1') -Raw -Encoding UTF8
$handled   = $deploySrc.IndexOf("action -eq 'not-editable'")
$already   = $deploySrc.IndexOf('already referenced')
Check 'deploy.ps1 has a not-editable branch' ($handled -ge 0) 'a not-editable result would fall into the wrong branch'
Check 'checked before the "already referenced" wording' ($handled -ge 0 -and $already -ge 0 -and $handled -lt $already) `
      "not-editable at $handled, 'already referenced' at $already"
Check 'and the pre-sync line no longer promises the list is kept in step' ($deploySrc -notmatch 'crt-list is kept in step') `
      'that is false on a node that cannot edit crt-lists'

Write-Host ""
if ($script:Failed) { Write-Host "$script:Failed CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
