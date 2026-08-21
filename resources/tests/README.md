# Tests

Headless DOM tests for the page. **Development-time only.** Cert Camel itself
needs nothing here: it is PowerShell plus static HTML/CSS/JS with no build step,
and nothing in the app references Node, npm or jsdom. A downloaded copy runs
without installing any of this. These exist to let the page be changed safely,
not to run it.

The suites are tracked in git; the `node_modules/` beside them is not. They used
to be ignored wholesale, which meant they lived on exactly one machine and a
`git clean -fdx` would have taken all of them.

## Running them

From the repository root:

```powershell
cd tests
node v5-automation-test.js
```

**`v12` is PowerShell, not Node**, because what it checks is PowerShell: it asks
`Get-Command` which parameters and aliases each script really binds, and reads
the call sites out of the AST rather than by pattern matching. It needs no
`node_modules` at all.

```powershell
powershell -ExecutionPolicy Bypass -File .12-script-args-test.ps1
```

Or all of them, reporting which failed:

```powershell
Get-ChildItem *-test.js | ForEach-Object {
  $out = & node $_.Name 2>&1
  "{0,-30} exit={1}" -f $_.Name, $LASTEXITCODE
}
```

Each prints what it found rather than asserting silently, so the output is meant
to be read. The newer suites (`v7` onward) also exit non-zero on failure, so they
can be checked mechanically; the older ones report `all errors: none` as their
pass condition and rely on being read — anything else there, including a
`TypeError`, is a failure.

## What each covers

| Suite | Covers |
|---|---|
| `v3-spa-test.js` | Routing, view registration, state loading |
| `v3-nav-test.js` | Sidebar, the collapsible Settings group, and that collapsing never hides the page you are on |
| `v3-domains-editor-test.js` | The domains.txt editor, including surviving a background re-render mid-edit |
| `v3-rowmenu-test.js` | The per-certificate row menu and its clipping trap |
| `v4-logs-test.js` | The Logs view: audit tab, event filter, run viewer, read-only-ness |
| `v5-automation-test.js` | Home layout, the Automation box, renewal forecast, UTC→local conversion |
| `v6-loadbalancers-test.js` | The Load balancers view: node status, certificates grouped by what serves them, and a certificate deployed to a crt-list no frontend reads |
| `v7-renewal-split-test.js` | Scheduled vs manual renewal across the tiles, callout and group headers; the console certificate renewing without the deployment picker; assignment reachable from the row menu |
| `v8-guide-links-test.js` | Every in-app link into a guide resolves to an anchor that actually exists |
| `v9-update-panel-test.js` | The Update panel, including that a check which could not run never reports as up to date |
| `v10-renewal-run-test.js` | When a certificate actually renews: the next scheduled run at or after the CA's window opens, across a daylight-saving change, and the cases where that is not knowable |
| `v11-home-run-failure-test.js` | Home raises a warning when an unattended run fails, and a preview cannot clear it |
| `v12-script-args-test.ps1` | Every parameter one script passes to another exists on the script it is passed to |

## How they work

Each loads the real `ssl-tracker.html` and the real `assets/*.js` into jsdom,
stubs `XMLHttpRequest` with canned API responses, and drives the page. No mocks
of our own code — if a view breaks, the suite breaks.

Three things worth knowing before writing another:

- **The stubbed XHR is synchronous**, which is the opposite of production. That
  is deliberate and it has already caught one real bug: the Automation tile's
  position depended on how fast the server answered. Anything that assumes a
  fetch resolves *after* the synchronous render will be caught here.
- **Watch for a suite that passes by not looking.** `v8` originally reported an
  uncaught `TypeError` and still exited zero — a panel had failed to render, so
  its links went unchecked. It now fails on any uncaught error, and a new suite
  should do the same.
- `TZ=America/New_York` matters for `v5`, which asserts that a UTC renewal
  window renders in local time. On a machine already in Eastern it passes
  either way, so do not read a pass there as proof the conversion works.
  `v10` sets `TZ` itself rather than relying on the caller, because every
  assertion in it is about local wall-clock scheduling.
- **`v10` needs no jsdom.** It pulls `CC.renewalRun` straight out of
  `assets/app.js` and runs it, so it works before `npm install` has been near
  this folder - which also means it keeps working if the jsdom install breaks.

## Dependencies

`node_modules/` here holds jsdom only, and is not in git. If it is missing:

```powershell
cd tests
npm install jsdom
```

Nothing else is needed, and nothing here is required to run Cert Camel.
