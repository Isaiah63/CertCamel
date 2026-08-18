<#
    PSScriptAnalyzer rules for Cert Camel.

    Unfiltered, the analyser reports 499 findings, 412 of which are one of four
    rules that are either style or written for a different kind of program. A
    Security tab with 499 entries is not a safety net; it is a wall that teaches
    everybody to scroll past, including past the fourteen that matter.

    So four rules are excluded and everything else is kept - including the noisy
    ones that are actually about correctness. The point is signal, not a low
    number.

    In .github\ rather than the repository root on purpose: the root is meant to
    be things you run, things you read, or things that are yours, and a linter
    configuration is none of the three.
#>
@{
    Severity = @('Error', 'Warning', 'Information')

    ExcludeRules = @(
        # 240 findings. This is a console application - First Time Setup and the
        # server print to a window a person is watching, and setup is a guided
        # conversation. Write-Host is the correct cmdlet for that. The rule
        # exists so that library functions do not write to a stream a caller
        # cannot capture or redirect, which is a different kind of program.
        'PSAvoidUsingWriteHost'

        # 92 findings, all Information. Style: Join-Path $a $b rather than
        # -Path/-ChildPath. Reasonable advice for a public module surface, and
        # noise for internal calls this codebase makes hundreds of times.
        'PSAvoidUsingPositionalParameters'

        # 31 findings. Get-CertTargetIds returns several ids, so the plural is
        # the honest name. Renaming a working internal API to satisfy a naming
        # convention is a worse trade than the convention is worth.
        'PSUseSingularNouns'

        # 13 findings. -WhatIf and -Confirm belong on cmdlets somebody composes
        # from a prompt. These are internal functions driven by a web console
        # that does its own confirming, and renew-due.ps1 already implements
        # -WhatIfOnly where the behaviour genuinely applies.
        'PSUseShouldProcessForStateChangingFunctions'
    )

    # Deliberately NOT excluded, though it is the largest remaining group:
    #
    #   PSAvoidUsingEmptyCatchBlock (80)
    #
    # Some of those are correct and commented as such - Set-SessionFileAcl
    # swallows a name that will not resolve so the other principals still get
    # applied. Others are almost certainly a thrown error going quietly into the
    # floor. Telling those two apart is exactly the work this repository spent a
    # week doing to the update panel, and hiding the rule would hide the next
    # one of those.
}
