// The domains.txt editor on the Certificates view: open, load, edit, survive a
// state-driven re-render mid-edit, save-then-auto-check, cancel.
const fs = require('fs');
const { JSDOM, VirtualConsole } = require('jsdom');

const ROOT = require('path').join(__dirname, '..') + require('path').sep;
const html = fs.readFileSync(ROOT + 'ssl-tracker.html', 'utf8');
const scripts = ['assets\\app.js', 'assets\\views\\home.js', 'assets\\views\\certificates.js',
                 'assets\\views\\settings.js', 'assets\\views\\docs.js']
  .map(p => fs.readFileSync(ROOT + p, 'utf8'));

const day = n => new Date(Date.now() + n * 864e5).toISOString();
const STATE = {
  generated: new Date().toISOString(),
  certs: [{ certId:'camelnuggets.com', displayName:'camelnuggets.com', kind:'san', zone:'camelnuggets.com',
    providerId:'p1', providerLabel:'CF', plugin:'Cloudflare', hosts:[], names:['camelnuggets.com'],
    deferredNames:[], categories:[], wildcard:false, external:false, targets:[],
    caId:'letsencrypt', caLabel:"LE", caStaging:true, caInherited:true,
    overridden:false, notAfter:day(80), hasLocalCert:false, issuedAt:null }],
  unmapped: [], haveZones: true, groupError: null,
  zones: { refreshed:new Date().toISOString(), count:1, errors:[] },
  deployment: {},
  settings: { contact:'me@x.com', defaultCaId:'letsencrypt',
    cas:[{id:'letsencrypt', label:'LE', directoryUrl:'x', stagingUrl:'y', useStaging:true, eabKid:'', eabHmacSet:false}],
    providers:[], targets:[],
    alerts:{ smtp:{host:'',port:587,encryption:'starttls',from:'',to:[],authRequired:false,username:'',passwordSet:false},
             expiry:{enabled:false,thresholds:[30,14,7]}, renewalSuccess:{enabled:false},
             deploymentFailure:{enabled:false}, monthlySummary:{enabled:false} } },
  catalog: {}, targetCatalog: {}, acmeReady: true
};

const calls = [];
let savedDomains = null;
function XHR(){
  this.readyState=0; this.status=0; this.responseText='';
  this.open=(m,u)=>{this._m=m;this._u=u;};
  this.setRequestHeader=()=>{};
  this.send=(b)=>{
    calls.push(this._m+' '+this._u+(b?' '+b:''));
    let r={ok:true, jobId:'abc123abc123'};
    if(this._u.indexOf('/api/state')===0) r=STATE;
    if(this._m==='GET' && this._u.indexOf('/api/domains')===0) r={content:'[Prod]\ncamelnuggets.com\n'};
    if(this._m==='POST' && this._u.indexOf('/api/domains')===0){ savedDomains=JSON.parse(b).content; r={ok:true}; }
    if(this._u.indexOf('/api/job/')===0) r={id:'abc123abc123', kind:'check', running:true, log:'...', result:null};
    this.status=200; this.readyState=4; this.responseText=JSON.stringify(r);
    if(this.onreadystatechange)this.onreadystatechange();
  };
}

function goto(w, hash){ w.location.hash = hash; w.dispatchEvent(new w.Event('hashchange')); }

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
  goto(w, '#/certificates');

  console.log('\n=== open the editor ===');
  const editBtn = Array.from(d.querySelectorAll('#view-certificates button')).find(b=>b.textContent==='Edit domains');
  console.log('  Edit domains button present: '+!!editBtn);
  editBtn.click();
  const ta = d.querySelector('#view-certificates textarea.domains-text');
  console.log('  editor visible: '+!ta.closest('.card').classList.contains('hidden'));
  console.log('  loaded from GET /api/domains: '+JSON.stringify(ta.value));

  console.log('\n=== edit, then a state refresh re-renders the view mid-edit ===');
  ta.value = '[Prod]\ncamelnuggets.com\nnew-host.camelnuggets.com\n';
  ta.dispatchEvent(new w.Event('input'));
  w.CertCamel.loadState(function(){
    const ta2 = d.querySelector('#view-certificates textarea.domains-text');
    console.log('  editor still open after re-render: '+!ta2.closest('.card').classList.contains('hidden'));
    console.log('  edit SURVIVED the re-render: '+(ta2.value.indexOf('new-host')!==-1));

    console.log('\n=== save & check now ===');
    const before = calls.length;
    const saveBtn = Array.from(d.querySelectorAll('#view-certificates button')).find(b=>b.textContent==='Save & check now');
    saveBtn.click();
    console.log('  POSTed the edited content: '+(savedDomains && savedDomains.indexOf('new-host')!==-1));
    console.log('  auto-ran check: '+calls.slice(before).some(c=>c.indexOf('POST /api/check')===0));
    console.log('  editor closed after save: '+d.querySelector('#view-certificates textarea.domains-text').closest('.card').classList.contains('hidden'));

    console.log('\nall errors: '+(errors.length?errors.join('\n'):'none'));

    // "Save & check now" starts the job poller, and the /api/job/ stub above
    // answers running:true forever - deliberately, because a finished 'check'
    // job makes app.js call location.reload(), which jsdom does not implement.
    // The poller's setInterval therefore never clears and holds node's event
    // loop open, so this file printed every result and then hung instead of
    // exiting. Closing the window tears the timers down. Nothing above is
    // affected; the assertions have already run.
    dom.window.close();
  });
});
