// The certificates toolbar: selection drives every action, a button is enabled
// only when it is valid for EVERY ticked certificate, and bulk renew asks
// before spending certificate-authority rate limit on things that are not due.
//
// Replaces v3-rowmenu-test.js. The per-row Renew button and the '...' menu are
// gone - a copy of the same furniture on every row, and no way to act on more
// than one certificate - so that test had nothing left to drive.
const fs = require('fs');
const { JSDOM, VirtualConsole } = require('jsdom');

const ROOT = require('path').join(__dirname, '..') + require('path').sep;
const html = fs.readFileSync(ROOT + 'ssl-tracker.html', 'utf8');
const scripts = ['assets\\app.js', 'assets\\views\\home.js', 'assets\\views\\certificates.js',
                 'assets\\views\\settings.js', 'assets\\views\\docs.js']
  .map(p => fs.readFileSync(ROOT + p, 'utf8'));

const day = n => new Date(Date.now() + n * 864e5).toISOString();
function cert(id, disp, external, targets){
  return { certId:id, displayName:disp, kind:'san', zone:id, providerId:'p1', providerLabel:'CF',
    plugin:'Cloudflare', hosts:[], names:[id], deferredNames:[], categories:[], wildcard:false,
    external:external, targets:targets, caId:'letsencrypt', caLabel:'LE', caStaging:true,
    caInherited:true, overridden:false, notAfter:day(40), hasLocalCert:true, issuedAt:day(-50) };
}
const STATE = {
  generated:new Date().toISOString(),
  certs:[ cert('camelnuggets.com','camelnuggets.com',false,['office']),
          cert('other.com','other.com',true,[]) ],
  unmapped:[], haveZones:true, groupError:null,
  zones:{refreshed:new Date().toISOString(),count:1,errors:[]},
  deployment:{ 'camelnuggets.com':{targets:['office'], last:{ at:day(-1), targets:[
    {id:'office', nodes:[{name:'lb1', push:{ok:true}, verify:[{sni:'camelnuggets.com',ok:true,daysRemaining:40}]}]}
  ]}} },
  settings:{ contact:'me@x.com', defaultCaId:'letsencrypt',
    cas:[{id:'letsencrypt',label:'LE',directoryUrl:'x',stagingUrl:'y',useStaging:true,eabKid:'',eabHmacSet:false}],
    providers:[], targets:[{id:'office',label:'Office',type:'haproxy-dataplane',
      nodes:[{name:'lb1',url:'http://127.0.0.1:1',verifyHost:''}], args:{}}],
    alerts:{ smtp:{host:'',port:587,encryption:'starttls',from:'',to:[],authRequired:false,username:'',passwordSet:false},
             expiry:{enabled:false,thresholds:[30]}, renewalSuccess:{enabled:false},
             deploymentFailure:{enabled:false}, monthlySummary:{enabled:false} } },
  catalog:{}, targetCatalog:{}, acmeReady:true
};

const calls = [];
function XHR(){
  this.readyState=0; this.status=0; this.responseText='';
  this.open=(m,u)=>{this._m=m;this._u=u;}; this.setRequestHeader=()=>{};
  this.send=(b)=>{
    calls.push(this._m+' '+this._u+(b?' '+b:''));
    let r={ok:true, jobId:'abc123abc123'};
    if(this._u.indexOf('/api/state')===0) r=STATE;
    if(this._u.indexOf('/api/job/')===0) r={id:'abc123abc123',kind:'renew',running:false,log:'x',result:{ok:true}};
    this.status=200; this.readyState=4; this.responseText=JSON.stringify(r);
    if(this.onreadystatechange)this.onreadystatechange();
  };
}
function goto(w,h){ w.location.hash=h; w.dispatchEvent(new w.Event('hashchange')); }

const errors=[]; const vc=new VirtualConsole();
vc.on('jsdomError',e=>errors.push(e.detail?e.detail.stack:e.message));
const dom=new JSDOM(html,{url:'http://127.0.0.1:1/?t=abc',runScripts:'outside-only',pretendToBeVisual:true,virtualConsole:vc});
const w=dom.window,d=dom.window.document;
w.SSL_DATA=null; w.XMLHttpRequest=XHR; w.alert=m=>errors.push('alert: '+m);
const store={};
Object.defineProperty(w,'localStorage',{value:{getItem:k=>store[k]||null,setItem:(k,v)=>store[k]=v,removeItem:k=>delete store[k]},configurable:true});
try{ scripts.forEach(s=>w.eval(s)); }catch(e){ errors.push('LOAD THREW: '+e.message+'\n'+e.stack); }
console.log('load errors: '+(errors.length?errors.join('\n'):'none'));

const q  = sel => d.querySelector(sel);
const qa = sel => Array.prototype.slice.call(d.querySelectorAll(sel));
const picks = () => qa('#certtable .cert-pick');
const btn = id => d.getElementById(id);
const on  = id => { const b = btn(id); return b ? !b.disabled : null; };

function tick(certId, want){
  const b = picks().filter(x => x.getAttribute('data-cert') === certId)[0];
  b.checked = want;
  b.dispatchEvent(new w.Event('change'));
}

let confirmAnswer = true, confirmSeen = null;
w.confirm = m => { confirmSeen = m; return confirmAnswer; };

w.CertCamel.loadState(function(){
  w.CertCamel.navigate();
  goto(w, '#/certificates');

  console.log('\n=== the row is just data now ===');
  console.log('  one checkbox per row: ' + picks().length + ' (2 rows)');
  console.log('  select-all present: ' + !!btn('cert-all'));
  console.log('  no row menu triggers left: ' + (qa('#certtable .menu-trigger').length === 0));
  console.log('  no per-row action cell left: ' + (qa('#certtable td.acts').length === 0));

  console.log('\n=== nothing selected: every action is off ===');
  console.log('  renew=' + on('btn-sel-renew') + ' deploy=' + on('btn-sel-deploy') +
              ' assign=' + on('btn-sel-assign') + ' download=' + on('btn-sel-download') +
              ' external=' + on('btn-sel-external'));
  console.log('  count is blank: ' + (btn('sel-count').textContent === ''));

  console.log('\n=== one managed certificate with targets ===');
  tick('camelnuggets.com', true);
  console.log('  count: ' + JSON.stringify(btn('sel-count').textContent));
  console.log('  renew=' + on('btn-sel-renew') + ' deploy=' + on('btn-sel-deploy') +
              ' assign=' + on('btn-sel-assign') + ' download=' + on('btn-sel-download'));

  console.log('\n=== adding an external one invalidates most of it ===');
  tick('other.com', true);
  console.log('  renew off (managed elsewhere): ' + (on('btn-sel-renew') === false));
  console.log('  deploy off (no targets): ' + (on('btn-sel-deploy') === false));
  console.log('  download still on (both have a local copy): ' + (on('btn-sel-download') === true));
  console.log('  external toggle off (selection is mixed): ' + (on('btn-sel-external') === false));
  console.log('  reason given: ' + JSON.stringify(btn('btn-sel-renew').title));

  console.log('\n=== select-all ===');
  const all = btn('cert-all');
  all.checked = true; all.dispatchEvent(new w.Event('change'));
  console.log('  every box ticked: ' + picks().every(b => b.checked));
  console.log('  not indeterminate when all are on: ' + (all.indeterminate === false));
  all.checked = false; all.dispatchEvent(new w.Event('change'));
  console.log('  clearing it unticks every box: ' + picks().every(b => !b.checked));

  console.log('\n=== deploy opens the picker with the selection ===');
  tick('camelnuggets.com', true);
  btn('btn-sel-deploy').click();
  console.log('  picker open: ' + !q('#picker').classList.contains('hidden'));
  q('#pick-cancel').click();

  console.log('\n=== bulk renew asks before spending rate limit ===');
  confirmSeen = null; confirmAnswer = false;
  btn('btn-sel-renew').click();
  console.log('  asked: ' + (confirmSeen !== null));
  console.log('  message names the count: ' + /1 certificate/.test(confirmSeen || ''));
  console.log('  declining opens nothing: ' + q('#picker').classList.contains('hidden'));
  confirmAnswer = true;
  btn('btn-sel-renew').click();
  console.log('  accepting opens the picker: ' + !q('#picker').classList.contains('hidden'));
  q('#pick-cancel').click();

  console.log('\n=== managed-elsewhere still POSTs ===');
  const before = calls.length;
  btn('btn-sel-external').click();
  console.log('  posted: ' + calls.slice(before).some(c => c.indexOf('/external') >= 0));

  console.log('\nall errors: ' + (errors.length ? errors.join('\n') : 'none'));
});
