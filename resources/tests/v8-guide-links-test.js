// Settings now answers "why is this here" by pointing into the guide rather
// than restating it. That only works while the anchors exist, and an anchor that
// quietly stops existing is invisible - the link still looks fine and just lands
// at the top of the page. So every in-app link into a guide is resolved against
// the real file here.
const fs = require('fs');
const path = require('path');
const { JSDOM, VirtualConsole } = require('jsdom');

const ROOT = path.join(__dirname, '..') + path.sep;
const html = fs.readFileSync(ROOT + 'ssl-tracker.html', 'utf8');
const scripts = ['assets\\app.js', 'assets\\views\\home.js', 'assets\\views\\certificates.js',
                 'assets\\views\\settings.js', 'assets\\views\\logs.js', 'assets\\views\\docs.js',
                 'assets\\views\\loadbalancers.js']
  .map(p => fs.readFileSync(ROOT + p, 'utf8'));

// Anchors declared by each shipped guide.
//
// One level ABOVE ROOT, unlike everything else this suite reads. ROOT is
// resources\, where the app shell and its assets ship; the guides sit in the
// folder itself so somebody can find and open them without going hunting. The
// app links to them as bare filenames because the server serves them at the
// root of the URL space either way.
const GUIDE_DIR = path.join(ROOT, '..') + path.sep;
const guides = {};
['readme.html', 'haproxy-setup.html', 'security.html'].forEach(function(f){
  const src = fs.readFileSync(GUIDE_DIR + f, 'utf8');
  const ids = {};
  (src.match(/id="[^"]+"/g) || []).forEach(function(m){ ids[m.slice(4, -1)] = true; });
  guides[f] = ids;
});

const STATE = {
  generated: new Date().toISOString(),
  certs: [], unmapped: [], haveZones: true, groupError: null,
  zones: { refreshed: new Date().toISOString(), count: 1, errors: [] },
  deployment: {}, logs: { retentionDays: 45, maxSizeMb: 150 },
  settings: { contact:'me@x.com', defaultCaId:'letsencrypt', cas:[], providers:[],
    targets:[{ id:'prod', label:'Prod pair', nodes:[] }],
    logs:{ retentionDays:45, maxSizeMb:150 },
    alerts:{ smtp:{host:'',port:587,encryption:'starttls',from:'',to:[],authRequired:false,username:'',passwordSet:false},
             expiry:{enabled:false,thresholds:[30]}, renewalSuccess:{enabled:false},
             deploymentFailure:{enabled:false}, monthlySummary:{enabled:false} } },
  catalog:{}, targetCatalog:{ haproxy:{ label:'HAProxy', args:[] } }, acmeReady:true
};

function XHR(){
  this.readyState=0; this.status=0; this.responseText='';
  this.open=(m,u)=>{this._m=m;this._u=u;};
  this.setRequestHeader=()=>{};
  this.send=()=>{
    let r={ok:true};
    if(this._u.indexOf('/api/state')===0) r=STATE;
    this.status=200; this.readyState=4; this.responseText=JSON.stringify(r);
    if(this.onreadystatechange)this.onreadystatechange();
  };
}

let fails = 0;
function check(label, cond, detail){
  if (cond) { console.log('  PASS  ' + label); }
  else { console.log('  FAIL  ' + label + '  -- ' + detail); fails++; }
}

const errors=[]; const vc=new VirtualConsole();
vc.on('jsdomError', e=>errors.push(e.detail?e.detail.stack:e.message));
const dom=new JSDOM(html,{url:'http://127.0.0.1:1/?t=abc',runScripts:'outside-only',pretendToBeVisual:true,virtualConsole:vc});
const w=dom.window,d=dom.window.document;
w.SSL_DATA=null; w.XMLHttpRequest=XHR;
const store={};
Object.defineProperty(w,'localStorage',{value:{getItem:k=>store[k]||null,setItem:(k,v)=>store[k]=v,removeItem:k=>delete store[k]},configurable:true});
try { scripts.forEach(s=>w.eval(s)); } catch(e){ errors.push('LOAD THREW: '+e.message); }
console.log('load errors: '+(errors.length?errors.join('\n'):'none'));

w.CertCamel.loadState(function(){
  w.CertCamel.navigate();

  // Every view that carries guide links, not just Settings - the domains editor
  // on Certificates has one too, and Docs is now mostly deep links into the
  // middle of a guide, which is the kind that rots without looking broken. A
  // suite that only walked Settings would pass while those rotted.
  ['#/settings', '#/certificates', '#/docs'].forEach(function(h){
    w.location.hash = h;
    w.dispatchEvent(new w.Event('hashchange'));
  });

  const links = Array.from(d.querySelectorAll(
    'a[href*="readme.html"], a[href*="haproxy-setup.html"], a[href*="security.html"]'));

  console.log('\n=== every guide link resolves ===');
  check('the views rendered some guide links', links.length > 0, 'found none');

  links.forEach(function(a){
    const href = a.getAttribute('href');
    const hash = href.indexOf('#');
    const file = hash === -1 ? href : href.slice(0, hash);
    const id   = hash === -1 ? null : href.slice(hash + 1);
    const known = guides[file];

    // The Docs cards carry a title AND a description; the title alone is the
    // readable label here.
    const label = (a.querySelector('.t') || a).textContent.trim();

    check('"' + label + '" -> ' + href,
          !!known && (id === null || known[id] === true),
          !known ? 'no such guide file' : 'no id="' + id + '" in ' + file);
  });

  console.log('\n=== and opens without handing the opener over ===');
  const bad = links.filter(function(a){
    return a.getAttribute('target') !== '_blank' || !/noopener/.test(a.getAttribute('rel') || '');
  });
  check('all ' + links.length + ' carry target=_blank rel=noopener', bad.length === 0,
        bad.map(a=>a.getAttribute('href')).join(', '));

  // An exception during render means a panel never built, and its links were
  // never checked - which would let this suite pass by not looking.
  check('no uncaught errors while rendering', errors.length === 0, errors.join('\n'));

  if (fails) { console.log('\n' + fails + ' CHECK(S) FAILED'); process.exit(1); }
  console.log('\nall checks passed');
});
