// Home layout + Automation. Run with TZ=America/New_York so the UTC->local
// conversion is assertable: renewAfter is stored as a UTC instant, and showing
// 12:48 rather than 8:48 would be the whole point missed.
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
  certs: [
    { certId:'camelnuggets.com', displayName:'camelnuggets.com', kind:'san', zone:'camelnuggets.com',
      names:['www.camelnuggets.com'], hosts:[], deferredNames:[], categories:[], wildcard:false,
      external:false, targets:[], caId:'letsencrypt', caLabel:'LE', caStaging:false, caInherited:true,
      overridden:false, notAfter:day(80), hasLocalCert:true, issuedAt:day(-10) },
    { certId:'wildcard.camelnuggets.com', displayName:'*.camelnuggets.com', kind:'wildcard',
      zone:'camelnuggets.com', names:['*.camelnuggets.com'], hosts:[], deferredNames:[], categories:[],
      wildcard:true, external:false, targets:[], caId:'letsencrypt', caLabel:'LE', caStaging:false,
      caInherited:true, overridden:false, notAfter:day(60), hasLocalCert:true, issuedAt:day(-30) }
  ],
  unmapped: [], haveZones: true, groupError: null,
  zones: { refreshed:new Date().toISOString(), count:1, errors:[] },
  deployment: {
    'camelnuggets.com': { targets:['t1'], bindings:[{id:'t1',overrides:null}], last:{ at: day(-0.3), ok:true } },
    'wildcard.camelnuggets.com': { targets:[], bindings:[], last:{ at: day(-0.5), ok:true } }
  },
  settings: { contact:'me@x.com', defaultCaId:'letsencrypt',
    cas:[{id:'letsencrypt', label:'LE', directoryUrl:'x', stagingUrl:'y', useStaging:false, eabKid:'', eabHmacSet:false}],
    providers:[], targets:[{id:'t1', label:'Haproxy-Home-Lab', type:'haproxy', nodes:[{name:'lb1',url:'u'},{name:'lb2',url:'u'}], args:{}}],
    logs:{retentionDays:90, maxSizeMb:200},
    alerts:{ smtp:{host:'',port:587,encryption:'starttls',from:'',to:[],authRequired:false,username:'',passwordSet:false},
             expiry:{enabled:false,thresholds:[30,14,7]}, renewalSuccess:{enabled:false},
             deploymentFailure:{enabled:false}, monthlySummary:{enabled:false} } },
  catalog: {}, targetCatalog: {}, acmeReady: true
};
const SSL_DATA = { generated: new Date().toISOString(), results: [
  { host:'www.camelnuggets.com', ok:true, notAfter:day(80), issuer:'LE', category:'Prod', renewOnly:false },
  { host:'lbtest.camelnuggets.com', ok:true, notAfter:day(60), issuer:'LE', category:'Prod', renewOnly:false }
]};

function task(o){
  return Object.assign({
    key:'renew', name:'Cert Camel Renew', label:'Renew and deploy',
    level:'Issues certificates and pushes them to load balancers', detail:'…',
    registered:true, enabled:true, state:'ready',
    nextRun:day(0.4), lastRun:day(-0.6), lastResult:0,
    schedule:'2026-07-31T03:20:00-04:00', triggerType:'daily', pathMatches:true,
    commandPath:'C:\\Users\\ULTRA\\certcamel-v2\\renew-due.ps1'
  }, o);
}
const CHECK  = task({key:'check', name:'SSL Cert Check', label:'Expiry check', level:'Read-only',
                     schedule:'2026-07-31T09:00:00-04:00', commandPath:'C:\\Users\\ULTRA\\certcamel-v2\\check-ssl.ps1'});
const REPORT = task({key:'report', name:'Cert Camel Monthly Report', label:'Monthly summary email',
                     level:'Read-only', registered:false, enabled:false, state:'not registered',
                     nextRun:null, schedule:null, commandPath:null});
// A boot trigger carries a StartBoundary too - the moment it was registered - so
// this is the case that would otherwise render as "daily 3:47 PM".
const SERVER = task({key:'server', name:'Cert Camel Server', label:'Web page',
                     level:'Read-only', triggerType:'boot',
                     schedule:'2026-08-06T15:47:00-04:00',
                     commandPath:'C:\Users\ULTRA\certcamel-v2\serve.ps1'});

let AUTOMATION = { available:true, error:null, tasks:[task({}), CHECK, REPORT, SERVER] };
let FORECAST = {
  ok:true, mode:'run', startedAt:day(-0.5), finishedAt:day(-0.5), error:null, renewed:[],
  considered:[
    { certId:'camelnuggets.com', name:'camelnuggets.com', due:false, reason:null, renewAfter:'2026-10-04T12:48:53Z' },
    { certId:'wildcard.camelnuggets.com', name:'*.camelnuggets.com', due:false, reason:null, renewAfter:'2026-10-03T17:13:05Z' }
  ]
};

const calls = [];
function XHR(){
  this.readyState=0; this.status=0; this.responseText='';
  this.open=(m,u)=>{this._m=m;this._u=u;};
  this.setRequestHeader=()=>{};
  this.send=(b)=>{
    calls.push(this._m+' '+this._u);
    let r={ok:true, jobId:'fc1234fc1234'};
    if(this._u.indexOf('/api/state')===0) r=STATE;
    else if(this._u.indexOf('/api/automation')===0) r={automation:AUTOMATION, forecast:FORECAST, folder:'C:\\Users\\ULTRA\\certcamel-v2'};
    else if(this._u.indexOf('/api/job/')===0) r={id:'fc1234fc1234', kind:'forecast', running:false, log:'…', result:null};
    this.status=200; this.readyState=4; this.responseText=JSON.stringify(r);
    if(this.onreadystatechange)this.onreadystatechange();
  };
}
function goto(w,h){ w.location.hash=h; w.dispatchEvent(new w.Event('hashchange')); }
const txt = n => n ? n.textContent.replace(/\s+/g,' ').trim() : '(missing)';
// Selected by LABEL, never by position - the tile arrives from a fetch and the
// point of the placeholder is that its slot is fixed regardless.
function autoTile(){
  return Array.from(d.querySelectorAll('#view-home .pills .pill'))
    .find(p => txt(p.querySelector('.k')) === 'Automation Scripts');
}
function tileVal(){ const t=autoTile(); return t ? txt(t.querySelector('.val')) : '(no tile)'; }
function tileSub(){ const t=autoTile(); const s=t&&t.querySelector('.sub'); return s ? txt(s) :
  (t ? Array.from(t.querySelectorAll('.svc')).map(r=>txt(r.querySelector('.n'))+' '+txt(r.querySelector('.v'))).join('; ') : '(no tile)'); }

const errors=[]; const vc=new VirtualConsole();
vc.on('jsdomError', e=>errors.push(e.detail?e.detail.stack:e.message));
const dom=new JSDOM(html,{url:'http://127.0.0.1:1/?t=abc',runScripts:'outside-only',pretendToBeVisual:true,virtualConsole:vc});
const w=dom.window,d=dom.window.document;
w.SSL_DATA=SSL_DATA; w.XMLHttpRequest=XHR;
const store={};
Object.defineProperty(w,'localStorage',{value:{getItem:k=>store[k]||null,setItem:(k,v)=>store[k]=v,removeItem:k=>delete store[k]},configurable:true});
try { scripts.forEach(s=>w.eval(s)); } catch(e){ errors.push('LOAD THREW: '+e.message); }
console.log('load errors: '+(errors.length?errors.join('\n'):'none'));
console.log('process TZ: '+(process.env.TZ||'(inherited)'));

const home = () => d.getElementById('view-home');
function cardNamed(name){
  return Array.from(home().querySelectorAll('.card'))
    .find(c => { const h=c.querySelector('h4'); return h && h.textContent===name; });
}

w.CertCamel.loadState(function(){
  w.CertCamel.navigate();
  goto(w, '#/');

  console.log('\n=== four tiles in one row, Automation last ===');
  Array.from(home().querySelectorAll('.pills .pill')).forEach(function(p){
    var sub = p.querySelector('.sub');
    console.log('  [' + txt(p.querySelector('.k')).padEnd(11) + '] ' +
                txt(p.querySelector('.val')).padEnd(11) + '| ' + (sub ? txt(sub) : '(service list)'));
  });

  console.log('\n=== the tile lists services and times, with no dangling verb ===');
  Array.from(autoTile().querySelectorAll('.svc')).forEach(function(r){
    console.log('  ' + txt(r.querySelector('.n')).padEnd(24) + txt(r.querySelector('.v')));
  });
  // Every prose attempt left "checks"/"runs" without an object, which read as
  // though the SERVICES were being checked. A name and a time cannot be misread.
  console.log('  no dangling verb in the tile: ' + !/\b(checks|runs)\b/i.test(txt(autoTile())));
  console.log('  all four services listed: ' + (autoTile().querySelectorAll('.svc').length === 4));
  // The whole point of triggerType: a boot task must not claim a daily time.
  const svcRows = Array.from(autoTile().querySelectorAll('.svc'))
    .map(r => txt(r.querySelector('.n')) + ' = ' + txt(r.querySelector('.v')));
  const boot = svcRows.find(r => /^Web page /.test(r));
  console.log('  boot task reads: ' + boot);
  // The label used to end in "at startup" too, so the row said it twice.
  console.log('  says it once, not twice: ' + ((boot.match(/at startup/g) || []).length === 1));
  console.log('  says "at startup", not a daily time: ' + /at startup/.test(boot) + ', ' + !/daily/.test(boot));

  console.log('\n=== two cards side by side, schedule first ===');
  const row = home().querySelector('.cardrow');
  console.log('  cards in the row: ' + Array.from(row.querySelectorAll(':scope > .card h4')).map(h=>h.textContent).join(' | '));
  console.log('  no inline width on Recently deployed: ' + !cardNamed('Recently deployed').getAttribute('style'));

  console.log('\n=== full local date AND time, zone labelled (UTC 12:48:53Z -> EDT) ===');
  Array.from(cardNamed('Automated renewals scheduled').querySelectorAll('.renewal')).forEach(function(b){
    console.log('  ' + txt(b.querySelector('.n')));
    console.log('     ' + txt(b.querySelector('.d') || b.querySelector('.w')));
    const tail = b.querySelector('.g') || b.querySelectorAll('.w')[b.querySelectorAll('.w').length-1];
    console.log('     ' + txt(tail));
  });
  const first = txt(cardNamed('Automated renewals scheduled').querySelector('.renewal .d'));
  console.log('  converted from UTC (1:13 PM, not 17:13): ' + /1:13\s*PM/.test(first));
  console.log('  names a zone: ' + /E[DS]T/.test(first));

  console.log('\n=== "will not deploy" survives the redesign ===');
  console.log('  ' + (Array.from(cardNamed('Automated renewals scheduled').querySelectorAll('.renewal .w')).map(txt)
                        .find(t=>/not deploy/.test(t)) || 'NOT FLAGGED'));

  console.log('\n=== the service list lives in the tile only, not duplicated ===');
  const dupe = Array.from(cardNamed('Automated renewals scheduled').querySelectorAll('p.mini'))
                 .map(txt).find(t=>/Expiry check/.test(t));
  console.log('  card no longer repeats it: ' + !dupe);
  console.log('  tile still has it: ' + Array.from(autoTile().querySelectorAll('.svc .n'))
                 .map(txt).includes('Expiry check'));

  console.log('\n=== fresh forecast: no button anywhere on Home ===');
  console.log('  buttons: ' + (Array.from(home().querySelectorAll('button')).map(b=>b.textContent).join(', ') || '(none)'));

  console.log('\n=== stale forecast brings the button back ===');
  FORECAST = Object.assign({}, FORECAST, {finishedAt: day(-3)});
  w.CertCamel.loadState(function(){
    console.log('  buttons: ' + Array.from(home().querySelectorAll('button')).map(b=>b.textContent).join(', '));

    console.log('\n=== no forecast at all ===');
    FORECAST = null;
    w.CertCamel.loadState(function(){
      const c = cardNamed('Automated renewals scheduled');
      console.log('  ' + txt(c.querySelector('p.mini')));
      console.log('  button: ' + Array.from(c.querySelectorAll('button')).map(b=>b.textContent).join(', '));

      console.log('\n=== warnings now live in the alerts area, above the cards ===');
      FORECAST = {ok:true, mode:'run', finishedAt:day(-0.2), considered:[], renewed:[]};
      AUTOMATION = {available:true, error:null, tasks:[
        task({enabled:false, state:'disabled'}),
        task({key:'check', name:'SSL Cert Check', label:'Expiry check', pathMatches:false,
              commandPath:'D:\\old-copy\\check-ssl.ps1', schedule:'2026-07-31T09:00:00-04:00'})
      ]};
      w.CertCamel.loadState(function(){
        Array.from(home().querySelectorAll('.callout')).forEach(function(c){
          console.log('  [' + c.className.replace('callout ','') + '] ' + txt(c.querySelector('.h')));
        });
        console.log('  tile reads: ' + tileVal() + ' — ' + tileSub());
        console.log('  alerts sit above the card row: ' +
          (!!home().querySelector('.callout') &&
           home().querySelector('.callout').compareDocumentPosition(home().querySelector('.cardrow')) === 4));

        console.log('\n=== scheduler unreadable is still not "Off" ===');
        AUTOMATION = {available:false, error:'The RPC server is unavailable.', tasks:[]};
        w.CertCamel.loadState(function(){
          console.log('  tile: ' + tileVal() + ' — ' + tileSub());
          console.log('  alert: ' + txt(home().querySelector('.callout .h')));
          console.log('  says "off" anywhere: ' + /\boff\b/i.test(home().textContent));

          console.log('\n=== not set up ===');
          AUTOMATION = {available:true, error:null, tasks:[task({registered:false, enabled:false, state:'not registered', schedule:null, nextRun:null})]};
          w.CertCamel.loadState(function(){
            console.log('  tile: ' + tileVal() + ' — ' + tileSub());
            console.log('  alert: ' + txt(home().querySelector('.callout .h')));
            console.log('\nall errors: '+(errors.length?errors.join('\n'):'none'));
          });
        });
      });
    });
  });
});
