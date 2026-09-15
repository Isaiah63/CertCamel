<#
  A wildcard can say where it is served, so its own expiry can be tracked.

  THE GAP. check-ssl.ps1 never probes a "*.example.com" line - there is no host
  of that name to connect to - so the wildcard certificate never had a date of
  its own. It borrowed the zone's soonest expiry from some other name, and a
  zone that lists nothing but its wildcard had nothing to borrow: the
  certificate deployed, served, and showed no expiry anywhere. That was the work
  server's *.myflecitationtest.com exactly.

  The fix is a suffix on the wildcard's own line:

      *.example.com @ app.example.com
      *.example.com @ 10.199.77.21:443

  What has to hold, and what this pins:

  1. A LINE WITHOUT THE SUFFIX MEANS EXACTLY WHAT IT DID. Every existing
     domains.txt keeps working untouched.
  2. THE SNI IS CHOSEN, NOT COPIED. A single-label subdomain of the zone is sent
     as itself, because a server binding by hostname only answers correctly for
     a name it knows. An IP, the apex, a deeper name or a name outside the zone
     gets certcamel-probe.<apex>, which only this wildcard can match.
  3. THE SUFFIX NEVER BECOMES PART OF A NAME. It is where to look.
  4. A MEASURED DATE IS THE WILDCARD'S OWN, and wins over any borrowed one -
     including the apex's, which may belong to a different certificate.
  5. A FAILED PROBE LENDS NOTHING. The probe's coverage guard (in check-ssl.ps1)
     turns a wrong certificate into an error with no date; grouping must not
     manufacture one from it.
  6. RENEWAL IS UNAFFECTED. Which certificates exist does not change because a
     wildcard was probed.

  The probe itself - the handshake and the coverage guard - needs a live TLS
  endpoint, so it is proved end to end against the lab rather than here.

  Reads only. Every file the library would read is redirected into a sandbox.

      powershell -ExecutionPolicy Bypass -File .\v45-wildcard-check-address-test.ps1
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

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("cc-v45-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $sandbox
$script:DomainsFile  = Join-Path $sandbox 'domains.txt'
$script:SettingsFile = Join-Path $sandbox 'settings.json'
$script:SecretsFile  = Join-Path $sandbox 'secrets.xml'
Write-Host "sandbox: $sandbox"

try {
    # ----------------------------------------------------------------------- #
    Write-Host "`na line without the suffix means what it always did"
    Check 'a plain wildcard line is not a check address' `
          ($null -eq (Split-WildcardCheckAddress -Entry '*.example.com')) 'invented an address'
    Check 'a plain host is not a check address' `
          ($null -eq (Split-WildcardCheckAddress -Entry 'app.example.com')) 'treated a host as a wildcard'
    Check 'an @ on a plain host is not honoured' `
          ($null -eq (Split-WildcardCheckAddress -Entry 'app.example.com @ 10.0.0.1')) `
          'the suffix is only meaningful on a wildcard line'

    # ----------------------------------------------------------------------- #
    Write-Host "`nreading the address"
    $a = Split-WildcardCheckAddress -Entry '*.Example.COM @ App.Example.com'
    Check 'the wildcard is lower-cased' ($a -and $a.wildcard -eq '*.example.com') "got '$($a.wildcard)'"
    Check 'the apex is derived'         ($a -and $a.apex -eq 'example.com') "got '$($a.apex)'"
    Check 'the address is lower-cased'  ($a -and $a.checkHost -eq 'app.example.com') "got '$($a.checkHost)'"
    Check 'the port defaults to 443'    ($a -and $a.checkPort -eq 443) "got $($a.checkPort)"

    $b = Split-WildcardCheckAddress -Entry '*.example.com@10.199.77.21:8443'
    Check 'no spaces around @, with an IPv4 address and port' `
          ($b -and $b.checkHost -eq '10.199.77.21' -and $b.checkPort -eq 8443) "got $($b.checkHost):$($b.checkPort)"

    $c = Split-WildcardCheckAddress -Entry '*.example.com @ [2001:db8::1]:8443'
    Check 'a bracketed IPv6 literal with a port' `
          ($c -and $c.checkHost -eq '2001:db8::1' -and $c.checkPort -eq 8443) "got $($c.checkHost):$($c.checkPort)"

    $d = Split-WildcardCheckAddress -Entry '*.example.com @ 2001:db8::1'
    Check 'a bare IPv6 literal is taken whole, on 443' `
          ($d -and $d.checkHost -eq '2001:db8::1' -and $d.checkPort -eq 443) "got $($d.checkHost):$($d.checkPort)"

    Check 'a port out of range is refused' `
          ($null -eq (Split-WildcardCheckAddress -Entry '*.example.com @ lb.example.com:70000')) 'accepted port 70000'
    Check 'nothing after @ is refused' `
          ($null -eq (Split-WildcardCheckAddress -Entry '*.example.com @')) 'accepted an empty address'

    # ----------------------------------------------------------------------- #
    Write-Host "`nwhich name is sent as SNI"
    $sniCases = @(
        @('*.example.com @ app.example.com', 'app.example.com',
          'a real site: a server binding by hostname only answers correctly for a name it knows'),
        @('*.example.com @ 10.199.77.21',    'certcamel-probe.example.com',
          'an IP is not a name at all'),
        @('*.example.com @ example.com',     'certcamel-probe.example.com',
          'the apex is the name most likely claimed by a second certificate, and exact beats wildcard'),
        @('*.example.com @ a.b.example.com', 'certcamel-probe.example.com',
          '*.example.com covers one label, so a deeper name could only ever fetch another certificate'),
        @('*.example.com @ lb.other.net',    'certcamel-probe.example.com',
          'a name outside the zone is an address, not a name this certificate covers')
    )
    foreach ($case in $sniCases) {
        $r = Split-WildcardCheckAddress -Entry $case[0]
        Check "'$($case[0])' sends $($case[1])" ($r -and $r.sniName -eq $case[1]) `
              "got '$($r.sniName)' - $($case[2])"
    }

    # ----------------------------------------------------------------------- #
    Write-Host "`nthe suffix never becomes part of a name"
    Set-Content -LiteralPath $script:DomainsFile -Encoding UTF8 -Value @(
        '[Prod]'
        'app.example.com'
        '*.example.com @ lb.example.com:8443'
        'other.example.com:8443'
    )
    $watched = @(Get-WatchedHostNames)
    Check 'the wildcard is watched under its own name' ($watched -contains '*.example.com') ($watched -join ', ')
    Check 'no watched name carries the address' `
          (-not ($watched | Where-Object { $_ -match '@|lb\.example\.com' })) ($watched -join ', ')
    Check 'an ordinary host:port line still drops its port' ($watched -contains 'other.example.com') ($watched -join ', ')

    # ----------------------------------------------------------------------- #
    Write-Host "`ngrouping gives a probed wildcard its own date"
    # Built from the real defaults rather than a literal: Get-CertificateGroups
    # resolves a CA profile per certificate and throws without one.
    $settings = New-DefaultSettings
    $zones    = @{ zones = @(@{ zone = 'example.com'; providerId = 'p1'
                                providerLabel = 'Test'; plugin = 'Manual' }) }
    $soon     = (Get-Date).AddDays(20)
    $later    = (Get-Date).AddDays(80)

    function Get-Wildcard { param($Grp) @($Grp.certs | Where-Object { $_.kind -eq 'wildcard' })[0] }
    function Probed { param([datetime]$When)
        @{ host = '*.example.com'; ok = $true; notAfter = $When.ToString('o'); renewOnly = $true
           checkedAt = 'lb.example.com:443'; category = 'Prod' } }

    # A zone listing ONLY its wildcard - the work server's case, with nothing to borrow.
    $alone = Get-Wildcard (Get-CertificateGroups -Results @((Probed $later)) -Settings $settings -ZoneCache $zones)
    Check 'a wildcard-only zone still produces its certificate' ($null -ne $alone) 'no wildcard certificate'
    Check 'and it carries the date that was measured' `
          ($alone -and $alone.notAfter -and ([datetime]$alone.notAfter).Date -eq $later.Date) `
          "got '$($alone.notAfter)' - this is the row that showed nothing"

    # The measured date must win over anything borrowed, the apex's included.
    $mixed = @(
        @{ host = 'app.example.com'; ok = $true; notAfter = $soon.ToString('o'); renewOnly = $false; category = 'Prod' },
        @{ host = 'example.com';     ok = $true; notAfter = $soon.ToString('o'); renewOnly = $false; category = 'Prod' },
        (Probed $later)
    )
    $mixedGrp = Get-CertificateGroups -Results $mixed -Settings $settings -ZoneCache $zones
    $won = Get-Wildcard $mixedGrp
    Check 'the measured date wins over a borrowed or apex one' `
          ($won -and ([datetime]$won.notAfter).Date -eq $later.Date) `
          "got '$($won.notAfter)'; the zone's soonest, and the apex's, is $($soon.ToString('yyyy-MM-dd'))"

    # ----------------------------------------------------------------------- #
    Write-Host "`na date belongs to the wildcard it was read for, not to its zone"
    <#
      One DNS zone can carry several wildcards - *.jurystatus.com beside
      *.test.jurystatus.com is a real domains.txt. Keyed by zone, a date read at
      the deeper wildcard's address landed on the certificate for the other one:
      a confident, wrong date, which is the one thing the coverage guard exists
      to prevent. Keyed by the wildcard's own name, it cannot.
    #>
    $deeper = @(
        @{ host = '*.example.com'; ok = $false; notAfter = $null; renewOnly = $true; category = 'Prod' },
        @{ host = '*.test.example.com'; ok = $true; notAfter = $later.ToString('o'); renewOnly = $true
           checkedAt = 'lb.test.example.com:443'; category = 'Prod' }
    )
    $deeperGrp = Get-CertificateGroups -Results $deeper -Settings $settings -ZoneCache $zones
    $zoneWild  = @($deeperGrp.certs | Where-Object { $_.kind -eq 'wildcard' -and $_.certId -eq 'wildcard.example.com' })[0]
    Check "*.example.com does not take the date read for *.test.example.com" `
          ($zoneWild -and -not $zoneWild.notAfter) `
          "got '$($zoneWild.notAfter)' - that date belongs to a different certificate"

    # ----------------------------------------------------------------------- #
    Write-Host "`na failed probe lends nothing"
    $failedProbe = @{ host = '*.example.com'; ok = $false; notAfter = $null; renewOnly = $true
                      checkedAt = '10.0.0.1:443'; category = 'Prod'
                      error = '10.0.0.1:443 served CN=testlab.example.com, not *.example.com' }
    $noDate = Get-Wildcard (Get-CertificateGroups -Results @($failedProbe) -Settings $settings -ZoneCache $zones)
    Check 'the certificate still exists' ($null -ne $noDate) 'a failed check must not remove the certificate'
    Check 'but carries no date' ($noDate -and -not $noDate.notAfter) `
          "got '$($noDate.notAfter)' - a date here would be manufactured from a wrong certificate"

    # ----------------------------------------------------------------------- #
    Write-Host "`nan unprobed wildcard behaves exactly as before"
    $unprobed = @(
        @{ host = 'app.example.com'; ok = $true;  notAfter = $soon.ToString('o'); renewOnly = $false; category = 'Prod' },
        @{ host = '*.example.com';   ok = $false; notAfter = $null;                renewOnly = $true;  category = 'Prod' }
    )
    $unprobedGrp = Get-CertificateGroups -Results $unprobed -Settings $settings -ZoneCache $zones
    $old = Get-Wildcard $unprobedGrp
    Check 'it still borrows the zone soonest' ($old -and ([datetime]$old.notAfter).Date -eq $soon.Date) `
          "got '$($old.notAfter)'"

    # ----------------------------------------------------------------------- #
    Write-Host "`nrenewal is unaffected by a probe"
    $kindsUnprobed = (@($unprobedGrp.certs | ForEach-Object { "$($_.kind):$($_.certId)" }) | Sort-Object) -join ', '
    $probedToo     = @($unprobed[0], (Probed $later))
    $kindsProbed   = (@((Get-CertificateGroups -Results $probedToo -Settings $settings -ZoneCache $zones).certs |
                        ForEach-Object { "$($_.kind):$($_.certId)" }) | Sort-Object) -join ', '
    Check 'the same certificates exist whether or not the wildcard was probed' `
          ($kindsProbed -eq $kindsUnprobed) "unprobed: $kindsUnprobed | probed: $kindsProbed"
}
finally {
    Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:Failed) { Write-Host "$script:Failed CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
