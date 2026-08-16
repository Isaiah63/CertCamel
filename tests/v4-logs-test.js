// The Logs view: audit tab, event filter, run list, opening a run, and the
// thing most likely to actually annoy someone - a background state refresh
// throwing away the log they were part-way through reading.
const fs = require('fs');
const { JSDOM, VirtualConsole } = require('jsdom');

const ROOT = require('path').join(__dirname, '..') + require('path').sep;
const html = fs.readFileSync(ROOT + 'ssl-tracker.html', 'utf8');
const scripts = ['assets\\app.js', 'assets\\views\\home.js', 'assets\\views\\certificates.js',
                 'assets\\views\\settings.js', 'assets\\views\\logs.js', 'assets\\views\\docs.js']
  .map(p => fs.readFileSync(ROOT + p, 'utf8'));

const day = n => new Date(Date.now() + n * 864e5).toISOString();
const STATE = {
  generated: new Date().toISOString(),
  certs: [], unmapped: [], haveZones: true, groupError: null,
  zones: { refreshed:new Date().toISOString(), count:1, errors:[] },
  deployment: {},
  logs: { retentionDays: 45, maxSizeMb: 150 },
  settings: { contact:'me@x.com', defaultCaId:'letsencrypt',
    cas:[{id:'letsencrypt', label:'LE', directoryUrl:'x', stagingUrl:'y', useStaging:true, eabKid:'', eabHmacSet:false}],
    providers:[], targets:[],
    logs: { retentionDays: 45, maxSizeMb: 150 },
    alerts:{ smtp:{host:'',port:587,encryption:'starttls',from:'',to:[],authRequired:false,username:'',passwordSet:false},
             expiry:{enabled:false,thresholds:[30,14,7]}, renewalSuccess:{enabled:false},
             deploymentFailure:{enabled:false}, monthlySummary:{enabled:false} } },
  catalog: {}, targetCatalog: {}, acmeReady: true
};

const AUDIT = [
  '2026-08-05T09:00:00Z  ULTRA  task  check     -                  ok    12 certificates checked',
  '2026-08-05T09:47:25Z  ULTRA  task  renew     camelnuggets.com   ok    issued serial 05B3DC, expires 2026-11-03',
  '2026-08-05T09:47:27Z  ULTRA  task  deploy    camelnuggets.com   ok    lb1 serving, lb2 serving',
  '2026-08-05T10:02:11Z  ULTRA  ui    settings  -                  ok    general, logs'
];
const LOGS = {
  retention: { retentionDays: 45, maxSizeMb: 150 },
  totalBytes: 3 * 1048576,
  audit: { lines: AUDIT.length, archives: [{ name: 'audit-20260701-000000.log', bytes: 5242880 }] },
  runs: [
    { name: '2026-08-05T094500Z-renew.log', kind: 'renew', at: day(-0.1), bytes: 8192 },
    { name: '2026-08-05T090000Z-check.log', kind: 'check', at: day(-0.2), bytes: 4096 }
  ]
};

const calls = [];
function XHR(){
  this.readyState=0; this.status=0; this.responseText='';
  this.open=(m,u)=>{this._m=m;this._u=u;};
  this.setRequestHeader=()=>{};
  this.send=(b)=>{
    calls.push(this._m+' '+this._u+(b?' '+b:''));
    let r={ok:true};
    const u=this._u;
    if(u.indexOf('/api/state')===0) r=STATE;
    else if(u.indexOf('/api/logs/audit')===0){
      const m=/[?&]event=([^&]*)/.exec(u);
      const want=m?decodeURIComponent(m[1]):'';
      const lines=want?AUDIT.filter(l=>l.indexOf('  '+want)!==-1):AUDIT;
      r={lines:lines, truncated:false};
    }
    else if(u.indexOf('/api/logs/run/')===0) r={content:'T0 bundle valid\nT1 API accepted\nT3 serving on lb1\n'};
    else if(u.indexOf('/api/logs')===0) r=LOGS;
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
try { scripts.forEach(s=>w.eval(s)); } catch(e){ errors.push('LOAD THREW: '+e.message); }
console.log('load errors: '+(errors.length?errors.join('\n'):'none'));

w.CertCamel.loadState(function(){
  w.CertCamel.navigate();

  console.log('\n=== the sidebar entry exists and owns the route ===');
  const nav = d.querySelector('.sidebar .navitem[data-view="logs"]');
  console.log('  Logs nav item: '+txt(nav && nav.querySelector('.navlabel'))+'  href='+(nav&&nav.getAttribute('href')));
  console.log('  container present: '+!!d.getElementById('view-logs'));

  goto(w, '#/logs');
  const host = d.getElementById('view-logs');
  console.log('  view shown: '+!host.classList.contains('hidden'));
  console.log('  nav marked current: '+(nav.getAttribute('aria-current')==='page'));

  console.log('\n=== audit tab is the default and reads newest-first ===');
  const tabs = Array.from(host.querySelectorAll('.subnav a')).map(a=>a.textContent+(a.getAttribute('aria-current')==='page'?'*':''));
  console.log('  tabs: '+tabs.join(' | '));
  let pre = host.querySelector('pre.log');
  const first = pre.textContent.split('\n')[0];
  console.log('  first line on screen is the newest: '+(first.indexOf('10:02:11')!==-1));
  console.log('  all four entries rendered: '+(pre.textContent.split('\n').length===4));

  console.log('\n=== read-only: nothing on this page can write ===');
  console.log('  textareas: '+host.querySelectorAll('textarea').length+
              ', inputs: '+host.querySelectorAll('input').length+
              ', contenteditable: '+host.querySelectorAll('[contenteditable]').length);
  const writes = calls.filter(c=>c.indexOf('POST')===0||c.indexOf('PUT')===0||c.indexOf('DELETE')===0);
  console.log('  write requests made by the logs view: '+writes.length);

  console.log('\n=== retention note states the real settings ===');
  const note = Array.from(host.querySelectorAll('p.mini')).find(p=>p.textContent.indexOf('keeping')!==-1);
  console.log('  '+txt(note));

  console.log('\n=== archives are listed, not silently dropped ===');
  const arch = Array.from(host.querySelectorAll('p.mini')).find(p=>p.textContent.indexOf('rotated out')!==-1);
  console.log('  '+txt(arch));

  console.log('\n=== the event filter narrows the request, not just the display ===');
  const sel = host.querySelector('select');
  sel.value = 'renew';
  sel.dispatchEvent(new w.Event('change'));
  console.log('  requested: '+calls[calls.length-1]);
  pre = host.querySelector('pre.log');
  console.log('  showing only renewals: '+(pre.textContent.split('\n').length===1 && pre.textContent.indexOf('renew')!==-1));
  console.log('  filter survived its own re-render: '+(host.querySelector('select').value==='renew'));

  console.log('\n=== run logs tab ===');
  goto(w, '#/logs/runs');
  const rows = host.querySelectorAll('tbody tr');
  console.log('  runs listed: '+rows.length+'  ('+Array.from(rows).map(r=>r.cells[1].textContent).join(', ')+')');
  console.log('  sizes shown: '+Array.from(rows).map(r=>r.cells[2].textContent).join(', '));

  const view = rows[0].querySelector('button');
  console.log('  action label: '+txt(view));
  view.click();
  console.log('  fetched: '+calls[calls.length-1]);
  const runPre = host.querySelector('pre.log');
  console.log('  content shown: '+JSON.stringify(runPre.textContent.slice(0,20))+'...');
  console.log('  button now says: '+txt(host.querySelectorAll('tbody tr')[0].querySelector('button')));

  console.log('\n=== a background refresh must not close what is being read ===');
  w.CertCamel.loadState(function(){
    const stillTab = Array.from(host.querySelectorAll('.subnav a')).find(a=>a.getAttribute('aria-current')==='page');
    console.log('  still on tab: '+txt(stillTab));
    const stillOpen = host.querySelector('pre.log');
    console.log('  run still open: '+(!!stillOpen && stillOpen.textContent.indexOf('T3 serving')!==-1));

    console.log('\n=== hiding it again ===');
    host.querySelectorAll('tbody tr')[0].querySelector('button').click();
    console.log('  viewer closed: '+!host.querySelector('pre.log'));

    console.log('\n=== the retention settings round-trip through Settings -> General ===');
    goto(w, '#/settings/general');
    const days = d.getElementById('set-log-days'), mb = d.getElementById('set-log-mb');
    console.log('  populated from state: '+days.value+' days, '+mb.value+' MB');
    days.value = '30'; mb.value = '64';
    const before = calls.length;
    const save = Array.from(d.querySelectorAll('#view-settings button')).find(b=>/^Save/.test(b.textContent));
    save.click();
    const post = calls.slice(before).find(c=>c.indexOf('POST /api/settings')===0);
    const body = post ? JSON.parse(post.slice(post.indexOf('{'))) : {};
    console.log('  payload carries logs: '+JSON.stringify(body.logs));

    console.log('\n=== and it refuses nonsense rather than saving it ===');
    d.getElementById('set-log-days').value = '0';
    const n2 = calls.length;
    Array.from(d.querySelectorAll('#view-settings button')).find(b=>/^Save/.test(b.textContent)).click();
    console.log('  save suppressed: '+!calls.slice(n2).some(c=>c.indexOf('POST /api/settings')===0));
    console.log('  message: '+txt(d.getElementById('set-status')));

    console.log('\nall errors: '+(errors.length?errors.join('\n'):'none'));
  });
});
