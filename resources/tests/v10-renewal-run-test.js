/* When Cert Camel will actually renew, as opposed to when the CA's window opens.

   These are two different instants and they can be a day apart. renewAfter is
   Posh-ACME's copy of the ARI suggestedWindow.START - the earliest a renewal is
   permitted, a floor. Nothing runs at that moment. The renewal happens on the
   next unattended sweep at or after it, which is what CC.renewalRun works out
   and what the pages now show.

   Runs the real function out of assets/app.js rather than a copy, and exits
   non-zero on failure so it can be checked mechanically.

   TZ matters here: the whole point is local wall-clock scheduling, so the suite
   pins America/New_York rather than inheriting whatever the machine is set to. */
process.env.TZ = 'America/New_York';

const fs = require('fs');
const src = fs.readFileSync(__dirname + '/../assets/app.js', 'utf8');
const found = src.match(/CertCamel\.renewalRun = function[\s\S]*?\n  \};/);
if (!found) {
  console.error('FAIL  CC.renewalRun not found in assets/app.js');
  process.exit(1);
}
const CertCamel = {};
eval(found[0]);

let failed = 0;
function check(name, got, want) {
  const ok = String(got) === String(want);
  if (!ok) { failed++; }
  console.log((ok ? '  ok   ' : '  FAIL ') + name +
              (ok ? '' : '\n         got  ' + got + '\n         want ' + want));
}
const daily = (nextRun) => ({registered:true, enabled:true, triggerType:'daily', nextRun});
const local = (d) => d ? d.toLocaleString('en-US') : String(d);

// The task runs at 03:20 daily; these are the values /api/automation returns.
const task = daily('2026-08-20T03:20:00.0000000');

console.log('the window opens after the day\'s run, so it renews the NEXT day');
check('window 10:26 Aug 20 -> run 03:20 Aug 21',
      local(CertCamel.renewalRun('2026-08-20T14:26:40Z', task)), '8/21/2026, 3:20:00 AM');

console.log('the window opens before the day\'s run, so that same run takes it');
check('window 00:11 Oct 15 -> run 03:20 Oct 15',
      local(CertCamel.renewalRun('2026-10-15T04:11:02Z', daily('2026-10-15T03:20:00'))),
      '10/15/2026, 3:20:00 AM');

console.log('a window already open renews at the very next run');
check('window in the past -> next run',
      local(CertCamel.renewalRun('2020-01-01T00:00:00Z', task)), '8/20/2026, 3:20:00 AM');

/* Stepping a day at a time has to preserve the wall-clock hour. A scheduled task
   fires at 03:20 local on both sides of a daylight-saving change; adding a fixed
   86400000 ms would land on 02:20 after the clocks go back, quietly reporting a
   time the task never runs. US DST ends 1 Nov 2026. */
console.log('stepping across a daylight-saving change keeps the wall-clock time');
check('Oct 30 03:20 stepping past Nov 3 -> still 03:20',
      local(CertCamel.renewalRun('2026-11-03T12:00:00Z', daily('2026-10-30T03:20:00'))),
      '11/4/2026, 3:20:00 AM');

/* Every one of these means "cannot be worked out", and the pages fall back to
   naming the CA window instead of inventing a run time. */
console.log('unknowable cases return null rather than a guess');
check('no renewAfter',   CertCamel.renewalRun(null, task), 'null');
check('no task',         CertCamel.renewalRun('2026-08-20T14:26:40Z', null), 'null');
check('task disabled',   CertCamel.renewalRun('2026-08-20T14:26:40Z',
      {registered:true, enabled:false, triggerType:'daily', nextRun:'2026-08-20T03:20:00'}), 'null');
check('task unregistered', CertCamel.renewalRun('2026-08-20T14:26:40Z',
      {registered:false, enabled:true, triggerType:'daily', nextRun:'2026-08-20T03:20:00'}), 'null');
check('boot trigger has no daily time', CertCamel.renewalRun('2026-08-20T14:26:40Z',
      {registered:true, enabled:true, triggerType:'boot', nextRun:null}), 'null');
check('unparseable dates', CertCamel.renewalRun('not-a-date', task), 'null');

console.log(failed ? '\n' + failed + ' CHECK(S) FAILED' : '\nall checks passed');
process.exit(failed ? 1 : 0);
