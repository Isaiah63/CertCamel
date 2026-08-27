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

    [int]$VerifyTimeoutSeconds = 10,

    # Set by renew.ps1 when it calls this as its own deploy step, so this run
    # does not also send its own alert - renew.ps1 already sends one covering
    # both issuance and deployment together, and sending both would mean two
    # emails for one event.
    [switch]$CalledFromRenew,

    # See renew.ps1 - a path to write this run's narrative to, and whether a
    # person or the scheduler started it.
    [string]$RunLogPath,
    [string]$Source = 'cli'
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'acme-lib.ps1')

# Multi-value lists reach a child process comma-joined, because -File cannot
# carry a real array. See Expand-ListArgument.
$CertList   = Expand-ListArgument $CertList
$TargetList = Expand-ListArgument $TargetList

# When renew.ps1 invokes this as its deploy step it hands over its own log, so
# issuance and deployment read as one story in one file rather than two.
[void](Start-RunLog -Kind 'deploy' -Path $RunLogPath -Source $Source)

function Write-Log {
    param([string]$Message, [string]$Level = 'info')
    $line = "[$((Get-Date).ToString('HH:mm:ss'))] [$Level] $Message"
    Write-Output $line
    Write-RunLog $line     # so an unattended run leaves the same narrative behind
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

# The address to connect to for verification, or NOTHING when none is set.
#
# This used to fall back to the host part of the Data Plane API URL, reasoning
# that the API and the served site are normally the same machine. That guess is
# wrong in two ways, and both of them produce a GREEN deployment:
#
#   - the management address often has no :443 listener at all. Where each
#     domain has its own frontend on its own floating address - the topology the
#     API check exists for - a node's own address serves nothing.
#   - worse, several nodes usually share one management host. Every node of a
#     Docker or port-forwarded pair is "localhost", so the fallback verified one
#     endpoint once per node and reported that single answer against each of
#     them. Observed while building the crt-list work: both nodes of a pair
#     reported "serving the new certificate" at a moment when the crt-list had
#     just been created and no bind line referenced it. The check had reached a
#     different lab entirely, and would have passed no matter what those nodes
#     were doing.
#
# So a blank verify address now means what it says: nowhere was given, do not
# invent one. Verification falls through to asking the node's own Data Plane API
# what it has loaded - weaker evidence, labelled as such at the point of use,
# but evidence about THAT node. Setting a verify address restores the wire check.
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

    # Nothing set. Deliberately not derived from the node URL - see above.
    return @{ host = $null; port = $DefaultPort }
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
            if (@(Get-CertTargetIds -CertConfig $cfg).Count) { $planned += $cert }
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

            # T0 has already parsed the certificate, so this costs nothing: does
            # the artifact about to be pushed still carry a name that now belongs
            # to a sibling certificate? If so it will compete for that name on
            # every node it lands on, and no amount of correct deploying fixes
            # it - only a renewal does.
            $extra = @(@($pre.names) | Where-Object { @($cert.names) -notcontains $_ })
            if ($extra.Count) {
                Write-Log "T0  note - this certificate still carries $($extra -join ', '), which is no longer part of it. Renew to re-issue without it; until then it competes for that name wherever it is deployed." 'warn'
            }

            $pem = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($pemPath))

            # --- which targets -------------------------------------------- #
            # Bindings, not bare ids: an assignment may carry per-certificate
            # overrides (which crt-list, which port), so the group it names is
            # only half the answer.
            $bindings = @()
            if ($settings.certs -and $settings.certs.ContainsKey($certId)) {
                $bindings = Get-CertTargetBindings -CertConfig $settings.certs[$certId]
            }
            # A run-time selection replaces the stored assignment outright rather
            # than filtering it, so a newly added group can be deployed to before
            # anyone has got round to assigning it. Picked at run time means no
            # stored overrides to carry, so the group's own values apply.
            if ($TargetList -and @($TargetList).Count) {
                $bindings = @(@($TargetList) | ForEach-Object { @{ id = $_; overrides = @{} } })
            }

            if (-not $bindings.Count) { throw "No deployment target is assigned to this certificate." }

            foreach ($binding in $bindings) {
                $tid = $binding.id
                $target = Get-TargetProfile -Settings $settings -TargetId $tid
                if (-not $target) { Write-Log "Target '$tid' is no longer configured - skipping." 'warn'; continue }

                $tResult = @{ targetId = $tid; label = $target.label; ok = $false; nodes = @() }

                # Credentials stay group-level on purpose: they describe how to
                # reach the nodes, which is the one thing a per-certificate
                # override has no business changing.
                $user     = Get-TargetArg -Target $target -Name 'user'
                $password = Get-TargetSecret -TargetId $tid -Name 'password'
                $insecure = [bool](Get-TargetArg -Target $target -Name 'insecureTls' -Default $false)

                # Placement settings resolve through the binding first.
                $port     = [int](Resolve-TargetSetting -Target $target -Binding $binding -Name 'verifyPort' -Default 443)

                $remoteName = Resolve-TargetSetting -Target $target -Binding $binding -Name 'remoteName' -Default "$certId.pem"
                $remoteName = ([string]$remoteName).Replace('{certId}', $certId)
                # Carried on the result so the verification pass below can ask
                # the API about this file by name. It runs in a separate loop
                # over results and cannot see this scope.
                $tResult.remoteName = $remoteName

                # Two structures the setting picks between - one shared list, or
                # one per parent domain via {certId} - plus the rule that a
                # wildcard never shares a list with SAN certificates. All three
                # live in Resolve-CrtListPath, because the wildcard rule is about
                # the certificates rather than about the template, and a plain
                # .Replace here silently put the wildcard in with the rest
                # whenever the template had nothing to substitute.
                $crtListPath = Resolve-CrtListPath `
                    -Template ([string](Resolve-TargetSetting -Target $target -Binding $binding -Name 'crtList' -Default '')) `
                    -CertId $certId -IsWildcard:([bool]$cert.wildcard)

                if (@($binding.overrides.Keys).Count) {
                    Write-Log "  (this certificate overrides $(@($binding.overrides.Keys) -join ', ') for this group)"
                }

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
                        # for. HAProxy loads certificates by path, so something
                        # has to reference the real one.
                        #
                        # Whether that is the operator's problem depends entirely
                        # on whether a crt-list is configured. With one, the sync
                        # below reconciles it using exactly this name and there is
                        # nothing to do - warning there described work this run
                        # had already done, and made a clean deployment read like
                        # a failed one. Without one, a human must edit a bind
                        # line, and that genuinely is a warning.
                        if ($push.renamed) {
                            if ($crtListPath) {
                                Write-Log "  $nodeName : stored as '$($push.storedName)' (the API rewrites dots) - the crt-list is kept in step with that name"
                            } else {
                                Write-Log "  $nodeName : stored as '$($push.storedName)', not '$($push.remoteName)' - your bind line must reference '$($push.storedName)'" 'warn'
                            }
                        }

                        # With a crt-list configured, make sure this certificate
                        # is actually referenced by it - the step that lets a
                        # BRAND-NEW certificate start serving with no config
                        # edit. Runs on replacements too: it is a cheap check
                        # when the entry already exists, and it heals a file
                        # that was pushed before the crt-list was configured.
                        if ($crtListPath) {
                            $sync = Sync-HAProxyCrtList -BaseUrl $node.url -User $user -Password $password `
                                        -ApiVersion $push.apiVersion -CrtListPath $crtListPath `
                                        -CertStorageName $push.storedName -InsecureTls:$insecure
                            $nResult.crtList = $sync
                            if ($sync.ok) {
                                if ($sync.action -eq 'created') {
                                    Write-Log "  $nodeName : crt-list created - $($sync.path), containing $($push.storedName)" 'ok'
                                    if ($sync.path -ne $crtListPath) {
                                        Write-Log "  $nodeName : filed as '$($sync.path)', not '$crtListPath' - the API rewrites dots in a filename" 'warn'
                                    }
                                }
                                elseif ($sync.action -eq 'added') {
                                    if ($sync.runtimeLoaded) {
                                        Write-Log "  $nodeName : crt-list ok - appended $($push.storedName), and the running process loaded it" 'ok'
                                    } else {
                                        Write-Log "  $nodeName : crt-list ok - appended $($push.storedName)" 'ok'
                                    }
                                } else {
                                    Write-Log "  $nodeName : crt-list ok - already referenced"
                                }

                                # Keyed on needsBind, not on 'created': a list that
                                # an earlier run created is in exactly the same
                                # state, and so is the second node of a pair that
                                # shares one storage directory and therefore finds
                                # the file already there. All three need the same
                                # bind line, and none of them is serving yet.
                                if ($sync.needsBind) {
                                    Write-Log "  $nodeName : NOT served yet - no bind line references this list. Add it to the frontend, then reload:" 'warn'
                                    Write-Log "      $($sync.bindLine)"
                                    Write-Log "      haproxy -c -f /etc/haproxy/haproxy.cfg     # check it parses"
                                    Write-Log "      systemctl reload haproxy                   # graceful, no dropped connections"
                                }
                            }
                            else { Write-Log "  $nodeName : crt-list FAILED - $($sync.error)" 'error' }
                        }
                    }
                    else { Write-Log "  $nodeName : T1 FAILED - upload rejected - $($push.error)" 'error' }

                    $tResult.nodes += $nResult
                }

                # A failed crt-list sync fails the node just like a failed push:
                # a certificate nothing references is not deployed, however
                # cleanly it uploaded.
                $tResult.ok = (@($tResult.nodes | Where-Object {
                    (-not $_.push.ok) -or ($_.ContainsKey('crtList') -and -not $_.crtList.ok)
                }).Count -eq 0)
                $entry.targets += $tResult
            }

            # --- T3: what is each node actually serving? ------------------ #
            if (-not $SkipVerify) {
                # Deliberately after every push, and against every node
                # individually. Verifying through a floating VIP only ever tests
                # whichever node currently holds it, so a node that missed the
                # push stays invisible until failover - exactly when it hurts.
                Write-Log "T3  checking what each node serves (expecting serial $($pre.serial))..."

                # A wildcard cannot be sent as an SNI name, so it is probed by
                # proxy - and WHICH proxy decides whether the check proves
                # anything. The apex looks like the obvious stand-in, but it is
                # the name most likely to be claimed by a second certificate,
                # and an exact SNI match beats a wildcard. Probing only the apex
                # therefore tests "who won this name", not "is my wildcard
                # live", and reported a perfectly good deployment as failed.
                #
                # Two probes, with different jobs:
                #   identity - a synthetic subdomain only this wildcard can
                #              match. Real proof the certificate is loaded.
                #   coverage - the apex, when carried. Informative: it says who
                #              is serving a name several certificates may share.
                $probes = @()
                foreach ($n in @($cert.names)) {
                    if ($n.StartsWith('*.')) {
                        $apex = $n.Substring(2)
                        $probes += @{ sni = "certcamel-probe.$apex"; role = 'identity' }
                        if (@($cert.names) -contains $apex) {
                            $probes += @{ sni = $apex; role = 'coverage' }
                        }
                    }
                    else { $probes += @{ sni = $n; role = 'identity' } }
                }
                # De-duplicate on the name, keeping the strongest role: a name
                # reached both ways must not be demoted to coverage-only, or a
                # certificate could pass with nothing actually proving it.
                $seen = @{}
                $ordered = @()
                foreach ($p in $probes) {
                    if (-not $seen.ContainsKey($p.sni)) { $seen[$p.sni] = $p; $ordered += $p }
                    elseif ($p.role -eq 'identity') { $seen[$p.sni].role = 'identity' }
                }
                $probes = $ordered

                foreach ($t in $entry.targets) {
                    # Re-resolved per target rather than relying on the push
                    # loop's variables still holding the right values - with more
                    # than one group they would be the LAST group's credentials.
                    $vTarget = @($settings.targets | Where-Object { $_.id -eq $t.targetId })[0]

                    foreach ($n in $t.nodes) {
                        if (-not $n.verifyHost) {
                            # No address with a listener to connect to. Common
                            # where each domain has its own frontend on its own
                            # floating address: the node's management address has
                            # no :443 at all, and the floating one only ever
                            # reaches whichever node currently holds it - which is
                            # the failure verification exists to catch.
                            #
                            # Ask this node's OWN Data Plane API instead. Weaker
                            # evidence, and labelled as such: it proves the right
                            # certificate is loaded in the running process, not
                            # that a client asking for the name is served it.
                            if (-not $vTarget) { Write-Log "  $($n.name) : no address to verify against" 'warn'; continue }

                            $storage = $(if ($n.push -and $n.push.storedName) { $n.push.storedName } else { $t.remoteName })
                            $apiV    = $(if ($n.push -and $n.push.apiVersion) { $n.push.apiVersion } else { 'v3' })

                            $rt = Get-HAProxyRuntimeCertificate -BaseUrl $n.url `
                                    -User (Get-TargetArg -Target $vTarget -Name 'user') `
                                    -Password (Get-TargetSecret -TargetId $t.targetId -Name 'password') `
                                    -ApiVersion $apiV -StorageName $storage `
                                    -InsecureTls:([bool](Get-TargetArg -Target $vTarget -Name 'insecureTls' -Default $false)) `
                                    -TimeoutSeconds $VerifyTimeoutSeconds

                            # Coverage is checked against the names this
                            # CERTIFICATE carries, not against $entry.name - that
                            # is the zone's display name, and a certificate for
                            # www plus subdomains very often does not include the
                            # bare apex at all. Checking the apex therefore failed
                            # a perfectly good deployment every time, which went
                            # unnoticed only because this whole branch was
                            # unreachable until the verify-address fallback above
                            # was removed.
                            $missing = @()
                            if ($rt.found) {
                                $missing = @(@($cert.names) | Where-Object {
                                    -not (Test-NameCoveredBySans -Sans $rt.sans -Name $_)
                                })
                            }
                            $covers = ($rt.found -and $missing.Count -eq 0)
                            $serialOk = ($rt.found -and $rt.serial -and $pre.serial -and
                                         $rt.serial.TrimStart('0') -eq ([string]$pre.serial).TrimStart('0'))

                            $v = @{
                                node = $n.url; sni = $entry.name; method = 'api'
                                ok = [bool]($serialOk -and $covers -and $rt.status -eq 'Used')
                                servedSerial = $rt.serial; expectedSerial = $pre.serial
                                notAfter = $rt.notAfter; loadedStatus = $rt.status
                                servedCovers = $covers; contested = $false
                                role = 'identity'; error = $rt.error
                            }
                            if (-not $v.ok -and -not $v.error) {
                                $v.error = if (-not $rt.found)       { 'not present in the API' }
                                           elseif (-not $serialOk)   { "loaded serial $($rt.serial), expected $($pre.serial)" }
                                           elseif ($rt.status -ne 'Used') { "on disk but not in use (status $($rt.status))" }
                                           else                      { "loaded certificate does not cover $($missing -join ', ')" }
                            }
                            $n.verify += $v

                            if ($v.ok) {
                                Write-Log "  $($n.name) : T3* ok via the API - the running HAProxy has this serial loaded and in use. Not a wire check: set a verify address to prove what is actually served." 'ok'
                            } else {
                                Write-Log "  $($n.name) : T3* FAILED via the API - $($v.error)" 'error'
                                # A list created this run is referenced by nothing,
                                # so this failure is expected and already explained
                                # above. Say which it is, or the run reads as a
                                # mystery failure at the last step.
                                if ($n.ContainsKey('crtList') -and $n.crtList.needsBind) {
                                    Write-Log "      expected - the crt-list was created this run and no bind line references it yet. Add the bind line above, reload, then deploy again." 'warn'
                                }
                            }
                            continue
                        }

                        foreach ($p in $probes) {
                            $v = Test-ServedCertificate -ConnectHost $n.verifyHost -Port $n.verifyPort -SniName $p.sni `
                                     -ExpectedSerial $pre.serial -TimeoutSeconds $VerifyTimeoutSeconds
                            $v.role = $p.role
                            # Recorded on both paths so a reader of the deploy
                            # record can tell a wire check from an API one
                            # without inferring it from which fields are present.
                            $v.method = 'wire'
                            $n.verify += $v

                            if ($v.ok) {
                                Write-Log "  $($n.name) [$($p.sni)] : T3 ok - serving the new certificate, $($v.daysRemaining) days remaining" 'ok'
                            } elseif ($v.contested) {
                                Write-Log "  $($n.name) [$($p.sni)] : T3 contested - $($v.error). Only one certificate can serve a name; an exact match beats a wildcard." 'warn'
                            } else {
                                Write-Log "  $($n.name) [$($p.sni)] : T3 FAILED - $($v.error)" 'error'
                            }
                        }
                    }

                    # A node passes on evidence, not on absence of complaint: at
                    # least one identity probe must have matched the serial, and
                    # nothing may have hard-failed. A contested coverage probe is
                    # reported and forgiven; a contested IDENTITY probe is not,
                    # because that means something else is answering to a name
                    # only this certificate should be able to serve.
                    foreach ($n in $t.nodes) {
                        $checked = @($n.verify)
                        if (-not $checked.Count) { continue }   # nothing could be checked; already warned
                        $hardFailed = @($checked | Where-Object { -not $_.ok -and -not ($_.contested -and $_.role -eq 'coverage') }).Count
                        $proved     = @($checked | Where-Object { $_.ok -and $_.role -eq 'identity' }).Count
                        if ($hardFailed -gt 0 -or $proved -eq 0) { $t.ok = $false }
                    }
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

        # Only on failure, and only when this is a standalone deploy - renew.ps1
        # already sends its own alert covering issuance and deployment together
        # when it calls this as its own deploy step, and there is no "deployment
        # succeeded on its own" toggle to fire here on the success path.
        if (-not $entry.ok -and -not $CalledFromRenew) {
            Send-RenewalOutcomeAlert -Settings $settings -DisplayName $cert.displayName -Ok $false `
                -Deployed $false -ErrorMessage $(if ($entry.error) { $entry.error } else { 'Deployment did not fully succeed - see the log.' })
        }

        $outcome.results += $entry
        Save-Outcome

        # Per node, because "deployed" is not one fact - it is one per node, and
        # a pair where only one node took the certificate is the exact situation
        # this whole verification design exists to make visible.
        $nodeSummary = @()
        foreach ($t in @($entry.targets)) {
            foreach ($n in @($t.nodes)) {
                $checks = @($n.verify)
                $hardFailed = @($checks | Where-Object { -not $_.ok -and -not ($_.contested -and $_.role -eq 'coverage') }).Count
                $proved     = @($checks | Where-Object { $_.ok -and $_.role -eq 'identity' }).Count
                $state = if (-not ($n.push -and $n.push.ok)) { 'push failed' }
                         elseif (-not $checks.Count)         { 'pushed, not verified' }
                         elseif ($hardFailed -eq 0 -and $proved) { 'serving' }
                         else                                { 'not serving' }
                $nodeSummary += "$($n.name) $state"
            }
        }
        Write-AuditEvent -Event 'deploy' -Object $cert.displayName -Outcome $(if ($entry.ok) { 'ok' } else { 'fail' }) `
            -Detail "$(if ($entry.preflight) { "serial $($entry.preflight.serial); " })$($nodeSummary -join ', ')$(if ($entry.error) { " - $($entry.error)" })"

        # A per-certificate copy of the outcome, so the page can show the last
        # known deployment state for each row without re-probing every node on
        # page load. Written whether the deployment succeeded or not - a failed
        # deployment is exactly the state worth remembering.
        # MERGED PER TARGET, not replaced. A deployment to one group must not
        # erase what is known about the others: this file used to hold only the
        # last run, so pushing to test an hour after prod made the page look as
        # though prod had never been deployed to at all - which reads as work
        # still to do, and is the opposite of the truth.
        $prevFile = Join-Path $script:JobsDir "deploy-$certId.json"
        $byTarget = @{}
        if (Test-Path $prevFile) {
            try {
                $prev = (Get-Content $prevFile -Raw -Encoding UTF8) | ConvertFrom-Json
                if ($prev -and $prev.PSObject.Properties['byTarget'] -and $prev.byTarget) {
                    foreach ($p in $prev.byTarget.PSObject.Properties) { $byTarget[$p.Name] = $p.Value }
                }
        } catch { $null = $_ }   # no previous result to compare against; treated as a first deployment
        }
        $stamp = (Get-Date).ToString('o')
        foreach ($t in @($entry.targets)) {
            $nodeStates = @()
            foreach ($n in @($t.nodes)) {
                $checks = @($n.verify)
                $hf = @($checks | Where-Object { -not $_.ok -and -not ($_.contested -and $_.role -eq 'coverage') }).Count
                $pv = @($checks | Where-Object { $_.ok -and $_.role -eq 'identity' }).Count
                $nodeStates += @{
                    name = [string]$n.name
                    ok   = [bool](($n.push -and $n.push.ok) -and $checks.Count -and $hf -eq 0 -and $pv)
                }
            }
            $byTarget[[string]$t.targetId] = @{
                targetId = [string]$t.targetId; label = [string]$t.label
                ok = [bool]$t.ok; at = $stamp; nodes = $nodeStates
            }
        }

        try {
            Write-TextFileAtomic -Path $prevFile `
                -Content (@{
                    certId = $certId; name = $cert.displayName; ok = $entry.ok
                    at = $stamp; serial = $(if ($entry.preflight) { $entry.preflight.serial } else { $null })
                    error = $entry.error; targets = $entry.targets; byTarget = $byTarget
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
