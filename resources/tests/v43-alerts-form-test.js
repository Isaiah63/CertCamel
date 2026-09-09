// The alerts form: a summary FREQUENCY where there used to be a monthly
// tick-box, plus a switch for formatted mail.
//
// Two shapes reach this form and both have to work, because a page held open
// across an upgrade is handed whatever the server had at the time:
//
//   new:  alerts.summary = {cadence, weeklyDay, monthDay}
//   old:  alerts.monthlySummary = {enabled}
//
// The old one must land on "monthly" rather than silently on "off" - reading it
// wrong would turn somebody's summary off on their next save, without anyone
// touching that control.
//
// The other trap is htmlEmail. It is backfilled server-side and defaults ON, so
// an ABSENT value must load as ticked; a form that defaulted it off would turn
// formatted mail off for every existing install the first time Settings was
// saved for an unrelated reason.
const fs = require('fs');
const { JSDOM, VirtualConsole } = require('jsdom');

const ROOT = require('path').join(__dirname, '..') + require('path').sep;
const html = fs.readFileSync(ROOT + 'ssl-tracker.html', 'utf8');
const scripts = ['assets\\app.js', 'assets\\views\\home.js', 'assets\\views\\certificates.js',
                 'assets\\views\\loadbalancers.js', 'assets\\views\\renewals.js',
                 'assets\\views\\settings.js', 'assets\\views\\docs.js']
  .map(p => fs.readFileSync(ROOT + p, 'utf8'));

function stateWith(alerts){
  return {
    generated: new Date().toISOString(), certs: [], unmapped: [], haveZones: true, groupError: null,
    zones: {refreshed: new Date().toISOString(), count: 1, errors: []}, deployment: {},
    settings: { contact: 'me@x.com', defaultCaId: 'letsencrypt',
      cas: [{id:'letsencrypt',label:'LE',directoryUrl:'x',stagingUrl:'y',useStaging:true,eabKid:'',eabHmacSet:false}],
      providers: [], targets: [], alerts: alerts },
    catalog: {}, targetCatalog: {}, acmeReady: true
  };
}
const SMTP = {host:'mail.x', port:587, encryption:'starttls', from:'a@x', to:['b@x'],
              authRequired:false, username:'', passwordSet:false};
const BASE = {
  smtp: SMTP,
  expiry: {enabled:false, thresholds:[30]},
  scheduledRenewal: {enabled:false},
  renewalSuccess: {enabled:false},
  deploymentFailure: {enabled:true}
};

let failed = 0;
function check(name, ok, detail){
  if (ok) { console.log('  ok   ' + name); }
  else { console.log('  FAIL ' + name + '  -- ' + detail); failed++; }
}

// Boots the app with the given alerts block and lands on the alerts panel.
function open(alerts){
  const errors = [];
  const posted = {value: null};
  const STATE = stateWith(alerts);
  function XHR(){
    this.open = (m,u) => { this._m = m; this._u = u; };
    this.setRequestHeader = () => {};
    this.send = (b) => {
      let r = {ok:true};
      if (this._u.indexOf('/api/state') === 0) { r = STATE; }
      // Exactly '/api/settings'. '/api/settings/test-email' also POSTs, and
      // matching on a prefix captures that one instead - which reads as the
      // save having sent an empty body.
      if (this._u === '/api/settings' && this._m === 'POST') { posted.value = JSON.parse(b); }
      this.status = 200; this.readyState = 4; this.responseText = JSON.stringify(r);
      if (this.onreadystatechange) { this.onreadystatechange(); }
    };
  }
  const vc = new VirtualConsole();
  vc.on('jsdomError', e => errors.push(e.detail ? e.detail.stack : e.message));
  const dom = new JSDOM(html, {url:'http://127.0.0.1:1/?t=abc', runScripts:'outside-only',
                               pretendToBeVisual:true, virtualConsole:vc});
  const w = dom.window, d = dom.window.document;
  w.SSL_DATA = null; w.XMLHttpRequest = XHR; w.alert = m => errors.push('alert: ' + m);
  const store = {};
  Object.defineProperty(w, 'localStorage', {value:{getItem:k=>store[k]||null,
    setItem:(k,v)=>store[k]=v, removeItem:k=>delete store[k]}, configurable:true});
  try { scripts.forEach(s => w.eval(s)); } catch(e) { errors.push('LOAD THREW: ' + e.message); }
  return {w, d, errors, posted};
}

function run(alerts, then){
  const ctx = open(alerts);
  ctx.w.CertCamel.loadState(function(){
    ctx.w.CertCamel.navigate();
    ctx.w.location.hash = '#/settings/alerts';
    ctx.w.dispatchEvent(new ctx.w.Event('hashchange'));
    then(ctx);
  });
}

function save(ctx){
  const btn = Array.from(ctx.d.querySelectorAll('button')).filter(b => /^Save$/i.test(b.textContent.trim()))[0];
  if (!btn) { return null; }
  btn.click();
  return ctx.posted.value;
}

console.log('\nthe stored frequency loads into the form');
run(Object.assign({}, BASE, {summary:{cadence:'weekly', weeklyDay:'Thursday', monthDay:1},
                             htmlEmail:{enabled:true}}), function(ctx){
  const cad = ctx.d.querySelector('.al-summary-cadence');
  const day = ctx.d.querySelector('.al-summary-weekday');
  check('the cadence control exists', !!cad, 'the monthly tick-box was replaced by a frequency');
  check('and shows the stored value', cad && cad.value === 'weekly', cad && cad.value);
  check('the weekday shows too', day && day.value === 'Thursday', day && day.value);
  check('and its row is visible for a weekly summary',
        day && !day.closest('.field').classList.contains('hidden'), 'hidden when it matters');

  // Only weekly has a day, so the control hides rather than sitting there
  // inviting somebody to set something that changes nothing.
  cad.value = 'daily';
  cad.dispatchEvent(new ctx.w.Event('change'));
  check('and hides once the summary is daily',
        day.closest('.field').classList.contains('hidden'), 'still showing');

  console.log('\nand saving sends the new shape');
  const body = save(ctx);
  check('it posted', !!body, 'no POST to /api/settings');
  check('with the chosen cadence', body && body.alerts.summary.cadence === 'daily',
        JSON.stringify(body && body.alerts.summary));
  check('and the weekday it would use', body && body.alerts.summary.weeklyDay === 'Thursday',
        JSON.stringify(body && body.alerts.summary));
  check('and the html switch', body && body.alerts.htmlEmail.enabled === true,
        JSON.stringify(body && body.alerts.htmlEmail));
  check('the replaced key is not sent back', body && !body.alerts.monthlySummary,
        'monthlySummary would be written back into settings.json');
  check('no errors', ctx.errors.length === 0, ctx.errors.join('\n'));

  console.log('\nan older settings shape still lands on monthly');
  run(Object.assign({}, BASE, {monthlySummary:{enabled:true}}), function(c2){
    const cad2 = c2.d.querySelector('.al-summary-cadence');
    check('monthlySummary=true reads as monthly', cad2 && cad2.value === 'monthly',
          'got ' + (cad2 && cad2.value) + ' - the next save would switch their summary off');

    run(Object.assign({}, BASE, {monthlySummary:{enabled:false}}), function(c3){
      const cad3 = c3.d.querySelector('.al-summary-cadence');
      check('monthlySummary=false reads as off', cad3 && cad3.value === 'off',
            'got ' + (cad3 && cad3.value) + ' - an upgrade must not start sending mail');

      console.log('\nhtmlEmail defaults to on when the server sent none');
      run(BASE, function(c4){
        const box = c4.d.querySelector('.al-html-email');
        check('the switch exists', !!box, 'no html toggle');
        check('and an absent value loads as on', box && box.checked === true,
              'a form defaulting it off would turn formatted mail off on the next save');

        console.log('\nand an explicit false is respected');
        run(Object.assign({}, BASE, {htmlEmail:{enabled:false}}), function(c5){
          const box5 = c5.d.querySelector('.al-html-email');
          check('off stays off', box5 && box5.checked === false, 'ignored a deliberate choice');

          console.log('\n"this install does not send email" also stops the summary');
          run(Object.assign({}, BASE, {none:true, summary:{cadence:'daily', weeklyDay:'Monday', monthDay:1}}),
            function(c6){
              const body6 = save(c6);
              check('the cadence is forced off', body6 && body6.alerts.summary.cadence === 'off',
                    JSON.stringify(body6 && body6.alerts.summary) +
                    ' - the summary task reads the cadence, not the none flag');
              check('no errors anywhere', c6.errors.length === 0, c6.errors.join('\n'));

              if (failed) { console.log('\n' + failed + ' CHECK(S) FAILED'); process.exit(1); }
              console.log('\nall checks passed');
            });
        });
      });
    });
  });
});
