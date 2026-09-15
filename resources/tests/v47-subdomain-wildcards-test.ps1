<#
  Several wildcards in one DNS zone are several certificates.

  THE BUG. A domains.txt carrying

      *.jurystatus.com
      *.test.jurystatus.com
      *.dev.jurystatus.com
      *.qa.jurystatus.com

  ordered ONE certificate - *.jurystatus.com, jurystatus.com - and the other
  three were never ordered. Grouping recorded only WHETHER a zone had a
  wildcard, keyed by the DNS zone every one of those lines resolves to, and
  always built the certificate as *.<zone>. Nothing reported the three it
  dropped.

  What has to hold:

  1. EACH WILDCARD IS ITS OWN CERTIFICATE, identified as wildcard.<base>.
  2. NOTHING ALREADY ISSUED CHANGES. The zone's own wildcard keeps the id
     wildcard.<zone> and exactly the names it had, so its folder, order and
     settings all still match.
  3. EVERY WILDCARD CARRIES ITS BASE, because *.test.example.com does not match
     test.example.com - the apex rule, one level down.
  4. A BASE COMES OFF THE SAN CERTIFICATE, or one name sits on two certificates
     of equal specificity and HAProxy only ever serves one.
  5. A ZONE WITH ONLY A DEEPER WILDCARD LEAVES ITS APEX ALONE - the apex moves
     only for *.<zone>.
  6. EVERY ID IS ONE renew.ps1 ACCEPTS, and a typed trailing dot never reaches it.

  Reads only. Grouping is exercised in memory against fixtures.

      powershell -ExecutionPolicy Bypass -File .\v47-subdomain-wildcards-test.ps1
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

# Built from the real defaults: grouping resolves a CA profile per certificate
# and throws without one.
$settings = New-DefaultSettings
$soon     = (Get-Date).AddDays(20)
$later    = (Get-Date).AddDays(80)

function Zones { param([string]$Zone) @{ zones = @(@{ zone = $Zone; providerId = 'p1'; providerLabel = 'DME'; plugin = 'DMEasy' }) } }
function Hst   { param([string]$Name) @{ host = $Name; ok = $true;  notAfter = $soon.ToString('o'); renewOnly = $false; category = 'Jury' } }
function Wild  { param([string]$Name) @{ host = $Name; ok = $false; notAfter = $null; renewOnly = $true; category = 'Jury' } }
function Cert  { param($Grp, [string]$Id) @($Grp.certs | Where-Object { $_.certId -eq $Id })[0] }
function Names { param($C) (@($C.names) | Sort-Object) -join ', ' }

# ----------------------------------------------------------------------- #
Write-Host "`nthe jurystatus.com domains.txt"
$jury = @(
    (Hst 'app.jurystatus.com'), (Hst 'test.jurystatus.com'), (Hst 'jurystatus.com'),
    (Wild '*.jurystatus.com'), (Wild '*.test.jurystatus.com'),
    (Wild '*.dev.jurystatus.com'), (Wild '*.qa.jurystatus.com')
)
$grp = Get-CertificateGroups -Results $jury -Settings $settings -ZoneCache (Zones 'jurystatus.com')
$ids = (@($grp.certs | ForEach-Object { $_.certId }) | Sort-Object) -join ', '

foreach ($id in @('wildcard.jurystatus.com', 'wildcard.test.jurystatus.com',
                  'wildcard.dev.jurystatus.com', 'wildcard.qa.jurystatus.com')) {
    Check "$id is ordered" ($null -ne (Cert $grp $id)) "certificates produced: $ids"
}

# ----------------------------------------------------------------------- #
Write-Host "`nnothing already issued changes"
$top = Cert $grp 'wildcard.jurystatus.com'
Check 'the zone wildcard keeps its id and exactly its names' `
      ($top -and (Names $top) -eq '*.jurystatus.com, jurystatus.com') "got '$(Names $top)'"
Check 'and still displays as itself' ($top -and $top.displayName -eq '*.jurystatus.com') "got '$($top.displayName)'"

# ----------------------------------------------------------------------- #
Write-Host "`nevery wildcard carries its base"
$test = Cert $grp 'wildcard.test.jurystatus.com'
Check '*.test.jurystatus.com carries test.jurystatus.com' `
      ($test -and (Names $test) -eq '*.test.jurystatus.com, test.jurystatus.com') "got '$(Names $test)'"
Check 'it is a wildcard certificate' ($test -and $test.kind -eq 'wildcard') "got kind '$($test.kind)'"
Check 'displayed as the wildcard, not the id' ($test -and $test.displayName -eq '*.test.jurystatus.com') "got '$($test.displayName)'"
$dev = Cert $grp 'wildcard.dev.jurystatus.com'
Check '*.dev.jurystatus.com carries dev.jurystatus.com, never listed as a host' `
      ($dev -and (Names $dev) -eq '*.dev.jurystatus.com, dev.jurystatus.com') "got '$(Names $dev)'"

# ----------------------------------------------------------------------- #
Write-Host "`nbase names come off the SAN certificate"
$san = Cert $grp 'jurystatus.com'
Check 'the SAN certificate still exists' ($null -ne $san) "certificates produced: $ids"
Check 'it keeps an ordinary host' ($san -and @($san.names) -contains 'app.jurystatus.com') "got '$(Names $san)'"
Check 'it no longer carries test.jurystatus.com' ($san -and @($san.names) -notcontains 'test.jurystatus.com') `
      "got '$(Names $san)' - one name on two certificates, and HAProxy serves only one"
Check 'nor the apex, as before' ($san -and @($san.names) -notcontains 'jurystatus.com') "got '$(Names $san)'"
Check 'and it says which names moved' `
      ($san -and @($san.movedToWildcard) -contains 'test.jurystatus.com' -and @($san.movedToWildcard) -contains 'jurystatus.com') `
      "got '$(@($san.movedToWildcard) -join ', ')'"

# ----------------------------------------------------------------------- #
Write-Host "`nevery id is one renew.ps1 accepts"
foreach ($c in @($grp.certs)) {
    Check "'$($c.certId)' passes Test-SafeCertName" (Test-SafeCertName $c.certId) `
          'renew.ps1 rejects -Zone values that fail it, so this certificate could never be ordered'
}

# ----------------------------------------------------------------------- #
Write-Host "`nduplicates and a typed trailing dot"
$messy = @((Wild '*.test.jurystatus.com'), (Wild '*.test.jurystatus.com'), (Wild '*.dev.jurystatus.com.'))
$messyGrp = Get-CertificateGroups -Results $messy -Settings $settings -ZoneCache (Zones 'jurystatus.com')
Check 'a repeated line is one certificate' `
      (@($messyGrp.certs | Where-Object { $_.certId -eq 'wildcard.test.jurystatus.com' }).Count -eq 1) `
      ((@($messyGrp.certs | ForEach-Object { $_.certId })) -join ', ')
Check 'a trailing dot does not reach the id' ($null -ne (Cert $messyGrp 'wildcard.dev.jurystatus.com')) `
      ((@($messyGrp.certs | ForEach-Object { $_.certId })) -join ', ')
Check 'nor the names' `
      (-not (@($messyGrp.certs | ForEach-Object { $_.names }) | Where-Object { $_.EndsWith('.') })) `
      ((@($messyGrp.certs | ForEach-Object { $_.names })) -join ', ')

# ----------------------------------------------------------------------- #
Write-Host "`na zone with only a deeper wildcard"
$deepOnly = Get-CertificateGroups -Results @((Hst 'example.com'), (Hst 'www.example.com'), (Wild '*.qa.example.com')) `
                -Settings $settings -ZoneCache (Zones 'example.com')
$apexSan = Cert $deepOnly 'example.com'
Check 'keeps its apex on the SAN certificate' ($apexSan -and @($apexSan.names) -contains 'example.com') `
      "got '$(Names $apexSan)' - the apex moves only for *.example.com"
Check 'does not claim the apex is on a wildcard' ($apexSan -and -not $apexSan.apexOnWildcard) 'apexOnWildcard is set'
Check 'orders the deeper wildcard' ($null -ne (Cert $deepOnly 'wildcard.qa.example.com')) `
      ((@($deepOnly.certs | ForEach-Object { $_.certId })) -join ', ')
Check 'and invents no *.example.com' ($null -eq (Cert $deepOnly 'wildcard.example.com')) 'a wildcard nobody asked for'

# ----------------------------------------------------------------------- #
Write-Host "`na zone with only its own wildcard is exactly as before"
$plain = Get-CertificateGroups -Results @((Hst 'www.example.com'), (Wild '*.example.com')) `
             -Settings $settings -ZoneCache (Zones 'example.com')
$plainWild = Cert $plain 'wildcard.example.com'
Check 'wildcard.example.com, *.example.com + example.com' `
      ($plainWild -and (Names $plainWild) -eq '*.example.com, example.com') "got '$(Names $plainWild)'"
Check 'and still one wildcard certificate' (@($plain.certs | Where-Object { $_.kind -eq 'wildcard' }).Count -eq 1) `
      ((@($plain.certs | ForEach-Object { $_.certId })) -join ', ')

# ----------------------------------------------------------------------- #
Write-Host "`na probed date lands on the wildcard it was read for"
$probed = @(
    (Hst 'app.jurystatus.com'), (Wild '*.jurystatus.com'),
    @{ host = '*.test.jurystatus.com'; ok = $true; notAfter = $later.ToString('o'); renewOnly = $true
       checkedAt = 'lb.test.jurystatus.com:443'; category = 'Jury' }
)
$pGrp = Get-CertificateGroups -Results $probed -Settings $settings -ZoneCache (Zones 'jurystatus.com')
$pTest = Cert $pGrp 'wildcard.test.jurystatus.com'
$pTop  = Cert $pGrp 'wildcard.jurystatus.com'
Check '*.test.jurystatus.com gets the date read for it' `
      ($pTest -and $pTest.notAfter -and ([datetime]$pTest.notAfter).Date -eq $later.Date) "got '$($pTest.notAfter)'"
Check '*.jurystatus.com does not' `
      ($pTop -and -not ($pTop.notAfter -and ([datetime]$pTop.notAfter).Date -eq $later.Date)) `
      "got '$($pTop.notAfter)' - that date belongs to a different certificate"

Write-Host ""
if ($script:Failed) { Write-Host "$script:Failed CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
