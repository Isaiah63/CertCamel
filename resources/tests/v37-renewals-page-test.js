// The renewals page: search and a "how soon" window over the forecast, and a
// home card that summarises instead of listing everything.
//
// The card used to render one block per considered certificate with no cap,
// filter or search. Four looked fine; fifty is a wall on the page whose job is
// to say whether anything is about to happen. The detail moved to #/renewals.
//
// The case worth guarding is the certificate with NO renewal date. It must stay
// visible under "All" - the absence is the point - and must NOT be swept into a
// narrow window, because it might be due tomorrow or in a year and claiming
// either would be inventing a fact.
const fs = require('fs');
const { JSDOM, VirtualConsole } = require('jsdom');

const ROOT = require('path').join(__dirname, '..') + require('path').sep;
const html = fs.readFileSync(ROOT + 'ssl-tracker.html', 'utf8');
const scripts = ['assets\\app.js', 'assets\\views\\home.js', 'assets\\views\\certificates.js',
                 'assets\\views\\renewals.js', 'assets\\views\\settings.js', 'assets\\views\\docs.js']
  .map(p => fs.readFileSync(ROOT + p, 'utf8'));

const day = n => new Date(Date.now() + n * 864e5).toISOString();
function cert(id, names){
  return { certId:id, displayName:id, kind:'san', zone:id, providerId:'p1', providerLabel:'CF',
    plugin:'Cloudflare', hosts:[], names:names || [id], deferredNames:[], categories:[], wildcard:false,
    external:false, targets:['office'], caId:'letsencrypt', caLabel:'LE', caStaging:true,
    caInherited:true, overridden:false, notAfter:day(40), hasLocalCert:true, issuedAt:day(-50) };
}

// Issued AFTER the forecast finished, which is the case that made three real
// certificates read as though their expiry could not be found.
function fresh(id){
  var c = cert(id);
  c.issuedAt = new Date(Date.now() + 60000).toISOString();
  return c;
}

const STATE = {
  generated:new Date().toISOString(),
  certs:[ cert('soon.example.com'), cert('later.example.com'),
          cert('nodate.example.com', ['nodate.example.com','alias.example.com']),
          fresh('justissued.example.com') ],
  unmapped:[], haveZones:true, groupError:null,
  zones:{refreshed:new Date().toISOString(),count:1,errors:[]},
  deployment:{},
  forecastState:{ recordedAt:new Date().toISOString(), hosts:[] },
  settings:{ contact:'me@x.com', defaultCaId:'letsencrypt',
    cas:[{id:'letsencrypt',label:'LE',directoryUrl:'x',stagingUrl:'y',useStaging:true,eabKid:'',eabHmacSet:false}],
    providers:[], targets:[{id:'office',label:'Office',type:'haproxy-dataplane',
      nodes:[{name:'lb1',url:'http://127.0.0.1:1',verifyHost:''}], args:{}}],
    alerts:{ smtp:{host:'',port:587,encryption:'starttls',from:'',to:[],authRequired:false,username:'',passwordSet:false},
             expiry:{enabled:false,thresholds:[30]}, renewalSuccess:{enabled:false},
             deploymentFailure:{enabled:false}, monthlySummary:{enabled:false} } },
  catalog:{}, targetCatalog:{}, acmeReady:true
};

// Three certificates, deliberately spread across the windows being tested.
const AUTOMATION = {
  automation:{ enabled:true, tasks:[
    {kind:'renew', registered:true, enabled:true, schedule:'daily', nextRun:day(0.2)} ] },
  forecast:{ finishedAt:new Date().toISOString(), mode:'scheduled', considered:[
    {certId:'soon.example.com',   name:'soon.example.com',   due:false, renewAfter:day(0.5)},
    {certId:'later.example.com',  name:'later.example.com',  due:false, renewAfter:day(45)},
    {certId:'nodate.example.com', name:'nodate.example.com', due:false, renewAfter:null},
    {certId:'justissued.example.com', name:'justissued.example.com', due:false, renewAfter:null}
  ]}
};

const calls = [];
function XHR(){
  this.readyState=0; this.status=0; this.responseText='';
  this.open=(m,u)=>{this._m=m;this._u=u;}; this.setRequestHeader=()=>{};
  this.send=(b)=>{
    calls.push(this._m+' '+this._u+(b?' '+b:''));
    let r={ok:true, jobId:'abc123abc123'};
    if(this._u.indexOf('/api/state')===0) r=STATE;
    if(this._u.indexOf('/api/automation')===0) r=AUTOMATION;
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

let failed = 0;
function check(name, ok, detail){
  if (ok) { console.log('  ok   ' + name); }
  else { console.log('  FAIL ' + name + '  -- ' + detail); failed++; }
}
const rows  = () => Array.from(d.querySelectorAll('#renew-list .renewal'));
const names = () => rows().map(r => r.querySelector('.n').textContent);
const tally = () => (d.getElementById('renew-tally') || {}).textContent;

function setWindow(v){
  const s = d.getElementById('renew-window');
  s.value = v;
  s.dispatchEvent(new w.Event('change'));
}
function search(v){
  const s = d.getElementById('renew-search');
  s.value = v;
  s.dispatchEvent(new w.Event('input'));
}

w.CertCamel.loadState(function(){
  w.CertCamel.navigate();

  console.log('\nthe home card summarises rather than lists');
  const card = Array.from(d.querySelectorAll('#view-home .card')).filter(
    c => /Automated renewals/i.test(c.textContent))[0];
  check('the card is there', !!card, 'no renewals card on Home');
  check('it does NOT list every certificate',
        card.querySelectorAll('.renewal').length === 0,
        card.querySelectorAll('.renewal').length + ' blocks still rendered');
  check('it names the next one', /soon\.example\.com/.test(card.textContent), card.textContent);
  check('and counts the ones with no date',
        /2 with no date yet/.test(card.textContent), card.textContent);
  const more = Array.from(card.querySelectorAll('button')).filter(
    b => /See all renewals/.test(b.textContent))[0];
  check('there is a way through to the detail', !!more, 'no button');

  console.log('\nand the button goes to the page');
  more.click();
  // jsdom does not always fire hashchange off an assignment, so nudge it the
  // way the other view tests do.
  w.dispatchEvent(new w.Event('hashchange'));
  check('navigated', w.location.hash === '#/renewals', 'hash is ' + w.location.hash);
  check('the view is showing',
        !d.getElementById('view-renewals').classList.contains('hidden'), 'still hidden');

  console.log('\nevery considered certificate is listed by default');
  check('four rows', rows().length === 4, names().join(' | '));
  check('soonest first', names()[0] === 'soon.example.com', names().join(' | '));
  check('the undated ones sort last',
        names().slice(2).sort().join() === 'justissued.example.com,nodate.example.com',
        names().join(' | '));
  check('tally counts them', tally() === '4 of 4', tally());

  console.log('\nthe window filters by how soon it is due');
  setWindow('1');
  check('next 24 hours keeps only the imminent one',
        names().length === 1 && names()[0] === 'soon.example.com', names().join(' | '));
  check('an undated certificate is NOT claimed to be due',
        names().indexOf('nodate.example.com') === -1, names().join(' | '));
  check('tally says how much is hidden', tally() === '1 of 4', tally());

  setWindow('90');
  check('three months reaches the 45-day one',
        names().indexOf('later.example.com') !== -1, names().join(' | '));
  check('but still not the undated one',
        names().indexOf('nodate.example.com') === -1, names().join(' | '));

  setWindow('all');
  check('All brings the undated one back',
        names().indexOf('nodate.example.com') !== -1, names().join(' | '));

  console.log('\na date missing because the forecast predates the certificate');
  /* The forecast is not wrong there - it simply ran first. Saying only
     "Renewal date not known yet" reads as a failure to read the expiry, which
     is what three real certificates looked like after being issued three hours
     after a sweep. */
  function rowFor(name){
    return rows().filter(function(r){ return r.querySelector('.n').textContent === name; })[0];
  }
  check('says the forecast predates it, not that the date is unknowable',
        /issued since this forecast ran/i.test(rowFor('justissued.example.com').textContent),
        rowFor('justissued.example.com').textContent);
  check('a genuinely undated one still says so plainly',
        /Renewal date not known yet/.test(rowFor('nodate.example.com').textContent),
        rowFor('nodate.example.com').textContent);
  check('and the fix is on the page', !!d.getElementById('renew-refresh'), 'no refresh button');

  console.log('\nsearch covers names and the domains they carry');
  search('later');
  check('matches the certificate name', names().join() === 'later.example.com', names().join(' | '));
  search('alias.example.com');
  check('matches a covered domain the row does not print',
        names().join() === 'nodate.example.com', names().join(' | '));
  search('nothing-like-this');
  check('no matches says so', rows().length === 0 && /Nothing matches/.test(
        d.getElementById('renew-list').textContent), d.getElementById('renew-list').textContent);
  search('');
  check('clearing it restores everything', rows().length === 4, names().join(' | '));

  console.log('\nsearch and window combine rather than override');
  setWindow('1');
  search('later');
  check('a match outside the window still stays hidden', rows().length === 0, names().join(' | '));

  console.log('\nload errors: ' + (errors.length ? errors.join('\n') : 'none'));
  if (failed) { console.log('\n' + failed + ' CHECK(S) FAILED'); process.exit(1); }
  console.log('\nall checks passed');
});
