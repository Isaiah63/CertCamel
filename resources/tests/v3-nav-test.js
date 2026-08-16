// The Settings nav group folds up, Docs is no longer inside it, and the editor
// gets real room. Focus: the collapse must never hide the page you are on.
const fs = require('fs');
const { JSDOM, VirtualConsole } = require('jsdom');

const ROOT = require('path').join(__dirname, '..') + require('path').sep;
const html = fs.readFileSync(ROOT + 'ssl-tracker.html', 'utf8');
const scripts = ['assets\\app.js', 'assets\\views\\home.js', 'assets\\views\\certificates.js',
                 'assets\\views\\settings.js', 'assets\\views\\docs.js']
  .map(p => fs.readFileSync(ROOT + p, 'utf8'));

const STATE = {
  generated: new Date().toISOString(), certs: [], unmapped: [], haveZones: true, groupError: null,
  zones: { refreshed: new Date().toISOString(), count: 0, errors: [] }, deployment: {},
  settings: { contact: 'me@x.com', defaultCaId: 'letsencrypt',
    cas: [{id:'letsencrypt', label:'LE', directoryUrl:'x', stagingUrl:'y', useStaging:true, eabKid:'', eabHmacSet:false}],
    providers: [], targets: [],
    alerts: { smtp:{host:'',port:587,encryption:'starttls',from:'',to:[],authRequired:false,username:'',passwordSet:false},
              expiry:{enabled:false,thresholds:[30,14,7]}, renewalSuccess:{enabled:false},
              deploymentFailure:{enabled:false}, monthlySummary:{enabled:false} } },
  catalog: {}, targetCatalog: {}, acmeReady: true
};

function XHR(){
  this.readyState=0; this.status=0; this.responseText='';
  this.open=(m,u)=>{this._u=u;}; this.setRequestHeader=()=>{};
  this.send=()=>{
    let r = {ok:true};
    if(this._u.indexOf('/api/state')===0) r=STATE;
    if(this._u.indexOf('/api/domains')===0) r={content:'example.com\n'};
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

const group = d.getElementById('navgroup-settings');
const btn   = d.getElementById('btn-settings-group');

console.log('\n=== structure ===');
console.log('  Settings group has a toggle button: '+!!btn);
const docsLink = d.querySelector('.navitem[data-view="docs"]');
console.log('  Docs is OUTSIDE the settings group: '+ !group.contains(docsLink));
console.log('  Docs group has a divider rule: '+ docsLink.closest('.navgroup').classList.contains('navgroup-divided'));
const settingsItems = group.querySelectorAll('.navitem[data-view="settings"]');
console.log('  settings items inside the group: '+settingsItems.length+' (expect 5)');

w.CertCamel.loadState(function(){
  w.CertCamel.navigate();

  console.log('\n=== collapse toggling ===');
  console.log('  starts expanded: '+ !group.classList.contains('collapsed'));
  btn.click();
  console.log('  after click, collapsed: '+ group.classList.contains('collapsed'));
  console.log('  aria-expanded: '+ btn.getAttribute('aria-expanded'));
  console.log('  persisted: '+ store['certcamel-navgroup-settings-collapsed']);
  btn.click();
  console.log('  after 2nd click, expanded again: '+ !group.classList.contains('collapsed'));

  console.log('\n=== the important one: collapse must never hide the active page ===');
  btn.click();                                  // collapse it
  console.log('  collapsed before navigating: '+ group.classList.contains('collapsed'));
  goto(w, '#/settings/alerts');                 // deep-link into a settings page
  console.log('  auto-expanded on landing there: '+ !group.classList.contains('collapsed'));
  const active = group.querySelector('.navitem[aria-current="page"]');
  console.log('  active item is visible + marked: '+ (active ? active.getAttribute('data-sub') : 'NONE'));

  console.log('\n=== navigating away leaves it expanded (user can re-collapse) ===');
  goto(w, '#/home');
  console.log('  still expanded: '+ !group.classList.contains('collapsed'));

  console.log('\n=== editor sizing ===');
  goto(w, '#/certificates');
  const editBtn = Array.from(d.querySelectorAll('#view-certificates button')).find(b=>b.textContent==='Edit domains');
  editBtn.click();
  const ta = d.querySelector('textarea.domains-text');
  console.log('  textarea has no inline rows/size overriding CSS: rows='+ta.getAttribute('rows'));
  console.log('  no inline font-size left behind: '+ (ta.style.fontSize === ''));
  console.log('  card is .wide (full width): '+ ta.closest('.card').classList.contains('wide'));

  console.log('\nall errors: '+(errors.length?errors.join('\n'):'none'));
});
