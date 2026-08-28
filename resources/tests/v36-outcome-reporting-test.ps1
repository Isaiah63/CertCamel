<#
  Five ways the same deployment was described differently, and one silent rewrite.

  Four of these are the same shape: "awaiting bind" was added as a third
  deployment outcome, deploy.ps1's own log was taught to say it, and every OTHER
  surface kept deciding for itself from a two-state world. So one certificate
  could be green in the log, red on the Certificates page, "issued and deployed"
  in the renewal email above a node marked FAILED, and ", deployed" in the audit
  trail - all describing the same node, at the same moment.

  The fifth is worse because it is silent. Resolve-CrtListPath applies "a
  wildcard never shares a list with SAN certificates" to a per-certificate
  OVERRIDE as well as to a group template, so a filename an operator pinned by
  hand was rewritten to one no bind line reads. It then failed invisibly: the
  directory guard in Sync-HAProxyCrtList compares directories and the prefix
  only changes the filename, so the wrong file is created, the runtime does not
  know it, and the run reports the new "awaiting bind" state - exit 0, no alert.
  Two of this session's changes cancelling each other out.

  An override is not a template. It is one file named for one certificate by
  somebody who already knows which certificate it is, so there is nothing left
  to infer.

  Logic and source checks. Nothing is deployed and no node is contacted.

      powershell -ExecutionPolicy Bypass -File .\v36-outcome-reporting-test.ps1
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
$certJs    = Get-Content (Join-Path $srcDir 'assets/views/certificates.js') -Raw -Encoding UTF8
$cssSrc    = Get-Content (Join-Path $srcDir 'assets/app.css') -Raw -Encoding UTF8

$D = '/opt/vrrp-lab/certs'

# --------------------------------------------------------------------------- #
Write-Host "`na pinned crt-list is left exactly as pinned"
# The live case: settings.json pinned crt-list-wild.txt for a WILDCARD
# certificate, and the rule renamed it to wildcard-crt-list-wild.txt.
$pin = "$D/crt-list-wild.txt"
Check 'an override on a wildcard survives untouched' `
      ((Resolve-CrtListPath -Template $pin -CertId 'wildcard.example.com' -IsWildcard -FromOverride) -eq $pin) `
      "got $(Resolve-CrtListPath -Template $pin -CertId 'wildcard.example.com' -IsWildcard -FromOverride)"
Check 'and so does one on a SAN certificate' `
      ((Resolve-CrtListPath -Template "$D/mine.txt" -CertId 'example.com' -FromOverride) -eq "$D/mine.txt") `
      'nothing should touch an explicit choice'

Write-Host "`nbut the rule still governs a group template"
Check 'a shared template still splits the wildcard off' `
      ((Resolve-CrtListPath -Template "$D/crt-list.txt" -CertId 'wildcard.example.com' -IsWildcard) -eq "$D/wildcard-crt-list.txt") `
      "got $(Resolve-CrtListPath -Template "$D/crt-list.txt" -CertId 'wildcard.example.com' -IsWildcard) - the carve-out must not be lost while exempting overrides"
Check 'and a SAN certificate is unaffected either way' `
      ((Resolve-CrtListPath -Template "$D/crt-list.txt" -CertId 'example.com') -eq "$D/crt-list.txt") `
      'the rule was never about SAN certificates'
Check '{certId} still wins, override or not' `
      ((Resolve-CrtListPath -Template "$D/{certId}-crt-list.txt" -CertId 'wildcard.example.com' -IsWildcard -FromOverride) -eq "$D/wildcard.example.com-crt-list.txt") `
      'a token is an instruction, and an override does not cancel it'

Write-Host "`nand deploy decides which it has BEFORE resolving"
# The resolved string cannot say where it came from, so the question has to be
# asked of the binding while it is still in hand.
Check 'deploy asks the binding, not the result' `
      ($deploySrc -match '\$crtListPinned = \[bool\]\(\$binding -and \$binding\.overrides -and') `
      'without this the two cases are indistinguishable at the point of use'
Check 'and passes it through' ($deploySrc -match '-FromOverride:\$crtListPinned') `
      'the switch exists and nothing sets it'

# --------------------------------------------------------------------------- #
Write-Host "`nthe renewal email stops contradicting itself"
# Format-DeploymentSummary classified from $served. An awaiting-bind node HAS a
# failed verify record - deploy.ps1 appends one before it skips the hard-fail
# test - so $served was false and the ladder ended on FAILED, printed directly
# under "issued and deployed successfully".
Check 'the summary tests awaitingBind before it tests served' `
      ($libSrc -match "elseif \(\`$awaiting\)     \{ 'deployed, waiting for a bind line' \}") `
      'a node with a failed probe and no bind reading its list still reads as FAILED'
$aIdx = $libSrc.IndexOf("elseif (`$awaiting)")
$sIdx = $libSrc.IndexOf("elseif (`$served)")
Check 'in that order, which is the whole fix' ($aIdx -ge 0 -and $sIdx -ge 0 -and $aIdx -lt $sIdx) `
      "awaiting at $aIdx, served at $sIdx"
Check 'and it tolerates records written before the field existed' `
      ($libSrc -match "\`$awaiting = \[bool\]\(\`$n\.PSObject\.Properties\['awaitingBind'\]") `
      'an older deploy-*.json has no such property, and reading it directly would throw'

Write-Host "`nrenewal keeps the flag rather than only logging it"
Check 'it is stored on the entry' ($renewSrc -match '\$entry\.awaitingBind = \$deployAwaiting') `
      'computed, used for one log line, and thrown away - which is why two other surfaces still guessed'
Check 'the entry declares it' ($renewSrc -match 'files = @\(\); awaitingBind = \$false \}') `
      'absent-when-false leaves every reader guessing whether absent means false or means old'

Write-Host "`nthe audit trail says which kind of deployed"
Check 'it has an awaiting arm' `
      ($renewSrc -match ", deployed - awaiting a bind line'") `
      'the same physical outcome was audited as "awaiting bind" by deploy and ", deployed" by renew'

# --------------------------------------------------------------------------- #
Write-Host "`nthe Certificates page stops painting it red"
Check 'the persisted node record carries the state' `
      ($deploySrc -match 'awaitingBind = \[bool\]\$n\.awaitingBind') `
      'set in memory and dropped when the record was written, so no page could see it'
Check 'the node literal declares it' `
      ($deploySrc -match 'verifyHost = \$vt\.host; \$?verifyPort = \$vt\.port[\s\S]{0,200}awaitingBind = \$false') `
      'the one record shape written conditionally was the one missing the declaration'
Check 'the target record carries it too' `
      ($deploySrc -match 'ok = \[bool\]\$t\.ok; awaitingBind = \[bool\]\$t\.awaitingBind') `
      'the page reads per-target before it reads per-node'
Check 'ok still means proved to be serving' `
      ($deploySrc -match '# ok keeps its meaning: PROVED to be serving it') `
      'flipping ok to true would have been the easy fix and would have lied to every other reader'

Check 'the page separates waiting from broken' `
      ($certJs -match 'var waiting = \(rec\.nodes \|\| \[\]\)\.filter\(function\(n\)\{ return !n\.ok && n\.awaitingBind; \}\);') `
      'one filter for both means one colour for both'
Check 'and gives waiting its own class' ($certJs -match "cls = 'pending'") `
      'still red on the documented way to add a domain'
Check 'not the class that already means something else' `
      ($certJs -notmatch "waiting\.length[^;]*'pip warn'") `
      '.pip.warn means "deployed here but not assigned", which is more urgent and unrelated'
Check 'the class exists in the stylesheet' ($cssSrc -match '\.pip\.pending\{') `
      'an unknown class renders as an unstyled pip'
Check 'built from tokens that exist' `
      (($cssSrc -match '--blue:') -and ($cssSrc -match '--blue-bg:')) `
      'a colour from a token nothing defines is transparent'
Check 'the client-side rebuild carries it as well' `
      ($certJs -match 'awaitingBind: !!n\.awaitingBind') `
      'the same deployment would read blue through one path and red through the other'
Check 'the hover explains what to do' ($certJs -match 'Add the bind line the deployment log printed') `
      'a colour nobody can act on is decoration'

# --------------------------------------------------------------------------- #
Write-Host "`nthe tracker panel does not cry wolf over a stale sweep"
# Configuring the console's address splits it onto a certificate with a brand-new
# id, which no earlier sweep contains. Absence there proves nothing yet.
Check 'a not-caught-up forecast gets its own wording' `
      ($libSrc -match 'The last renewal sweep predates this certificate') `
      'the hard "nothing will renew it" wording fired on a race that clears itself tonight'
Check 'decided by the forecast state, not by guesswork' `
      ($libSrc -match "Get-RenewalForecastState -Forecast \`$forecast -WatchedHosts @\(Get-WatchedHostNames\)\)\.state -ne 'current'") `
      'without asking, the two cases are indistinguishable from inside this function'
Check 'and the hard wording survives for a current forecast' `
      ($libSrc -match 'is NOT in the renewal set - nothing will renew it') `
      'this row exists for exactly that case and must still say it plainly'

Write-Host ""
if ($script:Failed) { Write-Host "$script:Failed CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
