<#
  The permissions that protect the private keys, and the one rule in them that
  looks redundant and is not.

  Set-CamelAcl grants three principals: SYSTEM, Administrators, and the account
  it is running as. That third rule is the whole reason this test exists.

  The scheduled tasks run -RunLevel Limited, which hands the process a FILTERED
  token, and in a filtered token the Administrators SID grants nothing. A folder
  given only to SYSTEM and Administrators is therefore a folder the running
  server CANNOT READ - while every interactive check of it passes, because a
  person testing by hand is elevated. Delete that rule as "covered by
  Administrators anyway" and renewal breaks only when unattended, which is the
  hardest possible way to find out.

  Identities are asserted as SIDs rather than names on purpose:
  "BUILTIN\Administrators" is localised, and a name that fails to resolve on a
  non-English Windows would simply not be added - the same lockout, reached by a
  different route.

  Exits non-zero on failure.

      powershell -ExecutionPolicy Bypass -File .\v14-install-acl-test.ps1
#>

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'acme-lib.ps1')

$script:Failed = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    if ($Ok) { Write-Host "  ok   $Name" -ForegroundColor Green }
    else     { Write-Host "  FAIL $Name  -- $Detail" -ForegroundColor Red; $script:Failed++ }
}

$SYSTEM = 'S-1-5-18'
$ADMINS = 'S-1-5-32-544'
$ME     = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

function New-Scratch {
    $p = Join-Path $env:TEMP ('camel-acl-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}
function Get-ExplicitSids {
    param([string]$Path)
    return @((Get-Acl -Path $Path).GetAccessRules(
                $true, $false, [Security.Principal.SecurityIdentifier]) |
             Where-Object { $_.AccessControlType -eq 'Allow' } |
             ForEach-Object { $_.IdentityReference.Value })
}

# --------------------------------------------------------------------------- #
Write-Host "`na directory, with children that inherit"
$dir = New-Scratch
try {
    New-Item -ItemType Directory -Path (Join-Path $dir 'sub') -Force | Out-Null
    Set-Content -Path (Join-Path $dir 'sub\existing.txt') -Value 'x' -Encoding Ascii

    Set-CamelAcl -Path $dir -Inheritable
    $sids = Get-ExplicitSids -Path $dir

    Check 'inheritance from the parent is broken' `
          ((Get-Acl -Path $dir).AreAccessRulesProtected) `
          'the folder still inherits, so tightening the parent is the only thing protecting it'
    Check 'exactly three rules, no others left behind' ($sids.Count -eq 3) "got $($sids.Count): $($sids -join ', ')"
    Check 'grants SYSTEM'                       ($sids -contains $SYSTEM) 'scheduled work running as SYSTEM would be locked out'
    Check 'grants Administrators'               ($sids -contains $ADMINS) 'an operator could not read it'
    Check 'grants the account it runs as'       ($sids -contains $ME) `
          'THE FILTERED-TOKEN RULE IS MISSING - the server would be unable to read its own files while every elevated test passed'

    # A file created after the fact is the case that matters: renewals write new
    # certificate folders long after setup has finished.
    Set-Content -Path (Join-Path $dir 'sub\created-later.txt') -Value 'y' -Encoding Ascii
    $later = @((Get-Acl -Path (Join-Path $dir 'sub\created-later.txt')).Access | Where-Object { $_.IsInherited })
    Check 'a file created afterwards inherits the restriction' ($later.Count -ge 3) `
          "only $($later.Count) inherited rules - a certificate written later would not be protected"

    $existing = @((Get-Acl -Path (Join-Path $dir 'sub\existing.txt')).Access | Where-Object { $_.IsInherited })
    Check 'a file that was already there picks it up too' ($existing.Count -ge 3) `
          "only $($existing.Count) inherited rules"
}
finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }

# --------------------------------------------------------------------------- #
Write-Host "`na file, where inheritance flags are invalid rather than merely pointless"
$dir2 = New-Scratch
try {
    $f = Join-Path $dir2 'secret.xml'
    Set-Content -Path $f -Value 'x' -Encoding Ascii

    Set-CamelAcl -Path $f
    $rules = @((Get-Acl -Path $f).GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))

    Check 'the same three principals'  ($rules.Count -eq 3) "got $($rules.Count)"
    Check 'no inheritance flags on a file' `
          (@($rules | Where-Object { $_.InheritanceFlags -ne 'None' }).Count -eq 0) `
          'inheritance flags on a file are rejected by Windows, so this would throw at setup'

    # -Inheritable is accepted and ignored for a file rather than throwing:
    # Protect-CamelInstall passes a mix of files and folders and should not need
    # to know which is which beyond choosing the flag.
    $threw = $false
    try { Set-CamelAcl -Path $f -Inheritable } catch { $threw = $true }
    Check '-Inheritable on a file is ignored, not fatal' (-not $threw) 'threw instead of ignoring the flag'
}
finally { Remove-Item -LiteralPath $dir2 -Recurse -Force -ErrorAction SilentlyContinue }

# --------------------------------------------------------------------------- #
Write-Host "`nrunning it twice, which setup explicitly allows"
# Not merely an optimisation. Re-applying an identical DACL to a path whose DACL
# is already protected fails with "The process does not possess the
# 'SeSecurityPrivilege' privilege", so without the already-correct check a
# second setup run threw on every path the first run had protected.
$dir3 = New-Scratch
try {
    $g = Join-Path $dir3 'file.txt'
    Set-Content -Path $g -Value 'x' -Encoding Ascii

    Set-CamelAcl -Path $dir3 -Inheritable
    $firstDir = Get-ExplicitSids -Path $dir3

    $err = ''
    try { Set-CamelAcl -Path $dir3 -Inheritable } catch { $err = ($_.Exception.Message -split "`n")[0].Trim() }
    Check 'a second pass over a folder is a no-op' ($err -eq '') $err

    $err = ''
    Set-CamelAcl -Path $g
    try { Set-CamelAcl -Path $g } catch { $err = ($_.Exception.Message -split "`n")[0].Trim() }
    Check 'a second pass over a file is a no-op' ($err -eq '') $err

    Check 'the second pass left the rules alone' `
          (@(Compare-Object $firstDir (Get-ExplicitSids -Path $dir3)).Count -eq 0) `
          'the repeat run changed the access rules'
}
finally { Remove-Item -LiteralPath $dir2 -Recurse -Force -ErrorAction SilentlyContinue }

# --------------------------------------------------------------------------- #
Write-Host "`nrefusals"
$threw = $false
try { Set-CamelAcl -Path (Join-Path $env:TEMP ('camel-absent-' + [Guid]::NewGuid().ToString('N'))) }
catch { $threw = $true }
Check 'a path that does not exist is refused' $threw `
      'silently succeeding on a missing path would report protection that was never applied'

# --------------------------------------------------------------------------- #
Write-Host "`nthe set of paths that get protected"
# Get-CamelProtectedPaths, never Protect-CamelInstall: calling the latter here
# would harden the real install as a side effect of running the tests, and on an
# unelevated machine putting it back needs a privilege this process lacks.
$targets = @(Get-CamelProtectedPaths)
$labels  = @($targets | ForEach-Object { $_.label })

foreach ($needed in @('install folder', 'certificates', 'ACME state', 'job files', 'secrets.xml', 'audit.log')) {
    Check "covers '$needed'" ($labels -contains $needed) `
          'not in the list, so nothing would ever protect it and no failure would be reported either'
}

Check 'the install root is covered' `
      (@($targets | Where-Object { $_.path -eq $script:Root }).Count -eq 1) `
      'without the root, an ordinary user can still reach the launchers'

Check 'the root is inheritable, so children are covered by one write' `
      ([bool](@($targets | Where-Object { $_.path -eq $script:Root })[0].inheritable)) `
      'a non-inheriting root would need a walk over every file to protect anything'

foreach ($fileTarget in @($script:SecretsFile, $script:AuditFile)) {
    $t = @($targets | Where-Object { $_.path -eq $fileTarget })
    Check "$([IO.Path]::GetFileName($fileTarget)) is not marked inheritable" `
          ($t.Count -eq 1 -and -not $t[0].inheritable) `
          'inheritance flags on a file are rejected by Windows'
}

Write-Host ""
if ($script:Failed) { Write-Host "$script:Failed CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
