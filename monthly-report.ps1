<#
  monthly-report.ps1 - a summary email of what needs attention, on the 1st of
  the month.

  The ScheduledTasks module has no clean "run monthly" trigger through
  New-ScheduledTaskTrigger - the parameter set only covers daily, weekly and
  logon/startup triggers, and the CIM monthly trigger it does not expose is
  more machinery than a once-a-month email justifies. So this is registered as
  a DAILY task, like the checker and renew-due.ps1, and checks the date itself:
  every day but the 1st it does nothing and exits 0. Simpler to read, simpler
  to test (run it any day with -Force), and there is nothing to get wrong in a
  trigger definition this script does not have to trust.

      powershell -ExecutionPolicy Bypass -File .\monthly-report.ps1
      powershell -ExecutionPolicy Bypass -File .\monthly-report.ps1 -Force
#>

[CmdletBinding()]
param(
    # Send even when today is not the 1st. For testing.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'acme-lib.ps1')

function Write-Log {
    param([string]$Message, [string]$Level = 'info')
    Write-Output "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [$Level] $Message"
}

try {
    if (-not $Force -and (Get-Date).Day -ne 1) {
        Write-Log "Not the 1st of the month; nothing to do. (-Force to send anyway.)"
        exit 0
    }

    New-TrackerDirectories
    $settings = Get-TrackerSettings

    if (-not $settings.alerts -or -not $settings.alerts.monthlySummary.enabled) {
        Write-Log "Monthly summary is not enabled in Settings."
        exit 0
    }

    $checker = Get-CheckerResults
    $results = @($checker.results)
    if (-not $results.Count) {
        Write-Log "No certificate data yet - nothing to summarise."
        exit 0
    }

    $now = Get-Date
    $failing = @($results | Where-Object { -not $_.ok })
    $dueSoon = @($results | Where-Object {
        $_.ok -and $_.notAfter -and (([datetime]$_.notAfter) - $now).TotalDays -le 31
    } | Sort-Object { [datetime]$_.notAfter })

    $lines = @()
    $lines += "Cert Camel monthly summary - $($now.ToString('yyyy-MM-dd'))"
    $lines += ""

    if ($dueSoon.Count) {
        $lines += "Due within 31 days ($($dueSoon.Count)):"
        foreach ($r in $dueSoon) {
            $days = [math]::Floor(([datetime]$r.notAfter - $now).TotalDays)
            $lines += "  $($r.host)  -  $days day(s), expires $(([datetime]$r.notAfter).ToString('yyyy-MM-dd'))"
        }
    }
    else {
        $lines += "Nothing is due within 31 days."
    }
    $lines += ""

    if ($failing.Count) {
        $lines += "Currently failing checks ($($failing.Count)):"
        foreach ($r in $failing) {
            $lines += "  $($r.host)  -  $($r.error)"
        }
    }
    else {
        $lines += "No hosts are currently failing their check."
    }
    $lines += ""
    $lines += "Checker last ran $($checker.generated)."

    try {
        Send-AlertEmail -Settings $settings -Subject "Cert Camel monthly summary - $($now.ToString('yyyy-MM'))" `
            -Body ($lines -join "`r`n")
        Write-Log "Monthly summary sent." 'ok'
    }
    catch {
        Write-Log "Monthly summary could not be sent: $(($_.Exception.Message -split "`n")[0].Trim())" 'error'
        exit 1
    }

    exit 0
}
catch {
    Write-Log "$(($_.Exception.Message -split "`n")[0].Trim())" 'error'
    exit 1
}
