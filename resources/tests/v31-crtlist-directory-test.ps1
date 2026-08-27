<#
  The crt-list directory, checked while somebody is still looking at it.

  A crt-list is created by uploading a FILENAME - the Data Plane API alone
  decides which directory the file lands in. So a crt-list configured in any
  other directory is a file no bind line will ever read, and the certificate
  pushed alongside it is served by nothing.

  Sync-HAProxyCrtList already refuses that case with a good message. The problem
  was WHEN: the refusal arrives mid-deploy, days after the path was typed on the
  Settings page, where the answer was knowable at the time. A first install hit
  exactly this - the hint's example path, /etc/haproxy/ssl/, was copied into a
  lab whose API keeps everything in /opt/vrrp-lab/certs, and nothing said so
  until a deployment failed.

  Two halves here. Get-HAProxyStorageDir, which answers "where can this API
  actually write", and the save path, which asks it and warns.

  A WARNING, never a rejection. The refusal message itself offers "or create the
  file on the node by hand", which is a real configuration - blocking the save
  would take it away.

  All stubbed. No node is contacted and nothing is written.

      powershell -ExecutionPolicy Bypass -File .\v31-crtlist-directory-test.ps1
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

# What the stubbed API will answer with, per storage path.
$script:Reply = @{}
$script:Seen  = @()

# Replaces the real one for the rest of this file: defined after the dot-source,
# so this definition is the one Get-HAProxyStorageDir resolves to.
function Invoke-DataPlaneRequest {
    # Only the parameters Get-HAProxyStorageDir actually passes: a double has to
    # bind what its caller sends and nothing more.
    param(
        [string]$BaseUrl, [string]$User, [string]$Password, [string]$Path,
        [switch]$InsecureTls, [int]$TimeoutSeconds = 10
    )
    # Bound so the call succeeds, unread on purpose - the path is the only thing
    # that decides an answer here.
    $null = $BaseUrl, $User, $Password, $InsecureTls, $TimeoutSeconds

    $script:Seen += $Path
    foreach ($k in $script:Reply.Keys) {
        if ($Path -like "*$k*") {
            $v = $script:Reply[$k]
            if ($v -is [string]) { throw $v }   # a string reply means "fail this way"
            return $v
        }
    }
    throw 'HTTP 404 Not Found'
}

# NOT named Dir: that is a built-in alias for Get-ChildItem, and the alias wins
# over a function defined here - every call tried to list a directory named
# "System.Collections.Hashtable".
function Probe { param($Reply)
    $script:Reply = $Reply
    $script:Seen  = @()
    return Get-HAProxyStorageDir -BaseUrl 'https://node:5555' -User 'u' -Password 'p' -ApiVersion 'v3'
}

# --------------------------------------------------------------------------- #
Write-Host "`nthe directory comes from what the API has filed"
$r = Probe @{ 'ssl_certificates' = @(
              @{ storage_name = 'a.pem'; file = '/opt/vrrp-lab/certs/a.pem' },
              @{ storage_name = 'b.pem'; file = '/opt/vrrp-lab/certs/b.pem' }) }
Check 'it answers'            $r.ok  "error: $($r.error)"
Check 'with the directory'    ($r.dir -eq '/opt/vrrp-lab/certs') "got '$($r.dir)'"
Check 'and says where from'   ($r.source -eq 'certificates') "got '$($r.source)'"
Check 'the basename is gone'  ($r.dir -notmatch '\.pem$') "got '$($r.dir)'"

# --------------------------------------------------------------------------- #
Write-Host "`ncertificates are asked about before crt-lists"
# Deliberate: Sync-HAProxyCrtList derives the directory it will accept from the
# certificate it just pushed. Agreeing with that is the entire point, so a node
# whose two stores disagree must follow the certificates.
$r = Probe @{ 'ssl_certificates' = @(@{ file = '/certs/a.pem' })
            'ssl_crt_lists'    = @(@{ file = '/somewhere/else/list.txt' }) }
Check 'the certificate directory wins' ($r.dir -eq '/certs') "got '$($r.dir)'"
Check 'and crt-lists were not needed'  (-not (@($script:Seen) -match 'ssl_crt_lists')) `
      "asked for: $(@($script:Seen) -join ', ')"

# --------------------------------------------------------------------------- #
Write-Host "`na node with lists but no certificates yet"
$r = Probe @{ 'ssl_certificates' = @()
            'ssl_crt_lists'    = @(@{ file = '/etc/haproxy/ssl/list.txt' }) }
Check 'falls back to the crt-lists' ($r.dir -eq '/etc/haproxy/ssl') "got '$($r.dir)'"
Check 'and says so'                 ($r.source -eq 'crt-lists') "got '$($r.source)'"

# --------------------------------------------------------------------------- #
Write-Host "`nan API build with no crt-list routes at all"
# 3.1 answers 404 for these. That is "try the next thing", not a broken node -
# reporting it as an error would blame the operator for their API version.
$r = Probe @{ 'ssl_certificates' = @(@{ file = '/certs/a.pem' }) }
Check 'a 404 on the other store is not an error' ($r.ok -and -not $r.error) `
      "ok=$($r.ok) error=$($r.error)"

# --------------------------------------------------------------------------- #
Write-Host "`nnothing filed anywhere"
$r = Probe @{ 'ssl_certificates' = @(); 'ssl_crt_lists' = @() }
Check 'it does not answer'   (-not $r.ok) "claimed '$($r.dir)'"
Check 'and explains why'     ($r.error -match 'no certificates or crt-lists') "said: $($r.error)"

Write-Host "`nrecords the API filed without a path"
$r = Probe @{ 'ssl_certificates' = @(@{ storage_name = 'a.pem' }) }
Check 'a record with no file is skipped' (-not $r.ok) "derived '$($r.dir)' from nothing"

# --------------------------------------------------------------------------- #
Write-Host "`nan unreachable node is a result, not an exception"
# This is used to VALIDATE a setting. A node being down must never be the reason
# somebody cannot save one.
$threw = $false
try { $r = Probe @{ 'ssl_certificates' = 'HTTP 502 Bad Gateway' } }
catch { $threw = $true }
Check 'it does not throw'  (-not $threw) 'a down node would stop the settings page saving'
Check 'it reports not-ok'  (-not $r.ok)  "claimed '$($r.dir)'"
Check 'and carries the reason' ($r.error -match '502') "said: $($r.error)"

# --------------------------------------------------------------------------- #
Write-Host "`na wildcard never shares a list with SAN certificates"
# Two structures the setting picks between, and one rule that holds under both.
# Under the per-domain template it falls out of the certIds themselves; under a
# shared one nothing would separate them, because a template with nothing to
# substitute resolves every certificate to the same file.
$D = '/opt/vrrp-lab/certs'
$shared = "$D/crt-list.txt"
$perDom = "$D/{certId}-crt-list.txt"

Check 'shared: a SAN certificate lands in the one list' `
      ((Resolve-CrtListPath -Template $shared -CertId 'example.com') -eq "$D/crt-list.txt") `
      "got $(Resolve-CrtListPath -Template $shared -CertId 'example.com')"
Check 'shared: the wildcard does NOT' `
      ((Resolve-CrtListPath -Template $shared -CertId 'wildcard.example.com' -IsWildcard) -eq "$D/wildcard-crt-list.txt") `
      "got $(Resolve-CrtListPath -Template $shared -CertId 'wildcard.example.com' -IsWildcard) - a plain string replace put it in with the rest"
Check 'and the prefix goes on the FILENAME, not the directory' `
      ((Resolve-CrtListPath -Template $shared -CertId 'w' -IsWildcard) -notmatch '/wildcard-opt/') `
      'a sibling directory is one the API cannot write to'

Check 'per-domain: each zone gets its own' `
      ((Resolve-CrtListPath -Template $perDom -CertId 'example.com') -eq "$D/example.com-crt-list.txt") `
      "got $(Resolve-CrtListPath -Template $perDom -CertId 'example.com')"
Check 'per-domain: the wildcard already differs, and is not double-prefixed' `
      ((Resolve-CrtListPath -Template $perDom -CertId 'wildcard.example.com' -IsWildcard) -eq "$D/wildcard.example.com-crt-list.txt") `
      "got $(Resolve-CrtListPath -Template $perDom -CertId 'wildcard.example.com' -IsWildcard)"

Check 'an unset template stays unset' `
      ((Resolve-CrtListPath -Template '' -CertId 'example.com') -eq '') `
      'an empty setting must not become a filename'
Check 'a bare filename with no directory still gets the rule' `
      ((Resolve-CrtListPath -Template 'crt-list.txt' -CertId 'w' -IsWildcard) -eq 'wildcard-crt-list.txt') `
      'the path form must not decide whether the rule applies'

# Read here rather than at the top: these two checks are about acme-lib's own
# source, and the first of them is a -notmatch. An undefined variable would
# satisfy that vacuously and report ok while proving nothing - which is
# exactly what it did until its sibling failed and gave it away.
$libSrc = Get-Content (Join-Path $srcDir 'acme-lib.ps1') -Raw -Encoding UTF8

Check 'the load balancer page reads paths the same way it writes them' `
      ($libSrc -notmatch "\`$path = \`$path\.Replace\('\{certId\}', \`$certId\)") `
      'Get-CrtListReconciliation kept its own bare Replace, so under a shared template it hunted a wildcard in crt-list.txt while deploy had put it in wildcard-crt-list.txt - and reported a working deployment as never going to be served'
Check 'and it passes the wildcard flag through' `
      ($libSrc -match '-CertId \$certId -IsWildcard:\(\[bool\]\$g\.wildcard\)') `
      'without it every certificate resolves as a SAN one and the rule is inert on that page'
Check 'deploy asks for the rule rather than replacing inline' `
      ((Get-Content (Join-Path $srcDir 'deploy.ps1') -Raw -Encoding UTF8) -match 'Resolve-CrtListPath `') `
      'a bare .Replace there is what let the wildcard share a list'

# --------------------------------------------------------------------------- #
Write-Host "`nthe save path warns rather than refusing"
$saveSrc = Get-Content (Join-Path $srcDir 'serve.ps1') -Raw -Encoding UTF8

Check 'the check runs on save' ($saveSrc -match 'Get-HAProxyStorageDir') `
      'the mismatch is only found mid-deploy again'
Check 'it returns warnings, not an error' ($saveSrc -match 'return @\{ ok = \$true; warnings = @\(\$warnings\) \}') `
      'a rejection would remove the documented "create the file by hand" option'
Check 'the old path is captured before the payload is applied' `
      ($saveSrc -match '\$crtListWas\[\[string\]\$t\.id\] = \[string\]\(Get-TargetArg') `
      'settings is mutated in place, so a snapshot taken later is the NEW value and nothing ever looks changed'
Check 'unchanged crt-lists are not probed' `
      ($saveSrc -match '\$crtListWas\[\[string\]\$t\.id\] -eq \$want\) \{ continue \}') `
      'every unrelated settings save would pay for a network round trip'
Check 'one reachable node answers for the pair' ($saveSrc -match 'break   # the pair is configured alike') `
      'both nodes probed on every save, for an answer that cannot differ'
Check 'an unreachable node is skipped quietly' ($saveSrc -match 'catch \{ continue \}   # unreachable node') `
      'a node being down would produce a warning about the wrong thing'

Write-Host "`nthe page shows what it was told"
$uiSrc = Get-Content (Join-Path $srcDir 'assets/views/settings.js') -Raw -Encoding UTF8
Check 'save reads the warnings back' ($uiSrc -match 'saved && saved\.warnings') `
      'the server warns and the page throws it away'
Check 'and shows them instead of the success line' `
      ($uiSrc -match "setStatus\('Saved, but: ' \+ warn\.join") `
      'two writes to one status area means the later one wins and nobody sees this'

Write-Host ""
if ($script:Failed) { Write-Host "$script:Failed CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
