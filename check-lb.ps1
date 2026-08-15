<#
  check-lb.ps1 - ask every configured load balancer node whether it is alive,
  and write the answer to jobs\lb-status.json for the Home page to read.

  Runs as a DETACHED CHILD, never inside serve.ps1. A node that blackholes
  packets takes ten seconds to fail and serve.ps1 handles one connection at a
  time, so probing on the request thread would freeze the whole UI - at exactly
  the moment somebody is trying to find out what is wrong with it.

  Reports only what the Data Plane API can actually be asked for: the node's own
  name, the running HAProxy version, and whether it answered at all.

  It does NOT report VRRP state, and cannot. MASTER/BACKUP lives in keepalived,
  which has no API; HAProxy binds its frontends on every node regardless of who
  holds the virtual address, and has no idea one exists. Anything shown here
  claiming otherwise would be a guess.

      powershell -ExecutionPolicy Bypass -File .\check-lb.ps1
#>

[CmdletBinding()]
param(
    [string]$RunLogPath,
    [string]$Source = 'task',
    # Per node, per attempt. Short deliberately - see the note above.
    [int]$TimeoutSeconds = 5
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'acme-lib.ps1')

New-TrackerDirectories
$script:RunLogSource = $Source
if ($RunLogPath) { $script:RunLogPath = $RunLogPath }

function Write-Line { param([string]$Text, [string]$Level = 'info')
    Write-Host $Text
    try { Write-RunLog $Text } catch { }
}

$settings = Get-TrackerSettings
$targets  = @($settings.targets)

$result = @{
    checkedAt = (Get-Date).ToString('o')
    targets   = @()
}

if (-not $targets.Count) {
    # Not an error. Plenty of installs only watch and renew, and never deploy
    # anywhere - the Home page hides the panel entirely in that case.
    Write-Line "No load balancer targets are configured. Nothing to check."
    Write-TextFileAtomic -Path $script:LbStatusFile -Content ($result | ConvertTo-Json -Depth 12)
    exit 0
}

Write-Line "Checking $($targets.Count) load balancer group(s)..."

foreach ($t in $targets) {
    $entry = @{
        id    = [string]$t.id
        label = [string]$t.label
        type  = [string]$t.type
        nodes = @()
    }

    # Read once per group rather than per node: Get-TargetSecret decrypts, and
    # doing that inside the loop would be work for no gain.
    $user  = Get-TargetArg -Target $t -Name 'user'
    $pass  = Get-TargetSecret -TargetId $t.id -Name 'password'
    $insec = [bool](Get-TargetArg -Target $t -Name 'insecureTls' -Default $false)

    foreach ($n in @($t.nodes)) {
        $name = [string]$n.name
        Write-Line "  $($t.label) / $name -> $($n.url)"

        $s = Get-HAProxyNodeStatus -BaseUrl ([string]$n.url) -User $user -Password $pass `
                -InsecureTls:$insec -TimeoutSeconds $TimeoutSeconds

        $frontends = @()
        $feError   = $null

        if ($s.reachable) {
            Write-Line "    ok - node '$($s.node)', HAProxy $($s.haproxyVersion), API $($s.apiVersion)"

            # Read the configuration back so the page can answer the question
            # neither verification tier can: does any bind actually READ the
            # crt-list a certificate is deployed to? Only attempted when the
            # node answered - there is nothing to ask otherwise.
            $fe = Get-HAProxyFrontendBinds -BaseUrl ([string]$n.url) -User $user -Password $pass `
                    -ApiVersion $s.apiVersion -InsecureTls:$insec -TimeoutSeconds $TimeoutSeconds

            if ($fe.ok) {
                $frontends = @($fe.frontends)
                $tls = @($frontends | ForEach-Object { $_.binds } | Where-Object { $_.ssl }).Count
                Write-Line "    $(@($frontends).Count) frontend(s), $tls TLS bind(s)"
            } else {
                $feError = $fe.error
                Write-Line "    could not read the configuration - $($fe.error)" 'warn'
            }
        } else {
            Write-Line "    unreachable - $($s.error)" 'warn'
        }

        # Only the fields the page shows. The credential is never any of them,
        # and neither $s nor $fe carries a copy of it to leak by accident.
        $entry.nodes += @{
            name           = $name
            url            = [string]$n.url
            reachable      = [bool]$s.reachable
            node           = $s.node
            haproxyVersion = $s.haproxyVersion
            apiVersion     = $s.apiVersion
            error          = $s.error
            frontends      = $frontends
            frontendError  = $feError
        }
    }

    $result.targets += $entry
}

$up   = @($result.targets | ForEach-Object { $_.nodes } | Where-Object { $_.reachable }).Count
$all  = @($result.targets | ForEach-Object { $_.nodes }).Count
Write-Line ""
Write-Line "$up of $all node(s) answering."

# Depth 12, not the default and not 6. The nesting reaches
# result > targets > target > nodes > node > frontends > frontend > binds > bind,
# which is nine levels before a bind's own fields - and ConvertTo-Json truncates
# past its depth SILENTLY, writing a file that looks fine and has empty binds.
# That is exactly what happened at 6.
Write-TextFileAtomic -Path $script:LbStatusFile -Content ($result | ConvertTo-Json -Depth 12)
Write-Line "Wrote $($script:LbStatusFile)."
exit 0
