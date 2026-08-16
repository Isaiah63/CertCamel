<#
  new-lb-api-cert.ps1 - issue a TLS certificate for a load balancer's Data Plane
  API, from the machine running Cert Camel.

      powershell -ExecutionPolicy Bypass -File .\new-lb-api-cert.ps1 -Node lb1.internal -IP 10.0.0.11

  WHY THIS RUNS HERE AND NOT ON THE LOAD BALANCER

  Cert Camel cannot issue this one over ACME - it deploys THROUGH the API, so
  the API has to be reachable and trusted before Cert Camel can do anything at
  all. That leaves a private CA, and the question is where it lives.

  It lives here, and that is the point. Trust follows the ISSUER, not the
  machine: a certificate generated on this box only helps if this box also holds
  the CA that signed it. Keeping the CA here means the one machine that has to
  TRUST the API is the same machine that ISSUES for it, so there is nothing to
  install in the trust store on a second run and nothing to copy back.

  What crosses to the load balancer is the node's certificate and key. The CA
  private key never leaves this machine.

  NO OPENSSL REQUIRED. Windows ships everything needed to create the
  certificates; the private key is written as PEM by encoding it here, because
  .NET Framework - which is what Windows PowerShell 5.1 runs on - has no
  ExportPkcs8PrivateKey. Verified byte-for-byte against openssl during
  development, but nothing at run time depends on openssl being installed.
#>

[CmdletBinding()]
param(
    # The name the API certificate is issued for. Use the name Cert Camel will
    # connect to, exactly - a certificate for lb1.internal is rejected when the
    # target is https://10.0.0.11:5555, correctly and confusingly.
    [Parameter(Mandatory = $true)]
    [string]$Node,

    # Any additional addresses or names the same node answers to. The address
    # you put in Cert Camel MUST be in here or in -Node.
    [string[]]$IP = @(),
    [string[]]$AlsoNamed = @(),

    # Where to write the node's certificate and key. Defaults to a folder beside
    # this script, per node.
    [string]$OutDir,

    # How long the node certificate is good for. 825 days is the maximum public
    # CAs allow and a sane private ceiling; the CA itself gets ten years.
    [int]$Days = 825,

    # Import the CA into the Windows trusted root store. Needs administrator.
    # Without it the command to run is printed instead.
    [switch]$Trust
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'acme-lib.ps1')

$caDir  = Join-Path $PSScriptRoot 'lb-ca'
$caPfx  = Join-Path $caDir 'lb-ca.pfx'
$caCrt  = Join-Path $caDir 'lb-ca.crt'
if (-not $OutDir) { $OutDir = Join-Path $caDir $Node }

function Write-Step { param([string]$Text, [string]$Colour = 'Gray') Write-Host $Text -ForegroundColor $Colour }

# --------------------------------------------------------------------------- #
# PEM encoding
# --------------------------------------------------------------------------- #
function ConvertTo-Pem {
    param([byte[]]$Der, [string]$Label)
    $b64 = [Convert]::ToBase64String($Der)
    $sb  = New-Object Text.StringBuilder
    [void]$sb.AppendLine("-----BEGIN $Label-----")
    for ($i = 0; $i -lt $b64.Length; $i += 64) {
        [void]$sb.AppendLine($b64.Substring($i, [Math]::Min(64, $b64.Length - $i)))
    }
    [void]$sb.AppendLine("-----END $Label-----")
    return $sb.ToString()
}

# DER, by hand, because .NET Framework cannot export a private key to PEM.
#
# A PKCS#1 RSAPrivateKey is a SEQUENCE of nine INTEGERs in a fixed order, and
# RSAParameters hands over all nine. The only subtlety is that DER INTEGERs are
# SIGNED: a value whose top bit is set needs a leading 0x00 or it reads as
# negative, which produces a key file that looks right and no tool will load.
function ConvertTo-DerLength {
    param([int]$Length)
    if ($Length -lt 0x80) { return [byte[]]@($Length) }
    $bytes = [Collections.Generic.List[byte]]::new()
    $n = $Length
    while ($n -gt 0) { $bytes.Insert(0, [byte]($n -band 0xFF)); $n = $n -shr 8 }
    return ,([byte[]]@(0x80 -bor $bytes.Count) + $bytes.ToArray())
}

function ConvertTo-DerInteger {
    param([byte[]]$Value)
    # Strip leading zeros the parameters may carry, then re-add exactly one if
    # the high bit would otherwise make this negative.
    $v = @($Value)
    $i = 0
    while ($i -lt ($v.Count - 1) -and $v[$i] -eq 0) { $i++ }
    $v = $v[$i..($v.Count - 1)]
    if ($v[0] -band 0x80) { $v = @([byte]0) + $v }
    return ,([byte[]]@(0x02) + (ConvertTo-DerLength $v.Count) + $v)
}

function ConvertTo-Pkcs1PrivateKey {
    # $KeyParams, not $P, and the loop below is $part rather than $p - for the
    # same reason renew.ps1 names its parameter $ZoneList. PowerShell variable
    # names are case-insensitive, so a parameter $P and a loop variable $p are
    # ONE variable; with $P typed, every iteration tried to coerce a byte array
    # back into RSAParameters and failed with "Cannot convert System.Object[]
    # to RSAParameters" - pointing at the caller, which was fine.
    param([Security.Cryptography.RSAParameters]$KeyParams)
    $parts = @(
        (ConvertTo-DerInteger @([byte]0)),      # version
        (ConvertTo-DerInteger $KeyParams.Modulus),
        (ConvertTo-DerInteger $KeyParams.Exponent),
        (ConvertTo-DerInteger $KeyParams.D),
        (ConvertTo-DerInteger $KeyParams.P),
        (ConvertTo-DerInteger $KeyParams.Q),
        (ConvertTo-DerInteger $KeyParams.DP),
        (ConvertTo-DerInteger $KeyParams.DQ),
        (ConvertTo-DerInteger $KeyParams.InverseQ)
    )
    $body = [byte[]]@()
    foreach ($part in $parts) { $body += $part }
    return ,([byte[]]@(0x30) + (ConvertTo-DerLength $body.Count) + $body)
}

function Export-PrivateKeyPem {
    param([Security.Cryptography.X509Certificates.X509Certificate2]$Cert)
    $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Cert)
    if (-not $rsa) { throw "Could not read the private key for $($Cert.Subject)." }
    try   { $params = $rsa.ExportParameters($true) }
    catch { throw "The private key is not exportable, so it cannot be written as PEM. Delete $caDir and run again." }
    return (ConvertTo-Pem -Der (ConvertTo-Pkcs1PrivateKey $params) -Label 'RSA PRIVATE KEY')
}

# --------------------------------------------------------------------------- #
# The CA - created once, reused after
# --------------------------------------------------------------------------- #
if (-not (Test-Path $caDir)) { New-Item -ItemType Directory -Path $caDir -Force | Out-Null }

# -Signer resolves the signing certificate THROUGH THE STORE, by thumbprint - it
# will not take a certificate object that is only in memory, and says so as
# "CSignerCertificate::Initialize: Cannot find object or property. 0x80092004",
# which sounds like a missing file rather than a missing store entry. So the CA
# is put back into the store for the duration and taken out again at the end;
# the .pfx on disk stays the durable copy either way.
$ca = $null
if (Test-Path $caPfx) {
    $ca = New-Object Security.Cryptography.X509Certificates.X509Certificate2 `
            @($caPfx, '', ([Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable -bor
                           [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet))
    $my = New-Object Security.Cryptography.X509Certificates.X509Store 'My', 'CurrentUser'
    $my.Open('ReadWrite'); $my.Add($ca); $my.Close()
    Write-Step "Using the existing CA: $($ca.Subject), expires $($ca.NotAfter.ToString('d MMM yyyy'))" 'Gray'
}
else {
    Write-Step "Creating a certificate authority (once - every node is signed by this)..." 'Cyan'
    $ca = New-SelfSignedCertificate `
            -Subject "CN=Cert Camel Load Balancer CA" `
            -KeyExportPolicy Exportable -KeyLength 4096 -KeyAlgorithm RSA `
            -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears(10) `
            -CertStoreLocation 'Cert:\CurrentUser\My' `
            -KeyUsage CertSign, CRLSign, DigitalSignature `
            -TextExtension @('2.5.29.19={text}CA=true&pathlength=0')

    # Kept as a file, not left in the store: the store copy is an artefact of
    # how New-SelfSignedCertificate works, and a CA that only exists in one
    # user's profile is a CA that vanishes when that profile does.
    [IO.File]::WriteAllBytes($caPfx, $ca.Export('Pfx', ''))
    [IO.File]::WriteAllText($caCrt, (ConvertTo-Pem -Der $ca.RawData -Label 'CERTIFICATE'),
                            (New-Object Text.UTF8Encoding $false))
    Write-Step "  wrote $caCrt and $caPfx" 'Green'
    Write-Step "  the CA private key never leaves this machine." 'DarkGray'
}

# --------------------------------------------------------------------------- #
# The node certificate
# --------------------------------------------------------------------------- #
$dnsNames = @($Node) + @($AlsoNamed) | Where-Object { $_ } | Select-Object -Unique
$sanParts = @()
foreach ($d in $dnsNames)   { $sanParts += "DNS=$d" }
foreach ($a in @($IP))      { if ($a) { $sanParts += "IPAddress=$a" } }
if (-not $sanParts.Count)   { throw "No names to issue for." }

Write-Step ""
Write-Step "Issuing for $($sanParts -join ', ')" 'Cyan'

$leaf = New-SelfSignedCertificate `
          -Subject "CN=$Node" -Signer $ca `
          -KeyExportPolicy Exportable -KeyLength 2048 -KeyAlgorithm RSA `
          -HashAlgorithm SHA256 -NotAfter (Get-Date).AddDays($Days) `
          -CertStoreLocation 'Cert:\CurrentUser\My' `
          -KeyUsage DigitalSignature, KeyEncipherment `
          -TextExtension @(
              '2.5.29.37={text}1.3.6.1.5.5.7.3.1',          # serverAuth
              "2.5.29.17={text}$($sanParts -join '&')"      # subjectAltName
          )

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$crtPath = Join-Path $OutDir 'dpa.crt'
$keyPath = Join-Path $OutDir 'dpa.key'
$utf8    = New-Object Text.UTF8Encoding $false

[IO.File]::WriteAllText($crtPath, (ConvertTo-Pem -Der $leaf.RawData -Label 'CERTIFICATE'), $utf8)
[IO.File]::WriteAllText($keyPath, (Export-PrivateKeyPem -Cert $leaf), $utf8)

# Both come out of the personal store now that the files are written. Leaving
# them would put a load balancer's private key in this user's certificate store
# for no reason - the files are what gets used, and the CA's .pfx is what gets
# reloaded next time.
Remove-Item -Path ("Cert:\CurrentUser\My\" + $leaf.Thumbprint) -Force -ErrorAction SilentlyContinue
Remove-Item -Path ("Cert:\CurrentUser\My\" + $ca.Thumbprint)   -Force -ErrorAction SilentlyContinue

Write-Step "  wrote $crtPath" 'Green'
Write-Step "  wrote $keyPath" 'Green'

# --------------------------------------------------------------------------- #
# Trust, and what to do next
# --------------------------------------------------------------------------- #
$store = New-Object Security.Cryptography.X509Certificates.X509Store 'Root', 'CurrentUser'
$store.Open('ReadOnly')
$already = @($store.Certificates | Where-Object { $_.Thumbprint -eq $ca.Thumbprint }).Count -gt 0
$store.Close()

Write-Step ""
# Printed BEFORE the import, because Windows shows a security warning asking you
# to "confirm its origin" against exactly this value - and a prompt you cannot
# check is a prompt everyone learns to click through. Match the two, then say
# yes. They should be identical; if they are not, something else is asking to be
# trusted as a root CA and the answer is no.
Write-Step ("CA thumbprint (SHA1): " + (($ca.Thumbprint -replace '(.{8})', '$1 ').Trim())) 'White'

if ($already) {
    Write-Step "The CA is already trusted on this machine." 'Green'
}
elseif ($Trust) {
    Write-Step "Windows will ask you to confirm this - check the thumbprint above matches the dialog." 'Yellow'
    # CurrentUser\Root, not LocalMachine: this needs no administrator, and Cert
    # Camel runs as this user. A scheduled task running as another account would
    # need LocalMachine instead - noted in the guide.
    $rw = New-Object Security.Cryptography.X509Certificates.X509Store 'Root', 'CurrentUser'
    $rw.Open('ReadWrite')
    $rw.Add((New-Object Security.Cryptography.X509Certificates.X509Certificate2 $caCrt))
    $rw.Close()
    Write-Step "Imported the CA into this user's trusted roots." 'Green'
}
else {
    Write-Step "The CA is NOT trusted here yet. Re-run with -Trust, or:" 'Yellow'
    Write-Step "    certutil -user -addstore Root `"$caCrt`"" 'White'
}

Write-Step ""
Write-Step "Copy these two files to $Node and point the Data Plane API at them:" 'Cyan'
Write-Step "    $crtPath"
Write-Step "    $keyPath"
Write-Step ""
Write-Step "  dataplaneapi.yml:" 'DarkGray'
Write-Step "    tls:"
Write-Step "      tls_certificate: /etc/haproxy/dpa/dpa.crt"
Write-Step "      tls_key: /etc/haproxy/dpa/dpa.key"
Write-Step ""
Write-Step "  Then restart the API, and leave 'Skip TLS verification' OFF in Cert Camel." 'DarkGray'
Write-Step "  The key is a private key: chmod 600 it on the node, and delete the copy" 'DarkGray'
Write-Step "  from this machine once it is in place." 'DarkGray'
