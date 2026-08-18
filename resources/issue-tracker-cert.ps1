<#
  issue-tracker-cert.ps1 - issue the console's own certificate by hand, with a
  DNS record you add yourself.

      powershell -ExecutionPolicy Bypass -File .\issue-tracker-cert.ps1 -HostName tracker.example.com

  WHAT THIS IS FOR

  A bootstrap, for the case where you want this console on HTTPS today but the
  DNS API credential is a week away. It asks the certificate authority for a
  certificate covering one name, prints the TXT record to create, waits while
  you create it, and writes the result where every other part of this tool
  expects to find it.

  WHAT IT IS NOT

  It is not a way to avoid configuring a DNS provider. Renewal validates through
  the API, so until a provider covers this zone the certificate sits outside the
  renewal set entirely - Get-CertificateGroups files the name under `unmapped`
  and skips it - and Settings > Tracker address will correctly show Renewal in
  red. Ninety days later the console stops serving HTTPS.

  That is worth being plain about, because the failure is quiet and the thing
  that would normally warn you is the thing that goes down.

  Once a provider IS configured, nothing here needs repeating: renew-due.ps1 has
  an explicit branch for certificates it did not issue, and picks this one up
  when the live certificate gets close to expiry.
#>

[CmdletBinding()]
param(
    # The name this console is served on. One name, not a wildcard - a wildcard
    # cannot be the address of a page.
    [Parameter(Mandatory = $true)]
    [string]$HostName,

    # Which configured certificate authority to order from. Defaults to the one
    # marked default in Settings.
    [string]$CaId,

    # Added to domains.txt so the checker watches it and renewal can pick it up
    # later. On by default: a certificate nothing watches is one nothing renews.
    [int]$Port = 8787,
    [switch]$NoDomainsEntry
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'acme-lib.ps1')

function Say { param([string]$T, [string]$C = 'Gray') Write-Host $T -ForegroundColor $C }

$name = ([string]$HostName).Trim().TrimEnd('.').ToLowerInvariant()
if (-not $name)            { throw "No hostname given." }
if ($name.StartsWith('*.')) { throw "A wildcard cannot be the address of this page. Give it one name." }

$settings = Get-TrackerSettings
if (-not $settings.contact) {
    throw "Set a contact email under Settings > General first - the certificate authority requires one."
}

New-TrackerDirectories
Import-PoshAcme

$ca = Get-CaProfile -Settings $settings -CaId $CaId
Say ""
Say "  Issuing a certificate for $name" 'Cyan'
Say ("  Authority: {0}{1}" -f $ca.label, $(if ($ca.useStaging) { ' (STAGING - not publicly trusted)' } else { '' })) 'Gray'
Say ""
Say "  You will be shown a TXT record to create. Create it, let it propagate," 'DarkGray'
Say "  then press a key. Nothing is written here until the order completes." 'DarkGray'
Say ""

# Point Posh-ACME at this CA, then make sure an account exists on it. Accounts
# are per-CA and staging counts as a different CA, so a first run against a CA
# this install has never used has nothing to order with.
#
# renew.ps1 has the same logic, but as a nested function closing over its own
# logging and cache, so it cannot be called from here. Kept deliberately minimal
# rather than copied wholesale: this only ever orders one name, once.
Set-PAServer -DirectoryUrl (Get-ActiveDirectoryUrl -Ca $ca)

$account = $null
try { $account = Get-PAAccount } catch { $account = $null }
if (-not $account) {
    $acctParams = @{ Contact = $settings.contact; AcceptTOS = $true }

    # External Account Binding: required by DigiCert, ZeroSSL and Sectigo, never
    # by Let's Encrypt. Without this the order fails at registration with an
    # error about the account rather than about the missing key.
    if ($ca.ContainsKey('eabKid') -and $ca.eabKid) {
        $hmac = Get-TrackerSecret -Key "ca:$($ca.id):eabHmacKey" -AsPlainText
        if (-not $hmac) { throw "$($ca.label) has an EAB key ID but no HMAC key. Add it under Settings > Certificate Authorities." }
        $acctParams.ExtAcctKID     = $ca.eabKid
        $acctParams.ExtAcctHMACKey = $hmac
        Say ("  Binding to external account {0}." -f $ca.eabKid) 'DarkGray'
    }

    Say ("  No account on {0} yet - registering {1}..." -f $ca.label, $settings.contact) 'DarkGray'
    New-PAAccount @acctParams | Out-Null
}
else { Say ("  Using existing account {0} on {1}." -f $account.id, $ca.label) 'DarkGray' }

# Plugin 'Manual' prints the record and waits. Interactive by design: the whole
# point is a person standing at a DNS console, so DnsSleep is left short - the
# keypress IS the wait, and sleeping again afterwards only adds confusion.
$paCert = New-PACertificate -Domain @($name) `
            -Plugin 'Manual' -PluginArgs @{} `
            -Contact $settings.contact -AcceptTOS `
            -DnsSleep 10 -ErrorAction Stop

if (-not $paCert) { throw "The certificate authority did not return a certificate." }

# --------------------------------------------------------------------------- #
# Write it where the rest of the tool looks
# --------------------------------------------------------------------------- #
# Same layout renew.ps1 produces, so serve.ps1, Find-CertificateForHost, the
# download link and the Settings page all treat this exactly like an automatic
# renewal. Anything else would work once and then be invisible.
$certId  = $name
$destDir = Join-Path $script:CertsDir $certId
if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

$pemPath = Join-Path $destDir "$certId-full.pem"
$newPem  = (Get-Content $paCert.FullChainFile -Raw -Encoding UTF8).Trim() + "`n" +
           (Get-Content $paCert.KeyFile       -Raw -Encoding UTF8).Trim() + "`n"

$archived = Save-CertificateHistory -CertDir $destDir -CertId $certId -NewPemContent $newPem
if ($archived) { Say ("  Archived the previous certificate to history\{0}" -f [IO.Path]::GetFileName($archived)) 'DarkGray' }

New-CombinedPem -FullChainPath $paCert.FullChainFile -KeyPath $paCert.KeyFile -Destination $pemPath | Out-Null
Say ("  Wrote {0}" -f $pemPath) 'Green'

foreach ($src in @($paCert.CertFile, $paCert.ChainFile, $paCert.FullChainFile, $paCert.KeyFile, $paCert.PfxFile, $paCert.PfxFullChain)) {
    $one = @($src | Where-Object { $_ }) | Select-Object -First 1
    if (-not $one -or -not (Test-Path -LiteralPath $one)) { continue }
    Copy-Item -LiteralPath $one -Destination (Join-Path $destDir ([IO.Path]::GetFileName([string]$one))) -Force
}

try {
    Write-AuditEvent -Event 'renew' -Object $certId -Outcome 'ok' `
        -Detail "issued by hand with a manual DNS record, expires $($paCert.NotAfter)"
        } catch { $null = $_ }   # the certificate was issued; failing to audit it must not undo that

# --------------------------------------------------------------------------- #
# Make sure something is watching it
# --------------------------------------------------------------------------- #
if (-not $NoDomainsEntry) {
    try {
        $r = Add-TrackerDomainEntry -HostName $name -Port $Port
        Say ("  {0}" -f $(if ($r.changed) { "Added $($r.entry) to domains.txt." } else { $r.note })) 'Green'
    } catch { Say ("  Could not update domains.txt: {0}" -f $_.Exception.Message) 'Yellow' }
}

# --------------------------------------------------------------------------- #
# Say plainly whether this will ever renew itself
# --------------------------------------------------------------------------- #
$zoneOk = $false
try {
    $zones = @((Get-ZoneCache).zones)
    if ($zones.Count) { $zoneOk = [bool](Resolve-HostZone -HostName $name -Zones $zones) }
        } catch { $null = $_ }   # zone lookup is advisory here; the prompt below asks anyway

Say ""
Say ("  Issued. Expires {0}." -f $paCert.NotAfter) 'Green'
Say ""
if ($zoneOk) {
    Say "  A DNS provider covers this zone, so this was the only manual step." 'Green'
    Say "  Renewal is automatic from here - nothing to repeat." 'DarkGray'
} else {
    Say "  NO DNS provider covers this zone yet, so NOTHING WILL RENEW THIS." 'Yellow'
    Say "  It expires in about 90 days and the console stops serving HTTPS." 'Yellow'
    Say ""
    Say "  Add one under Settings > DNS Automation and this certificate is picked" 'DarkGray'
    Say "  up automatically - renewal handles certificates it did not issue. Until" 'DarkGray'
    Say "  then, Settings > Tracker address shows Renewal in red, which is correct." 'DarkGray'
}
Say ""
Say "  Turn HTTPS on under Settings > General, then restart the console." 'Cyan'
Say ""
