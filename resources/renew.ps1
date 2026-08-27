<#
  renew.ps1 - order (or re-order) a certificate over ACME and write out a
  combined PEM containing the certificate, its chain and the private key.

  Normally started by serve.ps1 as a hidden child process when you press Renew,
  with its output captured into jobs\<id>.log. It also runs perfectly well on
  its own, which is what makes it usable from Task Scheduler later:

      powershell -ExecutionPolicy Bypass -File .\renew.ps1 -Zone example.com

  The name list is always recomputed here from ssl-data.js and settings.json.
  It is deliberately not accepted as an argument: the browser must not be able
  to choose which names end up on a certificate.
#>

[CmdletBinding()]
param(
    # One or more zones, as shown in the Certificates table. Multiple zones are
    # processed one after another - concurrent orders against the same DNS
    # account collide on the _acme-challenge record.
    #
    # Named $ZoneList, not $Zone, on purpose. PowerShell variable names are
    # case-insensitive, so a parameter called $Zone is the same variable as a
    # loop-local $zone further down - and because this one is declared
    # [string[]], every assignment to $zone would be silently coerced back into
    # a one-element array. That surfaces much later as a type error on whatever
    # first needs a plain string. The alias keeps -Zone working for callers.
    [Parameter(Mandatory = $true)]
    [Alias('Zone')]
    [string[]]$ZoneList,

    # Where to drop the machine-readable outcome. serve.ps1 passes this so the
    # page can tell success from failure without scraping the log.
    [string]$ResultPath,

    # Order even if the current certificate still has plenty of life left.
    [switch]$Force,

    # Issue only, do not push to the load balancers. For proving an issuance in
    # isolation; the normal path deploys, because a certificate that never
    # reaches a load balancer has not solved the problem it was renewed for.
    [switch]$NoDeploy,

    # Deploy to these groups instead of whatever the certificate is assigned to.
    #
    # Distinct from -NoDeploy on purpose. Not passing this means "use the stored
    # assignment", which is what the scheduled task relies on. Passing it empty
    # is not expressible on a command line, so "renew and push nothing" stays
    # -NoDeploy - one flag, one meaning, rather than an empty array quietly
    # meaning something different from an absent one.
    [string[]]$TargetList,

    # Where to write this run's narrative. serve.ps1 passes one so the page can
    # tail the same file that is kept afterwards; run from a scheduled task with
    # nothing passed, a self-describing name is generated instead.
    [string]$RunLogPath,

    # 'ui' or 'task' - recorded on every audit line, because whether a person or
    # the scheduler made a change is usually the next question asked about it.
    [string]$Source = 'cli'
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'acme-lib.ps1')

# Multi-value lists reach a child process comma-joined, because -File cannot
# carry a real array. See Expand-ListArgument.
$ZoneList   = Expand-ListArgument $ZoneList
$TargetList = Expand-ListArgument $TargetList

[void](Start-RunLog -Kind 'renew' -Path $RunLogPath -Source $Source)

# --------------------------------------------------------------------------- #
# Logging
# --------------------------------------------------------------------------- #
# Everything goes to stdout, which serve.ps1 redirects to the job log and the
# page tails. Timestamps matter here: a DNS propagation wait looks identical to
# a hang without them.

function Write-Log {
    param([string]$Message, [string]$Level = 'info')
    $line = "[$((Get-Date).ToString('HH:mm:ss'))] [$Level] $Message"
    Write-Output $line
    Write-RunLog $line     # so an unattended run leaves the same narrative behind
}

$outcome = @{
    ok        = $false
    startedAt = (Get-Date).ToString('o')
    results   = @()
    error     = $null
}

function Save-Outcome {
    if (-not $ResultPath) { return }
    $outcome.finishedAt = (Get-Date).ToString('o')
    try { Write-TextFileAtomic -Path $ResultPath -Content ($outcome | ConvertTo-Json -Depth 8) }
    catch { Write-Log "Could not write the result file: $($_.Exception.Message)" 'warn' }
}

# --------------------------------------------------------------------------- #
# Work out what to order
# --------------------------------------------------------------------------- #

try {
    New-TrackerDirectories

    $settings = Get-TrackerSettings
    if (-not $settings.contact) {
        throw "No contact email is set. Open Settings and add one - the CA requires it for expiry notices."
    }

    $checker = Get-CheckerResults
    if (-not $checker.results -or @($checker.results).Count -eq 0) {
        throw "There is no certificate data yet. Run 'Check Now.bat' first."
    }

    $grouping = Get-CertificateGroups -Results @($checker.results) -Settings $settings -ZoneCache (Get-ZoneCache)

    $planned = @()
    foreach ($z in $ZoneList) {
        $zl = $z.ToLowerInvariant()

        if (-not (Test-SafeCertName $zl)) { throw "'$z' is not a valid zone name." }

        # Matched on the certificate identifier, not the zone: one zone can
        # produce both an explicit-name certificate and a wildcard one, and they
        # are separate orders.
        $cert = @($grouping.certs | Where-Object { $_.certId -eq $zl })[0]
        if (-not $cert) {
            throw "'$z' is not a renewable certificate. Its DNS zone is not managed by any configured provider."
        }
        if (-not $cert.names -or @($cert.names).Count -eq 0) {
            throw "'$z' resolved to an empty name list, so there is nothing to order."
        }

        $planned += $cert
    }

    Write-Log "Importing Posh-ACME..."
    Import-PoshAcme
    Write-Log "Posh-ACME ready, state in $($script:AcmeState)"

    # Certificates can sit on different CAs - one estate often keeps some on a
    # paid authority for policy reasons and moves the rest to a free one. The
    # active CA is therefore switched per certificate rather than once up front.
    $caReady = @{}

    function Use-CertificateAuthority {
        param([hashtable]$Ca)

        $dirUrl = Get-ActiveDirectoryUrl -Ca $Ca
        Set-PAServer -DirectoryUrl $dirUrl

        if ($caReady.ContainsKey($Ca.id)) { return }

        Write-Log "CA: $($Ca.label) -> $dirUrl"
        if ($Ca.useStaging -and $Ca.stagingUrl) {
            Write-Log "STAGING - certificates from this CA will NOT be trusted by browsers." 'warn'
        }

        # Accounts are per-CA, and staging counts as a different CA. Posh-ACME
        # keeps them apart; we only register the first time we see a directory.
        $account = $null
        try { $account = Get-PAAccount } catch { $account = $null }

        if (-not $account) {
            Write-Log "No account on $($Ca.label) yet, registering $($settings.contact)..."
            $acctParams = @{ Contact = $settings.contact; AcceptTOS = $true }

            # External Account Binding: required by DigiCert, ZeroSSL and
            # Sectigo, never used by Let's Encrypt.
            if ($Ca.ContainsKey('eabKid') -and $Ca.eabKid) {
                $hmac = Get-TrackerSecret -Key "ca:$($Ca.id):eabHmacKey" -AsPlainText
                if (-not $hmac) {
                    throw "$($Ca.label) has an EAB key ID but no HMAC key. Add it in Settings."
                }
                $acctParams.ExtAcctKID     = $Ca.eabKid
                $acctParams.ExtAcctHMACKey = $hmac
                Write-Log "Binding to external account $($Ca.eabKid)."
            }

            New-PAAccount @acctParams | Out-Null
            Write-Log "Account registered on $($Ca.label)."
        }
        else {
            Write-Log "Using existing account $($account.id) on $($Ca.label)."
        }

        $caReady[$Ca.id] = $true
    }

    # --- order each zone -------------------------------------------------- #

    foreach ($cert in $planned) {
        # $certId is the filesystem- and URL-safe identifier ("wildcard.x.com");
        # $display is what a human should see ("*.x.com").
        $certId  = $cert.certId
        $display = $cert.displayName
        $names   = @($cert.names)

        Write-Log "-----------------------------------------------------------"
        Write-Log "Certificate: $display$(if ($cert.kind -eq 'wildcard') { '   [wildcard]' })"
        Write-Log "Names      : $($names -join ', ')"
        Write-Log "DNS        : $($cert.providerLabel) [$($cert.plugin)]"
        Write-Log "Issuer     : $($cert.caLabel)$(if ($cert.caStaging) { ' (staging)' })"

        if ($cert.deferredNames -and @($cert.deferredNames).Count -gt 0) {
            Write-Log ("Not included: {0}. These are on the live certificate but are either wildcards or in a zone no configured provider manages." -f (@($cert.deferredNames) -join ', ')) 'warn'
        }

        $entry = @{ certId = $certId; name = $display; kind = $cert.kind; names = $names; ok = $false; error = $null; pem = $null; files = @() }

        $entry.ca = $cert.caLabel

        try {
            $provider = @($settings.providers | Where-Object { $_.id -eq $cert.providerId })[0]
            if (-not $provider) { throw "The DNS profile for this zone is no longer configured." }

            # Point Posh-ACME at this certificate's CA before ordering.
            Use-CertificateAuthority -Ca (Get-CaProfile -Settings $settings -CaId $cert.caId)

            $pluginArgs = Get-ProviderPluginArgs -Provider $provider

            $params = @{
                Domain     = $names
                Plugin     = $provider.plugin
                PluginArgs = $pluginArgs
                Contact    = $settings.contact
                AcceptTOS  = $true
                Force      = [bool]$Force
            }

            # Posh-ACME waits this long after writing the TXT record before it
            # asks the CA to validate. Too short and validation fails on a zone
            # that has not propagated yet.
            if ($settings.ContainsKey('dnsSleep') -and $settings.dnsSleep) {
                $params.DnsSleep = [int]$settings.dnsSleep
            }
            if ($settings.ContainsKey('keyLength') -and $settings.keyLength) {
                $params.CertKeyLength = [string]$settings.keyLength
            }

            Write-Log "Placing the order. This takes a few minutes while DNS propagates..."

            # Merge the verbose and warning streams into the output so the
            # progress Posh-ACME reports ends up in the job log.
            #
            # Match the certificate by shape rather than by "not a record".
            # An order that is already complete makes New-PACertificate emit
            # other objects instead, and treating one of those as the
            # certificate produces an object whose properties silently resolve
            # by member enumeration - a string path becomes a string array, and
            # the failure surfaces much later as a type error.
            $paCert = $null
            $alreadyComplete = $false

            New-PACertificate @params -Verbose 4>&1 3>&1 | ForEach-Object {
                $item = $_
                if ($item -is [System.Management.Automation.VerboseRecord] -or
                    $item -is [System.Management.Automation.WarningRecord]) {
                    if ("$($item.Message)" -match 'already been completed') { $alreadyComplete = $true }
                    Write-Log $item.Message 'acme'
                }
                elseif ($item -is [string]) { Write-Log $item 'acme' }
                elseif ($item -and $item.PSObject.Properties['FullChainFile'] -and
                                   $item.PSObject.Properties['KeyFile']) {
                    $paCert = $item
                }
                elseif ($item) {
                    Write-Log "Ignoring unexpected output of type $($item.GetType().Name)." 'acme'
                }
            }

            if (-not $paCert) {
                # Nothing cert-shaped came back, so read it from Posh-ACME's own
                # store. -MainDomain is the first name on the order.
                $paCert = @(Get-PACertificate -MainDomain $names[0])[0]
            }
            if (-not $paCert -or -not $paCert.FullChainFile) {
                throw "The order finished but no certificate came back."
            }

            if ($alreadyComplete) {
                Write-Log "Already current - the CA had a valid certificate for these names, so nothing was re-issued. Expires $($paCert.NotAfter)." 'ok'
            } else {
                Write-Log "Issued. Expires $($paCert.NotAfter)."
            }

            # --- assemble the download ----------------------------------- #

            $destDir = Join-Path $script:CertsDir $certId
            if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

            $pemPath = Join-Path $destDir "$certId-full.pem"

            # Archive whatever is currently there before overwriting it. The
            # current certificate always stays at this stable path so download
            # links and anything pointed at this folder keep working; previous
            # versions go under history\<date the cert was written>\.
            $newPem = (Get-Content $paCert.FullChainFile -Raw -Encoding UTF8).Trim() + "`n" +
                      (Get-Content $paCert.KeyFile -Raw -Encoding UTF8).Trim() + "`n"
            $archived = Save-CertificateHistory -CertDir $destDir -CertId $certId -NewPemContent $newPem
            if ($archived) { Write-Log "Archived the previous certificate to history\$([IO.Path]::GetFileName($archived))." }

            New-CombinedPem -FullChainPath $paCert.FullChainFile -KeyPath $paCert.KeyFile -Destination $pemPath | Out-Null
            Write-Log "Wrote $([IO.Path]::GetFileName($pemPath)) (certificate + chain + private key)."

            # Copy the individual artefacts alongside it, so the page can offer
            # the .pfx or a bare key without reaching into Posh-ACME's state.
            $files = @([IO.Path]::GetFileName($pemPath))
            foreach ($src in @($paCert.CertFile, $paCert.ChainFile, $paCert.FullChainFile, $paCert.KeyFile, $paCert.PfxFile, $paCert.PfxFullChain)) {
                # Coerce to a single path: Test-Path happily accepts an array,
                # so a multi-valued property would sail past the guard and only
                # blow up on Join-Path further down.
                $one = @($src | Where-Object { $_ }) | Select-Object -First 1
                if (-not $one) { continue }
                if (-not (Test-Path -LiteralPath $one)) { continue }

                $leaf = [IO.Path]::GetFileName([string]$one)
                Copy-Item -LiteralPath $one -Destination (Join-Path $destDir $leaf) -Force
                $files += $leaf
            }

            # Bounded on purpose: every archived version holds a private key that
            # stays usable until that certificate expires.
            $keep = 5
            if ($settings.ContainsKey('keepHistory') -and $null -ne $settings.keepHistory) {
                $keep = [int]$settings.keepHistory
            }
            $dropped = Remove-OldCertificateHistory -CertDir $destDir -Keep $keep
            if (@($dropped).Count) {
                Write-Log "Pruned $(@($dropped).Count) old version(s), keeping the most recent $keep."
            }

            $entry.ok       = $true
            $entry.pem      = [IO.Path]::GetFileName($pemPath)
            $entry.files    = @($files | Select-Object -Unique)
            $entry.notAfter = $paCert.NotAfter.ToString('o')
            # The serial is what identifies one specific issuance, so it is the
            # thing worth recording in the audit trail - "renewed" without it
            # cannot be matched against what a node is actually serving.
            $entry.serial   = [string]$paCert.Thumbprint
            try {
                $issued = New-Object Security.Cryptography.X509Certificates.X509Certificate2 $paCert.CertFile
                $entry.serial = $issued.SerialNumber
            } catch { $null = $_ }   # serial unavailable: the entry simply records none

            Write-Log "$display issued." 'ok'

            # --- deploy ---------------------------------------------------- #
            # A renewed certificate sitting in a folder has not fixed anything.
            # Deployment runs in-process rather than as another job so the log
            # reads as one story, and so a renewal that cannot be delivered is
            # reported as a failure rather than a success with a caveat.
            # A run-time selection wins over the stored assignment; without one
            # the assignment is used, which is what renew-due.ps1 depends on.
            $certTargets = @()
            if ($TargetList -and @($TargetList).Count) {
                $certTargets = @($TargetList)
            }
            elseif ($settings.certs -and $settings.certs.ContainsKey($certId)) {
                $certTargets = Get-CertTargetIds -CertConfig $settings.certs[$certId]
            }

            if (-not $certTargets.Count) {
                Write-Log "$display has no load balancer assigned - issued but not deployed." 'warn'
                $entry.deployed = $null
            }
            elseif ($NoDeploy) {
                Write-Log "$display : deployment skipped (-NoDeploy)." 'warn'
                $entry.deployed = $null
            }
            else {
                # Labels, not ids. A group's id is fixed at creation and is often
                # a leftover from whatever it was first called, while the label is
                # the name the operator actually maintains - and every other line
                # in the deploy log already uses the label. Falls back to the id
                # for a group that has since been deleted, which is the one case
                # where the raw id is the more useful thing to print.
                $targetNames = @($certTargets | ForEach-Object {
                    $tp = Get-TargetProfile -Settings $settings -TargetId $_
                    if ($tp -and $tp.label) { $tp.label } else { "$_ (no longer configured)" }
                })
                Write-Log "Deploying $display to $($targetNames -join ', ')..."
                $deployScript = Join-Path $PSScriptRoot 'deploy.ps1'
                $deployResult = Join-Path $script:JobsDir "renew-deploy-$certId.json"

                # Pass the resolved list explicitly rather than letting deploy.ps1
                # re-read the assignment, so a run-time override survives the hop
                # between the two scripts.
                # Comma-joined: an array handed to a native command arrives as
                # one token per element, and -File binds only the first of them
                # to -TargetList. See Expand-ListArgument.
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $deployScript `
                    -Cert $certId -ResultPath $deployResult -TargetList ($certTargets -join ',') -CalledFromRenew `
                    -Source $Source 2>&1 |
                  ForEach-Object { Write-Output $_ }
                $deployOk = ($LASTEXITCODE -eq 0)

                # Exit code alone cannot tell "serving" from "on the node, with
                # no frontend reading it yet" - both are a successful run. Read
                # the outcome file for that, so this does not report a
                # certificate as live when nothing is serving it.
                $deployAwaiting = $false
                try {
                    if (Test-Path $deployResult) {
                        $dr = [IO.File]::ReadAllText($deployResult) | ConvertFrom-Json
                        $deployAwaiting = [bool](@($dr.results | Where-Object { $_.awaitingBind }).Count)
                    }
                }
                catch { $null = $_ }   # unreadable: fall back to the plainer wording

                $entry.deployed = $deployOk
                if (-not $deployOk) {
                    # The certificate exists and is valid; it just is not live
                    # anywhere yet. Say exactly that rather than implying the
                    # issuance failed.
                    $entry.ok    = $false
                    $entry.error = 'Issued successfully, but deployment did not fully succeed.'
                    Write-Log "$display : issued, but NOT fully deployed." 'error'
                }
                elseif ($deployAwaiting) {
                    Write-Log "$display issued and deployed - waiting for a bind line before it can serve." 'warn'
                }
                else {
                    Write-Log "$display issued and deployed." 'ok'
                }
            }
        }
        catch {
            # One bad zone must not abandon the rest of a bulk run.
            $entry.error = ($_.Exception.Message -split "`n")[0].Trim()

            # Include where it happened. A renewal touches a CA, a DNS provider
            # and the filesystem, so "which of those broke" is most of the
            # diagnosis - and the log is all anyone has to go on afterwards.
            $where = ''
            if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) {
                $where = " [$([IO.Path]::GetFileName($_.InvocationInfo.ScriptName)):$($_.InvocationInfo.ScriptLineNumber)]"
            }
            Write-Log "$display FAILED: $($entry.error)$where" 'error'
        }

        # Per-node detail from the deploy step's own result file, so the email
        # says which node did what rather than only that something failed.
        $deployDetail = @()
        try { $deployDetail = @(Format-DeploymentSummary -ResultPath (Join-Path $script:JobsDir "renew-deploy-$certId.json")) }
        catch { $null = $_ }   # the summary is decoration for the email; the renewal already happened

        Send-RenewalOutcomeAlert -Settings $settings -DisplayName $display -Ok $entry.ok `
            -Deployed $entry.deployed -ErrorMessage $entry.error -Detail $deployDetail

        # One audit line per certificate, not one per run: the question later is
        # always "what happened to this certificate", never "what did run 7 do".
        Write-AuditEvent -Event 'renew' -Object $display -Outcome $(if ($entry.ok) { 'ok' } else { 'fail' }) `
            -Detail $(if ($entry.ok) {
                "issued serial $($entry.serial), expires $(if ($entry.notAfter) { ([datetime]$entry.notAfter).ToString('yyyy-MM-dd') } else { 'unknown' })$(if ($null -eq $entry.deployed) { ', not deployed' } elseif ($entry.deployed) { ', deployed' } else { ', deployment incomplete' })"
            } else { $entry.error })

        $outcome.results += $entry
        Save-Outcome
    }

    $failed = @($outcome.results | Where-Object { -not $_.ok }).Count
    $outcome.ok = ($failed -eq 0)

    Write-Log "-----------------------------------------------------------"
    if ($outcome.ok) {
        Write-Log "All done - $(@($outcome.results).Count) certificate(s) issued." 'ok'
    } else {
        Write-Log "$failed of $(@($outcome.results).Count) certificate(s) failed." 'error'
    }

    Save-Outcome
    exit $(if ($outcome.ok) { 0 } else { 1 })
}
catch {
    $outcome.error = ($_.Exception.Message -split "`n")[0].Trim()
    Write-Log $outcome.error 'error'
    Save-Outcome
    exit 1
}
