<#
  status-summary.ps1 - what every scheduled task, certificate and load balancer
  is doing, emailed at whatever frequency Settings asks for.

  This exists so nobody has to sign in to a server to find out that nothing is
  wrong. Two decisions follow from that and are worth stating, because both look
  like mistakes until you know the reason:

  1. THE VERDICT IS IN THE SUBJECT LINE. A daily mail you must OPEN to learn
     that nothing is wrong has simply moved the chore from the server to the
     inbox. On a good day this should cost one glance at a preview pane.

  2. IT SENDS ON GOOD DAYS TOO. There is deliberately no "only mail me when
     something changed" option. Silence is ambiguous - nothing wrong, or the
     tool is dead? - and that ambiguity is the whole thing being fixed. Sent
     unconditionally, a missing email is itself the alarm, which is why the
     footer says when the next one is due.

  Registered as a DAILY task whatever the cadence, and it checks for itself
  whether today is a send day. PowerShell 5.1's New-ScheduledTaskTrigger has no
  monthly trigger and the CIM one it does not expose is more machinery than an
  email justifies - and a script that reads its own setting can be tested by
  handing it a date. Was monthly-report.ps1, which worked the same way.

      powershell -ExecutionPolicy Bypass -File .\status-summary.ps1
      powershell -ExecutionPolicy Bypass -File .\status-summary.ps1 -Force
#>

[CmdletBinding()]
param(
    # Send even when today is not a send day. For testing.
    [switch]$Force,

    # Compose and print, send nothing. Answers "what would today's mail say"
    # without spending a message or touching the audit trail.
    [switch]$WhatIfOnly,

    [string]$RunLogPath,
    [string]$Source = 'task'
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'acme-lib.ps1')

function Write-Log {
    param([string]$Message, [string]$Level = 'info')
    $line = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [$Level] $Message"
    Write-Output $line
    Write-RunLog $line
}

try {
    $settings = Get-TrackerSettings
    $now      = Get-Date

    $cadence = 'off'
    try { $cadence = [string]$settings.alerts.summary.cadence } catch { $cadence = 'off' }

    if ($cadence -eq 'off' -and -not $Force) {
        Write-Log "The status summary is switched off in Settings."
        exit 0
    }
    if (-not $Force -and -not (Test-SummaryDue -Settings $settings -Now $now)) {
        Write-Log "Not a send day for the '$cadence' summary; nothing to do. (-Force to send anyway.)"
        exit 0
    }

    # -WhatIfOnly answers "what would today's mail say" and must leave nothing
    # behind, so it runs before the run log is opened as well as before the
    # send. A preview that files a job log is not a preview.
    if ($WhatIfOnly) {
        $preview = New-StatusSummaryMessage -Settings $settings -Now $now
        Write-Output "Subject: $($preview.subject)"
        Write-Output ""
        Write-Output (Format-AlertText -Message $preview.message)
        exit 0
    }

    New-TrackerDirectories

    # Deliberately after the date check, exactly as the monthly version did.
    # This task fires daily and does nothing on most of those days for a weekly
    # or monthly cadence; opening a log first would leave an empty file for each
    # of them and bury the one run that matters.
    [void](Start-RunLog -Kind 'status-summary' -Path $RunLogPath -Source $Source)

    $built   = New-StatusSummaryMessage -Settings $settings -Now $now
    $subject = [string]$built.subject

    try {
        # Captured, not left to fall out of the pipeline: Send-AlertEmail
        # returns a receipt, and an uncaptured hashtable would print itself into
        # this run log.
        $receipt = Send-AlertEmail -Settings $settings -Subject $subject -Message $built.message
        Write-EmailAuditEvent -Receipt $receipt -Subject $subject -Source $Source
        # "Accepted", not "sent" - that is all a returning Send() establishes.
        Write-Log "Status summary accepted by $($receipt.host) for $((@($receipt.to)) -join ', '); id $($receipt.messageId)." 'ok'
    }
    catch {
        $why = ($_.Exception.Message -split "`n")[0].Trim()
        Write-EmailAuditEvent -ErrorMessage $why -Subject $subject -Source $Source
        Write-Log "Status summary could not be sent: $why" 'error'
        exit 1
    }

    exit 0
}
catch {
    Write-Log "$(($_.Exception.Message -split "`n")[0].Trim())" 'error'
    exit 1
}
