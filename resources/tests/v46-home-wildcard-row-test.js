/* A wildcard checked at an address gets a row on Home.

   Home kept every renewOnly result out of its table, and before a wildcard line
   could say where it is served that was exactly right: a "*.example.com" line
   is a renewal instruction with nothing to measure. Once the line reads

       *.example.com @ lb.example.com

   the checker has read a real certificate and a real date for it, and leaving
   it off Home would put the one number somebody added the suffix to see
   nowhere they look.

   What has to hold:
     1. A probed wildcard gets a row, under its own name.
     2. The row says where it was read, because the port belongs to that address
        and not to the wildcard.
     3. A bare wildcard line still gets no row - it has nothing to show.

   Exits non-zero on failure. */
const fs = require('fs');
const path = require('path');
const { JSDOM, VirtualConsole } = require('jsdom');

const ROOT = path.join(__dirname, '..') + path.sep;
const html = fs.readFileSync(ROOT + 'ssl-tracker.html', 'utf8');
const scripts = ['assets/app.js', 'assets/views/home.js', 'assets/views/certificates.js',
                 'assets/views/settings.js', 'assets/views/logs.js', 'assets/views/docs.js',
                 'assets/views/loadbalancers.js', 'assets/views/renewals.js']
  .map(p => fs.readFileSync(ROOT + p.replace(/\//g, path.sep), 'utf8'));

const day = n => new Date(Date.now() + n * 864e5).toISOString();

const CHECKER = { generated: day(-0.1), results: [
  { host:'a.example.com', port:443, ok:true, notAfter:day(40), issuer:'LE', category:'Prod', renewOnly:false },
  { host:'*.example.com', port:443, ok:true, notAfter:day(80), issuer:'LE', category:'Prod', renewOnly:true,
    checkedAt:'lb.example.com:443' },
  { host:'*.bare.com',    port:443, ok:false, notAfter:null,   issuer:null, category:'Prod', renewOnly:true }
]};
const STATE = {
  generated: day(-0.1), tally: { tracked:2, expiring:0, expired:0 },
  certs: [], unmapped: [], haveZones: true, groupError: null,
  zones: { refreshed: day(-0.1), count: 1, errors: [] }, deployment: {},
  settings: { contact:'x@y.z', defaultCaId:'letsencrypt', cas:[], providers:[], targets:[],
    logs:{retentionDays:90, maxSizeMb:200},
    alerts:{ smtp:{host:'',port:587,encryption:'starttls',from:'',to:[],authRequired:false,
                   username:'',passwordSet:false},
             expiry:{enabled:false,thresholds:[30,14,7]}, renewalSuccess:{enabled:false},
             deploymentFailure:{enabled:false}, summary:{cadence:'off',weeklyDay:'Monday',monthDay:1} } },
  catalog: {}, targetCatalog: {}, acmeReady: true
};

function XHR(){
  this.readyState=0; this.status=0; this.responseText='';
  this.open=(m,u)=>{this._m=m;this._u=u;};
  this.setRequestHeader=()=>{};
  this.send=()=>{
    let r={ok:true};
    if(this._u.indexOf('/api/checker')===0) r=CHECKER;
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
try { scripts.forEach(s => w.eval(s)); } catch(e) { errors.push('LOAD THREW: ' + e.message); }

let failed = 0;
function check(name, ok, detail){
  if (!ok) { failed++; }
  console.log((ok ? '  ok   ' : '  FAIL ') + name + (ok ? '' : '  -- ' + detail));
}

// Attribute values holding "*" are matched by comparison rather than through a
// CSS selector, which would need escaping to mean what it says.
function rowFor(host){
  return Array.from(d.querySelectorAll('tr')).filter(t => t.getAttribute('data-host') === host)[0] || null;
}
function hosts(){
  return Array.from(d.querySelectorAll('tr')).map(t => t.getAttribute('data-host')).filter(Boolean);
}

w.CertCamel.loadState(function(){
  w.CertCamel.navigate();

  console.log('\na wildcard checked at an address');
  const probed = rowFor('*.example.com');
  check('gets a row on Home', !!probed, 'rows: ' + hosts().join(', '));
  check('under its own name', probed && /\*\.example\.com/.test(probed.querySelector('td.host').textContent),
        probed ? probed.querySelector('td.host').textContent : 'no row');
  check('saying where it was read', probed && /via lb\.example\.com:443/.test(probed.textContent),
        probed ? probed.textContent : 'no row');

  console.log('\na bare wildcard line');
  check('still gets no row - it has nothing to show', !rowFor('*.bare.com'), 'rows: ' + hosts().join(', '));

  console.log('\nordinary hosts');
  check('are unaffected', !!rowFor('a.example.com'), 'rows: ' + hosts().join(', '));

  console.log('\nload errors: ' + (errors.length ? errors.join('\n') : 'none'));
  check('no errors', errors.length === 0, errors.join('\n'));

  if (failed) { console.log('\n' + failed + ' CHECK(S) FAILED'); process.exit(1); }
  console.log('\nall checks passed');
});
