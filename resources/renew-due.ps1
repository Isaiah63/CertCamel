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
    # How many certificates this run set out to consider, and whether it
    # reached that many. The outer catch calls Save-Outcome too, which stamps
    # a fresh finishedAt over a TRUNCATED considered list - so age alone
    # reports a run that died on certificate two of five as freshly current.
    expected = $null; complete = $false
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
    # Derived here rather than at each exit: there are four (nothing
    # renewable, nothing due, -WhatIfOnly, and the outer catch) and a flag
    # set by hand would be missed by whichever one is added next. A run that
    # died before $renewable existed leaves expected $null, which is not
    # complete - correctly, since it never learned what it was meant to do.
    $outcome.complete = ($null -ne $outcome.expected -and
                         @($outcome.considered).Count -eq $outcome.expected)

    $outcome.finishedAt = (Get-Date).ToString('o')
        # The Home page reads this file to answer "when will it renew?". Losing it
        # is not fatal to the renewal that just happened, but it is worth saying so.
        try { Write-TextFileAtomic -Path $path -Content ($outcome | ConvertTo-Json -Depth 10) }
        catch { Write-RunLog "  ! could not write the sweep outcome: $(($_.Exception.Message -split "`n")[0].Trim())" }
}

try {
    New-TrackerDirectories
    $settings = Get-TrackerSettings

    # domains.txt is not an input to this sweep - the host set comes from the
    # checker's output - so an edit there changes nothing until a check runs.
    # That gap is what let three hostnames sit outside the forecast: the page
    # listed one certificate as the whole schedule while two of them were a
    # day from expiry.
    #
    # Re-checking here rather than firing a sweep when domains.txt is written
    # puts the trigger where the real dependency is, and makes the scheduled
    # run self-correcting after an edit from ANY of its three writers, with
    # no watcher and no new failure surface.
    #
    # Before Get-CheckerResults, not after: that throws when ssl-data.js is
    # absent, which is the fresh-install case this exists to get past.
    # Two LastWriteTimeUtc values, never finishedAt - that is written with a
    # local offset and comparing it against a UTC file time is wrong by the
    # offset, silently.
    $sslData = Join-Path $script:Root 'ssl-data.js'
    if ((Test-Path $script:DomainsFile) -and (Test-Path $sslData) -and
        ((Get-Item $script:DomainsFile).LastWriteTimeUtc -gt (Get-Item $sslData).LastWriteTimeUtc)) {
        Write-Log 'domains.txt changed since the last check - re-checking before working out what is due...'
        $prevEap = $ErrorActionPreference
        try {
            # Continue, because a native command writing to stderr is
            # terminating under Stop and the checker reports unreachable
            # hosts that way. Same guard the tail re-check uses.
            $ErrorActionPreference = 'Continue'
            & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                -File (Join-Path $PSScriptRoot 'check-ssl.ps1') -Source $Source 2>&1 |
              ForEach-Object { Write-Output $_ }
        }
        catch {
            Write-Log "The re-check did not run: $(($_.Exception.Message -split "`n")[0].Trim())" 'warn'
        }
        finally { $ErrorActionPreference = $prevEap }
    }

    $checker = Get-CheckerResults
    if (-not $checker.results -or @($checker.results).Count -eq 0) {
        throw "There is no certificate data yet. Run check-ssl.ps1 first."
    }

    $grouping = Get-CertificateGroups -Results @($checker.results) -Settings $settings -ZoneCache (Get-ZoneCache)
    $renewable = @($grouping.certs | Where-Object { -not $_.external })
    $outcome.expected = @($renewable).Count

    # AFTER the grouping, which it now needs: the countdown only goes to hosts
    # nothing here will renew, and $grouping is what says which those are.
    # Ordered the other way round it silently passed $null and warned about
    # every host, including the ones already handled.
    #
    # Never fatal - a bad SMTP setting must not stop the actual renewal work
    # below. Skipped under -WhatIfOnly, which promises a side-effect-free run.
    if (-not $WhatIfOnly) {
        try { Send-ExpiryAlerts -Settings $settings -Results @($checker.results) -Groups $grouping }
        catch { Write-Log "Expiry alerts could not be evaluated: $(($_.Exception.Message -split "`n")[0].Trim())" 'warn' }
    }

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

            # Matched on the domain SET, not on the first name - see
            # Resolve-PAOrderForCert. Looking it up by names[0] broke the moment
            # the name order changed, and broke silently: the order was not
            # found, this fell through to the plain day threshold, and the CA's
            # renewal window was ignored with nothing to show for it.
            $order = Resolve-PAOrderForCert -CertId $cert.certId -Names @($cert.names)
        } catch { $null = $_ }   # the per-certificate loop below reports the real failure

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
            # The names this entry keeps alive, recorded so a reader can ask
            # "will anything renew THIS host?" without going through certId.
            # certId is the folder under certs\, named from the grouping id at
            # the moment of issue, and that id legitimately changes afterwards -
            # see Get-TrackerAddressStatus, which used to compare the two and
            # call a perfectly healthy certificate abandoned.
            names = @($cert.names)
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

    # "Renewing tomorrow" - sent after the verdicts are known and before any
    # renewal runs, so it goes out the run BEFORE the one that acts. Needs the
    # next scheduled run to say when; with nothing scheduled there is no "about
    # to" and it is skipped rather than promising a run that will not come.
    if (-not $WhatIfOnly) {
        try {
            $nextRun = $null
            $rt = @((Get-AutomationStatus).tasks | Where-Object { $_.key -eq 'renew' })[0]
            if ($rt -and $rt.nextRun) { $nextRun = [datetime]$rt.nextRun }
            Send-ScheduledRenewalAlerts -Settings $settings -Considered @($outcome.considered) `
                -NextRun $nextRun -Groups $grouping
        }
        catch { Write-Log "Scheduled-renewal alerts could not be evaluated: $(($_.Exception.Message -split "`n")[0].Trim())" 'warn' }
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

        # -Zone, not -Cert. renew.ps1 takes -ZoneList (aliased -Zone) and
        # deploy.ps1 takes -CertList (aliased -Cert); the two scripts are called
        # the same way and take different names for the same-looking value, so
        # the deploy spelling reads as correct here and is not.
        #
        # This path only runs when a certificate is genuinely due, and
        # -WhatIfOnly stops before it, so the mismatch survived every safe check
        # there was until a real renewal came around.
        #
        # -Source rides along so the audit line for an unattended renewal says
        # 'task' and not 'cli'. Without it every unattended renewal would be
        # recorded as though a person had typed it, which is the one thing that
        # column is for.
        $renewArgs = @('-Zone', $cert.certId, '-ResultPath', $resultFile, '-Source', $Source)
        if ($NoDeploy) { $renewArgs += '-NoDeploy' }

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $renewScript @renewArgs 2>&1 |
          ForEach-Object { Write-Output $_ }

        $ok = ($LASTEXITCODE -eq 0)
        if (-not $ok) { $failed++ }
        $outcome.renewed += @{ certId = $cert.certId; name = $cert.displayName; ok = $ok }
        Save-Outcome
    }

    <#
      Everything below happened BEFORE this point in the old order of things, and
      that was the bug the page showed: the verdicts and the expiry data were
      both computed before anything renewed, so a certificate that had just been
      replaced still read as pending renewal until the next sweep or the next
      day's check. Refresh both while the run still knows what it did.
    #>
    $renewedOk = @($outcome.renewed | Where-Object { $_.ok })

    if ($renewedOk.Count) {
        # The verdicts were worked out before the renewals ran, so a certificate
        # that just renewed still carries the window that made it due. The child
        # process wrote the new window to the order on disk; re-importing is what
        # makes this process see it rather than its own cached copy.
        try {
            Import-PoshAcme
            foreach ($r in $renewedOk) {
                $cert = @($renewable | Where-Object { $_.certId -eq $r.certId })[0]
                if (-not $cert) { continue }

                $ca = Get-CaProfile -Settings $settings -CaId $cert.caId
                Set-PAServer -DirectoryUrl (Get-ActiveDirectoryUrl -Ca $ca) -ErrorAction Stop
                $fresh = Resolve-PAOrderForCert -CertId $cert.certId -Names @($cert.names)
                if (-not $fresh) { continue }

                foreach ($c in $outcome.considered) {
                    if ($c.certId -ne $r.certId) { continue }
                    $c.due    = $false
                    $c.reason = $null
                    $c.renewAfter = $(if ($fresh.PSObject.Properties['RenewAfter']) { $fresh.RenewAfter } else { $null })
                }
            }
        }
        catch {
            # A stale verdict is a cosmetic problem and the renewal already
            # succeeded; failing the run over it would be the wrong trade.
            Write-Log "Could not refresh the renewal forecast: $(($_.Exception.Message -split "`n")[0].Trim())" 'warn'
        }

        # The certificate being served changed, so every expiry date the page
        # shows is now wrong until the checker runs again - which is otherwise
        # not until tomorrow morning.
        #
        # ErrorActionPreference is Stop for this script, and under Stop ANY
        # native command writing to stderr raises a terminating error. Left
        # alone, a checker warning would abandon a run whose renewals had all
        # succeeded - which is how a wrong parameter took down the whole sweep
        # once already.
        Write-Log "Re-checking what is being served now..."
        $prevEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                -File (Join-Path $PSScriptRoot 'check-ssl.ps1') -Source $Source 2>&1 |
              ForEach-Object { Write-Output $_ }
        }
        catch {
            Write-Log "The re-check did not run: $(($_.Exception.Message -split "`n")[0].Trim())" 'warn'
        }
        finally { $ErrorActionPreference = $prevEap }
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

    # renew.ps1 alerts per certificate, but only once it is running. A run that
    # ends with failures still has to say so at the run level, because the
    # failures that matter most are the ones that stop it getting that far.
    if (-not $outcome.ok) {
        Send-SweepFailureAlert -Settings $settings `
            -ErrorMessage "$failed of $(@($due).Count) certificate(s) failed to renew." `
            -FailedNames @($outcome.renewed | Where-Object { -not $_.ok } | ForEach-Object { $_.name })
    }

    Invoke-LogRetention
    exit $(if ($outcome.ok) { 0 } else { 1 })
}
catch {
    $outcome.ok = $false
    $outcome.error = ($_.Exception.Message -split "`n")[0].Trim()
    Write-Log $outcome.error 'error'
    Write-AuditEvent -Event 'sweep' -Outcome 'fail' -Source $Source -Detail $outcome.error
    Save-Outcome

    # The path the wrong-parameter bug took: renew.ps1 wrote to stderr, which is
    # terminating under $ErrorActionPreference = 'Stop', so the run died here
    # having alerted nobody. $settings may be unset if the failure came before
    # it was read, in which case there is nothing to send with.
    # -WhatIfOnly promises a side-effect-free run, and every other alert call
    # here is guarded. Unguarded, a preview that throws emails "the unattended
    # renewal run did not complete" about a run nobody scheduled - and because
    # repeats are held to one a day per error message, a persistent fault hit
    # during a preview silences the real scheduled failure later that day.
    if ($settings -and -not $WhatIfOnly) {
        Send-SweepFailureAlert -Settings $settings -ErrorMessage $outcome.error
    }

    exit 1
}
