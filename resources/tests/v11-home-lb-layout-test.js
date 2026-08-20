/* The load balancer panel on Home: groups sit in a grid, not stacked.

   A group is a short card - a couple of node rows and a deployment line - and
   one per row left most of the width empty, because .lbnode ends in a 1fr
   column that a full-width card hands far more space than the version string
   in it needs.

   What this pins is the structure rather than the pixels: every group card is
   inside .lbgrid, and none is left as a direct child of the section. Getting
   that wrong is silent - the page still renders, it just stacks again.

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
  certs: [], unmapped: [], haveZones: true, groupError: null,
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

const node = (name, id) => ({ name, node:id, reachable:true, url:'https://localhost:5555',
                              haproxyVersion:'3.3.13', dataplaneVersion:'3.3.5', apiVersion:'v3' });

// Two groups is the shape that motivated the change; one group is the case a
// plain 1fr grid would still stretch across the whole page.
// haveTargets is what keeps the section on the page at all: an install with
// no deployment targets removes it rather than showing an empty one.
let LB = { haveTargets: true, checkedAt: new Date().toISOString(), targets: [
  { id:'t1', label:'Haproxy-Home-Lab', nodes:[node('lbtest1','hap1'), node('lbtest2','hap2')] },
  { id:'t2', label:'Haproxy-Prod-Pair', nodes:[node('lbprod1','lbprod1'), node('lbprod2','lbprod2')] }
]};

function XHR(){
  this.readyState=0; this.status=0; this.responseText='';
  this.open=(m,u)=>{this._m=m;this._u=u;};
  this.setRequestHeader=()=>{};
  this.send=()=>{
    let r={ok:true};
    if(this._u.indexOf('/api/state')===0) r=STATE;
    else if(this._u.indexOf('/api/loadbalancers')===0) r=LB;
    else if(this._u.indexOf('/api/automation')===0) r={automation:{available:true,error:null,tasks:[]},
                                                       forecast:null, folder:'C:/x'};
    this.status=200; this.readyState=4; this.responseText=JSON.stringify(r);
    if(this.onreadystatechange)this.onreadystatechange();
  };
}

const errors=[]; const vc=new VirtualConsole();
vc.on('jsdomError', e=>errors.push(e.detail?e.detail.stack:e.message));
const dom=new JSDOM(html,{url:'http://127.0.0.1:1/?t=abc',runScripts:'outside-only',
                          pretendToBeVisual:true,virtualConsole:vc});
const w=dom.window, d=dom.window.document;
w.SSL_DATA={generated:new Date().toISOString(), results:[]};
w.XMLHttpRequest=XHR;
const store={};
w.sessionStorage.getItem=k=>Object.prototype.hasOwnProperty.call(store,k)?store[k]:null;
w.sessionStorage.setItem=(k,v)=>{store[k]=String(v);};
scripts.forEach(s => w.eval(s));

let failed = 0;
function check(name, ok, detail){
  if (!ok) { failed++; }
  console.log((ok ? '  ok   ' : '  FAIL ') + name + (ok ? '' : '  -- ' + detail));
}

w.location.hash = '#/home';
w.dispatchEvent(new w.Event('hashchange'));

const grid = d.querySelector('#view-home .lbgrid');
check('the load balancer grid rendered', !!grid, 'no .lbgrid in #view-home');

const inGrid = grid ? grid.querySelectorAll(':scope > .lbgroup').length : 0;
check('both groups are inside the grid', inGrid === 2, 'found ' + inGrid);

/* The regression that matters: a group appended to the section instead of the
   grid still renders, and silently stacks full width again. */
const strays = Array.from(d.querySelectorAll('#view-home .lbgroup'))
  .filter(c => !c.closest('.lbgrid')).length;
check('no group left outside the grid', strays === 0, strays + ' stray group(s)');

check('no uncaught errors while rendering', errors.length === 0, errors.join(' | '));

console.log(failed ? '\n' + failed + ' CHECK(S) FAILED' : '\nall checks passed');
process.exit(failed ? 1 : 0);
