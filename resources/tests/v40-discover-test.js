// Discover: which frontends every node agrees on, and which only some have.
//
// THE INCIDENT. A standalone HAPEE node - one node, no pair - reported several
// of its frontends as "not on all 1 nodes, the pair is configured differently".
// A warning about a pair, on a machine with no pair, about frontends that were
// perfectly fine.
//
// The cause is that discovery returns one entry per TLS BIND, and the key used
// to group them is frontend|port|crt-list with no address in it. A frontend
// bound to two addresses on the same port with the same crt-list therefore
// counted twice on a single node: 2, where the node count was 1. Not equal, so
// "partial".
//
// What the code wants to know is on how many NODES a frontend appears, which is
// a different question from how many times it was seen, and the two only agree
// when every frontend has exactly one bind per node.
const fs = require('fs');
const { JSDOM, VirtualConsole } = require('jsdom');

const ROOT = require('path').join(__dirname, '..') + require('path').sep;
const html = fs.readFileSync(ROOT + 'ssl-tracker.html', 'utf8');
const scripts = ['assets\\app.js', 'assets\\views\\home.js', 'assets\\views\\certificates.js',
                 'assets\\views\\settings.js', 'assets\\views\\docs.js']
  .map(p => fs.readFileSync(ROOT + p, 'utf8'));

const day = n => new Date(Date.now() + n * 864e5).toISOString();

// One standalone node whose frontends have MORE THAN ONE BIND EACH - the shape
// that produced the bug. Two addresses, same port, same crt-list.
let DISCOVER = {
  nodes: [
    { node: 'drhapee', url: 'https://10.199.77.21:5555', ok: true,
      storageDir: '/etc/hapee-3.3/ssl',
      frontends: [
        { frontend: 'DRTest_flccis_FrontEnd', port: 443, crtList: '/etc/hapee-3.3/ssl/list.txt' },
        { frontend: 'DRTest_flccis_FrontEnd', port: 443, crtList: '/etc/hapee-3.3/ssl/list.txt' },
        { frontend: 'DRTestPowerBiHA',        port: 443, crtList: '' }
      ] }
  ]
};

const STATE = {
  generated: new Date().toISOString(),
  certs: [], unmapped: [], haveZones: true, groupError: null,
  zones: {refreshed:new Date().toISOString(), count:1, errors:[]},
  deployment: {},
  settings: { contact:'me@x.com', defaultCaId:'letsencrypt',
    cas:[{id:'letsencrypt',label:'LE',directoryUrl:'x',stagingUrl:'y',useStaging:true,eabKid:'',eabHmacSet:false}],
    providers: [],
    targets: [{ id:'tDR', label:'DR HAPEE', type:'haproxy-dataplane',
                nodes:[{name:'drhapee', url:'https://10.199.77.21:5555', verifyHost:''}],
                args:{ user:'certcamel', insecureTls:true, crtList:'', verifyPort:'443', remoteName:'' } }],
    alerts:{ smtp:{host:'',port:587,encryption:'starttls',from:'',to:[],authRequired:false,username:'',passwordSet:false},
             expiry:{enabled:false,thresholds:[30]}, renewalSuccess:{enabled:false},
             deploymentFailure:{enabled:false}, monthlySummary:{enabled:false} } },
  catalog: {},
  targetCatalog: { 'haproxy-dataplane': { label:'HAProxy Data Plane API', args:[
      {Name:'user',        Label:'API username',  Secret:false, Type:'text'},
      {Name:'password',    Label:'API password',  Secret:true,  Type:'text'},
      {Name:'remoteName',  Label:'Certificate filename on HAProxy', Secret:false, Type:'text'},
      {Name:'crtList',     Label:'crt-list structure (optional)',   Secret:false, Type:'text'},
      {Name:'verifyPort',  Label:'Port to verify on', Secret:false, Type:'text'},
      {Name:'insecureTls', Label:'Skip TLS verification of the API endpoint', Secret:false, Type:'bool'}
  ] } },
  acmeReady: true
};

const calls = [];
function XHR(){
  this.readyState=0; this.status=0; this.responseText='';
  this.open=(m,u)=>{this._m=m;this._u=u;}; this.setRequestHeader=()=>{};
  this.send=(b)=>{
    calls.push(this._m+' '+this._u);
    let r = {ok:true};
    if (this._u.indexOf('/api/state') === 0) r = STATE;
    if (this._u.indexOf('/api/targets/discover') === 0) r = DISCOVER;
    this.status=200; this.readyState=4; this.responseText=JSON.stringify(r);
    if (this.onreadystatechange) this.onreadystatechange();
  };
}
function goto(w,h){ w.location.hash=h; w.dispatchEvent(new w.Event('hashchange')); }

const errors=[]; const vc=new VirtualConsole();
vc.on('jsdomError', e => errors.push(e.detail ? e.detail.stack : e.message));
const dom = new JSDOM(html, {url:'http://127.0.0.1:1/?t=abc', runScripts:'outside-only',
                             pretendToBeVisual:true, virtualConsole:vc});
const w=dom.window, d=dom.window.document;
w.SSL_DATA=null; w.XMLHttpRequest=XHR; w.alert=m=>errors.push('alert: '+m);
const store={};
Object.defineProperty(w,'localStorage',{value:{getItem:k=>store[k]||null,setItem:(k,v)=>store[k]=v,removeItem:k=>delete store[k]},configurable:true});
try { scripts.forEach(s => w.eval(s)); } catch(e){ errors.push('LOAD THREW: '+e.message); }

let failed = 0;
function check(name, ok, detail){
  if (ok) { console.log('  ok   ' + name); }
  else { console.log('  FAIL ' + name + '  -- ' + detail); failed++; }
}
const rows  = () => Array.from(d.querySelectorAll('.testrow'));
const rowText = () => rows().map(r => r.textContent.replace(/\s+/g, ' ').trim());

function discover(){
  const btn = Array.from(d.querySelectorAll('#targets button'))
    .filter(b => /Discover/i.test(b.textContent))[0];
  btn.click();
}

w.CertCamel.loadState(function(){
  w.CertCamel.navigate();
  goto(w, '#/settings/deployments');

  console.log('\na standalone node with two binds per frontend');
  discover();
  const texts = rowText();
  console.log('  rows: ' + JSON.stringify(texts, null, 0).slice(0, 300));

  check('the doubly-bound frontend is NOT called partial',
        !texts.some(t => /DRTest_flccis_FrontEnd/.test(t) && /partial/i.test(t)),
        texts.join(' | '));
  check('and nothing claims a pair on a single node',
        !texts.some(t => /not on all 1 nodes|the pair is configured differently/i.test(t)),
        texts.join(' | '));
  check('it is offered as something to use',
        texts.some(t => /DRTest_flccis_FrontEnd/.test(t) && /:443/.test(t)),
        texts.join(' | '));
  check('the frontend with no crt-list still lists',
        texts.some(t => /DRTestPowerBiHA/.test(t) && /no crt-list/.test(t)),
        texts.join(' | '));
  check('two binds produce one row, not two',
        texts.filter(t => /DRTest_flccis_FrontEnd/.test(t)).length === 1,
        texts.join(' | '));

  console.log('\nthe results box spans the card instead of one column');
  const box = d.querySelector('#targets .discovery');
  check('it carries the class that spans', !!box,
        '.provider is a grid; an unclassed child gets one 17rem column');

  console.log('\na genuine difference across two nodes still reports');
  DISCOVER = {
    nodes: [
      { node:'lb1', url:'https://a:5555', ok:true, storageDir:'/etc/hapee-3.3/ssl',
        frontends:[ {frontend:'shared', port:443, crtList:'/x/list.txt'},
                    {frontend:'only_on_lb1', port:443, crtList:'/x/list.txt'} ] },
      { node:'lb2', url:'https://b:5555', ok:true, storageDir:'/etc/hapee-3.3/ssl',
        frontends:[ {frontend:'shared', port:443, crtList:'/x/list.txt'} ] }
    ]
  };
  discover();
  const t2 = rowText();
  check('the one-sided frontend is flagged',
        t2.some(t => /only_on_lb1/.test(t) && /partial/i.test(t)), t2.join(' | '));
  check('and says how many nodes have it',
        t2.some(t => /only_on_lb1/.test(t) && /on 1 of 2 nodes/.test(t)), t2.join(' | '));
  check('the shared one is not flagged',
        t2.some(t => /shared/.test(t) && !/partial/i.test(t)), t2.join(' | '));

  console.log('\nload errors: ' + (errors.length ? errors.join('\n') : 'none'));
  if (failed) { console.log('\n' + failed + ' CHECK(S) FAILED'); process.exit(1); }
  console.log('\nall checks passed');
});
