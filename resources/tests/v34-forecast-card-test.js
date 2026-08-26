/* What the "Automated renewals scheduled" card says when its forecast has been
   overtaken.

   The card renders the last sweep. It offered its "Work it out now" button only
   when the forecast looked stale, and staleness was 36 hours and nothing else.
   Three hostnames were added five hours after a sweep: the forecast counted as
   fresh, the button stayed hidden, and the card listed ONE certificate as the
   whole schedule while two of those hosts were a day from expiry.

   The button was never the missing piece - it already existed. What was missing
   was the card admitting the list was short. So this asserts both: the control
   appears, AND the uncovered hosts are named on the card, because a button
   nobody knows to press is what caused the incident in the first place.

   The verdict arrives on /api/state as forecastState. An older server, or a
   grouping that threw, sends none - and the card must fall back to the age test
   rather than lose the button altogether.

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

const day  = n => new Date(Date.now() + n * 864e5).toISOString();
const hrs  = n => new Date(Date.now() - n * 3600e3).toISOString();

/* Five hours old - fresh by the old rule, which is the whole point. */
let FORECAST = { ok: true, mode: 'run', error: null, finishedAt: hrs(5), considered: [
  { certId: 'console.example.com', name: 'console.example.com',
    names: ['console.example.com'], due: false, reason: null, renewAfter: day(60) }] };

let FSTATE = null;

const AUTOMATION = { available: true, error: null, isServer: false, tasks: [
  { key: 'renew', name: 'Cert Camel Renew', label: 'Renew and deploy', level: 'r',
    detail: 'd', registered: true, enabled: true, state: 'ready', nextRun: null,
    lastRun: null, lastResult: null, schedule: '2026-01-01T00:45:00',
    triggerType: 'daily', repeatMinutes: 360, pathMatches: true, commandPath: null }] };

function state() {
  return {
    generated: day(-0.1), tally: { tracked: 1, expiring: 0, expired: 0 },
    certs: [], unmapped: [], haveZones: true, groupError: null,
    zones: { refreshed: day(-0.1), count: 1, errors: [] }, deployment: {},
    forecastState: FSTATE,
    settings: { contact: 'x@y.z', defaultCaId: 'le', cas: [], providers: [], targets: [],
                logs: { retentionDays: 90, maxSizeMb: 200 },
                alerts: { smtp: { host: 'h', port: 1, encryption: 'none', from: 'a', to: ['b'],
                                  authRequired: false, username: '', passwordSet: false },
                          none: false, expiry: { enabled: false, thresholds: [30] },
                          scheduledRenewal: { enabled: false }, renewalSuccess: { enabled: false },
                          deploymentFailure: { enabled: false }, monthlySummary: { enabled: false } } },
    catalog: {}, targetCatalog: {}, acmeReady: true
  };
}

function XHR() {
  this.readyState = 0; this.status = 0; this.responseText = '';
  this.open = (m, u) => { this._u = u; };
  this.setRequestHeader = () => {};
  this.send = () => {
    let r = { ok: true };
    if (this._u.indexOf('/api/state') === 0) r = state();
    else if (this._u.indexOf('/api/checker') === 0) r = { generated: day(0), results: [] };
    else if (this._u.indexOf('/api/automation') === 0) r = { automation: AUTOMATION, forecast: FORECAST, folder: 'C:/x' };
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
function card() {
  return Array.from(d.querySelectorAll('#view-home .card'))
    .filter(c => { const h = c.querySelector('h4');
                   return h && h.textContent === 'Automated renewals scheduled'; })[0] || null;
}
const button = () => { const c = card(); return c ? Array.from(c.querySelectorAll('button'))
  .filter(b => /Work it out now/.test(b.textContent))[0] || null : null; };
const warnline = () => { const c = card(); return c ? c.querySelector('.mini.warnline') : null; };

console.log('a forecast that still describes reality');
FSTATE = { state: 'current', uncovered: [], complete: true, finishedAt: hrs(5), ageHours: 5, reason: '' };
boot();
check('the card renders', !!card(), 'the Home layout changed');
check('no button in the normal case', !button(),
      'the card is documented as carrying no control when there is nothing to act on');
check('and no warning line', !warnline(), 'said: ' + (warnline() || {}).textContent);

console.log('\nTHE INCIDENT: hosts added since the sweep');
FSTATE = { state: 'uncovered',
           uncovered: ['lbtest.example.com', 'lbprod.example.com', 'lbprod2.example.com'],
           complete: true, finishedAt: hrs(5), ageHours: 5,
           reason: '3 watched host(s) are not in this forecast yet' };
boot();
check('the button appears', !!button(),
      'five hours old is fresh by the clock, which is exactly how this stayed hidden');
check('the card says the list is short', !!warnline(),
      'the button alone was never the fix - nobody knew to press it');
check('and names the hosts', warnline() && /lbtest\.example\.com/.test(warnline().textContent) &&
      /lbprod2\.example\.com/.test(warnline().textContent),
      'said: ' + (warnline() || {}).textContent);
check('it says how many', warnline() && /^3 watched hosts/.test(warnline().textContent),
      'said: ' + (warnline() || {}).textContent);
check('the certificates it does know about are still listed',
      card() && /console\.example\.com/.test(card().textContent),
      'the warning replaced the content instead of joining it');

console.log('\nmany uncovered hosts do not become a wall of text');
FSTATE = { state: 'uncovered', complete: true, finishedAt: hrs(5), ageHours: 5, reason: 'x',
           uncovered: ['a.example.com', 'b.example.com', 'c.example.com',
                       'd.example.com', 'e.example.com', 'f.example.com'] };
boot();
check('it lists a few and counts the rest',
      warnline() && /and 2 more/.test(warnline().textContent),
      'said: ' + (warnline() || {}).textContent);

console.log('\none host reads as one host');
FSTATE = { state: 'uncovered', uncovered: ['only.example.com'], complete: true,
           finishedAt: hrs(5), ageHours: 5, reason: 'x' };
boot();
check('singular grammar', warnline() && /1 watched host is not/.test(warnline().textContent),
      'said: ' + (warnline() || {}).textContent);

console.log('\na sweep that stopped partway');
FSTATE = { state: 'incomplete', uncovered: [], complete: false, finishedAt: hrs(0.03),
           ageHours: 0.03, reason: 'the last sweep stopped partway through' };
boot();
check('the button appears despite being minutes old', !!button(),
      'a truncated list under a fresh timestamp is the one age can never catch');
check('and the card says so', warnline() && /stopped partway through/.test(warnline().textContent),
      'said: ' + (warnline() || {}).textContent);

console.log('\na forecast from before coverage was recorded');
FSTATE = { state: 'unknown', uncovered: [], complete: true, finishedAt: hrs(1), ageHours: 1,
           reason: 'this forecast predates the coverage check, so it cannot say what it covers' };
boot();
check('the button appears', !!button(), 'one refresh fixes it, so offer the refresh');
check('and it accuses no host', warnline() && !/example\.com/.test(warnline().textContent),
      'said: ' + (warnline() || {}).textContent);
check('saying it cannot tell, rather than that something is wrong',
      warnline() && /cannot say which hosts it covers/.test(warnline().textContent),
      'said: ' + (warnline() || {}).textContent);

console.log('\nthe 36-hour backstop, which coverage cannot replace');
FSTATE = { state: 'stale', uncovered: [], complete: true, finishedAt: hrs(40), ageHours: 40,
           reason: 'it was worked out more than a day and a half ago' };
boot();
check('the button appears', !!button(), 'a manual renewal moves the CA window without touching the sweep');
check('with no accusation on the card', !warnline(), 'said: ' + (warnline() || {}).textContent);

console.log('\nan older server that sends no verdict');
FSTATE = undefined;
FORECAST = { ok: true, mode: 'run', error: null, finishedAt: hrs(5), considered: [
  { certId: 'console.example.com', name: 'console.example.com',
    names: ['console.example.com'], due: false, reason: null, renewAfter: day(60) }] };
boot();
check('a fresh forecast still hides the button', !button(),
      'fell back to something other than the old age test');
FORECAST = Object.assign({}, FORECAST, { finishedAt: hrs(40) });
boot();
check('and an old one still shows it', !!button(),
      'losing the verdict must not lose the button - that is worse than the bug');

check('no uncaught errors', errors.length === 0, errors.join(' | '));

console.log(failed ? '\n' + failed + ' CHECK(S) FAILED' : '\nall checks passed');
process.exit(failed ? 1 : 0);
