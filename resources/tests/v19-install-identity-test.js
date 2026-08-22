/* Saying which copy of Cert Camel you are looking at.

   Two installs on one machine are indistinguishable in the browser once the
   page has rendered - same layout, same data shape, same everything. That is
   not hypothetical: an older copy on a second machine was opened during a work
   demo and cost real time, debugging behaviour that had already been fixed in
   the other folder.

   The version now sits in the sidebar and the folder is on hover. Small enough
   that nothing else covers it, and quiet enough that it has to be pinned here
   or a later tidy-up removes it as clutter - which is exactly what it looks
   like on every day except the one it is needed.

   Also pins the two ways it must fail softly. An older server that does not
   send `install` at all, and one that sends the key with no version in it, both
   have to leave the sidebar looking normal rather than showing "vundefined".

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

let INSTALL = { version: '1.002b', folder: 'C:\\CertCamel' };
const STATE = () => ({
  generated: day(-0.1), tally: { tracked: 0, expiring: 0, expired: 0 },
  certs: [], unmapped: [], haveZones: true, groupError: null,
  zones: { refreshed: day(-0.1), count: 0, errors: [] }, deployment: {},
  settings: { contact: 'x@y.z', defaultCaId: 'le', cas: [], providers: [], targets: [],
              logs: { retentionDays: 90, maxSizeMb: 200 },
              alerts: { smtp: { host: '', port: 587, encryption: 'starttls', from: '', to: [],
                                authRequired: false, username: '', passwordSet: false },
                        expiry: { enabled: false, thresholds: [30] }, renewalSuccess: { enabled: false },
                        deploymentFailure: { enabled: false }, monthlySummary: { enabled: false } } },
  catalog: {}, targetCatalog: {}, acmeReady: true,
  install: INSTALL
});

function XHR() {
  this.readyState = 0; this.status = 0; this.responseText = '';
  this.open = (m, u) => { this._u = u; };
  this.setRequestHeader = () => {};
  this.send = () => {
    let r = { ok: true };
    if (this._u.indexOf('/api/state') === 0) r = STATE();
    else if (this._u.indexOf('/api/checker') === 0) r = { generated: day(0), results: [] };
    else if (this._u.indexOf('/api/automation') === 0) r = { automation: { available: true, error: null, tasks: [] }, forecast: null, folder: 'C:/x' };
    else if (this._u.indexOf('/api/loadbalancers') === 0) r = { haveTargets: false };
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

const box = () => d.getElementById('sidebar-install');
const shown = () => box() && !box().classList.contains('hidden');

w.location.hash = '#/home';
w.CertCamel.loadState(function () { w.CertCamel.navigate(); });

console.log('the version is on screen');
check('the sidebar has somewhere to put it', !!box(),
      'the element was removed - two open copies become indistinguishable again');
check('it is visible when the server sends one', shown(), 'hidden despite a version being sent');
check('it shows the version', d.getElementById('install-version').textContent === 'v1.002b',
      'got "' + d.getElementById('install-version').textContent + '"');

console.log('\nthe folder is on hover, not on screen');
// The path is far too long for a sidebar this narrow, and it is only ever
// wanted at the moment somebody asks which copy this is.
check('the folder is in the tooltip', box().title.indexOf('C:\\CertCamel') >= 0,
      'the folder is not reachable at all: "' + box().title + '"');
check('the folder is not printed in the sidebar',
      d.getElementById('install-version').textContent.indexOf('C:\\') < 0,
      'the path is on screen and will clip or wrap');

console.log('\nan older server that sends nothing leaves the sidebar alone');
INSTALL = undefined;
w.CertCamel.loadState(function () {});
check('hidden when install is absent', !shown(),
      'an empty row is sitting in the sidebar of an install that never reports a version');

INSTALL = { folder: 'C:\\CertCamel' };
w.CertCamel.loadState(function () {});
check('hidden when the version is missing', !shown(), 'showing a row with no version in it');
check('never renders "vundefined"', d.getElementById('install-version').textContent.indexOf('undefined') < 0,
      'got "' + d.getElementById('install-version').textContent + '"');

INSTALL = { version: '1.002b', folder: '' };
w.CertCamel.loadState(function () {});
check('a version with no folder still shows', shown(), 'hidden when only the folder is missing');

check('no uncaught errors', errors.length === 0, errors.join(' | '));

console.log(failed ? '\n' + failed + ' CHECK(S) FAILED' : '\nall checks passed');
process.exit(failed ? 1 : 0);
