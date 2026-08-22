/* Warning about a rate limit before the authority starts refusing.

   Let's Encrypt allows five IDENTICAL certificates per week - the same exact
   set of names - and that is the one people actually hit. It sounds like plenty
   until a retry loop spends it in an afternoon, and the failure at the far end
   is the authority refusing to issue while the console reports nothing wrong.

   Two things have to be true of this panel or it is worse than not having it.

   It has to stay quiet when there is nothing to say. A card reading "2 of 50"
   on every healthy install is noise, and a panel that is almost always green
   teaches people not to look at it - so when it does turn red nobody sees.

   And it has to admit what it cannot see. The count comes from this install's
   own audit trail because the authority publishes no way to ask; anything
   issued for the same names on another machine spends the same allowance
   invisibly. A figure that reads as authoritative and is not would be trusted
   at exactly the wrong moment, which is the moment before an outage.

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

let RATE = null;
const STATE = () => ({
  generated: day(-0.1), tally: { tracked: 1, expiring: 0, expired: 0 },
  certs: [], unmapped: [], haveZones: true, groupError: null,
  zones: { refreshed: day(-0.1), count: 1, errors: [] }, deployment: {},
  settings: { contact: 'x@y.z', defaultCaId: 'le', cas: [], providers: [], targets: [],
              logs: { retentionDays: 90, maxSizeMb: 200 },
              alerts: { smtp: { host: '', port: 587, encryption: 'starttls', from: '', to: [],
                                authRequired: false, username: '', passwordSet: false },
                        expiry: { enabled: false, thresholds: [30] }, renewalSuccess: { enabled: false },
                        deploymentFailure: { enabled: false }, monthlySummary: { enabled: false } } },
  catalog: {}, targetCatalog: {}, acmeReady: true,
  rateLimits: RATE
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

function boot() {
  w.location.hash = '#/home';
  w.CertCamel.loadState(function () { w.CertCamel.navigate(); });
}
function panel() {
  return Array.from(d.querySelectorAll('#view-home .card'))
    .filter(c => (c.querySelector('h4') || {}).textContent === 'Approaching a rate limit')[0];
}
const limits = { perDomain: 50, duplicate: 5 };

console.log('quiet when there is nothing to say');
RATE = { days: 7, limits: limits, total: 2,
         perDomain: [{ name: 'example.com', used: 2, limit: 50 }],
         duplicates: [{ name: 'example.com', used: 2, limit: 5 }] };
boot();
check('no panel at 2 of 5', !panel(),
      'a card that is almost always present teaches people to stop reading it');

RATE = { days: 7, limits: limits, total: 0, perDomain: [], duplicates: [] };
boot();
check('no panel with nothing issued at all', !panel(), 'an empty panel on a fresh install');

console.log('\nspeaking up while there is still time to react');
RATE = { days: 7, limits: limits, total: 3,
         perDomain: [{ name: 'example.com', used: 3, limit: 50 }],
         duplicates: [{ name: 'example.com', used: 3, limit: 5 }] };
boot();
check('appears at 3 of 5, before the limit', !!panel(),
      'silent until the limit is already spent is too late to be useful');
check('names the certificate', panel() && panel().textContent.indexOf('example.com') >= 0,
      'a warning with no name cannot be acted on');
check('shows the count against the limit', panel() && /3 of 5/.test(panel().textContent),
      'got: ' + (panel() && panel().textContent));

console.log('\nat the limit it reads as a problem, not a note');
RATE = { days: 7, limits: limits, total: 5,
         perDomain: [{ name: 'example.com', used: 5, limit: 50 }],
         duplicates: [{ name: 'example.com', used: 5, limit: 5 }] };
boot();
check('the row is marked bad at the limit',
      !!(panel() && panel().querySelector('.mini.bad')),
      'reaching the limit looks the same as approaching it');

console.log('\nthe caveat travels with the number');
check('says the count is from this install only',
      !!(panel() && /audit trail/.test(panel().textContent)),
      'a locally-counted figure presented without that caveat reads as authoritative');
check('says other machines are not counted',
      !!(panel() && /another machine|elsewhere/.test(panel().textContent)),
      'the limitation that actually matters is missing');

console.log('\nan older server that sends nothing does not break the page');
RATE = undefined;
boot();
check('no panel when rateLimits is absent', !panel(), 'rendered a panel from nothing');
check('Home still rendered', !!d.querySelector('#view-home h2'), 'the whole view failed');

check('no uncaught errors', errors.length === 0, errors.join(' | '));

console.log(failed ? '\n' + failed + ' CHECK(S) FAILED' : '\nall checks passed');
process.exit(failed ? 1 : 0);
