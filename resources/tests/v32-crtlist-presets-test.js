/* Offering a crt-list path that will actually work.

   A crt-list is created by uploading a FILENAME - the Data Plane API decides
   the directory - so a path in any other directory is a file no bind line ever
   reads. The field is free text with an example path in its hint, and a first
   install copied that example (/etc/haproxy/ssl/) into a lab whose API keeps
   everything in /opt/vrrp-lab/certs. Nothing said so until a deploy failed.

   Discover already asks the nodes what they have. It now also asks where the
   API can write, and offers the two shapes worth a click:

     <dir>/crt-list.txt              every certificate in one list
     <dir>/{certId}-crt-list.txt     a list each, per frontend

   Presets, NOT a restriction. A node whose list is called something else
   entirely - crt-list-san.txt, say - is a normal configuration, and the per
   frontend "Use this" fills that in from the node itself. Replacing the field
   with two options would break exactly that.

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
  generated: day(-0.1), tally: { tracked: 1, expiring: 0, expired: 0 },
  certs: [], unmapped: [], haveZones: true, groupError: null,
  zones: { refreshed: day(-0.1), count: 1, errors: [] }, deployment: {},
  settings: {
    contact: 'me@x.com', defaultCaId: 'letsencrypt',
    cas: [{ id: 'letsencrypt', label: "Let's Encrypt", directoryUrl: 'x', stagingUrl: 'y',
            useStaging: false, eabKid: '', eabHmacSet: false }],
    providers: [],
    targets: [{ id: 'lab', label: 'Test pair', type: 'haproxy-dataplane',
                nodes: [{ name: 'n1', url: 'https://127.0.0.1:5555', verifyHost: '' },
                        { name: 'n2', url: 'https://127.0.0.1:5556', verifyHost: '' }],
                args: { user: 'admin', password: true, remoteName: '',
                        crtList: '', verifyPort: '443', insecureTls: true } }],
    logs: { retentionDays: 90, maxSizeMb: 200 },
    alerts: { smtp: { host: 'h', port: 25, encryption: 'none', from: 'a@b.c', to: ['d@e.f'],
                      authRequired: false, username: '', passwordSet: false },
              none: false, expiry: { enabled: false, thresholds: [30] },
              scheduledRenewal: { enabled: false }, renewalSuccess: { enabled: false },
              deploymentFailure: { enabled: false }, monthlySummary: { enabled: false } }
  },
  catalog: {},
  targetCatalog: { 'haproxy-dataplane': { label: 'HAProxy (Data Plane API)', args: [
    { Name: 'user', Label: 'API username', Secret: false, Type: 'text' },
    { Name: 'password', Label: 'API password', Secret: true, Type: 'text' },
    { Name: 'remoteName', Label: 'Cert filename', Secret: false, Type: 'text' },
    { Name: 'crtList', Label: 'crt-list', Secret: false, Type: 'text' },
    { Name: 'verifyPort', Label: 'Verify port', Secret: false, Type: 'text' },
    { Name: 'insecureTls', Label: 'Skip TLS verify', Secret: false, Type: 'bool' }] } },
  acmeReady: true
};

/* What the stubbed /api/targets/discover answers with. Both nodes report the
   same directory unless a case below says otherwise. */
let DISCOVER = null;
let SAVE_REPLY = { ok: true };
const posted = [];

function nodes(dir1, dir2) {
  const fe = [{ frontend: 'fe_https', port: 443, ssl: true,
                crtList: '/opt/vrrp-lab/certs/crt-list-san.txt', crt: '' }];
  return { ok: true, nodes: [
    { targetId: 'lab', node: 'n1', url: 'https://127.0.0.1:5555', ok: true,
      frontends: fe, storageDir: dir1, storageDirError: null, error: null },
    { targetId: 'lab', node: 'n2', url: 'https://127.0.0.1:5556', ok: true,
      frontends: fe, storageDir: dir2, storageDirError: null, error: null }] };
}

function XHR() {
  this.readyState = 0; this.status = 0; this.responseText = '';
  this.open = (m, u) => { this._m = m; this._u = u; };
  this.setRequestHeader = () => {};
  this.send = (b) => {
    posted.push(this._m + ' ' + this._u);
    let r = { ok: true };
    if (this._u.indexOf('/api/state') === 0) r = STATE;
    else if (this._u.indexOf('/api/targets/discover') === 0) r = DISCOVER;
    else if (this._u.indexOf('/api/settings/test') === 0) r = { ok: true, zoneCount: 1, errors: [] };
    else if (this._u.indexOf('/api/settings') === 0) r = SAVE_REPLY;
    else if (this._u.indexOf('/api/checker') === 0) r = { generated: day(0), results: [] };
    else if (this._u.indexOf('/api/automation') === 0) r = { automation: { available: false, tasks: [] }, folder: 'C:/x' };
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

function open() {
  w.location.hash = '#/settings/loadbalancers';
  w.dispatchEvent(new w.Event('hashchange'));
}
const btn = label => Array.from(d.querySelectorAll('button'))
  .filter(b => b.textContent.trim() === label)[0] || null;
const crtInput = () => d.querySelector('input[data-arg="crtList"]');
const statusText = () => {
  const s = d.querySelector('#set-status') || d.querySelector('.status');
  return s ? s.textContent : '';
};

w.CertCamel.loadState(function () {
  w.CertCamel.navigate();
  open();

  console.log('the field starts as free text, with nothing assumed');
  check('the crt-list field exists', !!crtInput(), 'the target card did not render it');
  check('it is empty to begin with', crtInput() && crtInput().value === '',
        'got "' + (crtInput() || {}).value + '"');
  check('no presets before anything is discovered', !btn('One shared list'),
        'a path was offered before any node had been asked where it can write');

  console.log('\nafter Discover, both shapes are one click away');
  DISCOVER = nodes('/opt/vrrp-lab/certs', '/opt/vrrp-lab/certs');
  const disco = btn('Discover');
  check('there is a Discover button', !!disco, 'nothing to drive');
  if (disco) { disco.click(); }

  check('the shared-list preset appears', !!btn('One shared list'),
        'the directory was known and nothing was offered');
  check('the per-certificate preset appears', !!btn('One per certificate'),
        'the shape that gives every domain its own list is the one this lab needs');

  console.log('\nthe presets build on the directory the API reported');
  const shared = btn('One shared list');
  check('the shared preset names the real path',
        shared && /\/opt\/vrrp-lab\/certs\/crt-list\.txt/.test(shared.title),
        'title said: ' + (shared || {}).title);
  const per = btn('One per certificate');
  check('the per-certificate preset keeps {certId}',
        per && /\/opt\/vrrp-lab\/certs\/\{certId\}-crt-list\.txt/.test(per.title),
        'title said: ' + (per || {}).title);
  check('the directory is stated on the row',
        /\/opt\/vrrp-lab\/certs/.test(d.body.textContent) &&
        /only directory this API can write to/.test(d.body.textContent),
        'nothing on screen says why these two paths and not others');

  console.log('\nclicking one fills the field');
  if (per) { per.click(); }
  check('the field takes the per-certificate path',
        crtInput() && crtInput().value === '/opt/vrrp-lab/certs/{certId}-crt-list.txt',
        'got "' + (crtInput() || {}).value + '"');
  if (shared) { shared.click(); }
  check('and the shared one replaces it',
        crtInput() && crtInput().value === '/opt/vrrp-lab/certs/crt-list.txt',
        'got "' + (crtInput() || {}).value + '"');

  console.log('\nthe per-frontend "Use this" still wins for a list named anything else');
  // The reason this stays free text. crt-list-san.txt is neither preset, and it
  // is what the node actually reads - offering only the two shapes would make
  // this configuration unreachable from the page.
  const use = btn('Use this');
  check('Use this is still offered', !!use, 'discovery stopped offering what the node really has');
  if (use) { use.click(); }
  check('it fills the node\'s own path',
        crtInput() && crtInput().value === '/opt/vrrp-lab/certs/crt-list-san.txt',
        'got "' + (crtInput() || {}).value + '"');

  console.log('\nnodes that disagree are not guessed between');
  DISCOVER = nodes('/opt/vrrp-lab/certs', '/etc/haproxy/ssl');
  if (btn('Discover')) { btn('Discover').click(); }
  check('no preset is offered', !btn('One shared list'),
        'one node\'s answer was picked for a pair that cannot share a path');
  check('the frontend rows still render', !!btn('Use this'),
        'a directory disagreement should not cost the rest of discovery');

  console.log('\na node that cannot say where it writes');
  DISCOVER = nodes('', '');
  if (btn('Discover')) { btn('Discover').click(); }
  check('nothing is offered rather than a broken path', !btn('One shared list'),
        'built a path on an empty directory');

  console.log('\na save that comes back with a warning says so');
  SAVE_REPLY = { ok: true, warnings: ['"Test pair" keeps its crt-list at ' +
                 "'/etc/haproxy/ssl/x.txt', but n1 can only manage files in '/opt/vrrp-lab/certs'."] };
  const save = btn('Save');
  check('there is a Save button', !!save, 'nothing to drive');
  if (save) { save.click(); }
  check('the warning reaches the screen', /can only manage files in/.test(statusText()),
        'status said: ' + statusText());
  check('and it is not dressed up as success', !/DNS zones found/.test(statusText()),
        'the success line overwrote it: ' + statusText());

  check('no uncaught errors', errors.length === 0, errors.join(' | '));

  console.log(failed ? '\n' + failed + ' CHECK(S) FAILED' : '\nall checks passed');
  process.exit(failed ? 1 : 0);
});
