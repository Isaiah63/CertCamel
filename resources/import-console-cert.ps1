<#
  import-console-cert.ps1 - put a certificate where the console will serve it.

      powershell -ExecutionPolicy Bypass -File .\import-console-cert.ps1 -HostName tracker.example.com -List
      powershell -ExecutionPolicy Bypass -File .\import-console-cert.ps1 -HostName tracker.example.com -FromHistory
      powershell -ExecutionPolicy Bypass -File .\import-console-cert.ps1 -HostName tracker.example.com -Path C:\temp\tracker.pfx

  WHAT THIS IS FOR

  The console serves itself with a certificate from certs\<name>\, and normally
  Cert Camel puts it there. This is the way back when it cannot: an expired
  certificate that renewal could not replace, a folder restored from a backup,
  a certificate issued somewhere else entirely.

  Doing it by hand is possible and unforgiving. Find-CertificateForHost skips
  any folder missing EITHER cert.cer or fullchain.pfx, and the PFX has to open
  with the password the server loads it with - so a perfectly good certificate
  copied into the right folder can be ignored with no error anywhere. This
  removes both traps.

  RESTORING IS USUALLY WHAT YOU WANT

  Every renewal archives the certificate it replaced into history\, complete
  with its fullchain.pfx. -FromHistory copies one back, which needs nothing
  from outside and is the fastest way out of a bad renewal. -List shows what is
  there, with dates.

  IMPORTING FROM OUTSIDE NEEDS A PFX

  A .pfx carries the certificate, its chain and its private key in one file that
  Windows PowerShell 5.1 can open directly. A PEM private key cannot be read
  here without shipping a parser for it - .NET Framework has no import for one -
  so a PEM pair has to be converted first. The error says how.

  This does not turn HTTPS on or restart anything. It puts the file in place;
  the running server picks it up within two minutes, or immediately on restart.
#>

# -Password is a plain string, and PSAvoidUsingPlainTextForPassword is right to
# notice. Suppressed here with the reasoning rather than silenced globally, so
# the rule keeps reporting everywhere else.
#
# A SecureString parameter cannot survive this call anyway: the script is run
# through `powershell.exe -File`, which hands every argument over as a literal
# string, so the type would only move the failure. More to the point, this
# password protects a file the operator is already holding in their hand, and
# the very next thing that happens to it is a re-export under the fixed password
# the server loads with. Hardening the parameter would protect nothing that is
# not already on disk two lines later.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password',
    Justification = 'Passed across a powershell.exe -File boundary, which stringifies every argument; guards a file the caller already holds and is immediately re-exported under the fixed store password.')]
[CmdletBinding(DefaultParameterSetName = 'Import')]
param(
    # The name the console is served on. Also the folder under certs\, because
    # that is how Find-CertificateForHost is asked.
    [Parameter(Mandatory = $true)]
    [string]$HostName,

    # A .pfx holding the certificate, its chain and its private key.
    [Parameter(ParameterSetName = 'Import')]
    [string]$Path,

    # The password on that .pfx. Blank if it has none.
    [Parameter(ParameterSetName = 'Import')]
    [string]$Password = '',

    # Put back a previously archived certificate for this name.
    [Parameter(ParameterSetName = 'History')]
    [switch]$FromHistory,

    # Which archive to restore. Omitted, the newest is used.
    [Parameter(ParameterSetName = 'History')]
    [string]$Stamp,

    # Show what is in history and stop.
    [Parameter(ParameterSetName = 'List')]
    [switch]$List,

    # Install a certificate that has already expired. Refused otherwise: it
    # cannot make the console reachable, and putting one in place looks like a
    # repair while changing nothing.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'acme-lib.ps1')

function Say { param([string]$T, [string]$C = 'Gray') Write-Host $T -ForegroundColor $C }

$name = ([string]$HostName).Trim().TrimEnd('.').ToLowerInvariant()
if (-not $name)             { throw "No hostname given." }
if ($name.StartsWith('*.')) { throw "A wildcard cannot be the address of this page. Give it one name." }

$destDir    = Join-Path $script:CertsDir $name
$historyDir = Join-Path $destDir 'history'

# --------------------------------------------------------------------------- #
# -List
# --------------------------------------------------------------------------- #
if ($List) {
    Say ""
    Say "  Archived certificates for $name" 'Cyan'
    Say ""
    if (-not (Test-Path $historyDir)) {
        Say "  Nothing archived yet. history\ appears the first time a renewal replaces" 'Yellow'
        Say "  the certificate in this folder." 'DarkGray'
        Say ""
        exit 0
    }

    $any = $false
    foreach ($h in @(Get-ChildItem -LiteralPath $historyDir -Directory | Sort-Object Name -Descending)) {
        $pfx = Join-Path $h.FullName 'fullchain.pfx'
        $cer = Join-Path $h.FullName 'cert.cer'
        # Both are required to restore, so an archive missing either is listed
        # as unusable rather than offered and then refused.
        if (-not (Test-Path $pfx) -or -not (Test-Path $cer)) {
            Say ("    {0,-22} incomplete - no fullchain.pfx" -f $h.Name) 'DarkGray'
            continue
        }
        $any = $true
        try {
            $c = New-Object Security.Cryptography.X509Certificates.X509Certificate2 (,[IO.File]::ReadAllBytes($cer))
            $state = $(if ($c.NotAfter -lt (Get-Date)) { 'EXPIRED' } else { 'valid to' })
            Say ("    {0,-22} {1} {2}" -f $h.Name, $state, $c.NotAfter.ToString('d MMM yyyy')) `
                $(if ($c.NotAfter -lt (Get-Date)) { 'DarkGray' } else { 'Green' })
        }
        catch { Say ("    {0,-22} unreadable certificate" -f $h.Name) 'Yellow' }
    }
    if (-not $any) { Say "    nothing restorable here" 'Yellow' }
    Say ""
    Say "  Restore the newest:  -HostName $name -FromHistory" 'DarkGray'
    Say "  Restore a specific:  -HostName $name -FromHistory -Stamp <name above>" 'DarkGray'
    Say ""
    exit 0
}

# --------------------------------------------------------------------------- #
# Work out what is being installed, and load it
# --------------------------------------------------------------------------- #
$sourcePfx = ''
$sourcePwd = ''
$sourceDir = ''

if ($FromHistory) {
    if (-not (Test-Path $historyDir)) { throw "There is no history\ folder for $name yet, so there is nothing to restore." }

    $picked = $null
    if ($Stamp) {
        $picked = Get-ChildItem -LiteralPath $historyDir -Directory |
                  Where-Object { $_.Name -eq $Stamp } | Select-Object -First 1
        if (-not $picked) { throw "No archive named '$Stamp'. Run with -List to see what is there." }
    }
    else {
        # Newest USABLE, not simply newest. Skipping incomplete folders is
        # obvious; skipping expired ones is the part that matters. The whole
        # reason to reach for -FromHistory is that the live certificate has
        # stopped working, and the archive immediately behind it is very often
        # the one that just expired - so "newest" would hand back something that
        # is refused two steps later while a working certificate sits one row
        # further down the list.
        #
        # An explicit -Stamp still restores exactly what was asked for. This
        # only decides what "the newest" means when nothing was specified.
        $usable = @(Get-ChildItem -LiteralPath $historyDir -Directory | Sort-Object Name -Descending |
                    Where-Object {
                        $p = Join-Path $_.FullName 'fullchain.pfx'
                        $c = Join-Path $_.FullName 'cert.cer'
                        if (-not (Test-Path $p) -or -not (Test-Path $c)) { return $false }
                        try {
                            $x = New-Object Security.Cryptography.X509Certificates.X509Certificate2 (,[IO.File]::ReadAllBytes($c))
                            return ($x.NotAfter -gt (Get-Date))
                        }
                        catch { return $false }   # unreadable is not restorable either
                    })

        $picked = @($usable) | Select-Object -First 1
        if (-not $picked) {
            throw ("Nothing in history\ is both complete and still valid.`n" +
                   "Run with -List to see what is there. To restore an expired one anyway:`n" +
                   "    -HostName $name -FromHistory -Stamp <name> -Force")
        }
    }

    $sourceDir = $picked.FullName
    $sourcePfx = Join-Path $sourceDir 'fullchain.pfx'
    $sourcePwd = $script:PfxPassword     # written by this tool, so the tool's own password
    Say ""
    Say "  Restoring $($picked.Name)" 'Cyan'
}
else {
    if (-not $Path) { throw "Give a .pfx with -Path, or use -FromHistory. Run with -List to see what has been archived." }
    if (-not (Test-Path -LiteralPath $Path)) { throw "$Path does not exist." }

    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($ext -in @('.pem', '.crt', '.cer', '.key')) {
        throw ("$Path looks like a PEM file, and this cannot read a PEM private key - " +
               ".NET Framework, which Windows PowerShell 5.1 runs on, has no import for one.`n`n" +
               "Convert it first, then import the result:`n" +
               "    openssl pkcs12 -export -out tracker.pfx -inkey cert.key -in cert.cer -certfile chain.cer`n`n" +
               "If this is a certificate Cert Camel issued, -FromHistory needs none of that.")
    }

    $sourcePfx = (Resolve-Path -LiteralPath $Path).Path
    $sourcePwd = $Password
    Say ""
    Say "  Importing $sourcePfx" 'Cyan'
}

# --------------------------------------------------------------------------- #
# Prove it is usable BEFORE anything on disk is touched
# --------------------------------------------------------------------------- #
# Every check happens here, while the folder still holds whatever it held. A
# certificate that turns out to be wrong should cost nothing, and the failure
# this is guarding against - replacing a working certificate with a broken one -
# takes the console down and the console is what would have explained it.
$cert = $null
try {
    $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2(
        $sourcePfx, $sourcePwd,
        [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
}
catch {
    throw ("Could not open that .pfx: $(($_.Exception.Message -split "`n")[0].Trim())`n" +
           "If it has a password, pass it with -Password.")
}

try {
    if (-not $cert.HasPrivateKey) {
        throw "That .pfx has no private key in it. A certificate alone cannot serve TLS."
    }

    $sans = @(Get-CertificateSanNames -Certificate $cert)
    if (-not (Test-NameCoveredBySans -Sans $sans -Name $name)) {
        throw ("That certificate does not cover $name.`n" +
               "  it covers: $(($sans | Sort-Object) -join ', ')`n" +
               "The console would keep serving the old one, and browsers would warn on this name.")
    }

    if ($cert.NotAfter -lt (Get-Date)) {
        if (-not $Force) {
            throw ("That certificate expired on $($cert.NotAfter.ToString('d MMM yyyy')). " +
                   "Installing it cannot make the console reachable - it only looks like a repair. " +
                   "Pass -Force if you have a reason to want it anyway.")
        }
        Say "  ! It expired on $($cert.NotAfter.ToString('d MMM yyyy')). Installing anyway (-Force)." 'Yellow'
    }
    elseif ($cert.NotBefore -gt (Get-Date)) {
        Say "  ! Not valid until $($cert.NotBefore.ToString('d MMM yyyy HH:mm')). Browsers will reject it until then." 'Yellow'
    }

    Say ("  Covers   : {0}" -f (($sans | Sort-Object) -join ', ')) 'Gray'
    Say ("  Valid to : {0}" -f $cert.NotAfter.ToString('d MMM yyyy')) 'Gray'
    Say ("  Issuer   : {0}" -f $cert.Issuer) 'DarkGray'

    # ----------------------------------------------------------------------- #
    # Archive what is there, then write
    # ----------------------------------------------------------------------- #
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

    $existingCer = Join-Path $destDir 'cert.cer'
    if (Test-Path $existingCer) {
        # Stamped from when the OLD certificate was written, so the archive reads
        # as "this was live from this date" rather than when it was replaced -
        # matching what renewal does.
        $stampName = (Get-Item -LiteralPath $existingCer).LastWriteTime.ToString('yyyy-MM-dd_HHmmss')
        $archive   = Join-Path $historyDir $stampName
        if (-not (Test-Path $archive)) { New-Item -ItemType Directory -Path $archive -Force | Out-Null }
        foreach ($f in @(Get-ChildItem -LiteralPath $destDir -File)) {
            Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $archive $f.Name) -Force
        }
        Say ("  Archived the current certificate to history\{0}" -f $stampName) 'DarkGray'
    }

    # Re-exported rather than copied, and this is the step that matters most.
    # The server opens fullchain.pfx with one fixed password, so a .pfx that
    # arrived with any other password - including none - has to be rewritten or
    # it is silently skipped by a server that then serves plain HTTP.
    $destPfx = Join-Path $destDir 'fullchain.pfx'
    [IO.File]::WriteAllBytes($destPfx, $cert.Export('Pfx', $script:PfxPassword))

    # cert.cer is the public certificate, and the only file discovery reads.
    # Without it the folder is invisible however good the .pfx is.
    [IO.File]::WriteAllBytes((Join-Path $destDir 'cert.cer'), $cert.RawData)

    # Anything else the archive had - the PEM bundle, the chain - is worth
    # carrying across on a restore so the folder ends up as it was, rather than
    # a half-populated version that works but looks wrong.
    if ($sourceDir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $sourceDir -File |
                         Where-Object { $_.Name -notin @('fullchain.pfx', 'cert.cer', 'about.json') })) {
            Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $destDir $f.Name) -Force
        }
    }

    Say ("  Wrote {0}" -f $destPfx) 'Green'

    # Re-assert permissions on the folder that now holds a new private key.
    # A restore can create certs\<name>\ for the first time, and a folder created
    # after setup ran has only whatever it inherited.
    try {
        Set-CamelAcl -Path $destDir -Inheritable
        Say "  Permissions restricted to you, SYSTEM and Administrators." 'DarkGray'
    }
    catch { Say ("  Could not restrict permissions: {0}" -f ($_.Exception.Message -split "`n")[0].Trim()) 'Yellow' }

    try {
        Write-AuditEvent -Event 'renew' -Object $name -Outcome 'ok' `
            -Detail $(if ($sourceDir) { "restored by hand from history\$([IO.Path]::GetFileName($sourceDir)), expires $($cert.NotAfter)" }
                      else { "imported by hand from a .pfx, expires $($cert.NotAfter)" })
    } catch { $null = $_ }   # the certificate is in place; failing to audit it must not undo that
}
finally {
    # The key was materialised into a container to open the PFX. Disposing
    # releases it; leaving it would accumulate key material for every run.
    if ($cert) { try { $cert.Dispose() } catch { $null = $_ } }
}

Say ""
Say "  Done. The running console picks this up within two minutes, or" 'Green'
Say "  immediately if you restart it." 'DarkGray'
Say ""
Say "  It will NOT renew itself unless a DNS provider covers this zone and the" 'DarkGray'
Say "  name is watched. Settings > Tracker address says which of those is true." 'DarkGray'
Say ""
