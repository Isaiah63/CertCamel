/* Logs: the audit trail, and the narrative of individual runs. Read-only by
   design - this is the record of what happened, and a page that could edit it
   would not be worth much as a record. */
(function(){
  "use strict";
  var CC = window.CertCamel;
  var el = CC.el, api = CC.api, ago = CC.ago;

  var TABS = [
    {id: 'audit', label: 'Audit trail'},
    {id: 'runs',  label: 'Run logs'}
  ];
  // Kept across re-renders so a background job finishing does not throw away
  // the log someone is reading. The tab itself lives in the route instead, so a
  // particular view of the logs can be linked to.
  var active = 'audit';
  var openRun = null;
  var eventFilter = '';

  function render(sub){
    if (sub === 'audit' || sub === 'runs') { active = sub; }
    var host = document.getElementById('view-logs');
    host.textContent = '';

    var head = el('div', 'viewhead');
    head.appendChild(el('h2', null, 'Logs'));
    host.appendChild(head);

    var nav = el('div', 'subnav');
    nav.setAttribute('role', 'tablist');
    TABS.forEach(function(t){
      var a = el('a', null, t.label);
      a.href = '#/logs/' + t.id;
      a.setAttribute('role', 'tab');
      a.setAttribute('aria-current', t.id === active ? 'page' : 'false');
      nav.appendChild(a);
    });
    host.appendChild(nav);

    var body = el('div');
    host.appendChild(body);
    body.appendChild(el('p', 'mini', 'Loading...'));

    api('GET', '/api/logs', null, function(err, res){
      if (err) { body.textContent = ''; body.appendChild(el('div', 'callout crit', err)); return; }
      body.textContent = '';
      if (active === 'audit') { renderAudit(body, res); }
      else                    { renderRuns(body, res); }
      body.appendChild(retentionNote(res));
    });
  }

  // What the retention settings currently are, stated on the page rather than
  // left to be discovered. An empty stretch in a log should never be a mystery.
  function retentionNote(res){
    var r = (res && res.retention) || {};
    var mb = res && res.totalBytes ? (res.totalBytes / 1048576).toFixed(1) : '0.0';
    var p = el('p', 'mini');
    p.textContent = 'Run logs: keeping ' + (r.retentionDays || '?') + ' days or ' +
      (r.maxSizeMb || '?') + ' MB, whichever comes first — currently ' + mb + ' MB. ' +
      'The audit trail is never trimmed automatically; it rotates to a dated file when large.';
    return p;
  }

  function renderAudit(host, res){
    var a = (res && res.audit) || {};

    var bar = el('div', 'toolbar');
    var lab = el('label', 'mini');
    lab.textContent = 'Show ';
    var sel = document.createElement('select');
    sel.className = 'ca-pick';
    [['', 'everything'], ['sweep', 'scheduled renewal sweeps'], ['renew', 'renewals'],
     ['deploy', 'deployments'], ['assign', 'assignments'], ['settings', 'settings changes'],
     ['secret', 'credential changes'], ['check', 'checks'], ['alert', 'alerts'],
     ['retention', 'log trims'], ['ca', 'issuer changes'],
     ['external', 'managed-elsewhere changes']].forEach(function(o){
      var opt = document.createElement('option');
      opt.value = o[0]; opt.textContent = o[1];
      if (o[0] === eventFilter) { opt.selected = true; }
      sel.appendChild(opt);
    });
    sel.addEventListener('change', function(){ eventFilter = sel.value; render(); });
    lab.appendChild(sel);
    bar.appendChild(lab);
    bar.appendChild(el('span', 'spacer'));
    bar.appendChild(el('span', 'mini', (a.lines || 0) + ' entries'));
    host.appendChild(bar);

    var pre = el('pre', 'log');
    pre.textContent = 'Loading...';
    host.appendChild(pre);

    api('GET', '/api/logs/audit' + (eventFilter ? '?event=' + encodeURIComponent(eventFilter) : ''),
        null, function(err, res2){
      if (err) { pre.textContent = err; return; }
      var lines = (res2 && res2.lines) || [];
      if (!lines.length) {
        pre.textContent = eventFilter
          ? 'No entries of that kind yet.'
          : 'Nothing recorded yet. Renewals, deployments and settings changes appear here as they happen.';
        return;
      }
      // Newest first reads better on screen, though the file itself is
      // append-only and therefore oldest-first.
      pre.textContent = lines.slice().reverse().join('\n');
      if (res2.truncated) {
        host.appendChild(el('p', 'mini', 'Showing the most recent entries only. The full record is in audit.log.'));
      }
    });

    if ((a.archives || []).length) {
      var arch = el('p', 'mini');
      arch.textContent = 'Older, rotated out but kept: ' +
        a.archives.map(function(x){ return x.name; }).join(', ');
      host.appendChild(arch);
    }
  }

  function renderRuns(host, res){
    var runs = (res && res.runs) || [];
    if (!runs.length) {
      host.appendChild(el('div', 'empty', 'No run logs yet.'));
      return;
    }

    var tw = el('div', 'tablewrap');
    var table = document.createElement('table');
    table.innerHTML = '<thead><tr><th>When</th><th>Run</th><th class="n">Size</th><th></th></tr></thead>';
    var tbody = document.createElement('tbody');
    table.appendChild(tbody);
    tw.appendChild(table);
    host.appendChild(tw);

    var viewer = el('div');
    host.appendChild(viewer);

    runs.forEach(function(r){
      var tr = el('tr');
      var when = el('td', 'dim');
      when.textContent = ago(r.at);
      when.title = new Date(r.at).toLocaleString();
      tr.appendChild(when);
      tr.appendChild(el('td', 'host', r.kind));
      tr.appendChild(el('td', 'n', (r.bytes / 1024).toFixed(1) + ' KB'));

      var acts = el('td', 'acts');
      var open = el('button', 'btn sm', openRun === r.name ? 'Hide' : 'View');
      open.type = 'button';
      open.addEventListener('click', function(){
        if (openRun === r.name) { openRun = null; render(); return; }
        openRun = r.name;
        render();
      });
      acts.appendChild(open);
      tr.appendChild(acts);
      tbody.appendChild(tr);
    });

    if (openRun) {
      var pre = el('pre', 'log');
      pre.textContent = 'Loading ' + openRun + '...';
      viewer.appendChild(el('h4', null, openRun));
      viewer.appendChild(pre);
      api('GET', '/api/logs/run/' + encodeURIComponent(openRun), null, function(err, res2){
        if (err) { pre.textContent = err; return; }
        pre.textContent = (res2 && res2.content) || '(empty)';
        pre.scrollTop = pre.scrollHeight;
      });
    }
  }

  CC.registerView('logs', {render: render});
  CC.onStateChanged(function(){
    if (CC.currentRoute().view === 'logs') { render(); }
  });
})();
