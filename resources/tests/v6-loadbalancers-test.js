// The Load balancers view: node status, certificates grouped by what serves
// them, and the case the page exists for - a certificate deployed to a crt-list
// that no frontend reads, which every other check reports as a success.
const fs = require('fs');
const { JSDOM, VirtualConsole } = require('jsdom');

const ROOT = require('path').join(__dirname, '..') + require('path').sep;
const html = fs.readFileSync(ROOT + 'ssl-tracker.html', 'utf8');
const scripts = ['assets\\app.js', 'assets\\views\\home.js', 'assets\\views\\certificates.js',
                 'assets\\views\\settings.js', 'assets\\views\\logs.js', 'assets\\views\\docs.js',
                 'assets\\views\\loadbalancers.js']
  .map(p => fs.readFileSync(ROOT + p, 'utf8'));

const STATE = {
  generated: new Date().toISOString(),
  certs: [], unmapped: [], haveZones: true, groupError: null,
  zones: { refreshed: new Date().toISOString(), count: 1, errors: [] },
  deployment: {}, logs: { retentionDays: 45, maxSizeMb: 150 },
  settings: { contact: 'me@x.com', defaultCaId: 'letsencrypt', cas: [], providers: [], targets: [],
    logs: { retentionDays: 45, maxSizeMb: 150 },
    alerts: { smtp: { host:'', port:587, encryption:'starttls', from:'', to:[], authRequired:false, username:'', passwordSet:false },
              expiry:{enabled:false,thresholds:[30]}, renewalSuccess:{enabled:false},
              deploymentFailure:{enabled:false}, monthlySummary:{enabled:false} } },
  catalog: {}, targetCatalog: {}, acmeReady: true
};

// One group: one certificate correctly served, one deployed to a path nothing
// reads, and a frontend outside the tool entirely.
const LB = {
  checkedAt: new Date().toISOString(),
  haveTargets: true,
  targets: [],
  groups: [{
    id: 'pair', label: 'Edge pair',
    nodes: [
      { name:'lb1', url:'https://10.0.0.11:5555', reachable:true, node:'hap1',
        haproxyVersion:'3.3.13', apiVersion:'v3', error:null, frontends:[{}, {}], frontendError:null },
      { name:'lb2', url:'https://10.0.0.12:5555', reachable:false, node:null,
        haproxyVersion:null, apiVersion:null, error:'connection refused', frontends:[], frontendError:null }
    ],
    certificates: [
      { certId:'good.com', name:'good.com', crtList:'/etc/haproxy/certs/good.txt', state:'served', note:null,
        frontends:[{ node:'lb1', frontend:'fe_good', address:'203.0.113.7', port:443, viaDirectory:false }] },
      { certId:'lost.com', name:'lost.com', crtList:'/etc/haproxy/certs/TYPO.txt', state:'unreferenced', note:null,
        frontends:[] }
    ],
    unmanaged: [
      { node:'lb1', frontend:'fe_legacy', address:'203.0.113.9', port:443,
        crtList:'/etc/haproxy/certs/legacy.txt', crtDir:'' }
    ]
  }]
};

const calls = [];
function XHR(){
  this.readyState=0; this.status=0; this.responseText='';
  this.open=(m,u)=>{this._m=m;this._u=u;};
  this.setRequestHeader=()=>{};
  this.send=()=>{
    calls.push(this._m+' '+this._u);
    let r={ok:true};
    if(this._u.indexOf('/api/state')===0) r=STATE;
    else if(this._u.indexOf('/api/loadbalancers')===0) r=LB;
    this.status=200; this.readyState=4; this.responseText=JSON.stringify(r);
    if(this.onreadystatechange)this.onreadystatechange();
  };
}

function goto(w, hash){ w.location.hash = hash; w.dispatchEvent(new w.Event('hashchange')); }
const txt = n => n ? n.textContent : '(missing)';

const errors=[]; const vc=new VirtualConsole();
vc.on('jsdomError', e=>errors.push(e.detail?e.detail.stack:e.message));
const dom=new JSDOM(html,{url:'http://127.0.0.1:1/?t=abc',runScripts:'outside-only',pretendToBeVisual:true,virtualConsole:vc});
const w=dom.window,d=dom.window.document;
w.SSL_DATA=null; w.XMLHttpRequest=XHR;
const store={};
Object.defineProperty(w,'localStorage',{value:{getItem:k=>store[k]||null,setItem:(k,v)=>store[k]=v,removeItem:k=>delete store[k]},configurable:true});
// jsdom has no <dialog> support; stub only what the view calls.
const dlg = d.getElementById('lbfix');
if (dlg && !dlg.showModal) { dlg.showModal = function(){ this.setAttribute('open',''); }; }
try { scripts.forEach(s=>w.eval(s)); } catch(e){ errors.push('LOAD THREW: '+e.message); }
console.log('load errors: '+(errors.length?errors.join('\n'):'none'));

w.CertCamel.loadState(function(){
  w.CertCamel.navigate();

  console.log('\n=== the sidebar entry owns the route ===');
  const nav = d.querySelector('.sidebar .navitem[data-view="loadbalancers"]');
  console.log('  nav item: '+txt(nav && nav.querySelector('.navlabel'))+'  href='+(nav&&nav.getAttribute('href')));
  console.log('  container present: '+!!d.getElementById('view-loadbalancers'));

  goto(w, '#/loadbalancers');
  const host = d.getElementById('view-loadbalancers');
  console.log('  view shown: '+!host.classList.contains('hidden'));
  console.log('  did NOT fall back to home: '+d.getElementById('view-home').classList.contains('hidden'));

  console.log('\n=== nodes, including one that did not answer ===');
  const nodes = Array.from(host.querySelectorAll('.lbnode'));
  console.log('  nodes rendered: '+nodes.length);
  console.log('  unreachable node marked: '+(nodes[1] && nodes[1].classList.contains('down')));
  console.log('  and says why: '+/connection refused/.test(txt(nodes[1])));

  console.log('\n=== certificates, worst first ===');
  const certs = Array.from(host.querySelectorAll('.lbcert'));
  const order = certs.map(c=>txt(c.querySelector('.lbcertname')));
  console.log('  order: '+order.join(' | '));
  console.log('  the broken one is first: '+(order[0]==='lost.com'));
  console.log('  its state badge: '+txt(certs[0].querySelector('.lbstate')));
  console.log('  stripe class applied: '+certs[0].classList.contains('unreferenced'));
  console.log('  served one lists its frontend: '+/fe_good/.test(txt(certs[1])));

  console.log('\n=== the fix dialog offers BOTH directions ===');
  const fix = certs[0].querySelector('button');
  console.log('  button present: '+!!fix);
  fix.click();
  const body = d.querySelector('#lbfix .fixbody');
  const t = txt(body);
  console.log('  shows Cert Camel path: '+/TYPO\.txt/.test(t));
  console.log('  shows what HAProxy reads: '+/legacy\.txt/.test(t));
  console.log('  offers pointing HAProxy at Cert Camel: '+/point HAProxy at/i.test(t));
  console.log('  offers pointing Cert Camel at HAProxy: '+/point Cert Camel at/i.test(t));
  console.log('  says it never edits the config: '+/never edits your HAProxy/i.test(t));

  console.log('\n=== unmanaged frontends are shown, not treated as errors ===');
  console.log('  legacy frontend listed: '+/fe_legacy/.test(txt(host)));

  console.log('\n=== read-only: the page changes nothing by rendering ===');
  const writes = calls.filter(c=>c.indexOf('POST')===0||c.indexOf('PUT')===0||c.indexOf('DELETE')===0);
  console.log('  write calls made: '+(writes.length?writes.join(', '):'none'));

  console.log('\nall errors: '+(errors.length?errors.join('\n'):'none'));
});
