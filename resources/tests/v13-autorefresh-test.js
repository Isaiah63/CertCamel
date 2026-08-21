/* Picking up new data without being told to, without being annoying.

   Everything on the page used to be frozen at page load: window.SSL_DATA
   arrives as a <script> tag and cannot be re-read, so a renewal could complete
   and deploy while the page went on showing the old expiry until somebody
   pressed reload.

   The refresh has to obey two rules, and both are easy to break by accident:

     1. Re-render ONLY when something actually changed. Every view rebuilds
        itself from scratch, so an unconditional refresh on a timer would close
        an open menu and move the scroll under whoever is reading.
     2. Never while somebody is mid-action.

   Neither is visible in normal use - a broken version looks fine until the
   moment it wipes something out from under you - so both are pinned here.

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

let CHECKER = { generated: day(-0.1), results: [
  { host:'a.example.com', ok:true, notAfter:day(40), issuer:'LE', category:'Prod', renewOnly:false }
]};
let STATE = {
  generated: day(-0.1), tally: { tracked:1, expiring:0, expired:0 },
  certs: [], unmapped: [], haveZones: true, groupError: null,
  zones: { refreshed: day(-0.1), count: 1, errors: [] }, deployment: {},
  settings: { contact:'x@y.z', defaultCaId:'letsencrypt', cas:[], providers:[], targets:[],
    logs:{retentionDays:90, maxSizeMb:200},
    alerts:{ smtp:{host:'',port:587,encryption:'starttls',from:'',to:[],authRequired:false,
                   username:'',passwordSet:false},
             expiry:{enabled:false,thresholds:[30,14,7]}, renewalSuccess:{enabled:false},
             deploymentFailure:{enabled:false}, monthlySummary:{enabled:false} } },
  catalog: {}, targetCatalog: {}, acmeReady: true
};

let checkerCalls = 0;
function XHR(){
  this.readyState=0; this.status=0; this.responseText='';
  this.open=(m,u)=>{this._m=m;this._u=u;};
  this.setRequestHeader=()=>{};
  this.send=()=>{
    let r={ok:true};
    if(this._u.indexOf('/api/checker')===0){ checkerCalls++; r=CHECKER; }
    else if(this._u.indexOf('/api/state')===0) r=STATE;
    else if(this._u.indexOf('/api/automation')===0) r={automation:{available:true,error:null,tasks:[]},
                                                       forecast:null, folder:'C:/x'};
    else if(this._u.indexOf('/api/loadbalancers')===0) r={haveTargets:false};
    this.status=200; this.readyState=4; this.responseText=JSON.stringify(r);
    if(this.onreadystatechange)this.onreadystatechange();
  };
}

const errors=[]; const vc=new VirtualConsole();
vc.on('jsdomError', e=>errors.push(e.detail?e.detail.stack:e.message));
const dom=new JSDOM(html,{url:'http://127.0.0.1:1/?t=abc',runScripts:'outside-only',
                          pretendToBeVisual:true,virtualConsole:vc});
const w=dom.window, d=dom.window.document;
w.SSL_DATA = CHECKER;
w.XMLHttpRequest = XHR;
const store={};
w.sessionStorage.getItem=k=>Object.prototype.hasOwnProperty.call(store,k)?store[k]:null;
w.sessionStorage.setItem=(k,v)=>{store[k]=String(v);};
scripts.forEach(s => w.eval(s));

let failed = 0;
function check(name, ok, detail){
  if (!ok) { failed++; }
  console.log((ok ? '  ok   ' : '  FAIL ') + name + (ok ? '' : '  -- ' + detail));
}

/* Boot the way the real page does: state first, then render. DOMContentLoaded
   has already fired by the time these scripts are eval'd, so the app's own boot
   handler never runs here and this stands in for it. Rendering before the state
   exists would make the first refresh look like a change when it is only the
   page catching up with its own startup. */
w.location.hash = '#/home';
w.CertCamel.loadState(function(){
  w.CertCamel.navigate();
});

// A marker on the rendered DOM. If the view rebuilds, the marker is gone -
// which is exactly what "did it re-render" means for a view that wipes its host.
function mark(){
  const host = d.getElementById('view-home');
  const m = d.createElement('span');
  m.id = 'rerender-probe';
  host.appendChild(m);
}
function markSurvived(){ return !!d.getElementById('rerender-probe'); }

console.log('nothing changed, so nothing is torn down');
mark();
w.CertCamel.refreshIfChanged();
check('no re-render when the data is identical', markSurvived(),
      'the view rebuilt for no reason - an open menu or the scroll position would have gone with it');
check('it still asked the server', checkerCalls > 0, 'never fetched /api/checker');

console.log('\nnew data arrives, so the page catches up');
mark();
CHECKER = { generated: day(0), results: CHECKER.results };
STATE = Object.assign({}, STATE, { generated: day(0) });
w.CertCamel.refreshIfChanged();
check('re-renders when the checker data moved', !markSurvived(), 'the page kept showing stale data');
check('CC.sslData was replaced, not just refetched',
      w.CertCamel.sslData && w.CertCamel.sslData.generated === CHECKER.generated,
      'sslData still points at the page-load copy, which is the whole bug');

console.log('\nhands on the page means leave it alone');
[
  ['a row menu is open',    () => { const e=d.createElement('div'); e.className='rowmenu'; d.body.appendChild(e); return e; }],
  ['the filter panel is open', () => { const e=d.createElement('div'); e.className='filterpanel'; d.body.appendChild(e); return e; }],
  ['a dialog is open',      () => { const e=d.createElement('dialog'); e.setAttribute('open',''); d.body.appendChild(e); return e; }]
].forEach(function(pair){
  const label = pair[0], make = pair[1];
  w.location.hash = '#/home'; w.dispatchEvent(new w.Event('hashchange'));
  const el = make();
  mark();
  CHECKER = { generated: day(0.1), results: CHECKER.results };
  STATE = Object.assign({}, STATE, { generated: day(0.1) });
  w.CertCamel.refreshIfChanged();
  check('no re-render while ' + label, markSurvived(), 'rebuilt the view out from under an open control');
  el.parentNode.removeChild(el);
});

check('no uncaught errors', errors.length === 0, errors.join(' | '));

console.log(failed ? '\n' + failed + ' CHECK(S) FAILED' : '\nall checks passed');
process.exit(failed ? 1 : 0);
