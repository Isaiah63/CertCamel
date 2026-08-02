# Cert Camel v2

Watches when your TLS certificates expire, renews them, **deploys them to your
load balancers without a reload, and proves they are actually being served.**

Anything you track here is something you presumably intend to renew, so the
halves are one tool: the table tells you what needs attention, the Certificates
section renews it, and deployment puts it where it belongs.

Renewal goes over ACME with DNS-01 challenges, so it needs **no public IP and no
inbound web server** — only an API token for your DNS. That also makes wildcard
certificates possible, which HTTP-01 cannot issue at all.

```
┌─ Cert Camel ──────────────────────────────────────────────────────────────────┐
│  Certificates                                                                 │
│  example.com              Let's Encrypt   61 d   lb1 lb2 lb3 lb4   [Renew]    │
│  *.example.com  wildcard  Let's Encrypt   61 d   lb1 lb2 lb3 lb4   [Renew]    │
│  pay.example.com          DigiCert       142 d   lb1 lb2 ·· lb4    [Deploy]    │
└───────────────────────────────────────────────────────────────────────────────┘
```

> ### About v2
>
> v2 forked from **v1 commit `d96274d`** ([Isaiah63/CertCamel](https://github.com/Isaiah63/CertCamel)).
>
> v1 remains a working, standalone certificate watcher and ACME renewal console.
> It is stable and in maintenance. v2 adds deployment to HAProxy, verification
> that the deployment actually took, and unattended renewal.
>
> The two repositories share no git history, so **fixes do not propagate between
> them** — anything found in one has to be ported by hand.

## Deploying to HAProxy

Issuing a certificate does not fix anything until it reaches the load balancers.
v2 pushes it there over the **HAProxy Data Plane API**, without a reload, and
then checks that every node is genuinely serving it.

### Why the Data Plane API and not the Runtime API

The Runtime API can update a certificate live, but the change is **memory only**.
The next reload for any unrelated reason — a config change, a package update —
silently reverts to whatever is on disk, and you would not find out until the
certificate expired. The Data Plane API storage endpoint writes to disk *and*
pushes to the runtime socket, falling back to a reload only if that push fails.
Durable and hitless, which is the combination that matters.

Needs **HAProxy 2.2 or newer** (HAPEE 3.0 is comfortably past it).

### One-time HAProxy change: stable certificate paths

**HAProxy identifies a certificate by its file path.** A path with a date in it —
`/certs/2026.example.com/fullchain.pem` — cannot be updated in place, because
next year it is a different path, which means a config edit, which means a
reload.

```
Before                                     After
/certs/2026.example.com/fullchain.pem  ->  /certs/example.com.pem
/certs/2027.example.com/fullchain.pem      (path never changes; contents replaced)
```

No history is lost: Cert Camel already archives every previous version under
`certs/<id>/history/<timestamp>/` with an `about.json` recording issuer, validity
and names — finer-grained than a folder per year.

The certificates also have to live inside the directory the Data Plane API
manages (`resources.ssl_certs_dir` in `dataplaneapi.yml`). Converging them there
is usually more work than the config lines themselves.

**One reload to migrate. Zero reloads thereafter.**

Referencing them with `crt-list` rather than `crt` additionally makes *adding* a
new domain hitless, not just renewing an existing one. Both are supported.

### Setting it up

Settings → **Load balancers** → add a group. One entry per set of nodes that
share credentials; each node is still pushed to and verified individually. Nodes
go one per line:

```
lb1 https://10.0.0.11:5555
lb2 https://10.0.0.12:5555
dr1 https://10.9.0.11:5555  10.9.0.11
```

Name, then the Data Plane API URL. An optional third value is the address to
verify against, for when the site is not served from the same host as the API.

Press **Test** on the group to check every node answers before you rely on it.
It saves first, because the password lives in the encrypted store and an unsaved
card has no credential to test with. Results are per node:

```
lb1  ok    API v3, 4 certificates on disk
lb2  fail  authentication failed - check the username and password
```

Then assign the group to a certificate: click the **Deployed** cell on its row.
That assignment is what unattended renewal uses, since at 3am there is nobody to
ask.

**Renew** and **Deploy** both open a picker with that assignment pre-ticked,
which you can change for that run:

- Untick everything on **Renew** to renew only and push nothing.
- **Deploy** needs at least one - deploying nowhere is not a thing.
- Ticking a group the certificate is *not* assigned to deploys there anyway,
  which is how you reach a load balancer you have only just added.

## How deployment is verified

"The API returned 200" is not evidence that anything is being served. Four tiers:

| Tier | Check | Catches |
|---|---|---|
| **T0** | Before any push: the bundle parses, **the private key matches the certificate**, the chain is present, it is not expired, and it covers the names expected | Pushing a broken certificate to every node at once |
| **T1** | Each node's API accepted the upload | Auth, network, config-version conflicts |
| **T2** | Implicit — the Data Plane API only falls back to a reload if the runtime push failed, so a node passing T3 has loaded it | Written to disk but never loaded |
| **T3** | Connect to **each node directly** and compare the **serial** of what it serves | The real proof: wrong crt-list entry, wrong SNI mapping, one node missed |

**Serial, not expiry date.** A serial is unique per issuance, so it is the only
value that identifies a specific certificate. Two certificates issued the same
day have indistinguishable expiry dates — "days remaining went up" is
reassurance, not evidence. Days remaining is still reported, because it is the
number a human actually wants to see.

**Each node directly, never the VIP.** With a floating VIP, testing the VIP only
ever exercises whichever node currently holds it. A node that missed the push
stays invisible until failover — precisely when you cannot afford it. The
Deployed column shows one pip per node for the same reason.

A deployment is green only when **every** node passes. One node failing does not
stop the others, and the exit code is non-zero.

## Unattended renewal

`renew-due.ps1` renews only what the certificate authority says is due, then
deploys and verifies. `First Time Setup.bat` can register it as a daily task.

Timing comes from **ACME Renewal Information (ARI)**, not a number we picked. The
CA tells each client when to come back, which spreads load and — during a mass
revocation — lets the CA pull every renewal window forward. A hard-coded "30 days
before expiry" cannot hear that. A fixed threshold is used only as a fallback for
a CA that publishes no ARI.

Try it safely first:

```powershell
powershell -ExecutionPolicy Bypass -File .\renew-due.ps1 -WhatIfOnly
```

That reports what it would renew and stops.

> **Only put this on a machine that is always on.** If it sleeps or gets shut
> down, nothing renews and the first you hear about it is an expiry warning.
> Note also that credentials are DPAPI-encrypted and bound to one Windows user
> on one machine, so they are re-entered on the server rather than copied.

## Email alerts

Under Settings > Alerts, four independently switchable alerts:

| Alert | Fires when |
|---|---|
| Certificate expiring soon | A watched host crosses a configured threshold (default 30, 14, 7 days). Once per host per threshold, not on every check. |
| Renewal succeeded | Issuance and every deployment check passed. |
| Automated deployment failed | Anything on the unattended path did not fully succeed. The one that matters most — it is the only signal an unattended renewal has stopped working. |
| Monthly summary | 1st of the month: everything due within 31 days, and anything currently failing. |

The mail server needs a host, port, and at least one recipient. A username and
password are **optional** — leave "requires a username and password" unticked
for an internal relay that accepts mail from this machine with no login, which
is common on a corporate network. When you do supply a password it is stored
DPAPI-encrypted like every other credential here, never sent back to the
browser, and a blank password field on a later save means *keep the one
already stored*, not *clear it*.

Only two encryption modes are offered: STARTTLS (port 587, typical) and none.
Implicit TLS (a server that expects encryption from the first byte, historically
port 465) is not offered — PowerShell's mail client does not support it
reliably, and a security control that sometimes silently fails is worse than
one that plainly is not there. If your provider offers both, use STARTTLS.

A **Send test email** button saves first, then sends, the same pattern the DNS
and deployment tests use. Alerting can never fail a renewal: every send is
wrapped so a bad mail server gets logged and nothing else changes.

The monthly summary is a daily scheduled task that checks the date and does
nothing on every day but the 1st — the ScheduledTasks module has no clean
monthly trigger to reach for instead. `First Time Setup.bat` can register it.

## Requirements

- Windows, with **Windows PowerShell 5.1** (ships with Windows) and .NET 4.7.1+
- API access to your DNS provider — Cloudflare, DNS Made Easy and NS1 are wired
  up; adding another is a catalog entry, not new code
- No admin rights at any point. Monitoring needs nothing installed; renewal
  fetches [Posh-ACME](https://poshac.me) into `lib\` inside this folder

## Quick start

1. Clone or download this repository somewhere **outside** OneDrive, Dropbox or
   any other synced folder — see [Security](#security) for why.
2. Double-click **`First Time Setup.bat`** (once).
3. Double-click **`Open Tracker.bat`**.

Setup creates your domain list, optionally fetches the ACME client, runs the
first check, and offers to schedule a daily re-check at 9:00 AM.

`readme.html` in this folder is the same documentation as a browser page, with a
table of contents — it is linked from **Read me** in the app.

## The two ways to open it

A page opened from disk (`file://`) genuinely cannot run PowerShell, call a DNS
API, or write to its own folder — so buttons there would be decoration.
`Open Tracker.bat` starts a small server on `127.0.0.1` and opens the same page
against it, which is what gives the buttons something to talk to, and is now
the **only** way to open the tracker — every view, including the certificate
table, needs the session token the server hands it, so `ssl-tracker.html`
opened directly shows an explanation rather than a page. Close that window
and the server stops.

Nothing is exposed to your network: the server binds to loopback only, and every
request must carry a random token generated fresh each time it starts.

## Day-to-day use

| I want to... | Do this |
|---|---|
| Add or remove a domain | Edit **`domains.txt`**, one per line |
| Group domains by product | Add a `[Category]` header in `domains.txt` |
| Refresh the data | **Check now** on the page, or `Check Now.bat` |
| Renew a certificate | **Renew** next to it in the Certificates table |
| Get the certificate file | **.pem** next to it, after a renewal |
| Set up DNS credentials | **Settings** on the page |

`domains.txt` is the single source of truth for what gets watched. Blank lines
and `#` comments are ignored, and you can append `:port` to watch something
other than https:

```
example.com
www.example.com
mail.example.com:993
```

It is gitignored and never overwritten — it's yours. `domains.example.txt` is
the shipped sample that setup copies from on a first run.

## Categories

A line in `[Brackets]` starts a category. Every domain below it belongs to that
category until the next header — handy when one product has a pile of
subdomains:

```
[Example Product]
example.com
www.example.com
test.example.com
qa.example.com
```

The dashboard groups the table by category, gives each group a one-line health
summary (`7 domains · 2 need renewal`), and adds filter buttons. **Groups are
ordered by urgency, not alphabetically** — whichever category contains the
soonest expiry floats to the top. Past a dozen domains a search box appears too.

Categories are entirely optional and affect only how the page is organised.
They have nothing to do with how certificates are grouped — that's next.

---

# Renewal

## How certificates are grouped

You never configure this per domain. Certificates are grouped by **DNS zone**,
and the zone list comes from your DNS provider — the tool asks it which zones
the account manages, then puts every tracked hostname under the longest zone
that covers it.

So with `example.com` in your DNS account:

```
example.com          ─┐
www.example.com      ─┼─  one certificate, three names
shop.example.com     ─┘
```

Add a fourth hostname to `domains.txt` and it joins that certificate
automatically. Nothing to keep in sync.

This is why the zone list is read from the provider rather than guessed from the
name: guessing "the last two labels" is wrong for `example.co.uk`, and wrong
again when you have a delegated sub-zone like `dev.example.com` sitting under
`example.com`. The provider knows; we ask.

**Domains that map to no configured zone are flagged, not hidden.** They get a
`no DNS` badge and a callout, because a domain you can't renew is usually a gap
in the setup rather than a domain that doesn't matter.

## Certificates someone else renews

Some domains are worth watching precisely *because* something else renews them —
a hosting provider, a platform, another team. You want to know when that
automation quietly stops. What you do not want is this tool issuing a second
certificate alongside it.

Press **Managed elsewhere** on a certificate to mark it. It then:

- keeps being watched, with all the same expiry warnings
- shows a `managed elsewhere` badge and loses its Renew button
- is **excluded from "Renew all expiring"** — the important one
- is refused by the server even if something asks for it directly

Press **Renew here** to undo. The flag lives in `settings.json` under that
zone, so it survives re-checks and new domains.

### Which names end up on a certificate

The name list is your tracked hostnames **plus any additional names found on the
certificate currently being served**. That matters: if production has a
`legacy.example.com` that nobody ever added to `domains.txt`, renewing without
it would quietly break that host.

Two kinds of name are deliberately left off, and shown as *Not included* so the
omission is visible rather than silent:

- **Wildcards.** Never folded in — they get their own certificate, see below.
- **Names in zones you don't manage.** We couldn't complete the DNS challenge
  for them, so requesting them would fail the whole order.

## Wildcards

Contrary to a widespread belief, **HTTP-01 cannot issue wildcard certificates at
all** — DNS-01 is the only challenge type that can. HTTP-01 proves control of one
hostname by serving a file from it, and `*.example.com` stands for infinitely
many hostnames. DNS-01 proves control of the *zone* with one TXT record.

So wildcards need no public IP and no web server. Ask for one with its own line
in `domains.txt`:

```
[Example Product]
example.com          <- these three go on one certificate
www.example.com
shop.example.com

*.example.com        <- a SEPARATE wildcard certificate
```

That produces a second, independent certificate containing `*.example.com`
**and** `example.com`, with its own row, Renew button and `.pem`.

The wildcard is **never** merged into the certificate covering your explicit
names, and there is no setting to merge them. Some routers — OpenShift among
them — will not negotiate HTTP/2 against a wildcard certificate, so contaminating
the explicit-name certificate would break exactly the hosts it exists to serve.

Two things worth knowing: `*.example.com` does **not** match `example.com`, which
is why the apex rides along; and a wildcard matches one label only, so it covers
`www.example.com` but not `a.b.example.com`.

A wildcard line is not watched — nothing answers at a wildcard name, so there is
no certificate to read. Those lines stay out of the expiry table rather than
sitting there permanently as an error.

## Setting up DNS

Renewal proves you control a domain by writing a `_acme-challenge` TXT record
(DNS-01), which is why it needs API access to your DNS.

Open **Settings** and add a DNS profile. Press **Test connection** — it lists
the zones it can see, which is how you confirm credentials work before relying
on them.

| Provider | What you need | Where |
|---|---|---|
| **DNS Made Easy** | API Key + Secret Key | Console → *Account Information* |
| **NS1** | API Key | Portal → *Account Settings → API Keys* (needs DNS read + record write) |

Domains are many; DNS accounts are few. A handful of profiles typically covers
every domain you track.

Adding another provider is a catalog entry in `acme-lib.ps1`, not new code —
Posh-ACME ships 88 DNS plugins and `renew.ps1` passes whatever the profile holds
straight through. Only the zone auto-discovery is provider-specific.

> **Clock accuracy matters (DNS Made Easy).** It rejects any request whose
> timestamp is more than 30 seconds off from theirs. If the system clock has
> drifted you get a bare 403; the tool detects this case and says so explicitly.

### The DNS Made Easy sandbox

There's a free sandbox account at `sandbox.dnsmadeeasy.com` with its own API
keys, and a checkbox on the profile to use it.

It is useful for proving your credentials, request signing and zone discovery
work without touching a production DNS account. **It cannot issue a real
certificate**, though: sandbox zones aren't authoritative on the public
internet, so the certificate authority can't see the challenge record and
validation will fail. Use it to test the setup, not the issuance.

## Staging first

New setups start in **staging**, against Let's Encrypt's test environment.
Staging certificates are *not trusted by browsers*, but they don't consume rate
limits — and Let's Encrypt's limits are real (50 certificates per registered
domain per week, 5 identical certificates per week).

Run one renewal in staging, confirm it completes, then turn staging off in
Settings and do it for real.

## What you get

A renewal writes into `certs\<zone>\`:

```
<zone>-full.pem    certificate + chain + private key   <- the .pem button
fullchain.cer      certificate + chain
cert.cer           certificate only
chain.cer          intermediates only
cert.key           private key (PEM, unencrypted)
cert.pfx           certificate + key (PKCS#12)
```

The combined `-full.pem` is what most appliances and load balancers want pasted
in, and it's what the **.pem** button hands you. The rest are there when
something wants them separately.

Deploying the certificate is still yours to do — this tool issues and hands over,
it does not install. That also means the expiry date in the table won't change
after you renew: what it shows is whatever the live host is currently serving.

### Previous versions are kept

The current certificate always stays at that stable path, so download links and
anything pointed at the folder keep working. Each renewal copies the outgoing
certificate into `history\` first, stamped with the date it was written:

```
certs\example.com\
  example.com-full.pem          <- current, always here
  cert.cer  cert.key  chain.cer  fullchain.cer  cert.pfx  fullchain.pfx
  history\
    2026-07-29_210335\          <- the certificate live from that date
      about.json                   names, issuer and validity
      ...the full file set
```

Copied rather than moved, so a failed write leaves a working certificate at the
stable path instead of nothing. Re-running against an order the CA still
considers current does not archive a duplicate.

**History is capped at five versions**, and that is deliberate: every archived
version contains a usable private key, valid until that certificate expires, so
an unlimited archive quietly becomes a pile of live credentials. Set
`keepHistory` in `settings.json` to change it; `0` keeps none.

## Renewing several at once

**Renew all expiring** orders every certificate inside the 30-day window, one
after another. Sequentially on purpose: concurrent orders against one DNS
account collide on the `_acme-challenge` record, and serialising also keeps you
away from the rate limits. One failure doesn't abandon the rest.

Expect a few minutes per certificate — most of it is waiting for DNS to
propagate before the CA will validate.

## Certificate authorities

Different certificates can come from different authorities. A common pattern is
to move most of an estate to Let's Encrypt while keeping payment or otherwise
sensitive certificates with a paid CA.

Add authorities under *Settings → Certificate authorities*, then pick one per
certificate from the **Issuer** dropdown on its row. Anything not pinned follows
the default, and shows `default` under the dropdown so you can see which is
which. Staging is **per authority** — Let's Encrypt has a test environment, most
paid CAs do not.

Accounts are per authority, and Posh-ACME keeps them separate, so mixing costs
you nothing. The renewal log names the issuer for every order, and the
confirmation before a renewal spells out which CA each certificate goes to and
whether it is production or staging.

### DigiCert CertCentral

Get the ACME directory URL and the External Account Binding credentials (key ID
+ HMAC key) from *Automation → ACME Directory URLs* in CertCentral, and put them
in a new authority profile.

Two things to know:

- DigiCert retired its **legacy ACME endpoint on 24 February 2026** — use the
  current service.
- For **OV/EV** certificates the organization must be prevalidated in
  CertCentral first, and DigiCert then validates domains out of band, so those
  orders may not use a DNS challenge at all. For plain **DV** certificates none
  of that applies and it behaves like any other ACME CA.

### DV, OV and EV

Worth knowing which you actually have, because it decides what is possible:

| | Proves | Issued by |
|---|---|---|
| **DV** | You control the domain | Anyone, including Let's Encrypt |
| **OV** | Above, plus your organization legally exists | Paid CAs only |
| **EV** | Above, with stricter vetting | Paid CAs only |

Browsers treat all three the same — same padlock, same encryption. **Let's
Encrypt issues DV only.** If your paid certificates are DV, keeping them with a
paid CA is a policy, procurement or audit decision rather than a technical
requirement. That can be a perfectly good reason; it just isn't a constraint.

You can tell them apart in the certificate details: an OV or EV certificate
names your organization in the Subject, a DV certificate carries only the domain.

### Renewal is getting more frequent

Under CA/Browser Forum ballot SC-081v3, the maximum certificate lifetime dropped
to **200 days on 15 March 2026**, falls to **100 days in March 2027**, and to 47
days in 2029. This applies to every public CA, paid ones included. Whatever is
renewed by hand today needs doing twice as often next year.

---

## Why there's a script and not just a web page

A browser **cannot read SSL certificates.** There is no JavaScript API for it,
and a page loaded from disk is blocked from contacting other domains at all. So
`check-ssl.ps1` does the real work — it opens a TLS connection to each host and
reads the certificate — and `ssl-tracker.html` displays what it found.

This is also why the data lands in **`ssl-data.js`** rather than a `.json` file:
when you open the page straight from disk, the browser blocks it from reading a
sibling `.json` file even though it's sitting right there, but a `<script>` tag
has no such restriction. If you ever refactor this, keep it as `.js` — switching
to JSON will leave you with a page that silently shows nothing.

Hosts are checked in parallel, so a hundred domains take seconds rather than
spending the full timeout on each unreachable one in turn.

Days remaining is recalculated in the browser each time you open the page, so
the countdown is always right even if the checker hasn't run in a while.

## Status meanings

| Chip | Meaning |
|---|---|
| **OK** | More than 30 days left |
| **Renew soon** | 30 days or fewer — act on this |
| **Expired** | Already past due; visitors see a security warning |
| **Error** | Couldn't connect. Usually a typo in `domains.txt`, or the host is down |
| **no DNS** | No configured DNS provider manages this domain, so it can't be renewed here |

## Security notes

- The server listens on `127.0.0.1` only and requires a per-launch random token.
  Loopback alone isn't access control — anything else on the PC can reach it.
- DNS credentials are encrypted with **Windows DPAPI** (`secrets.xml`), scoped to
  your Windows account on this machine.
- `certs\` and `acme-state\` hold **private keys**. They are gitignored, but
  gitignore doesn't stop file sync — **if this folder is inside OneDrive,
  Dropbox or similar, exclude those two folders from syncing.**
- Nothing here — domains, credentials, certificates — is committed to git, so
  the folder can be handed to someone else clean.

## Moving or sharing this folder

Copy the folder anywhere and it works, with two exceptions worth knowing:

- **Credentials don't travel.** DPAPI ties them to one Windows user on one
  machine, so re-enter them in Settings. That's the right behaviour for a tool
  meant to be shared — nobody inherits anyone else's API keys.
- **The scheduled task stores an absolute path.** After moving, run
  `First Time Setup.bat` again to re-point it.

Requires Windows PowerShell 5.1, which ships with Windows. Monitoring needs
nothing installed. Renewal adds [Posh-ACME](https://poshac.me), downloaded into
`lib\` inside this folder rather than installed system-wide — no admin rights at
any point.

## The scheduled task

- **Name:** `SSL Cert Check`
- **Runs:** daily at 09:00, as the current user, hidden window
- **Catch-up:** runs as soon as possible if the PC was off (`StartWhenAvailable`)

It only re-checks expiry; it does not renew anything unattended.

```powershell
# Run it right now
Start-ScheduledTask -TaskName "SSL Cert Check"

# Turn it off / back on
Disable-ScheduledTask -TaskName "SSL Cert Check"
Enable-ScheduledTask  -TaskName "SSL Cert Check"

# Remove it completely
Unregister-ScheduledTask -TaskName "SSL Cert Check" -Confirm:$false
```

## Files

```
Open Tracker.bat      start the server and open the page  <- use this
ssl-tracker.html      the app shell (sidebar + view containers; needs the server)
assets\app.css        all styling
assets\app.js         router, API client, shared state, the job runner
assets\views\         one file per sidebar page (home, certificates, settings, docs)
readme.html           the documentation as a browser page
haproxy-setup.html    step-by-step HAProxy Data Plane API guide
domains.txt           the list you edit                   (yours, gitignored)
domains.example.txt   the shipped sample
Check Now.bat         refresh the data
First Time Setup.bat  one-time setup

check-ssl.ps1         the checker (parallel, records SANs and serials)
serve.ps1             the local server
renew.ps1             performs one renewal, then deploys it
deploy.ps1            pushes to load balancers and verifies every node
renew-due.ps1         renews whatever the CA says is due, sends expiry alerts (scheduled task)
monthly-report.ps1    sends the monthly summary email, if turned on (scheduled task)
acme-lib.ps1          shared settings, secrets, grouping and alert-sending logic
setup.ps1             what setup runs

generated, none committed:
  ssl-data.js         checker output
  settings.json       your configuration
  secrets.xml         DNS/SMTP credentials, DPAPI-encrypted
  zones.json          cached zone list from your DNS provider
  alert-state.json    which expiry thresholds have already been emailed, per host
  certs\              issued certificates and private keys
  acme-state\         ACME account and order state
  jobs\               renewal logs
  lib\                Posh-ACME
```
