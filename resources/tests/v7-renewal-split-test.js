// The amber/blue split. A certificate Cert Camel renews on its own must not be
// counted as needing attention: not in the tiles, not in the callout, not in the
// group header. Amber is reserved for the ones somebody actually has to act on -
// renewed elsewhere, or in a zone no DNS provider covers.
//
// Also covers two things on the Certificates page: the console certificate's
// Renew button, which must NOT open the deployment picker because that
// certificate deploys nowhere by design; and reaching assignment from the row
// menu rather than only by clicking a status cell nothing advertises.
const fs = require('fs');
const { JSDOM, VirtualConsole } = require('jsdom');

const ROOT = require('path').join(__dirname, '..') + require('path').sep;
const html = fs.readFileSync(ROOT + 'ssl-tracker.html', 'utf8');
const scripts = ['assets\\app.js', 'assets\\views\\home.js', 'assets\\views\\certificates.js',
                 'assets\\views\\settings.js', 'assets\\views\\logs.js', 'assets\\views\\docs.js',
                 'assets\\views\\loadbalancers.js']
  .map(p => fs.readFileSync(ROOT + p, 'utf8'));

const iso = d => new Date(Date.now() + d * 86400000).toISOString();

// Two categories, so the group header can be checked on a group that is entirely
// automated and one that is entirely manual.
const SSL_DATA = {
  generated: new Date().toISOString(),
  results: [
    { host:'auto1.example.com', ok:true, notAfter: iso(10), category:'Automated' },
    { host:'auto2.example.com', ok:true, notAfter: iso(12), category:'Automated' },
    { host:'elsewhere.example.com', ok:true, notAfter: iso(8),  category:'Manual' },
    { host:'nodns.example.com', ok:true, notAfter: iso(5),  category:'Manual' },
    { host:'fine.example.com',  ok:true, notAfter: iso(200), category:'Manual' }
  ]
};

const CERTS = [
  // Renewed here, and the forecast has a window for it -> scheduled, blue.
  { certId:'example.com', displayName:'example.com', zone:'example.com', external:false,
    hosts:['auto1.example.com','auto2.example.com'], names:['auto1.example.com','auto2.example.com'],
    caLabel:"Let's Encrypt", caStaging:false, targets:['prod'], hasLocalCert:true, tracker:false },
  // Marked managed elsewhere -> the countdown is the only thing that will ever
  // tell you, so it stays amber however close it is.
  { certId:'elsewhere.example.com', displayName:'elsewhere.example.com', zone:'elsewhere.example.com',
    external:true, hosts:['elsewhere.example.com'], names:['elsewhere.example.com'],
    caLabel:"Let's Encrypt", caStaging:false, targets:[], hasLocalCert:false, tracker:false },
  // Renewable in principle, but absent from the forecast - no provider covers
  // its zone. Also amber.
  { certId:'nodns.example.com', displayName:'nodns.example.com', zone:'nodns.example.com',
    external:false, hosts:['nodns.example.com'], names:['nodns.example.com'],
    caLabel:"Let's Encrypt", caStaging:false, targets:[], hasLocalCert:true, tracker:false },
  // The console's own certificate.
  { certId:'tracker.example.test', displayName:'tracker.example.test', zone:'example.test',
    external:false, hosts:['tracker.example.test'], names:['tracker.example.test'],
    caLabel:"Let's Encrypt", caStaging:false, targets:[], hasLocalCert:true, tracker:true,
    notAfter: iso(60) }
];

const STATE = {
  generated: new Date().toISOString(),
  certs: CERTS, unmapped: [], haveZones: true, groupError: null,
  zones: { refreshed: new Date().toISOString(), count: 1, errors: [] },
  deployment: {}, logs: { retentionDays: 45, maxSizeMb: 150 },
  settings: { contact:'me@x.com', defaultCaId:'letsencrypt', cas:[], providers:[],
    targets:[{ id:'prod', label:'Prod pair', nodes:[] }],
    logs:{ retentionDays:45, maxSizeMb:150 },
    alerts:{ smtp:{host:'',port:587,encryption:'starttls',from:'',to:[],authRequired:false,username:'',passwordSet:false},
             expiry:{enabled:false,thresholds:[30]}, renewalSuccess:{enabled:false},
             deploymentFailure:{enabled:false}, monthlySummary:{enabled:false} } },
  catalog:{}, targetCatalog:{}, acmeReady:true
};

// Only example.com has a renewal window. nodns is deliberately absent.
const AUTOMATION = {
  tasks: [], scheduler: { ok: true },
  forecast: {
    finishedAt: new Date().toISOString(),
    considered: [{ certId:'example.com', renewAfter: iso(4) }]
  }
};

const sent = [];
function XHR(){
  this.readyState=0; this.status=0; this.responseText='';
  this.open=(m,u)=>{this._m=m;this._u=u;};
  this.setRequestHeader=()=>{};
  this.send=(b)=>{
    sent.push({ method:this._m, url:this._u, body: b ? JSON.parse(b) : null });
    let r={ok:true};
    if(this._u.indexOf('/api/state')===0) r=STATE;
    else if(this._u.indexOf('/api/automation')===0) r=AUTOMATION;
    else if(this._u.indexOf('/api/renew')===0) r={ok:true, jobId:'j1'};
    else if(this._u.indexOf('/api/job/')===0) r={done:true, ok:true, log:'done'};
    this.status=200; this.readyState=4; this.responseText=JSON.stringify(r);
    if(this.onreadystatechange)this.onreadystatechange();
  };
}

function goto(w, hash){ w.location.hash = hash; w.dispatchEvent(new w.Event('hashchange')); }
const txt = n => n ? n.textContent : '(missing)';

let fails = 0;
function check(label, cond, detail){
  if (cond) { console.log('  PASS  ' + label); }
  else { console.log('  FAIL  ' + label + '  -- ' + detail); fails++; }
}

const errors=[]; const vc=new VirtualConsole();
vc.on('jsdomError', e=>errors.push(e.detail?e.detail.stack:e.message));
const dom=new JSDOM(html,{url:'http://127.0.0.1:1/?t=abc',runScripts:'outside-only',pretendToBeVisual:true,virtualConsole:vc});
const w=dom.window,d=dom.window.document;
w.SSL_DATA=SSL_DATA; w.XMLHttpRequest=XHR;
const store={};
Object.defineProperty(w,'localStorage',{value:{getItem:k=>store[k]||null,setItem:(k,v)=>store[k]=v,removeItem:k=>delete store[k]},configurable:true});
try { scripts.forEach(s=>w.eval(s)); } catch(e){ errors.push('LOAD THREW: '+e.message); }
console.log('load errors: '+(errors.length?errors.join('\n'):'none'));

// Tiles are keyed by their label, which is what a reader actually looks for.
function tileByLabel(host, label){
  return Array.from(host.querySelectorAll('.pill')).filter(function(p){
    return txt(p.querySelector('.k')) === label;
  })[0] || null;
}

w.CertCamel.loadState(function(){
  w.CertCamel.navigate();
  goto(w, '#/home');
  const host = d.getElementById('view-home');

  console.log('\n=== tiles: the count splits by who does the renewing ===');
  const soon  = tileByLabel(host, 'Renew soon');
  const sched = tileByLabel(host, 'Renews itself');
  check('"Renew soon" counts only the manual two',
        txt(soon.querySelector('.val')) === '2', 'got ' + txt(soon.querySelector('.val')));
  check('and is still amber', soon.classList.contains('hot'), 'classes=' + soon.className);
  check('"Renews itself" tile exists', !!sched, 'tile missing');
  check('and counts the automated two',
        sched && txt(sched.querySelector('.val')) === '2', 'got ' + (sched && txt(sched.querySelector('.val'))));
  check('and is blue, not amber',
        sched && sched.classList.contains('sched') && !sched.classList.contains('hot'),
        'classes=' + (sched && sched.className));

  console.log('\n=== the amber callout names only what needs a person ===');
  const warn = Array.from(host.querySelectorAll('.callout.warn')).filter(function(c){
    return /Renewal needed/.test(txt(c));
  })[0];
  const wt = txt(warn);
  check('lists the managed-elsewhere one', /elsewhere\.example\.com/.test(wt), wt);
  check('lists the one no provider covers', /nodns\.example\.com/.test(wt), wt);
  check('does NOT list the automated ones', !/auto1\.example\.com/.test(wt), wt);
  check('explains where the other two went', /2 others in this window renew automatically/.test(wt), wt);

  console.log('\n=== group headers follow the same rule ===');
  const heads = {};
  Array.from(host.querySelectorAll('tr.grouphead')).forEach(function(tr){
    heads[tr.getAttribute('data-cat')] = tr;
  });
  const auto = heads['Automated'], man = heads['Manual'];
  check('the all-automated group does not say "need renewal"',
        !/need renewal/.test(txt(auto)), txt(auto));
  check('it says "2 renewing" instead', /2 renewing/.test(txt(auto)), txt(auto));
  check('and is blue, not amber',
        !!auto.querySelector('.gmeta.sched') && !auto.querySelector('.gmeta.warn'),
        txt(auto));
  check('the manual group still says "need renewal"', /2 need renewal/.test(txt(man)), txt(man));
  check('and is still amber', !!man.querySelector('.gmeta.warn'), txt(man));

  console.log('\n=== the row badges still work (regression on 77a01a9) ===');
  const rows = Array.from(host.querySelectorAll('tr')).filter(function(tr){
    return /auto1\.example\.com/.test(txt(tr));
  });
  check('automated row shows "Renews <date>"', /Renews /.test(txt(rows[0])), txt(rows[0]));
  const mrow = Array.from(host.querySelectorAll('tr')).filter(function(tr){
    return /nodns\.example\.com/.test(txt(tr));
  })[0];
  check('unscheduled row keeps the countdown', /Renew soon/.test(txt(mrow)), txt(mrow));

  console.log('\n=== console certificate: Renew must not ask where to deploy ===');
  goto(w, '#/certificates');
  const cview = d.getElementById('view-certificates');
  const card = cview.querySelector('.trackercard');
  check('the console card rendered', !!card, 'no .trackercard');
  const rb = Array.from(card.querySelectorAll('button')).filter(function(b){
    return /Renew now/.test(txt(b));
  })[0];
  check('it has a Renew now button', !!rb, 'button missing');

  sent.length = 0;
  rb.click();

  const picker = d.getElementById('picker');
  check('the deployment picker did NOT open',
        picker.classList.contains('hidden'), 'picker is showing');

  const renew = sent.filter(function(s){ return /\/api\/renew/.test(s.url); })[0];
  check('it posted straight to /api/renew', !!renew, 'requests: ' + sent.map(s=>s.url).join(', '));
  check('for the console certificate only',
        renew && JSON.stringify(renew.body.zones) === JSON.stringify(['tracker.example.test']),
        renew && JSON.stringify(renew.body));
  check('with no deployment targets',
        renew && Array.isArray(renew.body.targets) && renew.body.targets.length === 0,
        renew && JSON.stringify(renew.body));
  check('the rate-limit warning is on the card, not behind the click',
        /counts against the certificate authority rate limits/.test(txt(card)), txt(card));

  console.log('\n=== assigning is reachable from the row menu, not only the cell ===');
  function menuFor(hostText){
    const row = Array.from(cview.querySelectorAll('tr')).filter(function(tr){
      return new RegExp(hostText).test(txt(tr)) && tr.querySelector('.menu-trigger');
    })[0];
    row.querySelector('.menu-trigger').click();
    return Array.from(d.querySelectorAll('.rowmenu [role=menuitem]')).map(txt);
  }
  const unassigned = menuFor('nodns\\.example\\.com');
  check('an unassigned certificate offers "Assign load balancers"',
        unassigned.indexOf('Assign load balancers') !== -1, unassigned.join(' | '));
  const already = menuFor('auto1\\.example\\.com');
  check('an assigned one offers "Change load balancers"',
        already.indexOf('Change load balancers') !== -1, already.join(' | '));
  check('and still offers Deploy', already.indexOf('Deploy to load balancers') !== -1, already.join(' | '));

  console.log('\n=== the cell says "not assigned", which is the actual fact ===');
  const nrow = Array.from(cview.querySelectorAll('tr')).filter(function(tr){
    return /nodns\.example\.com/.test(txt(tr));
  })[0];
  const cell = nrow.querySelector('td.deploy');
  check('label is "not assigned", not "not deployed"',
        txt(cell).indexOf('not assigned') !== -1, txt(cell));
  check('and says renewal will never push it',
        /renewal will never push it anywhere/.test(cell.querySelector('button').title),
        cell.querySelector('button').title);

  console.log('\n=== with no load balancers configured it stays "not deployed" ===');
  STATE.settings.targets = [];
  CERTS.forEach(function(c){ c.targets = []; });
  w.CertCamel.loadState(function(){
    goto(w, '#/certificates');
    const c2 = d.getElementById('view-certificates');
    const r2 = Array.from(c2.querySelectorAll('tr')).filter(function(tr){
      return /nodns\.example\.com/.test(txt(tr));
    })[0];
    const cell2 = r2.querySelector('td.deploy');
    check('reverts to "not deployed"', txt(cell2).indexOf('not deployed') !== -1, txt(cell2));
    check('and points at setting one up',
          /No load balancers configured/.test(cell2.querySelector('button').title),
          cell2.querySelector('button').title);

    console.log('\nall errors: ' + (errors.length ? errors.join('\n') : 'none'));
    if (fails) { console.log(fails + ' CHECK(S) FAILED'); process.exit(1); }
    console.log('all checks passed');
  });
});
