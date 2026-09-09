<#
  The DNS Made Easy API key is a credential, and it was the only one the app
  stored in settings.json in the clear and rendered back into the form on every
  page load. The secret key beside it was already masked; the API key was not.

  Two things have to hold, and they pull in opposite directions:

  1. It is stored and displayed like every other secret - written to
     secrets.xml, returned to the browser as a boolean, blank on save means
     "keep what is stored".

  2. It still reaches Posh-ACME as PLAIN TEXT. DMEasy.ps1 declares
     [string]$DMEKey with no securestring variant, unlike NS1 and Cloudflare.
     Handing it the SecureString every other secret uses would coerce to the
     literal "System.Security.SecureString" and the CA would answer 403 - a
     broken credential that looks like a typo rather than a bug.

  Plus the migration: a key already sitting in settings.json has to move on
  load, or turning it into a secret would silently break an existing profile
  and leave the plaintext on disk anyway.

  Runs against redirected settings and secret files. It touches neither the
  real settings.json nor the real secrets.xml.

      powershell -ExecutionPolicy Bypass -File .\v39-dme-key-secret-test.ps1
#>

$ErrorActionPreference = 'Stop'
$repo   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$srcDir = Join-Path $repo 'resources'
. (Join-Path $srcDir 'acme-lib.ps1')

$script:Failed = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    if ($Ok) { Write-Host "  ok   $Name" -ForegroundColor Green }
    else     { Write-Host "  FAIL $Name  -- $Detail" -ForegroundColor Red; $script:Failed++ }
}

# --------------------------------------------------------------------------- #
# Redirect the two files the library writes, so nothing here can reach the
# install this is running inside.
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("cc-v39-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $sandbox
$script:SettingsFile = Join-Path $sandbox 'settings.json'
$script:SecretsFile  = Join-Path $sandbox 'secrets.xml'
Write-Host "sandbox: $sandbox"

try {
    # ----------------------------------------------------------------------- #
    Write-Host "`nthe catalog says what it now is"
    $dme = $script:PluginCatalog['DMEasy'].Args | Where-Object { $_.Name -eq 'DMEKey' }
    Check 'the API key is a secret' ([bool]$dme.Secret) `
          'it would keep going to settings.json and back into the form'
    Check 'and is flagged to reach the plugin as plain text' `
          ($dme.ContainsKey('PlainToPlugin') -and [bool]$dme.PlainToPlugin) `
          'without this it is passed as a SecureString and DMEasy stringifies it'

    $sec = $script:PluginCatalog['DMEasy'].Args | Where-Object { $_.Name -eq 'DMESecret' }
    Check 'the secret key is unchanged' `
          ([bool]$sec.Secret -and -not $sec.ContainsKey('PlainToPlugin')) `
          'DMESecret is a securestring parameter and must stay one'

    # ----------------------------------------------------------------------- #
    Write-Host "`na key still sitting in settings.json is moved on load"
    $legacy = @{
        version   = 1
        providers = @(
            @{ id = 'pDME1'; label = 'DME'; plugin = 'DMEasy';
               args = @{ DMEKey = 'PLAINTEXT-KEY-1234'; DMEUseSandbox = $false } }
        )
    }
    Save-TrackerSettings -Settings $legacy

    $raw = Get-Content $script:SettingsFile -Raw
    Check 'it really was on disk in the clear to begin with' `
          ($raw -match 'PLAINTEXT-KEY-1234') 'the fixture did not set it up'

    $loaded = Get-TrackerSettings

    Check 'the value has left the settings object' `
          (-not (@($loaded.providers)[0].args.ContainsKey('DMEKey'))) `
          'still exposed to the Settings page'
    Check 'and is in the secret store' `
          ((Get-TrackerSecret -Key 'pDME1:DMEKey' -AsPlainText) -eq 'PLAINTEXT-KEY-1234') `
          'moving it without storing it would break the profile'

    $rawAfter = Get-Content $script:SettingsFile -Raw
    Check 'and no longer on disk in the clear' `
          ($rawAfter -notmatch 'PLAINTEXT-KEY-1234') `
          'the point of the change is getting it off disk, not just out of the form'

    # ----------------------------------------------------------------------- #
    Write-Host "`nmigrating twice does not clobber a re-entered key"
    Set-TrackerSecret -Key 'pDME2:DMEKey' -Value 'NEWER-KEY-FROM-THE-FORM'
    $stale = @{
        version   = 1
        providers = @(
            @{ id = 'pDME2'; label = 'DME'; plugin = 'DMEasy';
               args = @{ DMEKey = 'OLDER-STALE-KEY' } }
        )
    }
    Save-TrackerSettings -Settings $stale
    $null = Get-TrackerSettings
    Check 'the stored key wins over the stale plaintext copy' `
          ((Get-TrackerSecret -Key 'pDME2:DMEKey' -AsPlainText) -eq 'NEWER-KEY-FROM-THE-FORM') `
          'a value typed into the form is newer than one left in settings.json'

    # ----------------------------------------------------------------------- #
    Write-Host "`nwhat Posh-ACME is handed"
    $prov = @{ id = 'pDME1'; plugin = 'DMEasy'; args = @{ DMEUseSandbox = $false } }
    $pa   = Get-ProviderPluginArgs -Provider $prov
    Check 'the API key is a plain string' `
          ($pa['DMEKey'] -is [string] -and $pa['DMEKey'] -eq 'PLAINTEXT-KEY-1234') `
          "got [$($pa['DMEKey'].GetType().Name)] - DMEasy declares [string] and would receive nonsense"

    Set-TrackerSecret -Key 'pDME1:DMESecret' -Value 'THE-SECRET'
    $pa2 = Get-ProviderPluginArgs -Provider $prov
    Check 'the secret key is still a SecureString' `
          ($pa2['DMESecret'] -is [System.Security.SecureString]) `
          "got [$($pa2['DMESecret'].GetType().Name)] - DMEasy's -DMESecret is a securestring parameter"

    # ----------------------------------------------------------------------- #
    Write-Host "`nthe other providers are untouched by the new flag"
    foreach ($pair in @(@('NS1','NS1Key'), @('Cloudflare','CFToken'))) {
        $arg = $script:PluginCatalog[$pair[0]].Args | Where-Object { $_.Name -eq $pair[1] }
        Check "$($pair[0]) still passes $($pair[1]) as a SecureString" `
              ([bool]$arg.Secret -and -not $arg.ContainsKey('PlainToPlugin')) `
              'those plugins declare securestring parameters'
    }
}
finally {
    Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:Failed) { Write-Host "$script:Failed CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
