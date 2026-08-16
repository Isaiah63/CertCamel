// The row actions menu: opens, closes every way it should, fires the same API
// calls the old buttons did, and never leaves an orphan on document.body.
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

const menus = () => d.querySelectorAll('.rowmenu');
const triggers = () => d.querySelectorAll('#certtable .menu-trigger');

w.CertCamel.loadState(function(){
  w.CertCamel.navigate();
  goto(w, '#/certificates');

  console.log('\n=== row layout ===');
  console.log('  Renew still a visible button in the row: ' +
    !!Array.from(d.querySelectorAll('#certtable button')).find(b=>b.textContent==='Renew'));
  console.log('  one menu trigger per row: ' + triggers().length + ' (2 rows)');
  console.log('  deployed cell uses the spacing wrapper: ' + !!d.querySelector('#certtable .deploy-stack'));

  console.log('\n=== open ===');
  triggers()[0].click();
  console.log('  menu on document.body (escapes the table clip): ' +
    (menus().length === 1 && menus()[0].parentNode === d.body));
  console.log('  trigger marked expanded: ' + (triggers()[0].getAttribute('aria-expanded') === 'true'));
  // position:fixed comes from the .rowmenu class (jsdom does not load the
  // external stylesheet, so style.position is empty here by design). What this
  // asserts is that the positioning code ran and produced coordinates.
  console.log('  coordinates computed: left=' + (menus()[0].style.left !== '') +
              ' top=' + (menus()[0].style.top !== ''));
  const labels = Array.from(menus()[0].querySelectorAll('button,a')).map(n=>n.textContent);
  console.log('  items: ' + labels.join(' | '));

  console.log('\n=== only one open at a time ===');
  triggers()[1].click();
  console.log('  still exactly one menu: ' + menus().length);
  console.log('  first trigger reset to collapsed: ' + (triggers()[0].getAttribute('aria-expanded') === 'false'));
  console.log('  external cert has no Deploy item: ' +
    !Array.from(menus()[0].querySelectorAll('button')).some(b=>b.textContent.indexOf('Deploy')===0));

  console.log('\n=== closing ===');
  d.dispatchEvent(new w.KeyboardEvent('keydown',{key:'Escape'}));
  console.log('  Escape closes: ' + (menus().length === 0));
  triggers()[0].click();
  triggers()[0].click();
  console.log('  clicking the same trigger again closes: ' + (menus().length === 0));
  triggers()[0].click();
  d.dispatchEvent(new w.MouseEvent('mousedown',{bubbles:true}));
  console.log('  outside click closes: ' + (menus().length === 0));

  console.log('\n=== items do what the old buttons did ===');
  triggers()[0].click();
  const beforeDeploy = calls.length;
  Array.from(menus()[0].querySelectorAll('button')).find(b=>b.textContent.indexOf('Deploy')===0).click();
  console.log('  Deploy opened the picker: ' + !d.getElementById('picker').classList.contains('hidden'));
  console.log('  menu closed on choosing an item: ' + (menus().length === 0));
  d.getElementById('pick-cancel').click();

  triggers()[1].click();
  const beforeFlip = calls.length;
  Array.from(menus()[0].querySelectorAll('button')).find(b=>b.textContent==='Renew here').click();
  const flipCall = calls.slice(beforeFlip).find(c=>c.indexOf('/external')>0);
  console.log('  managed-elsewhere toggle still POSTs: ' + flipCall);

  console.log('\n=== a re-render must not orphan an open menu ===');
  triggers()[0].click();
  console.log('  open before re-render: ' + (menus().length === 1));
  w.CertCamel.loadState(function(){
    console.log('  cleaned up after re-render: ' + (menus().length === 0));
    console.log('\nall errors: ' + (errors.length?errors.join('\n'):'none'));
  });
});
