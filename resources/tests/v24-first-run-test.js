/* Telling a fresh install what it still has to do.

   Setup collects only what must exist before a certificate can: an
   administrator, a DNS credential, the console's own name. Everything after
   that lives in the app - and nothing said so. A new install rendered a
   working-looking console with no domains being watched, no certificate, and no
   address for alerts, and gave no indication that any of it was expected.

   The panel has one hard requirement, and it is the reason for this suite: it
   must disappear on its own. A "getting started" card that outlives getting
   started becomes furniture, and furniture that says "to do" next to things
   that are done trains people to ignore the panel that will one day be telling
   them something true.

   There is deliberately no dismiss button. Dismissing is a way to hide an
   unfinished install from yourself, and the next person to open the console
   would find one that looks complete.

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

let CERTS = [];
let NONE  = false;
let SMTP  = { host: '', port: 587, encryption: 'starttls', from: '', to: [],
              authRequired: false, username: '', passwordSet: false };
let CHECKER = { generated: day(0), results: [] };

const STATE = () => ({
  generated: day(-0.1), tally: { tracked: 0, expiring: 0, expired: 0 },
  certs: CERTS, unmapped: [], haveZones: true, groupError: null,
  zones: { refreshed: day(-0.1), count: 1, errors: [] }, deployment: {},
  settings: { contact: 'x@y.z', defaultCaId: 'le', cas: [], providers: [], targets: [],
              logs: { retentionDays: 90, maxSizeMb: 200 },
              alerts: { smtp: SMTP, none: NONE,
                        expiry: { enabled: false, thresholds: [30] }, renewalSuccess: { enabled: false },
                        deploymentFailure: { enabled: false }, monthlySummary: { enabled: false } } },
  catalog: {}, targetCatalog: {}, acmeReady: true
});

function XHR() {
  this.readyState = 0; this.status = 0; this.responseText = '';
  this.open = (m, u) => { this._u = u; };
  this.setRequestHeader = () => {};
  this.send = () => {
    let r = { ok: true };
    if (this._u.indexOf('/api/state') === 0) r = STATE();
    else if (this._u.indexOf('/api/checker') === 0) r = CHECKER;
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
w.SSL_DATA = CHECKER;
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
  w.CertCamel.sslData = CHECKER;
  w.location.hash = '#/home';
  w.CertCamel.loadState(function () { w.CertCamel.navigate(); });
}
function panel() {
  return Array.from(d.querySelectorAll('#view-home .card'))
    .filter(c => (c.querySelector('h4') || {}).textContent === 'Finish setting up')[0];
}
function todoCount() {
  const p = panel();
  if (!p) { return 0; }
  return Array.from(p.querySelectorAll('.st')).filter(s => s.textContent === 'to do').length;
}

console.log('a brand new install is told what is left');
boot();
check('the panel is there', !!panel(), 'a fresh install gives no sign that anything else is expected');
check('all three rows are outstanding', todoCount() === 3, 'got ' + todoCount() + ' to-do rows');
check('it links to where the work happens',
      !!(panel() && panel().querySelector('a[href="#/certificates"]')),
      'a checklist with no way through to the page is a list of complaints');
check('it links to alerts', !!(panel() && panel().querySelector('a[href="#/settings/alerts"]')),
      'no route to the alerts page');
check('there is no dismiss control',
      !!(panel() && !panel().querySelector('button')),
      'dismissing hides an unfinished install from the next person to open it');

console.log('\nrows clear as the work gets done');
CHECKER = { generated: day(0), results: [
  { host: 'a.example.com', ok: true, notAfter: day(60), issuer: 'LE', category: 'Prod', renewOnly: false }
]};
boot();
check('watching certificates is marked done', todoCount() === 2, 'got ' + todoCount() + ' to-do rows');

CERTS = [{ certId: 'example.com', zone: 'example.com', displayName: 'example.com', names: ['a.example.com'] }];
boot();
check('having a certificate is marked done', todoCount() === 1, 'got ' + todoCount() + ' to-do rows');

console.log('\nan alert address needs both halves to count');
SMTP = Object.assign({}, SMTP, { host: 'smtp.example.com', to: [] });
boot();
check('a server with no recipient is not done', todoCount() === 1,
      'alerts would be configured and still go nowhere');

SMTP = Object.assign({}, SMTP, { host: '', to: ['ops@example.com'] });
boot();
check('a recipient with no server is not done', todoCount() === 1,
      'alerts would be addressed and never sent');

console.log('\ndeclining email is a decision, not an omission');
/* The row used to be satisfiable only by configuring SMTP, so somebody who
   would rather check the page themselves had a card headed "Finish setting up"
   on their Home page for the life of the install. A panel that is always there
   is one nobody reads on the day it finally has something new to say - which is
   the whole reason this one removes itself. */
SMTP = Object.assign({}, SMTP, { host: '', to: [] });
NONE = true;
boot();
check('the alerts row is satisfied by declining', todoCount() === 0,
      'got ' + todoCount() + ' to-do rows with alerts explicitly declined');
check('and the panel is gone', !panel(),
      'declining email still leaves a permanent getting-started card');

NONE = false;
boot();
check('un-declining brings the row back', todoCount() === 1,
      'got ' + todoCount() + ' to-do rows after clearing the flag');

console.log('\nand the panel removes itself when there is nothing left');
SMTP = Object.assign({}, SMTP, { host: 'smtp.example.com', to: ['ops@example.com'] });
boot();
check('the panel is gone', !panel(),
      'a getting-started card that outlives getting started becomes furniture');
check('Home still renders normally', !!d.querySelector('#view-home h2'), 'the view broke without it');

check('no uncaught errors', errors.length === 0, errors.join(' | '));

console.log(failed ? '\n' + failed + ' CHECK(S) FAILED' : '\nall checks passed');
process.exit(failed ? 1 : 0);
