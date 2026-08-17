// Multi-file SPA smoke test: shell, router, all four views, settings round trip.
const fs = require('fs');
const { JSDOM, VirtualConsole } = require('jsdom');

const ROOT = require('path').join(__dirname, '..') + require('path').sep;
const html = fs.readFileSync(ROOT + 'ssl-tracker.html', 'utf8');
const appJs   = fs.readFileSync(ROOT + 'assets\\app.js', 'utf8');
const homeJs  = fs.readFileSync(ROOT + 'assets\\views\\home.js', 'utf8');
const certsJs = fs.readFileSync(ROOT + 'assets\\views\\certificates.js', 'utf8');
const setJs   = fs.readFileSync(ROOT + 'assets\\views\\settings.js', 'utf8');
const docsJs  = fs.readFileSync(ROOT + 'assets\\views\\docs.js', 'utf8');

const day = n => new Date(Date.now() + n * 864e5).toISOString();
const SSL_DATA = { generated: new Date().toISOString(), results: [
  { host:'camelnuggets.com', port:443, category:'C', ok:true, notAfter:day(20), notBefore:day(-70),
    issuer:'LE', subject:'camelnuggets.com', sans:['camelnuggets.com'], serial:'AAAA', thumbprint:'T', renewOnly:false, error:null },
  { host:'broken.example.com', port:443, category:'C', ok:false, notAfter:null, notBefore:null,
    issuer:null, subject:null, sans:[], serial:null, thumbprint:null, renewOnly:false, error:'connection refused' }
]};

const STATE = {
  generated: SSL_DATA.generated,
  certs: [
    { certId:'camelnuggets.com', displayName:'camelnuggets.com', kind:'san', zone:'camelnuggets.com',
      providerId:'p1', providerLabel:'CF', plugin:'Cloudflare', hosts:[], names:['camelnuggets.com'],
      deferredNames:[], categories:['C'], wildcard:false, external:false, targets:['office'],
      caId:'letsencrypt', caLabel:"Let's Encrypt", caStaging:true, caInherited:true,
      overridden:false, notAfter:day(20), hasLocalCert:true, issuedAt:day(-70) }
  ],
  unmapped: [], haveZones: true, groupError: null,
  zones: { refreshed: new Date().toISOString(), count: 1, errors: [] },
  deployment: { 'camelnuggets.com': { targets:['office'], last: { at: day(-1), targets: [
    { id:'office', nodes: [ { name:'lb1', push:{ok:true}, verify:[{sni:'camelnuggets.com', ok:true, daysRemaining:89}] } ] }
  ] } } },
  settings: {
    contact: 'me@x.com', defaultCaId: 'letsencrypt',
    cas: [{ id:'letsencrypt', label:"Let's Encrypt", directoryUrl:'x', stagingUrl:'y', useStaging:true, eabKid:'', eabHmacSet:false }],
    providers: [{ id:'p1', label:'CF', plugin:'Cloudflare', args:{ CFToken:true } }],
    targets: [{ id:'office', label:'Office prod', type:'haproxy-dataplane',
      nodes:[{name:'lb1', url:'http://127.0.0.1:15551', verifyHost:''}],
      args:{ user:'dpapi', password:true, remoteName:'{certId}.pem', crtList:'', verifyPort:'443', insecureTls:false } }],
    alerts: {
      smtp: { host:'smtp.example.com', port:587, encryption:'starttls', from:'a@x.com', to:['ops@x.com'],
              authRequired:true, username:'u', passwordSet:true },
      expiry: { enabled:true, thresholds:[30,14,7] },
      renewalSuccess: { enabled:true }, deploymentFailure: { enabled:true }, monthlySummary: { enabled:false }
    }
  },
  catalog: { Cloudflare: { label:'Cloudflare', args:[{Name:'CFToken', Label:'API Token', Secret:true, Type:'text'}] } },
  targetCatalog: { 'haproxy-dataplane': { label:'HAProxy (Data Plane API)', args:[
    {Name:'user', Label:'API username', Secret:false, Type:'text'},
    {Name:'password', Label:'API password', Secret:true, Type:'text'},
    {Name:'remoteName', Label:'Cert filename', Secret:false, Type:'text'},
    {Name:'crtList', Label:'crt-list', Secret:false, Type:'text'},
    {Name:'verifyPort', Label:'Verify port', Secret:false, Type:'text'},
    {Name:'insecureTls', Label:'Skip TLS verify', Secret:false, Type:'bool'}] } },
  acmeReady: true
};

const calls = [];
function XHR(){
  this.readyState = 0; this.status = 0; this.responseText = '';
  this.open = (m,u) => { this._m = m; this._u = u; };
  this.setRequestHeader = () => {};
  this.send = (b) => {
    calls.push(this._m + ' ' + this._u + (b ? ' ' + b : ''));
    let r = { ok:true, jobId:'abc123abc123' };
    if (this._u.indexOf('/api/state') === 0) r = STATE;
    if (this._u.indexOf('/api/job/') === 0) r = { id:'abc123abc123', kind:'renew', running:false, log:'done', result:{ok:true} };
    if (this._u.indexOf('/api/settings/test-email') === 0) r = { ok:true };
    if (this._u.indexOf('/api/targets/test') === 0) r = { ok:true, nodes:[{targetId:'office', node:'lb1', url:'u', ok:true, apiVersion:'v3', certificates:['a.pem'], error:null}] };
    this.status = 200; this.readyState = 4; this.responseText = JSON.stringify(r);
    // The download path asks for a blob and reads .response, not .responseText.
    this.response = this.responseType === 'blob' ? 'PEM BYTES' : this.responseText;
    if (this.onreadystatechange) this.onreadystatechange();
  };
}

// A bare `location.hash = x` fires 'hashchange' asynchronously in a real
// browser too, so this is not the app cutting a corner - it is the test
// forcing that event to fire synchronously, so assertions right after can see
// its effect without needing to await a real event-loop tick.
function goto(w, hash){
  w.location.hash = hash;
  w.dispatchEvent(new w.Event('hashchange'));
}

const errors = []; const vc = new VirtualConsole();
vc.on('jsdomError', e => errors.push(e.detail ? e.detail.stack : e.message));
const dom = new JSDOM(html, { url:'http://127.0.0.1:1/?t=abc', runScripts:'outside-only', pretendToBeVisual:true, virtualConsole:vc });
const w = dom.window, d = w.document;
w.SSL_DATA = SSL_DATA;
w.XMLHttpRequest = XHR;
w.alert = m => errors.push('alert: ' + m);
const store = {};
Object.defineProperty(w, 'localStorage', { value: { getItem:k=>store[k]||null, setItem:(k,v)=>store[k]=v, removeItem:k=>delete store[k] }, configurable:true });

// Saving a file is a blob URL clicked on the page's behalf, and jsdom has
// neither: createObjectURL is unimplemented, and clicking a real <a> would be
// a navigation it refuses. Record the save instead - what we care about is the
// filename and that the bytes came from an object URL rather than an address.
const saves = [];
w.URL.createObjectURL = () => 'blob:stub';
w.URL.revokeObjectURL = () => {};
w.HTMLAnchorElement.prototype.click = function(){
  saves.push(this.getAttribute('download') + ' from ' + this.href);
};

try {
  w.eval(appJs);
  w.eval(homeJs);
  w.eval(certsJs);
  w.eval(setJs);
  w.eval(docsJs);
} catch (e) { errors.push('SCRIPT LOAD THREW: ' + e.message + '\n' + e.stack); }

console.log('load errors: ' + (errors.length ? errors.join('\n') : 'none'));

// The token comes in on the query string because that is the only way the
// server can hand it to a page it is opening, and comes straight back out:
// the server task runs from boot, so one token is live for the machine's whole
// uptime and must not be left sitting in history or in a screenshot.
console.log('\n=== the token leaves the address bar ===');
console.log('  token still held: ' + (w.CertCamel.TOKEN === 'abc'));
console.log('  query string cleared: ' + (w.location.search === ''));
console.log('  kept for a reload: ' + (w.sessionStorage.getItem('certcamel.token') === 'abc'));

// DOMContentLoaded already fired before we eval'd app.js, so drive boot manually.
w.CertCamel.loadState(function(){
  w.CertCamel.navigate();

  console.log('\n=== router: default route ===');
  console.log('  current route: ' + JSON.stringify(w.CertCamel.currentRoute()));
  console.log('  #view-home visible: ' + !d.getElementById('view-home').classList.contains('hidden'));
  console.log('  Home nav aria-current: ' + d.querySelector('.navitem[data-view="home"]').getAttribute('aria-current'));

  console.log('\n=== navigate to certificates ===');
  goto(w, '#/certificates');
  console.log('  #view-certificates visible: ' + !d.getElementById('view-certificates').classList.contains('hidden'));
  console.log('  #view-home hidden again: ' + d.getElementById('view-home').classList.contains('hidden'));
  const certRows = d.querySelectorAll('#certtable tbody tr');
  console.log('  certificate rows rendered: ' + certRows.length);
  // Download lives in the row actions menu, which renders on document.body
  // rather than inside the table - so open the menu first. It is a button
  // rather than a link because the token no longer travels in a URL: the page
  // fetches the PEM with the header and saves the blob.
  const menuTrigger = d.querySelector('#certtable .menu-trigger');
  menuTrigger.click();
  const dl = Array.from(d.querySelectorAll('.rowmenu button'))
                  .find(b => b.textContent.indexOf('Download') === 0);
  console.log('  download label: ' + (dl && dl.textContent));
  const beforeDl = calls.length;
  dl.click();
  const dlCall = calls.slice(beforeDl).find(c => c.indexOf('GET /api/download/') === 0);
  console.log('  download went over XHR: ' + dlCall);
  console.log('  NO token in the download URL: ' + (dlCall.indexOf('t=') === -1));
  console.log('  saved to a file: ' + saves[0]);
  d.dispatchEvent(new w.KeyboardEvent('keydown', {key:'Escape'}));   // tidy up before the next step

  console.log('\n=== picker still works from the new view ===');
  const renewBtn = Array.from(d.querySelectorAll('#certtable button')).find(b => b.textContent === 'Renew');
  const before = calls.length;
  renewBtn.click();
  console.log('  picker opened: ' + !d.getElementById('picker').classList.contains('hidden'));
  console.log('  pre-ticked from assignment: ' + d.querySelector('#pick-targets .pick-target').checked);
  d.getElementById('pick-ok').click();
  const renewCall = calls.slice(before).find(c => c.indexOf('POST /api/renew') === 0);
  console.log('  renew call fired with right payload: ' + renewCall);
  console.log('  picker closed after confirm: ' + d.getElementById('picker').classList.contains('hidden'));

  console.log('\n=== settings: sub-pages preserve edits when switching ===');
  goto(w, '#/settings/general');
  console.log('  #view-settings visible: ' + !d.getElementById('view-settings').classList.contains('hidden'));
  console.log('  general panel visible: ' + !d.querySelector('[data-panel="general"]').classList.contains('hidden'));
  const contact = d.getElementById('set-contact');
  contact.value = 'changed@example.com';

  goto(w, '#/settings/deployments');
  console.log('  deployments panel now visible: ' + !d.querySelector('[data-panel="deployments"]').classList.contains('hidden'));
  console.log('  general panel now hidden: ' + d.querySelector('[data-panel="general"]').classList.contains('hidden'));
  console.log('  contact edit SURVIVED switching panels: ' + (d.getElementById('set-contact').value === 'changed@example.com'));
  console.log('  target card rendered: ' + !!d.querySelector('#targets .target'));

  console.log('\n=== settings: alerts panel populated from state ===');
  goto(w, '#/settings/alerts');
  console.log('  smtp host populated: ' + d.querySelector('.al-smtp-host').value);
  console.log('  password placeholder shows "saved": ' + (d.querySelector('.al-smtp-pass').placeholder.indexOf('Saved') !== -1));
  console.log('  expiry thresholds populated: ' + d.querySelector('.al-expiry-thresholds').value);
  console.log('  auth fields visible (authRequired=true): ' + !d.querySelector('.al-auth-fields').classList.contains('hidden'));

  console.log('\n=== save writes every panel, including ones not currently visible ===');
  const before2 = calls.length;
  const saveBtn = Array.from(d.querySelectorAll('#view-settings button')).find(b => b.textContent === 'Save');
  saveBtn.click();
  const saveCall = calls.slice(before2).find(c => c.indexOf('POST /api/settings ') === 0);
  const body = JSON.parse(saveCall.substring('POST /api/settings '.length));
  console.log('  contact from a panel we left: ' + body.contact);
  console.log('  targets still included: ' + body.targets.length);
  console.log('  alerts included: ' + !!body.alerts);
  console.log('  alerts.smtp.password key ABSENT (blank field must not send one): ' + !body.alerts.smtp.hasOwnProperty('password'));

  console.log('\n=== test email button ===');
  const before3 = calls.length;
  const testEmailBtn = Array.from(d.querySelectorAll('#view-settings button')).find(b => b.textContent === 'Send test email');
  testEmailBtn.click();
  console.log('  save-then-test sequence: ' + calls.slice(before3).map(c => c.split(' ')[0] + ' ' + c.split(' ')[1]).join(' -> '));

  console.log('\n=== docs view ===');
  goto(w, '#/docs');
  console.log('  doc links: ' + d.querySelectorAll('#view-docs .doclink').length);

  console.log('\n=== sidebar collapse persists ===');
  const toggle = d.getElementById('btn-sidebar-toggle');
  toggle.click();
  console.log('  collapsed after click: ' + d.body.classList.contains('sidebar-collapsed'));
  console.log('  persisted to localStorage: ' + store['certcamel-sidebar-collapsed']);

  console.log('\n=== theme menu ===');
  // The row opened a cycle until there were six themes to walk; it opens a
  // menu now. The menu renders on document.body, like the row menus on the
  // certificates table, so it is queried from there rather than the sidebar.
  const themeBtn = d.getElementById('btn-theme');
  const themeNow = d.getElementById('theme-now');
  console.log('  starts at: ' + themeNow.textContent + '  (data-theme=' +
              d.documentElement.getAttribute('data-theme') + ')');

  themeBtn.click();
  const themeItems = Array.from(d.querySelectorAll('.rowmenu button'));
  console.log('  menu lists: ' + themeItems.map(b => b.textContent).join(', '));
  console.log('  current one is marked: ' +
              (themeItems.find(b => b.hasAttribute('aria-current')) || {}).textContent);

  // Every theme in the registry must have a CSS block, or picking it silently
  // does nothing at all. Checked against app.css rather than trusted.
  //
  // 'auto' and 'light' are exempt, and for different reasons: auto REMOVES the
  // attribute, and light is what plain :root already is - its data-theme value
  // exists only so the :not([data-theme="light"]) on the dark media query can
  // exclude it, letting an explicit Light beat a dark OS setting.
  const css = fs.readFileSync(ROOT + 'assets\\app.css', 'utf8');
  const missing = w.CertCamel.THEMES
    .filter(t => t.value !== 'auto' && t.value !== 'light')
    .filter(t => css.indexOf(':root[data-theme="' + t.value + '"]') === -1)
    .map(t => t.value);
  console.log('  every theme has a CSS block: ' + (missing.length === 0) +
              (missing.length ? '  MISSING: ' + missing.join(', ') : ''));

  // Pick the last one, which is the case cycling made tedious.
  themeItems[themeItems.length - 1].click();
  console.log('  picked ' + themeNow.textContent + ' -> data-theme=' +
              d.documentElement.getAttribute('data-theme'));
  console.log('  stored: ' + store['certcamel-theme']);
  console.log('  menu closed after choosing: ' + (d.querySelectorAll('.rowmenu').length === 0));

  // Auto is the one that must CLEAR the attribute rather than set
  // data-theme="auto", so the OS preference takes over again.
  themeBtn.click();
  Array.from(d.querySelectorAll('.rowmenu button')).find(b => b.textContent === 'Auto').click();
  console.log('  back to Auto clears the attribute: ' +
              (d.documentElement.getAttribute('data-theme') === null));
  console.log('  auto stores nothing: ' + (store['certcamel-theme'] === undefined));

  console.log('\nall errors so far: ' + (errors.length ? errors.join('\n') : 'none'));
});
