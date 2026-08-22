/* HTTPS is decided by the hostname, not by a switch.

   The Settings page used to carry a "Serve this page over HTTPS" tick-box
   alongside the hostname and port. Two controls, one meaning, and a state they
   could disagree about: ticked with no certificate, or a hostname sitting there
   with the box cleared. The server resolved that disagreement by coming up on
   plain HTTP and writing the reason to a log nobody reads.

   So the box is gone and the rule is derived - a hostname means HTTPS on that
   name, no hostname means loopback HTTP. That rule now lives in two places that
   must not drift: this page, and Save-SettingsPayload in serve.ps1, which
   derives it again rather than trusting what arrives.

   The failure this guards against is quiet in the worst way. Reintroducing a
   control that sets `https` independently would not break anything visible
   here; it would produce a console that says it is serving HTTPS and is not.

   Exits non-zero on failure. */
const fs = require('fs');
const path = require('path');
const { JSDOM, VirtualConsole } = require('jsdom');

const ROOT = path.join(__dirname, '..') + path.sep;
const html = fs.readFileSync(ROOT + 'ssl-tracker.html', 'utf8');
const scripts = ['assets/app.js', 'assets/views/home.js', 'assets/views/certificates.js',
                 'assets/views/settings.js', 'assets/views/logs.js', 'assets/views/docs.js',
                 'assets/views/loadbalancers.js']
  .map(p => fs.readFileSync(ROOT + p.replace(/\//g, path.sep), 'utf8'));

const day = n => new Date(Date.now() + n * 864e5).toISOString();

const STATE = {
  generated: day(-0.1), tally: { tracked: 0, expiring: 0, expired: 0 },
  certs: [], unmapped: [], haveZones: true, groupError: null,
  zones: { refreshed: day(-0.1), count: 1, errors: [] }, deployment: {},
  serving: { scheme: 'http', host: '127.0.0.1', port: 1 },
  settings: {
    contact: 'x@y.z', defaultCaId: 'letsencrypt',
    // A CA has to be present or collectSettings refuses before it builds a
    // payload, and every check below would report "no web section" for a reason
    // that has nothing to do with the hostname.
    cas: [{ id: 'letsencrypt', label: "Let's Encrypt",
            directoryUrl: 'https://acme-v02.api.letsencrypt.org/directory',
            useStaging: false, eabKid: '', eabHmacKey: '' }],
    providers: [], targets: [],
    logs: { retentionDays: 90, maxSizeMb: 200 },
    web: { https: true, hostname: 'tracker.example.com', port: 8787, hsts: false },
    alerts: { smtp: { host: '', port: 587, encryption: 'starttls', from: '', to: [],
                      authRequired: false, username: '', passwordSet: false },
              expiry: { enabled: false, thresholds: [30, 14, 7] }, renewalSuccess: { enabled: false },
              deploymentFailure: { enabled: false }, monthlySummary: { enabled: false } }
  },
  catalog: {}, targetCatalog: {}, acmeReady: true
};

// Every POST body, so the payload the page actually sends can be inspected
// rather than inferred from the form.
const posted = [];
function XHR() {
  this.readyState = 0; this.status = 0; this.responseText = '';
  this.open = (m, u) => { this._m = m; this._u = u; };
  this.setRequestHeader = () => {};
  this.send = (body) => {
    if (this._m === 'POST') { posted.push({ url: this._u, body: body ? JSON.parse(body) : null }); }
    let r = { ok: true };
    if (this._u.indexOf('/api/state') === 0) r = STATE;
    else if (this._u.indexOf('/api/checker') === 0) r = { generated: day(0), results: [] };
    else if (this._u.indexOf('/api/automation') === 0) r = { automation: { available: true, error: null, tasks: [] }, forecast: null, folder: 'C:/x' };
    else if (this._u.indexOf('/api/loadbalancers') === 0) r = { haveTargets: false };
    else if (this._u.indexOf('/api/settings/test') === 0) r = { zoneCount: 1, errors: [] };
    else if (this._u.indexOf('/api/web/preflight') === 0) {
      r = { zone: { ok: true, detail: 'example.com' }, certificate: { ok: true, detail: 'ok' },
            portCheck: { ok: true, detail: 'free' }, hosts: { ok: true, detail: 'present' },
            renewal: { ok: true, detail: 'managed', file: 'C:/x', fileExists: true },
            elevated: true, ready: true };
    }
    this.status = 200; this.readyState = 4; this.responseText = JSON.stringify(r);
    if (this.onreadystatechange) this.onreadystatechange();
  };
}

const errors = []; const vc = new VirtualConsole();
vc.on('jsdomError', e => errors.push(e.detail ? e.detail.stack : e.message));
const dom = new JSDOM(html, { url: 'http://127.0.0.1:1/?t=abc', runScripts: 'outside-only',
                              pretendToBeVisual: true, virtualConsole: vc });
const w = dom.window, d = dom.window.document;
w.SSL_DATA = { generated: day(0), results: [] };
w.XMLHttpRequest = XHR;
const store = {};
w.sessionStorage.getItem = k => Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null;
w.sessionStorage.setItem = (k, v) => { store[k] = String(v); };
scripts.forEach(s => w.eval(s));

let failed = 0;
function check(name, ok, detail) {
  if (!ok) { failed++; }
  console.log((ok ? '  ok   ' : '  FAIL ') + name + (ok ? '' : '  -- ' + detail));
}

w.location.hash = '#/settings';
w.CertCamel.loadState(function () { w.CertCamel.navigate(); });

console.log('the switch is gone, and the fields are not hidden behind it');
check('no HTTPS on/off control exists', !d.getElementById('set-web-https'),
      'a control that sets https independently of the hostname is back, and the two can disagree again');

const fields = d.getElementById('set-web-fields');
check('the address fields render', !!fields, 'the tracker address section did not build');
check('the address fields are visible', fields && !fields.classList.contains('hidden'),
      'the fields are still hidden behind something - with no switch to reveal them, they are unreachable');
check('the hostname field is there', !!d.getElementById('set-web-host'), 'nothing to type a name into');

function save() {
  posted.length = 0;
  d.querySelectorAll('button').forEach(b => { if (b.textContent === 'Save') { b.click(); } });
  const s = posted.filter(p => p.url.indexOf('/api/settings') === 0 && p.body && p.body.web);
  return s.length ? s[0].body.web : null;
}

console.log('\na hostname means HTTPS on that name');
d.getElementById('set-web-host').value = 'Tracker.Example.COM';
d.getElementById('set-web-port').value = '8787';
let web = save();
check('the payload was sent', !!web, 'no settings POST carried a web section');
check('https is true when a hostname is set', web && web.https === true,
      'https=' + (web && web.https) + ' with a hostname present');
check('the hostname is normalised to lower case', web && web.hostname === 'tracker.example.com',
      'got ' + (web && web.hostname));
check('the port travels with it', web && web.port === 8787, 'got ' + (web && web.port));

console.log('\nno hostname means loopback HTTP');
d.getElementById('set-web-host').value = '';
web = save();
check('the payload was sent', !!web, 'no settings POST carried a web section');
check('https is false with no hostname', web && web.https === false,
      'https=' + (web && web.https) + ' with no hostname - the server would try to serve a name it does not have');
check('no hostname is sent', web && !web.hostname, 'got ' + (web && web.hostname));

console.log('\nHSTS stays a separate decision');
// It is the one setting here that can lock somebody out of their own console,
// so it must never arrive as a side effect of typing a hostname.
check('the HSTS control still exists', !!d.getElementById('set-web-hsts'),
      'HSTS was removed along with the HTTPS switch - it is a separate decision');
d.getElementById('set-web-host').value = 'tracker.example.com';
web = save();
check('typing a hostname does not turn HSTS on', web && web.hsts === false,
      'hsts=' + (web && web.hsts) + ' - enabling it as a side effect is how somebody gets locked out');

check('no uncaught errors', errors.length === 0, errors.join(' | '));

console.log(failed ? '\n' + failed + ' CHECK(S) FAILED' : '\nall checks passed');
process.exit(failed ? 1 : 0);
