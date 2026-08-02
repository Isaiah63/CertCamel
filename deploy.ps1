<#
  deploy.ps1 - push issued certificates to their deployment targets and verify
  that the targets are genuinely serving them.

  Normally started by serve.ps1 as a hidden child process when you press Deploy,
  with its output captured into jobs\<id>.log, and called by renew.ps1 straight
  after a successful issuance. It also runs standalone, which is what makes it
  usable from a scheduled task:

      powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -Cert example.com

  Verification runs in tiers, because "the API returned 200" is not evidence
  that anything is being served:

      T0  the bundle is valid at all        - before anything is pushed
      T1  the API accepted it               - per node
      T3  the node is actually serving it   - per node, per name, by serial

  T2 (present in HAProxy's memory) is covered implicitly: the Data Plane API
  pushes to the runtime socket and only falls back to a reload if that fails, so
  a node that passes T3 has necessarily loaded it.
#>

[CmdletBinding()]
param(
    # Certificate identifiers as shown in the Certificates table
    # ("example.com", "wildcard.example.com"). Omit to deploy every certificate
    # that has targets configured.
    [Alias('Cert')]
    [string[]]$CertList,

    # Restrict to these target groups. Omit to use every target the certificate
    # is assigned to. Named plural because a certificate can legitimately go to
    # several groups - production and DR, say - and picking a subset at run time
    # is the point of the deployment dialog.
    [Alias('TargetId')]
    [string[]]$TargetList,

    # Where to drop the machine-readable outcome, for the page to read.
    [string]$ResultPath,

    # Push without checking what the nodes end up serving. Only for debugging a
    # transport problem - a deployment nobody verified is a deployment nobody
    # can trust.
    [switch]$SkipVerify,

    [int]$VerifyTimeoutSeconds = 10
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'acme-lib.ps1')

function Write-Log {
    param([string]$Message, [string]$Level = 'info')
    Write-Output "[$((Get-Date).ToString('HH:mm:ss'))] [$Level] $Message"
}

$outcome = @{
    ok = $false; startedAt = (Get-Date).ToString('o'); results = @(); error = $null
}

function Save-Outcome {
    if (-not $ResultPath) { return }
    $outcome.finishedAt = (Get-Date).ToString('o')
    try { Write-TextFileAtomic -Path $ResultPath -Content ($outcome | ConvertTo-Json -Depth 10) }
    catch { Write-Log "Could not write the result file: $($_.Exception.Message)" 'warn' }
}

# The address to connect to for verification. Defaults to the host part of the
# Data Plane API URL, since the API and the served site are normally the same
# machine - but a node can override it when they differ.
#
# The override may carry its own port ("lb1.internal:8443"), which wins over the
# group's verify port. Nodes usually all serve on the same port and the group
# setting is the right place for it; the exception is reaching each node through
# a separate forward, where every node answers on a different local port. Without
# a per-node port those setups cannot verify each node individually at all - and
# checking them one at a time is the whole point of T3.
function Resolve-VerifyTarget {
    param($Node, [int]$DefaultPort)

    $override = $null
    if ($Node.PSObject.Properties['verifyHost'] -and $Node.verifyHost) {
        $override = [string]$Node.verifyHost
    }
    elseif ($Node -is [hashtable] -and $Node.ContainsKey('verifyHost') -and $Node.verifyHost) {
        $override = [string]$Node.verifyHost
    }

    if ($override) {
        # Split a trailing :port off, but leave a bare IPv6 literal alone - it is
        # colons all the way down, and "::1" is a host, not a host and a port.
        $m = [regex]::Match($override.Trim(), '^(?<h>\[[^\]]+\]|[^:]+):(?<p>\d+)$')
        if ($m.Success) {
            return @{ host = $m.Groups['h'].Value.Trim('[', ']'); port = [int]$m.Groups['p'].Value }
        }
        return @{ host = $override.Trim(); port = $DefaultPort }
    }

    $h = $null
    try { $h = ([Uri]$Node.url).Host } catch { }
    return @{ host = $h; port = $DefaultPort }
}

try {
    New-TrackerDirectories

    $settings = Get-TrackerSettings
    $checker  = Get-CheckerResults
    if (-not $checker.results -or @($checker.results).Count -eq 0) {
        throw "There is no certificate data yet. Run 'Check Now.bat' first."
    }

    $grouping = Get-CertificateGroups -Results @($checker.results) -Settings $settings -ZoneCache (Get-ZoneCache)

    # --- decide what to deploy ------------------------------------------- #

    $planned = @()
    if ($CertList -and @($CertList).Count) {
        foreach ($c in $CertList) {
            $cl = $c.ToLowerInvariant()
            if (-not (Test-SafeCertName $cl)) { throw "'$c' is not a valid certificate name." }
            $cert = @($grouping.certs | Where-Object { $_.certId -eq $cl })[0]
            if (-not $cert) { throw "'$c' is not a known certificate." }
            $planned += $cert
        }
    }
    else {
        foreach ($cert in @($grouping.certs)) {
            $cfg = $null
            if ($settings.certs -and $settings.certs.ContainsKey($cert.certId)) { $cfg = $settings.certs[$cert.certId] }
            if ($cfg -and $cfg.ContainsKey('targets') -and @($cfg.targets).Count) { $planned += $cert }
        }
        if (-not $planned.Count) { throw "No certificate has a deployment target configured." }
    }

    # --- deploy each ------------------------------------------------------ #

    foreach ($cert in $planned) {
        $certId = $cert.certId
        $entry  = @{ certId = $certId; name = $cert.displayName; ok = $false
                     preflight = $null; targets = @(); error = $null }

        Write-Log "-----------------------------------------------------------"
        Write-Log "Deploying: $($cert.displayName)"

        try {
            $pemPath = Join-Path (Join-Path $script:CertsDir $certId) "$certId-full.pem"
            if (-not (Test-Path -LiteralPath $pemPath)) {
                throw "No issued certificate on disk yet. Renew it before deploying."
            }

            # --- T0: never push a bundle that is broken ------------------- #
            # The tier labels are worth keeping - they are short enough to grep
            # for and to quote in a bug report - but they mean nothing to anyone
            # reading this log for the first time. Spell them out once per run,
            # rather than annotating each line and repeating it per node per
            # certificate.
            if (-not $script:LegendShown) {
                Write-Log "Checks: T0 the bundle is valid | T1 the node's API accepted it | T3 the node is really serving it"
                $script:LegendShown = $true
            }
            Write-Log "T0  validating the bundle..."
            $pre = Test-CertificateBundle -Path $pemPath -ExpectedNames @($cert.names)
            $entry.preflight = $pre

            foreach ($c in $pre.checks) {
                Write-Log ("      [{0}] {1} - {2}" -f $(if ($c.pass) {'ok  '} else {'FAIL'}), $c.name, $c.detail) `
                          $(if ($c.pass) { 'info' } else { 'error' })
            }
            if (-not $pre.ok) { throw "Pre-flight failed; nothing was pushed. $($pre.errors -join '; ')" }

            Write-Log "T0  ok - bundle valid, serial $($pre.serial), expires $(([datetime]$pre.notAfter).ToString('yyyy-MM-dd'))" 'ok'
            $pem = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($pemPath))

            # --- which targets -------------------------------------------- #
            $targetIds = @()
            if ($settings.certs -and $settings.certs.ContainsKey($certId)) {
                $cfg = $settings.certs[$certId]
                if ($cfg.ContainsKey('targets')) { $targetIds = @($cfg.targets) }
            }
            # A run-time selection replaces the stored assignment outright rather
            # than filtering it, so a newly added group can be deployed to before
            # anyone has got round to assigning it.
            if ($TargetList -and @($TargetList).Count) { $targetIds = @($TargetList) }

            if (-not $targetIds.Count) { throw "No deployment target is assigned to this certificate." }

            foreach ($tid in $targetIds) {
                $target = Get-TargetProfile -Settings $settings -TargetId $tid
                if (-not $target) { Write-Log "Target '$tid' is no longer configured - skipping." 'warn'; continue }

                $tResult = @{ targetId = $tid; label = $target.label; ok = $false; nodes = @() }

                $user     = Get-TargetArg -Target $target -Name 'user'
                $password = Get-TargetSecret -TargetId $tid -Name 'password'
                $insecure = [bool](Get-TargetArg -Target $target -Name 'insecureTls' -Default $false)
                $port     = [int](Get-TargetArg -Target $target -Name 'verifyPort' -Default 443)

                $remoteName = Get-TargetArg -Target $target -Name 'remoteName' -Default "$certId.pem"
                $remoteName = $remoteName.Replace('{certId}', $certId)

                Write-Log "Target: $($target.label)  ->  $remoteName"

                foreach ($node in @($target.nodes)) {
                    $nodeName = if ($node.name) { $node.name } else { $node.url }

                    # Resolve the verification address here, while the node
                    # object is in hand, so T3 does not have to match nodes back
                    # up by name afterwards.
                    $vt = Resolve-VerifyTarget -Node $node -DefaultPort $port
                    $nResult = @{
                        name = $nodeName; url = $node.url; push = $null; verify = @()
                        verifyHost = $vt.host; verifyPort = $vt.port
                    }

                    # --- T1: transport ------------------------------------ #
                    Write-Log "  $nodeName : pushing..."
                    $push = Push-CertificateToNode -BaseUrl $node.url -User $user -Password $password `
                                -RemoteName $remoteName -PemContent $pem -InsecureTls:$insecure
                    $nResult.push = $push

                    if ($push.ok) {
                        Write-Log "  $nodeName : T1 ok - upload accepted ($($push.action), API $($push.apiVersion))" 'ok'
                        # The API rewrites dots in a filename to underscores, so
                        # the name on disk is often not the name that was asked
                        # for. HAProxy loads certificates by path, so the bind
                        # line has to use the real one - say so plainly rather
                        # than letting T3 fail later with no explanation.
                        if ($push.renamed) {
                            Write-Log "  $nodeName : stored as '$($push.storedName)', not '$($push.remoteName)' - your bind line or crt-list must reference '$($push.storedName)'" 'warn'
                        }
                    }
                    else { Write-Log "  $nodeName : T1 FAILED - upload rejected - $($push.error)" 'error' }

                    $tResult.nodes += $nResult
                }

                $tResult.ok = (@($tResult.nodes | Where-Object { -not $_.push.ok }).Count -eq 0)
                $entry.targets += $tResult
            }

            # --- T3: what is each node actually serving? ------------------ #
            if (-not $SkipVerify) {
                # Deliberately after every push, and against every node
                # individually. Verifying through a floating VIP only ever tests
                # whichever node currently holds it, so a node that missed the
                # push stays invisible until failover - exactly when it hurts.
                Write-Log "T3  checking what each node serves (expecting serial $($pre.serial))..."

                # A wildcard cannot be sent as an SNI name, so it has to be
                # probed by proxy. The apex is the obvious stand-in, but only
                # when the certificate actually carries it: "*.example.com" does
                # NOT match a bare "example.com", so probing the apex against a
                # wildcard-only certificate asks for a name it does not cover and
                # fails a deployment that worked perfectly. Where the apex is
                # absent, use a subdomain the wildcard does match, distinctive
                # enough not to collide with a real host that has its own cert.
                $sniNames = @()
                foreach ($n in @($cert.names)) {
                    if ($n.StartsWith('*.')) {
                        $apex = $n.Substring(2)
                        if (@($cert.names) -contains $apex) { $sniNames += $apex }
                        else                                { $sniNames += "certcamel-probe.$apex" }
                    }
                    else { $sniNames += $n }
                }
                $sniNames = @($sniNames | Select-Object -Unique)

                foreach ($t in $entry.targets) {
                    foreach ($n in $t.nodes) {
                        if (-not $n.verifyHost) { Write-Log "  $($n.name) : no address to verify against" 'warn'; continue }

                        foreach ($sni in $sniNames) {
                            $v = Test-ServedCertificate -ConnectHost $n.verifyHost -Port $n.verifyPort -SniName $sni `
                                     -ExpectedSerial $pre.serial -TimeoutSeconds $VerifyTimeoutSeconds
                            $n.verify += $v

                            if ($v.ok) {
                                Write-Log "  $($n.name) [$sni] : T3 ok - serving the new certificate, $($v.daysRemaining) days remaining" 'ok'
                            } else {
                                Write-Log "  $($n.name) [$sni] : T3 FAILED - $($v.error)" 'error'
                            }
                        }
                    }
                    $t.ok = $t.ok -and (@($t.nodes | ForEach-Object { $_.verify } | Where-Object { -not $_.ok }).Count -eq 0)
                }
            }

            $entry.ok = (@($entry.targets | Where-Object { -not $_.ok }).Count -eq 0) -and @($entry.targets).Count -gt 0
            if ($entry.ok) { Write-Log "$($cert.displayName) deployed and verified." 'ok' }
            else           { Write-Log "$($cert.displayName) did NOT fully succeed - see above." 'error' }
        }
        catch {
            $entry.error = ($_.Exception.Message -split "`n")[0].Trim()
            $where = ''
            if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) {
                $where = " [$([IO.Path]::GetFileName($_.InvocationInfo.ScriptName)):$($_.InvocationInfo.ScriptLineNumber)]"
            }
            Write-Log "$($cert.displayName) FAILED: $($entry.error)$where" 'error'
        }

        $outcome.results += $entry
        Save-Outcome

        # A per-certificate copy of the outcome, so the page can show the last
        # known deployment state for each row without re-probing every node on
        # page load. Written whether the deployment succeeded or not - a failed
        # deployment is exactly the state worth remembering.
        try {
            Write-TextFileAtomic -Path (Join-Path $script:JobsDir "deploy-$certId.json") `
                -Content (@{
                    certId = $certId; name = $cert.displayName; ok = $entry.ok
                    at = (Get-Date).ToString('o'); serial = $(if ($entry.preflight) { $entry.preflight.serial } else { $null })
                    error = $entry.error; targets = $entry.targets
                } | ConvertTo-Json -Depth 10)
        }
        catch { Write-Log "Could not record the deployment state: $($_.Exception.Message)" 'warn' }
    }

    $failed = @($outcome.results | Where-Object { -not $_.ok }).Count
    $outcome.ok = ($failed -eq 0)

    Write-Log "-----------------------------------------------------------"
    if ($outcome.ok) { Write-Log "All $(@($outcome.results).Count) certificate(s) deployed and verified." 'ok' }
    else             { Write-Log "$failed of $(@($outcome.results).Count) certificate(s) did not fully succeed." 'error' }

    Save-Outcome
    exit $(if ($outcome.ok) { 0 } else { 1 })
}
catch {
    $outcome.error = ($_.Exception.Message -split "`n")[0].Trim()
    Write-Log $outcome.error 'error'
    Save-Outcome
    exit 1
}
