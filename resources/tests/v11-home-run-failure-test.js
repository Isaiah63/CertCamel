/* A failed unattended run has to be visible on Home.

   A renewal that died mid-run left the schedule reading normally, the renewals
   card still listing what it intended to do, and nothing saying the last
   attempt had not worked. It was found by someone noticing a certificate had
   not changed.

   The warning is keyed on the exit code the scheduler reports, NOT on the sweep
   file, because a preview started from the page rewrites that file - so a
   warning driven by it could be cleared by pressing refresh while nothing was
   fixed. That case is pinned below.

   Exits non-zero on failure, and fails on any uncaught error while rendering,
   which is the trap v8 was rewritten for: a panel that never rendered would
   otherwise report as a pass because nothing was there to be wrong. */
const fs = require('fs');
const path = require('path');
const { JSDOM, VirtualConsole } = require('jsdom');

const ROOT = path.join(__dirname, '..') + path.sep;
const html = fs.readFileSync(ROOT + 'ssl-tracker.html', 'utf8');
const scripts = ['assets/app.js', 'assets/views/home.js', 'assets/views/certificates.js',
                 'assets/views/settings.js', 'assets/views/logs.js', 'assets/views/docs.js']
  .map(p => fs.readFileSync(ROOT + p.replace(/\//g, path.sep), 'utf8'));

const day = n => new Date(Date.now() + n * 864e5).toISOString();

const STATE = {
  generated: new Date().toISOString(),
  /* Two certificates in ONE zone, which is the shape that broke the row badge.
     hosts is zone-wide and identical on both; names is what each certificate
     actually covers. Matching on hosts handed every row the first certificate
     it found. */
  certs: [
    { certId:'example.com', displayName:'example.com', kind:'san', zone:'example.com',
      names:['a.example.com','example.com'],
      hosts:['a.example.com','console.example.com'],
      deferredNames:[], categories:[], wildcard:false, tracker:false, external:false,
      targets:[], caId:'le', caLabel:'LE', caStaging:false, caInherited:true,
      overridden:false, notAfter:day(6), hasLocalCert:true, issuedAt:day(-1) },
    { certId:'console.example.com', displayName:'console.example.com', kind:'tracker',
      zone:'example.com',
      names:['console.example.com'],
      hosts:['a.example.com','console.example.com'],
      deferredNames:[], categories:[], wildcard:false, tracker:true, external:false,
      targets:[], caId:'le', caLabel:'LE', caStaging:false, caInherited:true,
      overridden:false, notAfter:day(85), hasLocalCert:true, issuedAt:day(-1) }
  ],
  unmapped: [], haveZones: true, groupError: null,
  zones: { refreshed: new Date().toISOString(), count: 1, errors: [] },
  deployment: { 'camelnuggets.com': { targets: ['t1'], bindings: [{id:'t1',overrides:null}],
                                      last: { at: day(-3), ok: true, name: 'camelnuggets.com' } } },
  settings: { contact:'me@x.com', defaultCaId:'letsencrypt', cas:[], providers:[],
    targets:[{id:'t1', label:'Haproxy-Home-Lab', type:'haproxy', nodes:[], args:{}},
             {id:'t2', label:'Haproxy-Prod-Pair', type:'haproxy', nodes:[], args:{}}],
    logs:{retentionDays:90, maxSizeMb:200},
    alerts:{ smtp:{host:'',port:587,encryption:'starttls',from:'',to:[],authRequired:false,
                   username:'',passwordSet:false},
             expiry:{enabled:false,thresholds:[30,14,7]}, renewalSuccess:{enabled:false},
             deploymentFailure:{enabled:false}, monthlySummary:{enabled:false} } },
  catalog: {}, targetCatalog: {}, acmeReady: true
};

/* The renew task as the Windows scheduler reports it. lastResult is the exit
   code of the last run, and it is what the failure callout keys on - not the
   sweep file, which a preview started from this page overwrites. */
function renewTask(o){
  return Object.assign({
    key:'renew', name:'Cert Camel Renew', label:'Renew and deploy', level:'x', detail:'x',
    registered:true, enabled:true, state:'ready', triggerType:'daily',
    schedule:'2026-08-15T03:20:00-04:00', repeatMinutes:360,
    nextRun:day(0.2), lastRun:day(-0.1), lastResult:0, pathMatches:true, commandPath:'C:/x/renew-due.ps1'
  }, o);
}
let AUTOMATION = { available:true, error:null, tasks:[renewTask({})] };
let FORECAST = { ok:true, mode:'run', error:null, finishedAt:day(-0.1), considered:[
  { certId:'example.com',         name:'example.com',         due:false, reason:null, renewAfter:day(4)  },
  { certId:'console.example.com', name:'console.example.com', due:false, reason:null, renewAfter:day(60) }
]};

function XHR(){
  this.readyState=0; this.status=0; this.responseText='';
  this.open=(m,u)=>{this._m=m;this._u=u;};
  this.setRequestHeader=()=>{};
  this.send=()=>{
    let r={ok:true};
    if(this._u.indexOf('/api/state')===0) r=STATE;
    else if(this._u.indexOf('/api/automation')===0) r={automation:AUTOMATION, forecast:FORECAST,
                                                       folder:'C:/x'};
    this.status=200; this.readyState=4; this.responseText=JSON.stringify(r);
    if(this.onreadystatechange)this.onreadystatechange();
  };
}

const errors=[]; const vc=new VirtualConsole();
vc.on('jsdomError', e=>errors.push(e.detail?e.detail.stack:e.message));
const dom=new JSDOM(html,{url:'http://127.0.0.1:1/?t=abc',runScripts:'outside-only',
                          pretendToBeVisual:true,virtualConsole:vc});
const w=dom.window, d=dom.window.document;
w.SSL_DATA={generated:new Date().toISOString(), results:[
  { host:'a.example.com',       ok:true, notAfter:day(6),  issuer:'LE', category:'Prod', renewOnly:false },
  { host:'console.example.com', ok:true, notAfter:day(85), issuer:'LE', category:'Prod', renewOnly:false }
]};
w.XMLHttpRequest=XHR;
const store={};
w.sessionStorage.getItem=k=>Object.prototype.hasOwnProperty.call(store,k)?store[k]:null;
w.sessionStorage.setItem=(k,v)=>{store[k]=String(v);};
scripts.forEach(s => w.eval(s));

const txtOf = n => n ? n.textContent.replace(/\s+/g,' ').trim() : '(missing)';
let failed = 0;
function check(name, ok, detail){
  if (!ok) { failed++; }
  console.log((ok ? '  ok   ' : '  FAIL ') + name + (ok ? '' : '  -- ' + detail));
}

/* Boot the way the real page does: state first, then render. DOMContentLoaded
   has already fired by the time these scripts are eval'd, so the app's own boot
   handler never runs here and this stands in for it. Without it CC.state stays
   null, and every check that depends on the certificate list quietly measures
   nothing at all. */
w.location.hash = '#/home';
w.CertCamel.loadState(function(){ w.CertCamel.navigate(); });

/* A row badge has to name the renewal of the certificate that actually covers
   that host.

   hosts is zone-wide and identical on every certificate in the zone, so
   matching on it gave every row whichever certificate came first. The console
   row claimed the SAN certificate's date while the renewals card, three inches
   above it, showed the console certificate's own - two months apart, both on
   screen at once. */
console.log('\na row badge names its own certificate');
AUTOMATION = { available:true, error:null, tasks:[renewTask({ lastResult:0 })] };
// The preview case above emptied the forecast, and the badges are driven by it.
FORECAST = { ok:true, mode:'run', error:null, finishedAt:day(-0.1), considered:[
  { certId:'example.com',         name:'example.com',         due:false, reason:null, renewAfter:day(4)  },
  { certId:'console.example.com', name:'console.example.com', due:false, reason:null, renewAfter:day(60) }
]};
render();

function badgeFor(host){
  const rows = Array.from(d.querySelectorAll('#view-home table tr'));
  const row = rows.find(function(tr){
    const cell = tr.querySelector('td.host');
    return cell && cell.textContent.indexOf(host) === 0;
  });
  const b = row && row.querySelector('.st.auto');
  return b ? b.textContent.replace(/\s+/g, ' ').trim() : null;
}

const sanBadge     = badgeFor('a.example.com');
const consoleBadge = badgeFor('console.example.com');
console.log('   a.example.com       -> ' + sanBadge);
console.log('   console.example.com -> ' + consoleBadge);

check('both rows carry a renewal badge', !!sanBadge && !!consoleBadge,
      'a row that renews automatically showed no badge at all');
check('the two rows do not share one date', sanBadge !== consoleBadge,
      'both rows show "' + sanBadge + '" - the badge matched the zone, not the certificate');

check('no uncaught errors while rendering', errors.length === 0, errors.join(' | '));

/* A failed unattended run.

   This is the case that went unreported: renewal died mid-run, the schedule
   still read normally, the renewals card still listed what it intended to do,
   and nothing said the last attempt had not worked. It was found by someone
   noticing a certificate had not changed.

   Keyed on the scheduler exit code rather than the sweep file, because a
   preview started from this page rewrites that file - so a warning driven by it
   could be cleared by pressing refresh, without anything being fixed. */
function render(){ w.location.hash = '#/nowhere'; w.dispatchEvent(new w.Event('hashchange'));
                   w.location.hash = '#/home';    w.dispatchEvent(new w.Event('hashchange')); }
function failureCallout(){
  return Array.from(d.querySelectorAll('#view-home .callout')).find(function(c){
    var h = c.querySelector('.h');
    return h && /did not finish/i.test(h.textContent);
  });
}

AUTOMATION = { available:true, error:null, tasks:[renewTask({ lastResult:1 })] };
FORECAST = { ok:false, mode:'run', error:'renew.ps1 : A parameter cannot be found that matches',
             finishedAt:day(-0.1), considered:[] };
render();
const failed1 = failureCallout();
check('a failed run raises a callout', !!failed1, 'no callout naming a failed run');
check('the callout quotes the reason',
      !!failed1 && /parameter cannot be found/.test(failed1.textContent),
      failed1 ? txtOf(failed1) : '(no callout)');

/* A preview overwrites the sweep file with ok:true. The run still failed, so
   the warning has to survive that - this is the regression that would let a
   refresh hide a real failure. */
FORECAST = { ok:true, mode:'preview', error:null, finishedAt:day(-0.05), considered:[] };
render();
check('a preview does not clear it', !!failureCallout(), 'the warning vanished when a preview overwrote the sweep file');

AUTOMATION = { available:true, error:null, tasks:[renewTask({ lastResult:0 })] };
render();
check('a successful run raises nothing', !failureCallout(), 'callout shown for a run that succeeded');

// A fresh install has never run, which is not a failure.
AUTOMATION = { available:true, error:null, tasks:[renewTask({ lastResult:267011, lastRun:null })] };
render();
check('a task that has never run raises nothing', !failureCallout(), 'callout shown for a task that has not run yet');



console.log(failed ? '\n' + failed + ' CHECK(S) FAILED' : '\nall checks passed');
process.exit(failed ? 1 : 0);
