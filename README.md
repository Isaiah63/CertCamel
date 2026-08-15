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
new domain hitless, not just renewing an existing one. Both are supported — and
with a crt-list this is automatic: put the list's path in the deployment group's
**crt-list path** field (exactly as it appears on the bind line), and any pushed
certificate the list does not reference yet is appended and hot-loaded. The
deploy log says which happened per node — `appended ... and the running process
loaded it` versus `already referenced` — and a certificate that got appended on
disk but never picked up by the running process fails the node loudly instead
of surfacing as an unexplained verification failure.

Rather than typing that path, press **Discover** on the group: it asks each node
which frontends terminate TLS and offers the ones every node agrees on, filling
in the crt-list and port from what they report. A frontend present on only some
of the nodes is shown as *partial* rather than offered — a pair configured
differently is worth fixing before you deploy to it. Discovery is strictly
read-only; Cert Camel writes certificate storage and crt-list entries, never a
bind line.

### One group, several frontends

A group answers *"which nodes, and what credentials"*. A crt-list answers
*"where is this certificate referenced"*. Those are different questions, so an
assignment can override the group's placement settings for one certificate:

```json
"certs": {
  "wildcard.example.com": {
    "targets": [ { "id": "office", "crtList": "/etc/haproxy/crt-list-wild.txt" } ]
  },
  "example.com": { "targets": [ "office" ] }
}
```

Both certificates go to the same pair of nodes with the same credentials, but
land in different frontends. Set it from the **Deployed** cell — tick a group,
open *Overrides for this certificate*, and leave anything blank to inherit. A
bare id stays a bare id, so nothing changes shape until you pin something.

> Overrides cover placement (`crtList`, `verifyPort`, `remoteName`), never
> credentials — those belong to the group, and the API refuses an override that
> names one.

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
- No admin rights to monitor or renew. Nothing is installed system-wide; renewal
  fetches [Posh-ACME](https://poshac.me) into `lib\` inside this folder.
  Administrator is needed only for the two things that genuinely require it:
  registering tasks that run while you are signed out, and starting the page at
  boot on a server

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
`Open Tracker.bat` — or the **Cert Camel** shortcut beside it, which is the same
launcher with the camel on it — starts a small server on `127.0.0.1` and opens
the same page against it, which is what gives the buttons something to talk to,
and is now the **only** way to open the tracker — every view, including the certificate
table, needs the session token the server hands it, so `ssl-tracker.html`
opened directly shows an explanation rather than a page. Close that window
and the server stops.

Nothing is exposed to your network: the server binds to loopback only, and every
request must carry a random token generated fresh each time it starts.

**Why a shortcut rather than an icon on the `.bat` itself?** Windows takes a
batch file's icon from the file *association*, which is per-extension and
machine-wide — giving this one a camel would put a camel on every `.bat` on the
computer. A shortcut carries its own icon, so that gets one instead. Setup
creates it, and offers a desktop copy. It is **not** in the repository: a `.lnk`
bakes in an absolute path, so a committed one would point at whoever built it.
Re-run setup after moving the folder and it is rebuilt.

### Serving the page over HTTPS

Optional, off by default, and it needs a DNS provider already configured — so
nothing about a first look at Cert Camel changes. **Settings → General → Tracker
address** turns it on: give the page a hostname and a fixed port, and it serves
itself over TLS using a certificate it issued.

It stays on loopback. The hostname resolves to `127.0.0.1` through this
machine's hosts file, and **no public DNS record is needed** — ACME's DNS-01
validation only reads a `_acme-challenge` TXT record and never connects to the
host. (A public record pointing at `127.0.0.1` would also work, and is the worse
option: resolvers routinely refuse to return loopback answers — `dnsmasq
--stop-dns-rebind` is on by default in a lot of router firmware — so it would
resolve in some places and silently fail in others.)

Four things have to be true, and the panel reports them separately because they
fail in four different places:

| | |
|---|---|
| **DNS zone** | A configured credential must manage the name's zone. A token scoped to one zone cannot issue for another, however plausible the name looks — check this before anything else |
| **Certificate** | One on disk must cover the name. A wildcard you already hold counts, and then no `domains.txt` entry is wanted: adding one would pull the name off the wildcard and onto the zone's other certificate |
| **Port** | Fixed, not the random free port used by default. A name is no use on a port that moves every launch |
| **Hosts file** | `127.0.0.1  tracker.example.com`. Needs administrator, so the panel offers to write it or gives you the line. **No port on this line** — the hosts file has no port field, and `name:8787` there does not error, it just never matches |

Two things worth knowing before you pick a name:

- **The hostname becomes public.** Every certificate's SAN list is published to
  Certificate Transparency logs, so `crt.sh` will list it the moment it is
  issued — with or without a DNS record. That is true of every certificate from
  every authority; skipping the DNS record buys resolution reliability, not
  privacy.
- **Certificates group by DNS zone.** Put the tracker on a name in a zone you
  already renew and it joins that zone's certificate. Give it a zone of its own
  and it gets a certificate of its own.

**Turning it on takes effect at the next start**, because the certificate is
loaded once when the server starts. Save, then restart — `Stop-ScheduledTask
-TaskName 'Cert Camel Server'` and `Start-ScheduledTask` if it runs at boot,
otherwise close the console and re-open `Open Tracker.bat`.

**Plain HTTP on that port gets a 302 to the HTTPS URL**, so an old bookmark or a
typed `127.0.0.1` still lands somewhere. It is deliberately a *temporary*
redirect: a permanent one is cached by the browser, and turning HTTPS back off
later would leave it still redirecting to a scheme the server no longer speaks.

If the certificate ever fails to *load* — missing file, unreadable key — the
server says so and falls back to plain HTTP rather than refusing to start. An
*expired* certificate is different and less serious: the browser still offers
Advanced → Proceed, and because renewal runs from the scheduled task rather than
from this page, the 03:20 run repairs it with nobody watching. `serve.ps1
-NoTls` forces plain HTTP for the cases neither of those covers.

The page never sends `Strict-Transport-Security`. It is a good header on a
public site and a lockout waiting to happen here — it removes the
click-through that is the recovery path for a local certificate problem.

## Day-to-day use

| I want to... | Do this |
|---|---|
| Add or remove a domain | **Edit domains** on the Certificates page — saving re-checks automatically. (Editing `domains.txt` by hand still works.) |
| Group domains by product | Add a `[Category]` header above them in the editor |
| Refresh the data | **Check now** on the page, or `Check Now.bat` |
| Renew a certificate | **Renew** next to it in the Certificates table |
| Get the certificate file | **.pem** next to it, after a renewal |
| Set up DNS credentials | **Settings** in the sidebar |

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

## Posh-ACME, and keeping it current

Renewal runs on [Posh-ACME](https://poshac.me), fetched into `lib\` by First Time
Setup rather than committed here. The Docs page shows which version you have.

**A fresh install always gets the newest**, because setup asks for the latest.
**An existing install stays where it is** and does not move on its own. That is
deliberate: this is the component every renewal talks to your CA and your DNS
provider through, so an update that breaks a DNS plugin breaks the 03:20
unattended run with nobody watching. It should move when you decide it does.

It is still worth moving occasionally — ACME keeps changing (renewal information,
certificate profiles, the shrinking lifetimes above) and DNS plugins get fixed.

```powershell
# update to the current release
. .\acme-lib.ps1
Install-PoshAcmeLocal -Force
```

The previous version is left in place beside the new one rather than deleted,
which makes going back a deletion rather than a reinstall:

```powershell
# list what is installed
Get-ChildItem .\lib\Posh-ACME

# revert - remove the newer folder and the older one takes over again
Remove-Item .\lib\Posh-ACME\<newer-version> -Recurse
```

Restart the tracker afterwards either way, and renew something against
**staging** before trusting it — that costs nothing and is the whole point of
having a staging authority configured.

## When a test email says it sent and nothing arrives

**"Sent" is not what the tool knows.** A send that returns without an error
means the SMTP server **accepted** the message. Whether it was then delivered,
filed as spam, or dropped is decided afterwards and elsewhere, and nothing
visible from here can tell those apart. So the page reports *accepted by
`<host>` for `<recipients>`*, and says so plainly.

**Every attempt is recorded** — the test button and every real alert — as an
`email` line in the audit trail, visible on the **Logs** page. It carries the
server, port, encryption, from-address, recipients and a **Message-ID that Cert
Camel generates itself**. That id is the one handle that survives into the
receiving mail server's logs, so it is what to hand to whoever runs it. The SMTP
password is never part of any of it.

When a message is accepted and does not arrive, the usual causes in order:

| | |
|---|---|
| **It has not arrived *yet*** | Check this first. A mail server that is behind delivers the whole backlog at once, sometimes hours later. Accepting a message and queueing it is normal, correct behaviour — and it is indistinguishable from a message that was dropped until the queue drains |
| **SPF or DKIM** | The from-address belongs to a domain whose records do not authorise this server. The relay accepts it and the recipient's side discards it |
| **The relay is discarding it** | Common on ISP and appliance relays that accept everything and quietly drop what they will not carry |
| **Spam filing** | Especially for a first message from a new sender to a domain |

This is exactly what the Message-ID is for. Rather than guessing between those
four, hand it to whoever runs the mail server and they can say which one it was
— including "it is still in the queue".

Alert failures used to be recorded only in the run log, where nobody looks for
"have my alerts stopped working". They are in the audit trail now too. A failed
alert still never fails the renewal it was reporting on — that is deliberate.

## The load balancer panel

Under Tracked domains, when — and only when — deployment targets are
configured. Per node: whether its Data Plane API answered, HAProxy's own **node
name** (`hap1`, `hap2` — the thing that tells two nodes behind one address
apart), the running HAProxy version, and the group's last deployment result.

**It never probes while you wait.** A node that blackholes packets takes ten
seconds to fail, and the web server handles one connection at a time — so the
sweep runs as a detached child process, writes `jobs\lb-status.json`, and the
page reads that. **Check now** starts a fresh sweep and polls it. The rest of
the UI stays responsive throughout, which matters most precisely when a load
balancer is unreachable.

**There is no VRRP row, and there cannot be an honest one.** MASTER and BACKUP
live in keepalived, which has no API. HAProxy binds its frontends on every node
whether or not that node holds the virtual address, and has no idea one exists —
so nothing the Data Plane API can be asked will tell you who is master. Reading
it truthfully needs something on each node publishing keepalived's state, which
is outside what this tool can arrange. Anything shown here claiming to know
would be guessing.

## The Load balancers page

The panel on Home is the summary; this is the detail, and it answers a question
nothing else can: **is any frontend actually reading the crt-list a certificate
is deployed to?**

That matters because Cert Camel writes certificate storage and crt-list entries
and **never a bind line**. A wrong crt-list path produces a green deployment, a
certificate sitting on disk, and nothing served. Neither verification tier sees
it — the wire check needs a per-node TLS address, and the runtime check proves a
certificate is loaded, not that anything references it.

Certificates are grouped by what serves them, worst first, in four states:

| | |
|---|---|
| **served** | a bind on this group reads the expected crt-list |
| **not referenced** | nothing reads it. The certificate is deployed and will never be served |
| **unknown** | a relative crt-list path. HAProxy resolves those against its own working directory, which cannot be checked from here, so it says so rather than guessing |
| **not managed here** | a TLS frontend reading a crt-list Cert Camel does not write. Not a fault — this is how you see what is still outside the tool |

**When a path does not match, the fix is offered in both directions**, because
which side is wrong depends on what you meant and the tool cannot know:

- *Point HAProxy at Cert Camel's list* — a `bind` edit on every node and a
  reload. Usually right when the certificate has its own frontend and the path
  was mistyped.
- *Point Cert Camel at HAProxy's list* — a settings change, no reload. Usually
  right when adopting a load balancer that already works.

The two paths are shown side by side, because a typo in a long path is nearly
invisible in prose. Cert Camel still never edits your configuration; the dialog
hands you the commands.

**A `crt` directory bind is not a fault.** If a frontend binds a directory
rather than a crt-list, everything in that directory is served — the certificate
is fine, it just is not hot-loaded until the next reload, and the row says so.

Like the Home panel, the page reads a cache. The sweep runs out of process, so
an unreachable node never freezes the interface.

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

**The apex goes on the wildcard, and comes off the other certificate.** It has
to be on the wildcard — `*.example.com` does not match a bare `example.com` — so
leaving it on both would put one name on two certificates of equal specificity,
where only one can ever serve it. HAProxy would match whichever it indexed
first and the loser would silently never appear. So in the example above, the
first certificate covers `www.` and `shop.` only, and the row says so.

Nothing to configure, and **do not delete the apex line from `domains.txt`** to
achieve it: a line there means both "watch this name" and "put it on the SAN
certificate", and removing it would stop the name being monitored. Both names
stay watched either way.

A certificate issued before this rule existed still carries the apex until it is
renewed, so its row and its deploy log say *"still carries example.com — renew
to apply"* until you do.

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

## Logs and the audit trail

The **Logs** page is read-only, and deliberately so — a page that could edit the
record would not be worth much as a record. It shows two different things that
are easy to confuse:

**Run logs** (`jobs\`) are the narrative of one run: every ACME step, every push,
every verification tier. Useful when something went wrong and you want to know
where. Named for what they are and when they ran — `2026-08-05T032000Z-renew-due.log`.
Scheduled runs write these too; before, the 03:20 renewal wrote nothing at all,
which meant the runs nobody watches were the ones with no record.

**The audit trail** (`audit.log`) is one line per state change, append-only:

```
when                  who    source  event     object            outcome  detail
2026-08-05T09:47:25Z  ULTRA  task    renew     camelnuggets.com  ok       issued serial 05B3DC…, expires 2026-11-03
2026-08-05T10:02:11Z  ULTRA  ui      settings  general, logs     ok       2 section(s) updated
```

`source` separates `ui` from `task` — whether a person or the scheduler made the
change, which is usually the next thing asked about any given line. A scheduled
sweep records itself even when nothing was due, so an empty stretch means
"nothing needed doing" rather than "the scheduler stopped firing".

**What is never recorded:** no credential value, no private key, no certificate
body. Credential changes are logged by key *name* only (`fake-pair:password
removed`), and every line goes through a redaction pass on the way in so a future
debug line cannot leak one by accident.

### Retention

Under **Settings → General**, applied to run logs only:

| | Default |
|---|---|
| Keep run logs for | 90 days |
| Maximum log folder size | 200 MB |

Whichever is reached first trims oldest-first. Per-certificate state files
(`deploy-<id>.json`) are current state rather than history and are never trimmed.
Every trim writes its own audit line, so the log accounts for its own gaps.

**The audit trail is exempt from both limits.** It rotates to `audit-<stamp>.log`
when large, and those archives are kept. Deleting audit records to reclaim disk
is what an assessor would object to, and a silent exception would be worse than a
stated one — so it is stated, on the page as well as here. If a retention policy
genuinely requires audit expiry, that wants to be its own explicit setting rather
than a side effect of a disk cap.

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

## The scheduled tasks

Three, all optional, all registered by `First Time Setup.bat`, all running as
the current user in a hidden window with `StartWhenAvailable` so they catch up
after the PC has been off. Only **one of the three can change anything**:

| Task | Runs | What that run does |
|---|---|---|
| `Cert Camel Renew` | daily 03:20 | Renews what the CA says is due, deploys each one, verifies every node is serving it |
| `SSL Cert Check` | daily 09:00 | Re-reads expiry dates. Never issues or deploys |
| `Cert Camel Monthly Report` | daily 08:00 | Emails a summary on the 1st; does nothing on other days |

### Seeing and changing them

They are ordinary Windows scheduled tasks — nothing about them is private to
Cert Camel. Press **Win+R**, run `taskschd.msc` (or search "Task Scheduler" in
Start), and click **Task Scheduler Library**. All of them sit in that root list,
not in a subfolder.

From there, right-click any of them for **Run**, **End**, **Disable** and
**Properties**, where the Triggers tab holds the time. **The times are yours to
change** — 03:20 is only a default, chosen because it is quiet and after most
backup windows. Nothing in Cert Camel depends on those exact times.

Worth turning on while you are in there: **Enable All Tasks History**, in the
right-hand Actions pane. It is a global Windows setting and it is **off by
default**, which means the History tab on every task is empty. That is exactly
the wrong state to discover halfway through working out why something did not
run.

The Home page reads the schedule back out of Windows rather than assuming the
defaults, so a time you change in Task Scheduler shows up there — which is the
quickest way to confirm an edit took.

Three things to know before you edit:

- **Changing the monthly report's day does nothing.** It is registered as a
  *daily* task that checks the date and exits on any day but the 1st, because
  `New-ScheduledTaskTrigger` has no clean monthly trigger to reach for. Moving
  it to the 5th just means it runs on the 5th and does nothing. Change its
  *time* freely; the day is decided in the script.
- **Watch the password checkbox.** The three unattended tasks are registered
  S4U — *Run whether user is logged on or not* with **Do not store password**
  ticked. If that box gets cleared while you are in Properties, Windows starts
  storing a password instead, and the task breaks the next time that password
  changes. `First Time Setup.bat -RepairTasks` (as administrator) puts the
  principal back and **keeps whatever schedule you set** — it re-registers each
  existing task with its own trigger and settings intact.
- **The task stores an absolute path.** Move or rename this folder and the tasks
  still point at the old one: renewal quietly stops and the first symptom is an
  expiry warning weeks later. The Home page flags this when it sees it, but
  re-running setup after a move is the fix.

### Keeping the page running (server installs)

Normally Cert Camel runs while `Open Tracker.bat` is open and stops when you sign
out. On a server that means it is gone after every reboot until somebody signs in
and starts it again.

Run `First Time Setup.bat` **as administrator** on a Windows Server and it offers
to register a fourth task, `Cert Camel Server`, which starts the page at boot:

| | |
|---|---|
| Listens on | `127.0.0.1:8787` — this machine only, reached over RDP |
| Survives | sign-out, and reboots |
| Exposed to the network | **nothing** |

It stays on loopback deliberately. Reaching it from another machine needs TLS, a
password and a network ACL, none of which exist yet — so this phase does not
pretend to offer it.

**Why a scheduled task and not a Windows service?** A service has to run as some
account, and the only one that can decrypt `secrets.xml` is the account that
saved it — so Windows would have to store that account's password, which breaks
the moment the password changes. A scheduled task using S4U stores no password at
all. The cost is that it lives in Task Scheduler rather than `services.msc`.

```powershell
# Start it now rather than waiting for a reboot
Start-ScheduledTask -TaskName "Cert Camel Server"

# Stop the running page (the task restarts it at next boot)
Get-Content .\jobs\session.json | ConvertFrom-Json | ForEach-Object { Stop-Process -Id $_.pid }

# Remove it entirely
Unregister-ScheduledTask -TaskName "Cert Camel Server" -Confirm:$false
```

Once it is running, `Open Tracker.bat` stops starting a second copy — it finds
the one already running and just opens your browser at it.

**If you change which account it runs as, it breaks.** `secrets.xml` is encrypted
with DPAPI, which is bound to one Windows account: a different account cannot
decrypt it, so DNS automation and load-balancer pushes start failing while
everything else looks fine. Re-enter the credentials under Settings as the new
account if you ever move it.

Two files appear once it runs. `jobs\session.json` records the current port and
token so the launcher can find it — it is locked to SYSTEM, Administrators and
the account running the server, because that token grants full use of the API.
`server.log` is the page's own diagnostics, which is the only place errors go
when there is no console; it rotates itself and never contains the token.

### Do they run when nobody is signed in?

Only if setup could register them that way, and that needs administrator.

Run `First Time Setup.bat` **as administrator** and the tasks are registered to
run whether or not you are logged on. Run it normally and Windows refuses
(*Access is denied*), so they fall back to running **only while you are signed
in** — setup says so at the time.

On a PC you use daily that is fine; `StartWhenAvailable` catches up whenever you
next log in. **On an always-on server it is not fine at all**: nobody stays
logged in, so the 03:20 renewal never fires. Task Scheduler still shows the task
as "Ready" and its history stays empty, and the first thing you notice is an
expired certificate. If you are installing on a server, elevate.

To check an existing install:

```powershell
Get-ScheduledTask -TaskName "Cert Camel Renew" | Select-Object -Expand Principal
```

`LogonType` of `S4U` runs unattended. `Interactive` does not — re-run setup as
administrator to fix it.

03:20 rather than the top of the hour because ACME rate limits are per-CA and
shared by everyone, and every naive scheduler piles up on the hour.

```powershell
# Run one right now
Start-ScheduledTask -TaskName "Cert Camel Renew"

# Turn it off / back on
Disable-ScheduledTask -TaskName "Cert Camel Renew"
Enable-ScheduledTask  -TaskName "Cert Camel Renew"

# Remove it completely
Unregister-ScheduledTask -TaskName "Cert Camel Renew" -Confirm:$false

# See what would renew, without renewing anything
powershell -ExecutionPolicy Bypass -File .\renew-due.ps1 -WhatIfOnly
```

### The Automation panel on Home

The Home page reports what the scheduler actually has registered, so none of the
above has to be taken on trust. The **Automation** box lists each service and
when it runs, with an overall state — a list rather than a sentence, because the
three run at three different times and any one-line summary of them is wrong:

```
AUTOMATION                        On
Renew and deploy       daily 3:20 AM
Expiry check           daily 9:00 AM
Monthly summary email     not set up
```

`On` here means unattended renewal specifically — the only one of the three that
can change a certificate. It reads `Off` when the task is registered but
disabled, `Not set up` when it was never registered, and `Unknown` when the
scheduler could not be read at all, which is deliberately not the same as `Off`.

**Automated renewals scheduled** then gives the date and time each certificate
is next due, in this PC's local time, and what happens afterwards:

```
*.camelnuggets.com
  Sat, Oct 3, 2026, 1:13 PM EDT
  deploys to Haproxy-Home-Lab

camelnuggets.com
  Sun, Oct 4, 2026, 8:48 AM EDT
  no load balancer assigned, so it will not deploy
```

Dates come from the CA's own ARI renewal window, not from a threshold we picked,
and they can move — the CA can pull every client's window forward during a mass
revocation. They are rechecked nightly. If the forecast is missing or has gone
over 36 hours stale, a **Work it out now** button appears, which runs
`renew-due.ps1 -WhatIfOnly`: it issues nothing and touches no load balancer.
When the forecast is current there is no button at all.

Three things this is there to catch, none of which anything else notices. All
three appear as alerts at the top of Home rather than inside the boxes:

- **A certificate with no load balancer assigned.** It will renew, and the new
  certificate will sit on disk. "Automation is on" reads as more reassuring than
  it should for such a certificate.
- **A task pointing at another folder.** The task stores an absolute path, so
  copying this folder leaves the old copy scheduled. Renewal silently stops and
  the first symptom is an expiry warning weeks later.
- **The scheduler being unreadable**, which is reported as exactly that rather
  than as "off" — the second would be a lie in the direction that gets
  certificates expired.

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

## Status and licence

**Cert Camel is beta software.** It issues real certificates from a real
certificate authority and can push them to production load balancers. Try it
against staging and a test host first — Settings → Certificate Authorities has a
staging switch, and staging certificates do not count against rate limits.

Licensed under the [MIT licence](LICENSE). In particular:

> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND … IN NO EVENT
> SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
> OTHER LIABILITY.

You are responsible for what it does to your certificates and your load
balancers. Read [the security notes](#security-notes) before pointing it at
anything you care about.
