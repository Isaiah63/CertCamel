/* The web page task is absent by design on a desktop, and the panel has to say
   so rather than reporting it as missing.

   "not set up" is the right words for a task somebody declined. It is the wrong
   words for one they were never offered: setup only proposes starting the
   console at boot on Windows Server, because on a PC you open the tracker when
   you want it and close it when you are done. On a desktop that row was the one
   thing in an otherwise green panel that looked broken.

   The tooltip differs by machine, and that is the part worth pinning. Telling a
   desktop user to re-run setup would send them round a loop - setup checks
   ProductType and will not offer the step there either, so they would run it,
   see nothing, and be no wiser. On a server it genuinely is worth registering,
   and there the same row should say so.

   The row also carries a small (i) after its name. The explanation was always
   on the title attribute; nothing on screen said to hover for it, and this row
   is the one where that matters most - the tooltip is the whole reason "manual
   launch" is not a fault.

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

function task(o) {
  return Object.assign({
    key: 'server', name: 'Cert Camel Server', label: 'Web page',
    level: 'Read-only', detail: 'Serves the console.',
    registered: false, enabled: false, state: 'not registered',
    nextRun: null, lastRun: null, lastResult: null,
    schedule: null, triggerType: null, repeatMinutes: null,
    pathMatches: true, commandPath: null
  }, o);
}

let AUTOMATION = { available: true, error: null, isServer: false, tasks: [task({})] };

const STATE = {
  generated: day(-0.1), tally: { tracked: 1, expiring: 0, expired: 0 },
  certs: [], unmapped: [], haveZones: true, groupError: null,
  zones: { refreshed: day(-0.1), count: 1, errors: [] }, deployment: {},
  settings: { contact: 'x@y.z', defaultCaId: 'le', cas: [], providers: [], targets: [],
              logs: { retentionDays: 90, maxSizeMb: 200 },
              alerts: { smtp: { host: 'h', port: 25, encryption: 'none', from: 'a@b.c',
                                to: ['d@e.f'], authRequired: false, username: '', passwordSet: false },
                        none: false, expiry: { enabled: false, thresholds: [30] },
                        scheduledRenewal: { enabled: false }, renewalSuccess: { enabled: false },
                        deploymentFailure: { enabled: false }, monthlySummary: { enabled: false } } },
  catalog: {}, targetCatalog: {}, acmeReady: true
};

function XHR() {
  this.readyState = 0; this.status = 0; this.responseText = '';
  this.open = (m, u) => { this._u = u; };
  this.setRequestHeader = () => {};
  this.send = () => {
    let r = { ok: true };
    if (this._u.indexOf('/api/state') === 0) r = STATE;
    else if (this._u.indexOf('/api/checker') === 0) {
      r = { generated: day(0), results: [
        { host: 'a.example.com', ok: true, notAfter: day(60), issuer: 'LE', category: 'P', renewOnly: false }] };
    }
    else if (this._u.indexOf('/api/automation') === 0) r = { automation: AUTOMATION, forecast: null, folder: 'C:/x' };
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
/* The name span holds the label and then the icon, so read past the icon
   rather than matching the two together - otherwise every lookup here silently
   depends on what glyph the icon uses. */
function nameOf(row) {
  const n = row.querySelector('.n');
  if (!n) { return null; }
  return Array.from(n.childNodes)
    .filter(c => c.nodeType === 3)
    .map(c => c.textContent).join('');
}
function rowNamed(label) {
  return Array.from(d.querySelectorAll('.svc'))
    .filter(r => nameOf(r) === label)[0] || null;
}
const valueOf = r => r ? (r.querySelector('.v') || {}).textContent : '(no row)';
const rows = () => Array.from(d.querySelectorAll('.svc'));

console.log('on a desktop, where the step is never offered');
boot();
check('the row exists', !!rowNamed('Web page'), 'the automation panel did not render it');
check('it does not say "not set up"', valueOf(rowNamed('Web page')) !== 'not set up',
      'reads as a fault on a machine where setup never proposes it');
check('it says manual launch', valueOf(rowNamed('Web page')) === 'manual launch',
      'got "' + valueOf(rowNamed('Web page')) + '"');
check('the tooltip says what does happen instead',
      /Open Tracker\.bat is open/.test(rowNamed('Web page').title),
      'names a state without saying what it means: ' + rowNamed('Web page').title);
check('and does NOT send a desktop user back to setup',
      !/run First Time Setup/.test(rowNamed('Web page').title),
      'setup checks ProductType and will not offer the step, so that is a loop');

console.log('\non a server, where it is worth registering');
AUTOMATION = { available: true, error: null, isServer: true, tasks: [task({})] };
boot();
check('still reads as manual launch', valueOf(rowNamed('Web page')) === 'manual launch',
      'got "' + valueOf(rowNamed('Web page')) + '"');
check('but now points at setup', /run First Time Setup/.test(rowNamed('Web page').title),
      'nobody stays signed in on a server, so the console is gone after every reboot');

console.log('\nthe special case does not leak');
AUTOMATION = { available: true, error: null, isServer: false, tasks: [
  task({ key: 'renew', name: 'Cert Camel Renew', label: 'Renew and deploy' }) ] };
boot();
check('an unregistered renewal still reads as not set up',
      valueOf(rowNamed('Renew and deploy')) === 'not set up',
      'got "' + valueOf(rowNamed('Renew and deploy')) + '" - that task really has not been configured');

console.log('\na registered web page task is unaffected');
AUTOMATION = { available: true, error: null, isServer: true, tasks: [
  task({ registered: true, enabled: true, state: 'ready', triggerType: 'boot',
         schedule: '2026-08-06T15:47:00-04:00' }) ] };
boot();
check('it reports the boot trigger', valueOf(rowNamed('Web page')) === 'at startup',
      'got "' + valueOf(rowNamed('Web page')) + '"');
check('and carries its own description again',
      rowNamed('Web page').title === 'Serves the console.',
      'got "' + rowNamed('Web page').title + '"');

console.log('\nan older server that reports no isServer still renders');
AUTOMATION = { available: true, error: null, tasks: [task({})] };
boot();
check('the row still says manual launch', valueOf(rowNamed('Web page')) === 'manual launch',
      'got "' + valueOf(rowNamed('Web page')) + '"');
check('and falls back to the desktop wording', !/run First Time Setup/.test(rowNamed('Web page').title),
      'undefined was treated as a server, which is the wrong way to be wrong');

console.log('\nthe hover is advertised, not left to be discovered');
AUTOMATION = { available: true, error: null, isServer: false, tasks: [
  task({}),
  task({ key: 'renew', name: 'Cert Camel Renew', label: 'Renew and deploy',
         registered: true, enabled: true, state: 'ready', triggerType: 'daily',
         schedule: '2026-08-06T00:45:00-04:00' }) ] };
boot();
check('every row carries an info icon', rows().length === 2 && rows().every(r => !!r.querySelector('.i')),
      'rendered ' + rows().length + ' row(s), ' + rows().filter(r => r.querySelector('.i')).length + ' with an icon');
check('the icon sits after the name, inside it',
      rows().every(r => { const n = r.querySelector('.n'); return n && n.lastElementChild === r.querySelector('.i'); }),
      'an icon outside the name span drifts to the far side of the row, next to the value');
check('the row still explains itself on hover',
      rows().every(r => !!r.title),
      'an icon pointing at an empty tooltip is worse than no icon');
check('the name still reads as the name', nameOf(rowNamed('Web page')) === 'Web page',
      'got "' + (rowNamed('Web page') || {}).textContent + '"');
check('the icon is hidden from screen readers',
      rows().every(r => r.querySelector('.i').getAttribute('aria-hidden') === 'true'),
      'it duplicates nothing and announces as a bare letter');

console.log('\nno uncaught errors');
check('no uncaught errors', errors.length === 0, errors.join(' | '));

console.log(failed ? '\n' + failed + ' CHECK(S) FAILED' : '\nall checks passed');
process.exit(failed ? 1 : 0);
