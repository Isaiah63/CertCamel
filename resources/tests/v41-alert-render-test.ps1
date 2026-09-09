<#
  Alert messages described once and rendered twice.

  Every alert used to be a plain-text string built inline at the call site. That
  was fine while plain text was the only format; adding HTML the same way would
  mean two hand-written bodies per sender, drifting apart the first time
  somebody edited one and forgot the other.

  So a message is now a structure, and two renderers are the only code that
  knows about formatting. Three things have to hold:

  1. THE TEXT PART NEVER GOES AWAY. It is the fallback in every multipart
     message, what a screen reader is handed, and what anyone reading mail in a
     terminal sees. A message that renders only as HTML is a regression.

  2. THE PART ORDER IS NOT COSMETIC. A client picks the LAST alternative view it
     can render, so text must be added first and HTML second. Backwards, and
     every client on earth quietly shows the plain text - a bug that looks
     exactly like the feature never having been built.

  3. A -Body CALLER CANNOT EMIT HTML. The six existing senders still pass plain
     strings, and they must behave exactly as they did however the new setting
     is left, or this change is not revertible one commit at a time.

  Runs against redirected settings and secret files. Touches neither the real
  settings.json nor the real secrets.xml, and sends no mail.

      powershell -ExecutionPolicy Bypass -File .\v41-alert-render-test.ps1
#>

$ErrorActionPreference = 'Stop'
$repo   = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$srcDir = Join-Path $repo 'resources'
. (Join-Path $srcDir 'acme-lib.ps1')

$script:Failed = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    if ($Ok) { Write-Host "  ok   $Name" -ForegroundColor Green }
    else     { Write-Host "  FAIL $Name  -- $Detail" -ForegroundColor Red; $script:Failed++ }
}

# Pull the content back out of an AlternateView so the parts can be inspected.
function Get-ViewText {
    param([Net.Mail.AlternateView]$View)
    $View.ContentStream.Position = 0
    $sr = New-Object IO.StreamReader($View.ContentStream, [Text.Encoding]::UTF8)
    $t  = $sr.ReadToEnd()
    $View.ContentStream.Position = 0
    return $t
}

function New-TestSettings {
    param([bool]$Html = $true)
    return @{
        contact = 'me@example.com'
        alerts  = @{
            smtp      = @{ host = 'localhost'; port = 1025; encryption = 'none'
                           from = 'camel@example.com'; to = @('me@example.com')
                           authRequired = $false; username = '' }
            htmlEmail = @{ enabled = $Html }
        }
    }
}

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("cc-v41-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $sandbox
$script:SettingsFile = Join-Path $sandbox 'settings.json'
$script:SecretsFile  = Join-Path $sandbox 'secrets.xml'
Write-Host "sandbox: $sandbox"

try {
    # ----------------------------------------------------------------------- #
    Write-Host "`nthe structure carries what the renderers need"
    $msg = New-AlertMessage -Title 'Cert Camel status' -Verdict 'warn' `
        -Summary '1 needs attention' -Footer 'Next summary due 10 Sep.' -Sections @(
            (New-AlertSection -Heading 'Scheduled tasks' -Rows @(
                (New-AlertRow -Text 'Renew and deploy' -Status 'ok'   -Note 'last ran 06:15'),
                (New-AlertRow -Text 'Expiry check'     -Status 'bad'  -Note 'not registered')
            )),
            # Deliberately empty: a heading with nothing under it reads as a
            # failure to look, not as nothing to report.
            (New-AlertSection -Heading 'Deployments' -Rows @())
        )
    Check 'verdict is kept' ($msg.verdict -eq 'warn') "got $($msg.verdict)"
    Check 'sections are an array even when one is given' ($msg.sections -is [array]) 'not an array'

    # ----------------------------------------------------------------------- #
    Write-Host "`nthe plain-text rendering"
    $text = Format-AlertText -Message $msg
    Check 'the title is there'          ($text -match 'Cert Camel status') $text
    Check 'the summary is there'        ($text -match '1 needs attention') $text
    Check 'a good row is marked ok'     ($text -match '\[ok\]\s+Renew and deploy') $text
    Check 'a bad row is marked FAIL'    ($text -match '\[FAIL\]\s+Expiry check') $text
    Check 'a note appears under its row' ($text -match 'Expiry check[\r\n]+\s+not registered') $text
    Check 'the footer is there'         ($text -match 'Next summary due') $text
    Check 'an empty section is dropped' ($text -notmatch 'Deployments') $text
    Check 'there is no markup in it'    ($text -notmatch '<') $text

    # A row with no verdict still has to read as a ROW. Blank markers put it at
    # the same indent as a note, where it looks like more detail about the line
    # above rather than its own entry.
    $plain = New-AlertMessage -Title 'T' -Sections @(
        (New-AlertSection -Heading 'H' -Rows @(
            (New-AlertRow -Text 'Failed thing' -Status 'bad' -Note 'the reason'),
            (New-AlertRow -Text 'Quiet thing'  -Status 'none' -Note 'just so you know')
        ))
    )
    $plainText = Format-AlertText -Message $plain
    Check 'a row with no status is still marked' ($plainText -match '\[--\]\s+Quiet thing') $plainText
    Check 'and is not indented like a note' `
          ($plainText -notmatch '(?m)^\s{9}Quiet thing') `
          'it would read as detail belonging to the row above'

    # ----------------------------------------------------------------------- #
    Write-Host "`nthe HTML rendering"
    $html = Format-AlertHtml -Message $msg
    Check 'it is a table layout, not flex or grid' `
          (($html -match '<table') -and ($html -notmatch 'display:\s*flex') -and ($html -notmatch 'display:\s*grid')) `
          'Outlook lays mail out with Word - no flex, no grid'
    Check 'there is no <style> block' ($html -notmatch '(?i)<style') `
          'Outlook does not reliably apply one; rules must be inline'
    Check 'there is no external stylesheet' ($html -notmatch '(?i)<link') 'same reason'
    Check 'status is carried by a WORD, not only by colour' `
          (($html -match '>OK<') -and ($html -match '>Failed<')) `
          'colour alone is unreadable when inverted, and to anyone colour-blind'
    Check 'the summary made it in' ($html -match '1 needs attention') 'missing'
    Check 'an empty section is dropped here too' ($html -notmatch 'Deployments') 'rendered an empty heading'

    Write-Host "`nand it escapes what it is given"
    $nasty = New-AlertMessage -Title 'a & b' -Sections @(
        (New-AlertSection -Heading 'H' -Rows @((New-AlertRow -Text '<script>x</script>' -Status 'ok')))
    )
    $nastyHtml = Format-AlertHtml -Message $nasty
    Check 'a certificate name cannot inject markup' `
          (($nastyHtml -notmatch '<script>x') -and ($nastyHtml -match '&lt;script&gt;')) `
          'a hostname is attacker-influenced input in some installs'
    Check 'an ampersand is escaped' ($nastyHtml -match 'a &amp; b') $nastyHtml

    # ----------------------------------------------------------------------- #
    Write-Host "`nmultipart assembly"
    $mail = New-Object Net.Mail.MailMessage
    try {
        Set-AlertMailBody -MailMessage $mail -Settings (New-TestSettings $true) -Message $msg
        Check 'two alternative views' ($mail.AlternateViews.Count -eq 2) `
              "got $($mail.AlternateViews.Count)"
        Check 'TEXT IS FIRST' `
              ($mail.AlternateViews[0].ContentType.MediaType -eq 'text/plain') `
              "got $($mail.AlternateViews[0].ContentType.MediaType) - a client takes the LAST it can render"
        Check 'HTML is second' `
              ($mail.AlternateViews[1].ContentType.MediaType -eq 'text/html') `
              "got $($mail.AlternateViews[1].ContentType.MediaType)"
        Check 'no Body is set alongside the views' ([string]::IsNullOrEmpty($mail.Body)) `
              'some servers then emit the content twice'
        Check 'the text part really is the text rendering' `
              ((Get-ViewText $mail.AlternateViews[0]) -match '\[FAIL\]') 'text part is not the text render'
        Check 'the html part really is the html rendering' `
              ((Get-ViewText $mail.AlternateViews[1]) -match '<table') 'html part is not the html render'
    }
    finally { $mail.Dispose() }

    # ----------------------------------------------------------------------- #
    Write-Host "`nwith HTML turned off, a structured message is still sent as text"
    $mail2 = New-Object Net.Mail.MailMessage
    try {
        Set-AlertMailBody -MailMessage $mail2 -Settings (New-TestSettings $false) -Message $msg
        Check 'no alternative views' ($mail2.AlternateViews.Count -eq 0) `
              "got $($mail2.AlternateViews.Count)"
        Check 'the body is the text rendering' ($mail2.Body -match '\[FAIL\]') $mail2.Body
        Check 'and is not flagged as HTML' (-not $mail2.IsBodyHtml) 'IsBodyHtml is set'
    }
    finally { $mail2.Dispose() }

    # ----------------------------------------------------------------------- #
    Write-Host "`nthe six existing senders are untouched by any of this"
    foreach ($html in @($true, $false)) {
        $m = New-Object Net.Mail.MailMessage
        try {
            Set-AlertMailBody -MailMessage $m -Settings (New-TestSettings $html) `
                -Body "plain text as it always was"
            Check "a -Body caller sends plain text (htmlEmail=$html)" `
                  (($m.AlternateViews.Count -eq 0) -and ($m.Body -eq 'plain text as it always was') -and (-not $m.IsBodyHtml)) `
                  "views=$($m.AlternateViews.Count) html=$($m.IsBodyHtml) body=$($m.Body)"
        }
        finally { $m.Dispose() }
    }

    # ----------------------------------------------------------------------- #
    Write-Host "`nan existing settings.json gets the new key backfilled"
    <#
      The top-level default merge fills in a MISSING alerts block but never
      looks inside one that is already there - and every install that matters
      has an alerts block. Without a nested backfill, a setting documented as
      "defaults to on" would be on for fresh installs and off for every real
      one, which is the worst of both.
    #>
    Save-TrackerSettings -Settings @{
        version = 1
        alerts  = @{
            smtp = @{ host = 'localhost'; port = 1025; encryption = 'none'
                      from = 'a@b.c'; to = @('d@e.f'); authRequired = $false; username = '' }
            expiry = @{ enabled = $true; thresholds = @(30) }
        }
    }
    $loaded = Get-TrackerSettings
    Check 'htmlEmail is present after loading an older file' `
          ($loaded.alerts.ContainsKey('htmlEmail')) 'the nested backfill did not run'
    Check 'and it is on' ([bool]$loaded.alerts.htmlEmail.enabled) `
          'an existing install would have silently kept text-only mail'
    Check 'a setting already in the file is not overwritten' `
          ([bool]$loaded.alerts.expiry.enabled) 'the backfill clobbered a real value'
}
finally {
    Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($script:Failed) { Write-Host "$script:Failed CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all checks passed' -ForegroundColor Green
exit 0
