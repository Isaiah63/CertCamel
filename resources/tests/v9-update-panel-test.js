// The Update panel is only useful if it is trusted, and it spent its whole life
// so far drawing a green tick over a `fatal:`. The cause was that the failure and
// the success looked identical on the wire: a check that died before it could
// count anything came back with behind = 0, and the panel read that as "already
// up to date".
//
// So what is pinned here is not the layout but the honesty - that the tick
// follows the server's `ok` and nothing else infers it from the numbers. Every
// scenario below is a real state the server can return.
const fs = require('fs');
const path = require('path');
const { JSDOM, VirtualConsole } = require('jsdom');

const ROOT = path.join(__dirname, '..') + path.sep;
const html = fs.readFileSync(ROOT + 'ssl-tracker.html', 'utf8');
const scripts = ['assets\\app.js', 'assets\\views\\home.js', 'assets\\views\\certificates.js',
                 'assets\\views\\settings.js', 'assets\\views\\logs.js', 'assets\\views\\docs.js',
                 'assets\\views\\loadbalancers.js']
  .map(p => fs.readFileSync(ROOT + p, 'utf8'));

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

// Swapped between clicks; whatever is here is what GET /api/update answers.
let UPDATE = null;

function XHR(){
  this.readyState=0; this.status=0; this.responseText='';
  this.open=(m,u)=>{this._m=m;this._u=u;};
  this.setRequestHeader=()=>{};
  this.send=()=>{
    let r={ok:true};
    if(this._u.indexOf('/api/state')!==-1) r=STATE;
    else if(this._u.indexOf('/api/update')!==-1) r=UPDATE;
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

// A base "healthy clone" reply; each scenario overrides only what it is about.
function reply(over){
  return Object.assign({
    ok:true, isRepo:true, branch:'main', remote:'origin', clean:true, dirty:[],
    behind:0, ahead:0, current:'bf02460 Rebuild Autumn as Halloween daylight',
    latest:'', incoming:[], canUpdate:false, reason:'Already up to date.',
    version:'1.001b'
  }, over || {});
}

function rows(){ return Array.from(d.querySelectorAll('#set-update-rows .addrrow')); }
function row(label){
  return rows().filter(function(r){
    const l = r.querySelector('.addrlabel');
    return l && l.textContent.trim().toLowerCase() === label.toLowerCase();
  })[0] || null;
}
function detail(label){ const r=row(label); return r ? r.querySelector('.addrdetail').textContent : ''; }
function green(label){ const r=row(label); return !!r && r.classList.contains('ok'); }
function mark(label){ const r=row(label); return r ? r.querySelector('.addrmark').textContent : ''; }

function press(payload){
  UPDATE = payload;
  const btn = Array.from(d.querySelectorAll('button'))
    .filter(b => b.textContent.trim() === 'Check for updates')[0];
  if (!btn) { throw new Error('no "Check for updates" button rendered'); }
  btn.click();
}

w.CertCamel.loadState(function(){
  w.CertCamel.navigate();
  // The Update card lives on the General tab of Settings.
  w.location.hash = '#/settings/general';
  w.dispatchEvent(new w.Event('hashchange'));

  console.log('\n=== a check that could not complete is NOT a tick ===');
  // Verbatim what the S4U server produced: git aborted, so nothing was counted,
  // and behind stayed at its initialised 0. This is the regression.
  press(reply({ ok:false, behind:0, canUpdate:false,
    reason:"Could not reach 'origin', so there is no way to tell whether an update is " +
           "waiting. Check the network and try again. (git: fatal: Unable to persist " +
           "credentials with the 'wincredman' credential store.)" }));
  check('Updates row is not green', green('Updates') === false, 'mark was "' + mark('Updates') + '"');
  check('and it says why', /Could not reach/.test(detail('Updates')), detail('Updates'));
  check('no "Update now" is offered', !Array.from(d.querySelectorAll('#set-update-rows button'))
        .some(b => b.textContent.trim() === 'Update now'), 'one was offered');

  console.log('\n=== a genuine "up to date" still is one ===');
  press(reply());
  check('Updates row is green', green('Updates') === true, 'mark was "' + mark('Updates') + '"');
  check('reason is the plain one', detail('Updates') === 'Already up to date.', detail('Updates'));

  console.log('\n=== updates waiting ===');
  press(reply({ behind:2, canUpdate:true, reason:'2 update(s) available.',
                incoming:['abc1234  first','def5678  second'] }));
  check('Updates row is green', green('Updates') === true, 'mark was "' + mark('Updates') + '"');
  check('"Update now" is offered', Array.from(d.querySelectorAll('#set-update-rows button'))
        .some(b => b.textContent.trim() === 'Update now'), 'none was offered');

  console.log('\n=== behind > 0 but the check itself failed: still not a tick ===');
  // Guards the obvious wrong fix - keying off canUpdate instead of ok, which
  // would let stale numbers from a failed check drive a green row.
  press(reply({ ok:false, behind:2, canUpdate:true, reason:'Could not reach origin.' }));
  check('Updates row is not green', green('Updates') === false, 'mark was "' + mark('Updates') + '"');

  console.log('\n=== this copy always names itself ===');
  press(reply());
  check('shows the version', /1\.001b/.test(detail('This copy')), detail('This copy'));
  check('and the commit', /bf02460/.test(detail('This copy')), detail('This copy'));
  press(reply({ current:'', version:'1.001b' }));
  check('version alone when there is no commit', detail('This copy').trim() === 'v1.001b',
        detail('This copy'));

  console.log('\n=== a ZIP install is told about the release instead ===');
  press(reply({ ok:false, isRepo:false, current:'', canUpdate:false,
    reason:'This folder is not a git clone, so there is nothing to pull from. Download the new version instead.',
    release:{ ok:true, tag:'1.002', url:'https://github.com/Isaiah63/CertCamel/releases/tag/v1.002' } }));
  check('Updates row is not green', green('Updates') === false, 'mark was "' + mark('Updates') + '"');
  check('the newer release is named', /1\.002/.test(detail('Latest release')), detail('Latest release'));
  const link = d.querySelector('#set-update-rows a[href*="releases"]');
  check('a release link is offered', !!link, 'none');
  check('and opens without handing the opener over',
        !!link && link.getAttribute('target') === '_blank' && /noopener/.test(link.getAttribute('rel')||''),
        link ? (link.getAttribute('target') + ' / ' + link.getAttribute('rel')) : 'no link');

  console.log('\n=== ZIP install already on the newest release ===');
  press(reply({ ok:false, isRepo:false, current:'', version:'1.001b',
    reason:'This folder is not a git clone, so there is nothing to pull from. Download the new version instead.',
    release:{ ok:true, tag:'1.001b', url:'https://github.com/Isaiah63/CertCamel/releases/tag/v1.001b' } }));
  check('release row is green', green('Latest release') === true, 'mark was "' + mark('Latest release') + '"');
  check('no link to somewhere it already is', !d.querySelector('#set-update-rows a[href*="releases"]'), 'a link was offered');

  console.log('\n=== GitHub itself unreachable ===');
  press(reply({ ok:false, isRepo:false, current:'',
    reason:'This folder is not a git clone, so there is nothing to pull from. Download the new version instead.',
    release:{ ok:false, tag:'', url:'', error:'No release has been published yet, so there is nothing to compare against.' } }));
  check('release row is not green', green('Latest release') === false, 'mark was "' + mark('Latest release') + '"');
  check('and says why', /No release has been published/.test(detail('Latest release')), detail('Latest release'));

  check('no uncaught errors while rendering', errors.length === 0, errors.join('\n'));

  console.log(fails ? '\n' + fails + ' CHECK(S) FAILED' : '\nall checks passed');
  process.exitCode = fails ? 1 : 0;
});
