/* The crt-list path is a directory nobody chooses and a filename they do.

   A crt-list is created by uploading a FILENAME - the Data Plane API decides
   which directory the file lands in - and Sync-HAProxyCrtList resolves an
   existing one through the API's own listing, which only ever covers that same
   directory. So a path anywhere else can neither be created nor appended to. It
   cannot work.

   The field was free text with an example path in its hint, and a first install
   copied that example (/etc/haproxy/ssl/) into a lab that keeps everything in
   /opt/vrrp-lab/certs. Nothing said so until a deploy failed. A warning was the
   first attempt at this; a constraint is the right shape, because there is no
   valid reason to type a directory the API cannot reach.

   THREE FILENAMES ARE OFFERED, NOT TWO, and that is the part most likely to be
   "simplified" away later. Cert Camel can create two shapes - one shared list,
   or one per certificate - but a node's bind line often reads a list named
   neither, which is API-managed and perfectly correct. This operator's own
   binds read crt-list-san.txt and crt-list-wild.txt. Offering only the two
   shapes would make the list already in use unreachable from the page.

   Each scenario gets its OWN document. The settings view builds its cards once
   and preserves them across navigation - deliberately, so switching sub-pages
   does not discard edits - so re-navigating cannot re-render a card with
   different stored data. Reloading is the only honest way to test what a saved
   target looks like when the page is opened.

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
const DIR = '/opt/vrrp-lab/certs';

let failed = 0;
function check(name, ok, detail) {
  if (!ok) { failed++; }
  console.log((ok ? '  ok   ' : '  FAIL ') + name + (ok ? '' : '  -- ' + detail));
}

function state(stored) {
  return {
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
                          crtList: stored, verifyPort: '443', insecureTls: true } }],
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
      { Name: 'crtList', Label: 'crt-list path (optional)', Secret: false, Type: 'text',
        Hint: 'Press Discover to fill this in.' },
      { Name: 'verifyPort', Label: 'Verify port', Secret: false, Type: 'text' },
      { Name: 'insecureTls', Label: 'Skip TLS verify', Secret: false, Type: 'bool' }] } },
    acmeReady: true
  };
}

function nodes(dir1, dir2, lists) {
  const fe = [{ frontend: 'fe_https', port: 443, ssl: true, crtList: DIR + '/crt-list-san.txt', crt: '' },
              { frontend: 'fe_https_wild', port: 4443, ssl: true, crtList: DIR + '/crt-list-wild.txt', crt: '' }];
  return { ok: true, nodes: [
    { targetId: 'lab', node: 'n1', url: 'https://127.0.0.1:5555', ok: true, frontends: fe,
      storageDir: dir1, storageDirError: null, crtLists: lists || [], error: null },
    { targetId: 'lab', node: 'n2', url: 'https://127.0.0.1:5556', ok: true, frontends: fe,
      storageDir: dir2, storageDirError: null, crtLists: lists || [], error: null }] };
}

const errors = [];

/* A whole page, as a browser would build it: fresh document, scripts evaluated,
   state loaded, settings open. The XHR stub answers synchronously, so by the
   time this returns the card exists. */
function page(opts) {
  const o = opts || {};
  const vc = new VirtualConsole();
  vc.on('jsdomError', e => errors.push(e.detail ? e.detail.stack : e.message));
  const dom = new JSDOM(html, { url: 'http://127.0.0.1:1/?t=abc', runScripts: 'outside-only',
                                pretendToBeVisual: true, virtualConsole: vc });
  const w = dom.window, d = dom.window.document;
  const ctx = { discover: o.discover || null, save: o.save || { ok: true } };

  function XHR() {
    this.readyState = 0; this.status = 0; this.responseText = '';
    this.open = (m, u) => { this._u = u; };
    this.setRequestHeader = () => {};
    this.send = () => {
      let r = { ok: true };
      if (this._u.indexOf('/api/state') === 0) r = state(o.stored || '');
      else if (this._u.indexOf('/api/targets/discover') === 0) r = ctx.discover;
      else if (this._u.indexOf('/api/settings/test') === 0) r = { ok: true, zoneCount: 1, errors: [] };
      else if (this._u.indexOf('/api/settings') === 0) r = ctx.save;
      else if (this._u.indexOf('/api/checker') === 0) r = { generated: day(0), results: [] };
      else if (this._u.indexOf('/api/automation') === 0) r = { automation: { available: false, tasks: [] }, folder: 'C:/x' };
      else if (this._u.indexOf('/api/loadbalancers') === 0) r = { haveTargets: false };
      this.status = 200; this.readyState = 4; this.responseText = JSON.stringify(r);
      if (this.onreadystatechange) this.onreadystatechange();
    };
  }

  w.SSL_DATA = { generated: day(0), results: [] };
  w.XMLHttpRequest = XHR;
  const store = {};
  w.sessionStorage.getItem = k => Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null;
  w.sessionStorage.setItem = (k, v) => { store[k] = String(v); };
  scripts.forEach(s => w.eval(s));

  w.CertCamel.loadState(function () { w.CertCamel.navigate(); });
  w.location.hash = '#/settings/loadbalancers';
  w.dispatchEvent(new w.Event('hashchange'));

  const api = {
    ctx: ctx,
    sel:     () => d.querySelector('.crtpath select.fname'),
    hidden:  () => d.querySelector('input[data-arg="crtList"]'),
    dirText: () => { const e = d.querySelector('.crtpath .dir'); return e ? e.textContent : '(no control)'; },
    text:    () => d.body.textContent,
    values:  () => { const s = api.sel(); return s ? Array.prototype.map.call(s.options, x => x.value) : []; },
    btn: label => Array.from(d.querySelectorAll('button')).filter(b => b.textContent.trim() === label)[0] || null,
    pick: v => { const s = api.sel(); s.value = v; s.dispatchEvent(new w.Event('change')); },
    status: () => (d.querySelector('#set-status') || d.querySelector('.status') || {}).textContent || '',
    doc: d, win: w
  };
  return api;
}

// --------------------------------------------------------------------------- //
console.log('the directory is not typeable');
let p = page({});
check('the control rendered', !!p.sel(), 'the crt-list field did not build');
check('there is no free-text box for the path',
      !p.doc.querySelector('input[type=text][data-arg="crtList"]'),
      'a directory the API cannot reach can still be typed, which is the whole bug');
check('the value still travels on a data-arg the save path reads', !!p.hidden(),
      'collectSettings reads input[data-arg] and would drop this');

console.log('\nbefore anything has been discovered');
check('the selector is disabled', p.sel() && p.sel().disabled,
      'a directory would be guessed before any node said where it writes');
check('and it says how to find out', /Press Discover/.test(p.text()),
      'a disabled control with no explanation is just broken');
check('nothing is stored yet', p.hidden().value === '', 'got "' + p.hidden().value + '"');

console.log('\na target configured earlier, reopened before any Discover');
/* The directory is recovered from the stored path, so a working target never
   drops back to "press Discover" just because the page was reloaded - and its
   value is not blanked by a node being unreachable. */
p = page({ stored: DIR + '/{certId}-crt-list.txt' });
check('the directory comes back from the stored path', p.dirText() === DIR + '/',
      'showed "' + p.dirText() + '"');
check('and the filename is selected', p.sel().value === '{certId}-crt-list.txt',
      'selector shows "' + p.sel().value + '"');
check('the stored value is untouched', p.hidden().value === DIR + '/{certId}-crt-list.txt',
      'got "' + p.hidden().value + '"');

console.log('\na path this build would not offer is kept, not silently dropped');
/* Somebody may have configured a list Cert Camel cannot create and no reachable
   node reports. Blanking it on render would change their configuration just by
   opening a page. */
p = page({ stored: DIR + '/hand-made.txt' });
check('it survives as a selectable option', p.sel().value === 'hand-made.txt',
      'selector shows "' + p.sel().value + '"');
check('and is still what would be saved', p.hidden().value === DIR + '/hand-made.txt',
      'got "' + p.hidden().value + '"');

// --------------------------------------------------------------------------- //
console.log('\nafter Discover: the directory is fixed, the filename is chosen');
p = page({ discover: nodes(DIR, DIR, [DIR + '/crt-list-san.txt', DIR + '/crt-list-wild.txt']) });
p.btn('Discover').click();

check('the directory is shown', p.dirText() === DIR + '/', 'showed "' + p.dirText() + '"');
check('the selector is usable', !p.sel().disabled, 'still disabled after a good discovery');
check('one shared list is offered', p.values().indexOf('crt-list.txt') >= 0,
      'options: ' + p.values().join(', '));
check('one per certificate is offered', p.values().indexOf('{certId}-crt-list.txt') >= 0,
      'options: ' + p.values().join(', '));
check('and the lists already on the node are offered',
      p.values().indexOf('crt-list-san.txt') >= 0 && p.values().indexOf('crt-list-wild.txt') >= 0,
      'options: ' + p.values().join(', ') +
      ' - the bind reads crt-list-san.txt, and only offering the two shapes makes it unreachable');
check('"not used" is still possible, since the field is optional',
      p.values().indexOf('') >= 0, 'options: ' + p.values().join(', '));

console.log('\nchoosing a filename writes a whole path');
p.pick('{certId}-crt-list.txt');
check('the stored value is directory plus filename',
      p.hidden().value === DIR + '/{certId}-crt-list.txt', 'got "' + p.hidden().value + '"');
p.pick('crt-list-san.txt');
check('picking the node\'s own list works too',
      p.hidden().value === DIR + '/crt-list-san.txt', 'got "' + p.hidden().value + '"');
p.pick('');
check('and "not used" clears it, rather than storing a bare directory',
      p.hidden().value === '', 'got "' + p.hidden().value + '"');

// --------------------------------------------------------------------------- //
console.log('\nnodes that disagree are not guessed between');
p = page({ discover: nodes(DIR, '/etc/haproxy/ssl', []) });
p.btn('Discover').click();
check('no directory is offered', p.sel().disabled,
      'one node\'s answer was picked for a pair that cannot share a path');

console.log('\na target pointed at the wrong directory is corrected, not just flagged');
p = page({ stored: '/etc/haproxy/ssl/{certId}-crt-list.txt',
           discover: nodes(DIR, DIR, [DIR + '/crt-list-san.txt']) });
check('it opens showing what was stored', p.dirText() === '/etc/haproxy/ssl/',
      'showed "' + p.dirText() + '"');
p.btn('Discover').click();
check('Discover moves it to the directory that works', p.dirText() === DIR + '/',
      'showed "' + p.dirText() + '"');
check('keeping the filename', p.sel().value === '{certId}-crt-list.txt',
      'selector shows "' + p.sel().value + '"');
check('and the stored value follows', p.hidden().value === DIR + '/{certId}-crt-list.txt',
      'got "' + p.hidden().value + '" - this is the exact fault that failed a deploy');

// --------------------------------------------------------------------------- //
console.log('\n"Use this" points at what a bind really reads');
p = page({ discover: nodes(DIR, DIR, [DIR + '/crt-list-san.txt']) });
p.btn('Discover').click();
const use = p.btn('Use this');
check('it is still offered', !!use, 'discovery stopped offering what the node actually has');
if (use) { use.click(); }
check('the selector lands on that list', p.sel().value === 'crt-list-san.txt',
      'selector shows "' + p.sel().value + '" while stored is "' + p.hidden().value + '"');
check('and the stored value agrees', p.hidden().value === DIR + '/crt-list-san.txt',
      'got "' + p.hidden().value + '"');

// --------------------------------------------------------------------------- //
console.log('\nthe save-time backstop is still wired');
p = page({ save: { ok: true, warnings: ['"Test pair" keeps its crt-list at ' +
           "'/etc/haproxy/ssl/x.txt', but n1 can only manage files in '" + DIR + "'."] } });
p.btn('Save').click();
check('a warning from the server still reaches the screen', /can only manage files in/.test(p.status()),
      'status said: ' + p.status());

check('no uncaught errors', errors.length === 0, errors.join(' | '));

console.log(failed ? '\n' + failed + ' CHECK(S) FAILED' : '\nall checks passed');
process.exit(failed ? 1 : 0);
