<#
  The ACME client is pinned to a version and verified against a recorded hash.

  The answer given to the security review conceded, accurately, that Cert Camel
  performed no verification of its own beyond what PowerShellGet and the NuGet
  provider do. This is the code that closes that gap, and this suite is what
  stops it silently reopening.

  Two failures it is built to catch, both of which would leave verification
  looking present while doing nothing:

    1. A hash that is not reproducible. If Get-ModuleContentHash included
       PSGetModuleInfo.xml - which PowerShellGet writes at install time carrying
       InstalledDate, InstalledLocation and the installing user's name - the
       recorded hash would be unique to one machine and would fail correctly and
       loudly for every honest install anywhere else.

    2. The recorded hash drifting from the vendored module. The pin is only
       worth anything while it describes the code actually in this repository.

  Reads only. Nothing here downloads, installs or writes.

      powershell -ExecutionPolicy Bypass -File .\v18-poshacme-pin-test.ps1
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

# --------------------------------------------------------------------------- #
Write-Host "`nthe pin exists and is well formed"
Check 'a version is pinned' ([bool]$script:PoshAcmeVersion) 'nothing pinned, so every install gets whatever the gallery serves'
Check 'a hash is recorded for that version' `
      ([bool]$script:PoshAcmeHashes[$script:PoshAcmeVersion]) `
      "no hash for $($script:PoshAcmeVersion) - the download would be reported as unverified"
Check 'the recorded hash is a SHA256' `
      ($script:PoshAcmeHashes[$script:PoshAcmeVersion] -match '^[0-9a-f]{64}$') `
      "got '$($script:PoshAcmeHashes[$script:PoshAcmeVersion])'"

$libSrc = Get-Content (Join-Path $appDir 'acme-lib.ps1') -Raw -Encoding UTF8
Check 'the download asks for that exact version' `
      ($libSrc -match 'Save-Module[^\r\n]*-RequiredVersion \$script:PoshAcmeVersion') `
      'Save-Module is not pinned, so what arrives cannot be verified against anything'
Check 'a mismatch removes the module rather than leaving it' `
      ($libSrc -match 'Remove-Item -LiteralPath \$moduleDir -Recurse') `
      'an unverified copy left on disk is found and used by the next run without another check'

# --------------------------------------------------------------------------- #
Write-Host "`nthe hash matches the module actually vendored here"
$moduleDir = Join-Path $script:LibDir ('Posh-ACME\' + $script:PoshAcmeVersion)
if (-not (Test-Path -LiteralPath $moduleDir)) {
    Write-Host "  --   Posh-ACME $($script:PoshAcmeVersion) is not vendored here, skipping" -ForegroundColor DarkGray
    Write-Host "       (lib\ is gitignored, so this is expected on a fresh clone)" -ForegroundColor DarkGray
}
else {
    $actual = Get-ModuleContentHash -Path $moduleDir
    Check 'the vendored module matches the recorded hash' `
          ($actual -eq $script:PoshAcmeHashes[$script:PoshAcmeVersion]) `
          "recorded $($script:PoshAcmeHashes[$script:PoshAcmeVersion]), got $actual"

    Check 'the same input hashes the same twice' `
          ($actual -eq (Get-ModuleContentHash -Path $moduleDir)) `
          'the hash is not stable, so it can never be verified against anything'

    Check 'install-time metadata is excluded' `
          ($libSrc -match "Name -ne 'PSGetModuleInfo\.xml'") `
          'PSGetModuleInfo.xml carries the installing user and path, so hashing it pins the value to one machine'
}

# --------------------------------------------------------------------------- #
Write-Host "`nthe hash notices what it is supposed to notice"
# Built in a scratch folder rather than by touching the vendored copy: a test
# that mutates the module it is verifying is a test that can leave the install
# broken when it fails halfway.
$scratch = Join-Path $env:TEMP ('camel-hash-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    $a = Join-Path $scratch 'a'; $b = Join-Path $scratch 'b'
    foreach ($d in @($a, $b)) {
        New-Item -ItemType Directory -Path (Join-Path $d 'Public') -Force | Out-Null
        Set-Content -Path (Join-Path $d 'mod.psd1')       -Value 'ModuleVersion = 1' -Encoding Ascii
        Set-Content -Path (Join-Path $d 'Public\Get-X.ps1') -Value 'function Get-X {}' -Encoding Ascii
    }
    Check 'identical trees hash identically' `
          ((Get-ModuleContentHash -Path $a) -eq (Get-ModuleContentHash -Path $b)) `
          'two identical module folders produced different hashes'

    # A changed byte in any file.
    Set-Content -Path (Join-Path $b 'Public\Get-X.ps1') -Value 'function Get-X { evil }' -Encoding Ascii
    Check 'a changed file changes the hash' `
          ((Get-ModuleContentHash -Path $a) -ne (Get-ModuleContentHash -Path $b)) `
          'edited content produced the same hash - the verification is worthless'

    # A file moved without its bytes changing, which a naive content-only hash
    # would miss entirely.
    Remove-Item -LiteralPath (Join-Path $b 'Public\Get-X.ps1') -Force
    Set-Content -Path (Join-Path $b 'Public\Get-Y.ps1') -Value 'function Get-X {}' -Encoding Ascii
    Check 'a renamed file changes the hash' `
          ((Get-ModuleContentHash -Path $a) -ne (Get-ModuleContentHash -Path $b)) `
          'the same bytes under a different name hashed the same - paths are not being included'

    # An added file.
    Remove-Item -LiteralPath (Join-Path $b 'Public\Get-Y.ps1') -Force
    Set-Content -Path (Join-Path $b 'Public\Get-X.ps1') -Value 'function Get-X {}' -Encoding Ascii
    Check 'the tree is back to matching' `
          ((Get-ModuleContentHash -Path $a) -eq (Get-ModuleContentHash -Path $b)) `
          'restoring the file did not restore the hash'
    Set-Content -Path (Join-Path $b 'extra.ps1') -Value '# added' -Encoding Ascii
    Check 'an added file changes the hash' `
          ((Get-ModuleContentHash -Path $a) -ne (Get-ModuleContentHash -Path $b)) `
          'a file dropped into the module went unnoticed'

    # And the exclusion, proved rather than assumed.
    Remove-Item -LiteralPath (Join-Path $b 'extra.ps1') -Force
    Set-Content -Path (Join-Path $b 'PSGetModuleInfo.xml') -Value '<Objs>machine specific</Objs>' -Encoding Ascii
    Check 'PSGetModuleInfo.xml does not change the hash' `
          ((Get-ModuleContentHash -Path $a) -eq (Get-ModuleContentHash -Path $b)) `
          'the install-time metadata is being hashed, so no two machines can ever agree'
}
finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ""
if ($script:Failed) { Write-Host "$script:Failed CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
