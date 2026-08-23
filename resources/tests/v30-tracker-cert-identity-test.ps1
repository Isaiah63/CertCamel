<#
  The console's certificate, and the folder it happens to sit in.

  certs\<certId>\ is named from the grouping id at the moment of issue, and that
  id is not fixed for life. Configuring the console's address moves its name off
  the zone's SAN certificate and onto a certificate of its own, with a new id -
  while the file stays in the folder it was written to. From then on the folder
  name and the certificate's identity disagree, and two things went wrong:

    THE NAME. Settings > Tracker address reported the folder, so a console
    serving tracker.example.com announced a certificate for "example.com" - a
    bare domain the operator had never asked about.

    THE ALARM. The renewal row looked its certId up in the last sweep by folder
    name, found the sweep listing it under the new id, and declared it NOT in
    the renewal set. That row exists to catch the one failure nothing else can
    warn about - the console's own certificate quietly ceasing to renew, where
    the thing that would tell you is the thing that goes down. A false positive
    there is worse than no row at all, because it teaches people to ignore it.

  The cause is an ordering bug in setup: renew.ps1 was invoked before
  web.hostname was saved, so at issue time Get-CertificateGroups could not know
  the console had an address and left the name on the zone's SAN order. Both
  halves are covered here - the matching that must survive the mismatch, and the
  ordering that must stop creating it.

  Runs against a COPY of acme-lib.ps1 in a scratch folder, so certs\ and jobs\
  land under scratch\ and the operator's install is never touched. Uses .invalid
  hostnames, which can never be real.

      powershell -ExecutionPolicy Bypass -File .\v30-tracker-cert-identity-test.ps1
#>

$ErrorActionPreference = 'Stop'
$repo   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
# Deliberately not named $appDir. acme-lib.ps1 sets $script:AppDir to its OWN
# folder, and PowerShell variable names are case-insensitive, so dot-sourcing
# the sandbox copy silently repointed it at the sandbox - and the source
# checks at the end went looking for renew-due.ps1 in a folder holding one
# file.
$srcDir = Join-Path $repo 'resources'

$sandbox    = Join-Path $env:TEMP ('camel-certid-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$sandboxRes = Join-Path $sandbox 'resources'
New-Item -ItemType Directory -Path $sandboxRes -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $srcDir 'acme-lib.ps1') -Destination (Join-Path $sandboxRes 'acme-lib.ps1') -Force
. (Join-Path $sandboxRes 'acme-lib.ps1')

$script:Failed = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    if ($Ok) { Write-Host "  ok   $Name" -ForegroundColor Green }
    else     { Write-Host "  FAIL $Name  -- $Detail" -ForegroundColor Red; $script:Failed++ }
}

$tag         = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$zone        = "$tag.invalid"        # what the folder is (wrongly) named
$trackerHost = "tracker.$zone"       # what the certificate is actually for
$certStore   = $null

try {
    New-TrackerDirectories

    # --- the misfiled state, built exactly as the bug produces it ----------- #
    # One certificate, one name - tracker.<zone> - sitting in certs\<zone>\.
    $certStore = New-SelfSignedCertificate -Subject "CN=$trackerHost" -DnsName $trackerHost `
                    -KeyExportPolicy Exportable -KeyLength 2048 -KeyAlgorithm RSA -HashAlgorithm SHA256 `
                    -NotBefore (Get-Date).AddMinutes(-5) -NotAfter (Get-Date).AddDays(60) `
                    -CertStoreLocation 'Cert:\CurrentUser\My'

    $misfiled = Join-Path $script:CertsDir $zone
    New-Item -ItemType Directory -Path $misfiled -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $misfiled 'cert.cer'), $certStore.Export('Cert'))
    # Both files, or the folder is invisible to Find-CertificateForHost.
    [IO.File]::WriteAllBytes((Join-Path $misfiled 'fullchain.pfx'), $certStore.Export('Pfx', $script:PfxPassword))
    # renew.ps1 names the PEM after the certId, which here is the folder, so the
    # misfiled state holds <zone>-full.pem inside certs\<zone>\. That pairing is
    # what makes renaming the folder a two-part job: the file has to move with
    # it, or the path the Certificate file row shows stops existing.
    [IO.File]::WriteAllText((Join-Path $misfiled "$zone-full.pem"),
        "-----BEGIN CERTIFICATE-----`n" +
        [Convert]::ToBase64String($certStore.Export('Cert'), 'InsertLineBreaks') +
        "`n-----END CERTIFICATE-----`n")

    function Set-Sweep {
        param($Considered)
        $body = @{ ok = $true; error = $null; mode = 'preview'
                   startedAt = (Get-Date).ToString('o'); finishedAt = (Get-Date).ToString('o')
                   considered = @($Considered); renewed = @() }
        [IO.File]::WriteAllText($script:SweepFile, ($body | ConvertTo-Json -Depth 10))
    }
    function Status {
        param([string]$Name = $trackerHost)
        return Get-TrackerAddressStatus -HostName $Name -Port 58789 `
                  -Settings (Get-TrackerSettings) -ZoneCache (Get-ZoneCache)
    }
    function Entry {
        param([string]$CertId, [string]$Display, [string[]]$Names)
        $e = @{ certId = $CertId; name = $Display; due = $false; reason = $null
                renewAfter = (Get-Date).AddDays(30).ToString('o') }
        # Omitted entirely when none are given, so the pre-names sweep format is
        # reproduced rather than approximated with an empty array.
        if ($null -ne $Names) { $e.names = @($Names) }
        return $e
    }

    # ----------------------------------------------------------------------- #
    Write-Host "`nthe certificate is found, and called by its own name"
    Set-Sweep @(Entry -CertId $trackerHost -Display $trackerHost -Names @($trackerHost))
    $r = Status
    Check 'the certificate is found at all' $r.certificate.covered `
          'Find-CertificateForHost missed a folder holding both required files'
    Check 'and matched exactly, not by wildcard' $r.certificate.exact 'the SAN is the host itself'
    Check 'the row names the host' ($r.certificate.detail -match [regex]::Escape($trackerHost)) `
          "said: $($r.certificate.detail)"
    # The folder name is a strict suffix of the host, so "does not mention the
    # zone" cannot be asked directly - what must not appear is the zone standing
    # on its own as the certificate's identity, at the start of the line.
    Check 'and does not open with the folder it sits in' `
          (-not $r.certificate.detail.StartsWith($zone)) `
          "reported the containing folder as the certificate's identity: $($r.certificate.detail)"

    # ----------------------------------------------------------------------- #
    Write-Host "`nthe renewal row follows the names, not the folder"
    # The exact shape of the live bug: file in certs\<zone>\, sweep entry filed
    # under the tracker's own id. Matching on certId compares <zone> against
    # tracker.<zone> and calls a healthy certificate abandoned.
    Check 'it is reported as renewed' $r.renewal.ok "said: $($r.renewal.detail)"
    Check 'and as managed' $r.renewal.managed 'nothing claimed responsibility for it'
    Check 'no false abandonment warning' ($r.renewal.detail -notmatch 'NOT in the renewal set') `
          "said: $($r.renewal.detail)"
    Check 'the renewal date comes from the sweep' ($r.renewal.detail -match 'renewal window opens') `
          "said: $($r.renewal.detail)"
    Check 'the file path still points at the folder that exists' $r.renewal.fileExists `
          "path shown does not exist: $($r.renewal.file)"

    # ----------------------------------------------------------------------- #
    Write-Host "`na wildcard entry covers the host too"
    Set-Sweep @(Entry -CertId "wildcard.$zone" -Display "*.$zone" -Names @("*.$zone", $zone))
    Check 'a *.zone entry renews a host in that zone' (Status).renewal.ok 'the wildcard was not consulted'

    # ----------------------------------------------------------------------- #
    Write-Host "`nan RFC 6125 wildcard is not stretched to fit"
    # *.zone does NOT cover a.b.zone. If it did, the loosened matching would be
    # marking deeper names as renewed by a certificate that cannot serve them.
    $deep = Status -Name "a.b.$zone"
    Check 'a two-label name is not claimed by *.zone' (-not $deep.renewal.ok) `
          "said: $($deep.renewal.detail)"

    # ----------------------------------------------------------------------- #
    Write-Host "`nthe alarm still fires when nothing really covers the name"
    # The guard that matters. Matching more loosely must not mean never warning:
    # this is a sweep that genuinely does not keep this host alive.
    Set-Sweep @(Entry -CertId "other.$zone" -Display "other.$zone" -Names @("other.$zone"))
    $r = Status
    Check 'it is reported as NOT renewed' (-not $r.renewal.ok) "said: $($r.renewal.detail)"
    Check 'and says so plainly' ($r.renewal.detail -match 'NOT in the renewal set') `
          "said: $($r.renewal.detail)"
    Check 'naming the host, not the folder' ($r.renewal.detail -match [regex]::Escape($trackerHost)) `
          "said: $($r.renewal.detail)"

    # ----------------------------------------------------------------------- #
    Write-Host "`na sweep written before names existed still reads correctly"
    # Upgrades happen in place: the file on disk is whatever the last sweep
    # wrote, and that may predate the names field by a day. Falling back to the
    # old comparison keeps those installs reading correctly rather than turning
    # every console red until the next sweep runs.
    Set-Sweep @(Entry -CertId $zone -Display $zone -Names $null)
    Check 'the old certId comparison still matches' (Status).renewal.ok `
          'an upgraded install reads as abandoned until its next sweep'

    # ----------------------------------------------------------------------- #
    Write-Host "`nno sweep at all"
    Remove-Item -LiteralPath $script:SweepFile -Force
    $r = Status
    Check 'says no sweep has run rather than accusing anyone' `
          ($r.renewal.detail -match 'No renewal sweep has run yet') "said: $($r.renewal.detail)"
}
finally {
    if ($certStore) {
        try { Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($certStore.Thumbprint)" -Force } catch { $null = $_ }
    }
    try { Remove-Item -LiteralPath $sandbox -Recurse -Force } catch { $null = $_ }
}

# --------------------------------------------------------------------------- #
Write-Host "`nthe sweep records what each entry covers"
$dueSrc = Get-Content (Join-Path $srcDir 'renew-due.ps1') -Raw -Encoding UTF8
Check 'considered entries carry their names' ($dueSrc -match 'names = @\(\$cert\.names\)') `
      'without them the status row has nothing to match on but the folder name'

# --------------------------------------------------------------------------- #
Write-Host "`nsetup saves the address BEFORE it orders the certificate"
# The ordering that stops the mismatch being created in the first place.
# Get-CertificateGroups only gives the console its own certificate when
# web.hostname is already set; ordered the other way round the name rides the
# zone's SAN order and is filed under the zone id.
$setupSrc = Get-Content (Join-Path $srcDir 'setup.ps1') -Raw -Encoding UTF8
$saveAt  = $setupSrc.IndexOf('$sPre.web.hostname = $webName')
$orderAt = $setupSrc.IndexOf("'renew.ps1') -Zone `$zoneForCert")
Check 'the address is written ahead of the order' `
      ($saveAt -ge 0 -and $orderAt -ge 0 -and $saveAt -lt $orderAt) `
      "save at $saveAt, order at $orderAt - reversed, the certificate is filed under the zone id"
Check 'and put back if no certificate comes of it' `
      ($setupSrc -match '\$sBack\.web\.hostname = \$webPrevName') `
      'a failed order would leave the console announcing an address it cannot serve'
Check 'the rollback guard is initialised, not assumed' `
      ($setupSrc -match '\$webPrevName = \$null') `
      'the rollback tests a variable that may never have been assigned'

Write-Host ""
if ($script:Failed) { Write-Host "$script:Failed CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
