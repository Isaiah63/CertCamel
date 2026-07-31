<#
  renew-due.ps1 - renew every certificate the certificate authority says is due,
  then deploy and verify it. This is the unattended entry point.

  Intended for a scheduled task on a machine that is always on:

      powershell -ExecutionPolicy Bypass -File .\renew-due.ps1

  Timing comes from the CA, not from a number we picked. ACME Renewal
  Information (ARI) has the authority tell each client when to come back, which
  matters for two reasons: it spreads load so every client on earth does not
  renew at midnight on day 60, and during a mass-revocation event the CA can
  pull every renewal window forward. A hard-coded "30 days before expiry" cannot
  hear that. The threshold below is only a fallback for a CA that offers no ARI.

  Exit codes:
     0  nothing was due, or everything due succeeded
     1  at least one certificate failed to renew or deploy
#>

[CmdletBinding()]
param(
    # Fallback window for a CA that publishes no ARI. Ignored when one does.
    [int]$FallbackDays = 30,

    # Report what would run and stop. Safe to schedule while you build trust.
    [switch]$WhatIfOnly,

    # Renew, but do not push to load balancers.
    [switch]$NoDeploy,

    [string]$ResultPath
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'acme-lib.ps1')

function Write-Log {
    param([string]$Message, [string]$Level = 'info')
    Write-Output "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [$Level] $Message"
}

$outcome = @{
    ok = $true; startedAt = (Get-Date).ToString('o')
    considered = @(); renewed = @(); error = $null
}

function Save-Outcome {
    if (-not $ResultPath) { return }
    $outcome.finishedAt = (Get-Date).ToString('o')
    try { Write-TextFileAtomic -Path $ResultPath -Content ($outcome | ConvertTo-Json -Depth 10) } catch { }
}

try {
    New-TrackerDirectories
    $settings = Get-TrackerSettings

    $checker = Get-CheckerResults
    if (-not $checker.results -or @($checker.results).Count -eq 0) {
        throw "There is no certificate data yet. Run check-ssl.ps1 first."
    }

    $grouping = Get-CertificateGroups -Results @($checker.results) -Settings $settings -ZoneCache (Get-ZoneCache)
    $renewable = @($grouping.certs | Where-Object { -not $_.external })

    if (-not $renewable.Count) {
        Write-Log "Nothing renewable is configured." 'warn'
        Save-Outcome; exit 0
    }

    Import-PoshAcme
    $now = Get-Date
    $due = @()

    foreach ($cert in $renewable) {
        $reason = $null
        $order  = $null

        # Posh-ACME stores the CA's renewal window on the order. Reading it needs
        # the right ACME server selected, since accounts and orders are per-CA.
        try {
            $ca = Get-CaProfile -Settings $settings -CaId $cert.caId
            Set-PAServer -DirectoryUrl (Get-ActiveDirectoryUrl -Ca $ca) -ErrorAction Stop
            $order = Get-PAOrder -Name $cert.names[0] -ErrorAction SilentlyContinue
        } catch { }

        if (-not $order) {
            # Never issued from here. Only due if something is actually expiring;
            # otherwise this would try to issue every tracked certificate on the
            # first scheduled run.
            if ($null -ne $cert.notAfter) {
                $days = [math]::Floor((([datetime]$cert.notAfter) - $now).TotalDays)
                if ($days -le $FallbackDays) { $reason = "never issued here, live certificate has $days day(s) left" }
            }
        }
        elseif ($order.PSObject.Properties['RenewAfter'] -and $order.RenewAfter) {
            $renewAfter = [datetime]$order.RenewAfter
            if ($now -ge $renewAfter) {
                $reason = "the CA's renewal window opened $($renewAfter.ToString('yyyy-MM-dd'))"
            }
        }
        else {
            # No ARI from this CA - fall back to a plain threshold.
            $expires = $null
            if ($order.PSObject.Properties['CertExpires'] -and $order.CertExpires) { $expires = [datetime]$order.CertExpires }
            elseif ($cert.notAfter) { $expires = [datetime]$cert.notAfter }

            if ($expires) {
                $days = [math]::Floor(($expires - $now).TotalDays)
                if ($days -le $FallbackDays) { $reason = "no ARI from this CA; $days day(s) left" }
            }
        }

        $outcome.considered += @{
            certId = $cert.certId; name = $cert.displayName
            due = [bool]$reason; reason = $reason
            renewAfter = $(if ($order -and $order.PSObject.Properties['RenewAfter']) { $order.RenewAfter } else { $null })
        }

        if ($reason) {
            $due += $cert
            Write-Log "DUE  $($cert.displayName) - $reason"
        } else {
            Write-Log "ok   $($cert.displayName) - not due yet"
        }
    }

    if (-not $due.Count) {
        Write-Log "Nothing is due. $(@($renewable).Count) certificate(s) checked." 'ok'
        Save-Outcome; exit 0
    }

    if ($WhatIfOnly) {
        Write-Log "$(@($due).Count) certificate(s) would be renewed. Stopping (-WhatIfOnly)." 'warn'
        Save-Outcome; exit 0
    }

    # One at a time, deliberately. Concurrent orders against the same DNS account
    # collide on the _acme-challenge record, and serialising also keeps a bad
    # night from burning the whole weekly rate limit in one go.
    $failed = 0
    foreach ($cert in $due) {
        Write-Log "-----------------------------------------------------------"
        Write-Log "Renewing $($cert.displayName)..."

        $renewScript = Join-Path $PSScriptRoot 'renew.ps1'
        $resultFile  = Join-Path $script:JobsDir "renew-due-$($cert.certId).json"

        $renewArgs = @('-Cert', $cert.certId, '-ResultPath', $resultFile)
        if ($NoDeploy) { $renewArgs += '-NoDeploy' }

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $renewScript @renewArgs 2>&1 |
          ForEach-Object { Write-Output $_ }

        $ok = ($LASTEXITCODE -eq 0)
        if (-not $ok) { $failed++ }
        $outcome.renewed += @{ certId = $cert.certId; name = $cert.displayName; ok = $ok }
        Save-Outcome
    }

    $outcome.ok = ($failed -eq 0)
    Write-Log "-----------------------------------------------------------"
    if ($outcome.ok) { Write-Log "$(@($due).Count) certificate(s) renewed and deployed." 'ok' }
    else             { Write-Log "$failed of $(@($due).Count) certificate(s) FAILED." 'error' }

    Save-Outcome
    exit $(if ($outcome.ok) { 0 } else { 1 })
}
catch {
    $outcome.ok = $false
    $outcome.error = ($_.Exception.Message -split "`n")[0].Trim()
    Write-Log $outcome.error 'error'
    Save-Outcome
    exit 1
}
