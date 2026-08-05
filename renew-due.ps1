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

    [string]$ResultPath,

    [string]$RunLogPath,

    # Defaults to 'task' rather than 'cli': this script exists to be run by the
    # scheduler at 03:20, and that is the run whose provenance matters most.
    [string]$Source = 'task'
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'acme-lib.ps1')
[void](Start-RunLog -Kind 'renew-due' -Path $RunLogPath -Source $Source)

function Write-Log {
    param([string]$Message, [string]$Level = 'info')
    $line = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [$Level] $Message"
    Write-Output $line
    Write-RunLog $line     # this is the run that had no record at all before
}

$outcome = @{
    ok = $true; startedAt = (Get-Date).ToString('o')
    # 'preview' means -WhatIfOnly: the verdicts are real, nothing was acted on.
    # The page says which, so a forecast is never mistaken for work done.
    mode = $(if ($WhatIfOnly) { 'preview' } else { 'run' })
    considered = @(); renewed = @(); error = $null
}

function Save-Outcome {
    # Falls back to a fixed path when no -ResultPath was given. Every night this
    # script works out exactly when each certificate is next due - the CA's own
    # ARI date - and until now threw all of it away, because the scheduled task
    # passes no -ResultPath and this function returned here. Writing it by
    # default means the Home page can answer "when will it renew?" without the
    # task having to be re-registered to pass an argument.
    $path = $ResultPath
    if (-not $path) { $path = Join-Path $script:JobsDir 'renew-due-sweep.json' }
    $outcome.finishedAt = (Get-Date).ToString('o')
    try { Write-TextFileAtomic -Path $path -Content ($outcome | ConvertTo-Json -Depth 10) } catch { }
}

try {
    New-TrackerDirectories
    $settings = Get-TrackerSettings

    $checker = Get-CheckerResults
    if (-not $checker.results -or @($checker.results).Count -eq 0) {
        throw "There is no certificate data yet. Run check-ssl.ps1 first."
    }

    # Every watched host, not just the ones this run might renew - an
    # externally-managed certificate still deserves a warning if whatever
    # renews it elsewhere is running late. Never fatal: a bad SMTP setting
    # here must not stop the actual renewal work below. Skipped under
    # -WhatIfOnly, which promises a side-effect-free dry run.
    if (-not $WhatIfOnly) {
        try { Send-ExpiryAlerts -Settings $settings -Results @($checker.results) }
        catch { Write-Log "Expiry alerts could not be evaluated: $(($_.Exception.Message -split "`n")[0].Trim())" 'warn' }
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

            # '*' is not a legal character in a Posh-ACME order name, and
            # Get-PAOrder throws on it rather than returning nothing. New-PAOrder
            # stores wildcards as '!' (New-PAOrder.ps1:120), so ask for the name
            # it was actually filed under.
            #
            # Without this the throw was swallowed by the catch below, $order
            # stayed null, and every wildcard silently fell through to the plain
            # 30-day fallback - never using the CA's ARI window, and never
            # reporting a renewal date at all.
            $orderName = ([string]$cert.names[0]).Replace('*', '!')
            $order = Get-PAOrder -Name $orderName -ErrorAction SilentlyContinue
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
        # Recorded even though nothing changed. An empty stretch in the trail
        # would otherwise be ambiguous between "nothing needed doing" and "the
        # scheduler never fired", and telling those apart is the whole point.
        Write-AuditEvent -Event 'sweep' -Outcome 'ok' -Source $Source `
            -Detail "nothing due, $(@($renewable).Count) certificate(s) checked"
        Save-Outcome; exit 0
    }

    if ($WhatIfOnly) {
        Write-Log "$(@($due).Count) certificate(s) would be renewed. Stopping (-WhatIfOnly)." 'warn'
        Write-AuditEvent -Event 'sweep' -Outcome 'ok' -Source $Source `
            -Detail "$(@($due).Count) certificate(s) due, stopped without renewing (-WhatIfOnly)"
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

        # -Source rides along so the audit line for a 03:20 renewal says 'task'
        # and not 'cli'. Without it every unattended renewal would be recorded as
        # though a person had typed it, which is the one thing that column is for.
        $renewArgs = @('-Cert', $cert.certId, '-ResultPath', $resultFile, '-Source', $Source)
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

    # The per-certificate detail is already recorded by renew.ps1 and deploy.ps1.
    # This is the sweep itself: it ran, over this many, with this result.
    Write-AuditEvent -Event 'sweep' -Outcome $(if ($outcome.ok) { 'ok' } else { 'fail' }) -Source $Source `
        -Detail $(if ($outcome.ok) { "$(@($due).Count) certificate(s) renewed and deployed" }
                  else { "$failed of $(@($due).Count) certificate(s) failed" })

    Save-Outcome
    Invoke-LogRetention
    exit $(if ($outcome.ok) { 0 } else { 1 })
}
catch {
    $outcome.ok = $false
    $outcome.error = ($_.Exception.Message -split "`n")[0].Trim()
    Write-Log $outcome.error 'error'
    Write-AuditEvent -Event 'sweep' -Outcome 'fail' -Source $Source -Detail $outcome.error
    Save-Outcome
    exit 1
}
