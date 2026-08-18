# Security

Cert Camel holds DNS provider API tokens, load balancer API credentials and TLS
private keys. A problem in it is worth reporting, and this page says how and what
to expect.

## Reporting a vulnerability

**Please do not open a public issue for a security problem.** Use GitHub's
[private vulnerability reporting](https://github.com/Isaiah63/CertCamel/security/advisories/new)
— the **Report a vulnerability** button on the Security tab. That opens a private
thread visible only to the maintainer.

If that button is not there, please **do not describe the problem in a public
issue**. Open an issue saying only that you have a security report and would like
somewhere private to send it, and you will be pointed at one.

Useful things to include, as far as you have them: what you did, what happened,
what you expected instead, the Cert Camel version from the `VERSION` file, your
Windows and PowerShell versions, and whether the page was reachable at anything
other than `127.0.0.1`.

**Please do not include real credentials, private keys or certificate bodies.**
Cert Camel masks those in its own logs on purpose; a bug report should not undo
that. Redact them and say what they were.

## What to expect

**This is a one-person beta project.** There is no security team, no on-call, and
no response-time promise. That is a real limitation, not modesty, and it is worth
weighing before deploying this somewhere that matters.

What is promised: a report will be read, you will get a reply, and you will be
credited when a fix ships unless you would rather not be.

## Supported versions

Only the newest release. There are no maintenance branches, and fixes are not
backported — updating is the remedy. **Settings → General → Update** compares
this copy against the newest published release, and
[the README](README.md#updating) explains how that works for clones and for ZIP
downloads.

## Scope

In scope: anything that exposes a credential or a private key, lets a request
without the session token reach an endpoint, permits code execution through the
page or its inputs, or defeats the loopback binding and Host check.

Out of scope, because they are documented design decisions rather than defects —
[Security notes](README.md#security-notes) explains each:

- **The page is not authenticated by a password.** It binds to loopback, requires
  a per-start session token, and checks the Host header. Anyone already running
  code as your Windows user has your certificates anyway.
- **Credentials are DPAPI-encrypted to one Windows user on one machine.** That is
  deliberate: copying the folder elsewhere does not carry them.
- **Administrator is required** to register tasks that run while signed out and
  to start the page at boot. Nothing else asks for it.
- **The tool trusts its own configuration.** Somebody who can edit
  `settings.json` can already run code as you.

## What it does not do

No telemetry, no analytics, and nothing on a timer that reports anywhere. The
only request to a host you did not configure is the release-version check behind
**Check for updates**, and only when you press it.
[Updating](README.md#updating) has the detail, and `security.html` in the folder
has more.
