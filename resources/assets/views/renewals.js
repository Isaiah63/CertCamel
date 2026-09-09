/* Renewals: every certificate the forecast speaks for, searchable and filtered
   by how soon it is due.

   This was a block per certificate on the home page with no cap, filter or
   search - fine at four, a wall at any real number, on the page that is meant to
   be the summary. The home card keeps the one thing a summary should answer (is
   anything about to happen) and links here for the detail.

   Reads CC.automationCache, filled by the home view when /api/automation
   answers, and fetches it itself when that is empty - so arriving here first, or
   by a bookmarked #/renewals, works the same. */
(function(){
  'use strict';
  var CC = window.CertCamel;
  var el = CC.el, api = CC.api;
  var fmtDateTime = CC.fmtDateTime;

  /* The windows offered. "All" is first because it is the honest default: any
     other starting point hides rows without being asked to. Compared against the
     CA window opening, which is the only date every row can have. */
  var WINDOWS = [
    {value: 'all', label: 'All',            days: null},
    {value: '1',   label: 'Next 24 hours',  days: 1},
    {value: '7',   label: 'Next week',      days: 7},
    {value: '14',  label: 'Next 2 weeks',   days: 14},
    {value: '90',  label: 'Up to 3 months', days: 90}
  ];

  var q = '', win = 'all';

  function taskOf(a, kind){
    return ((a && a.tasks) || []).filter(function(t){ return t.kind === kind; })[0] || null;
  }

  /* Days from now until the CA window opens. Null when there is no date - a real
     state, meaning the nightly run has not spoken for this one yet, and not the
     same as "due today". */
  function daysUntil(iso){
    if (!iso) { return null; }
    var t = new Date(iso).getTime();
    if (isNaN(t)) { return null; }
    return (t - Date.now()) / 864e5;
  }

  function matches(c, certsById){
    if (!q) { return true; }
    var hay = [c.name || '', c.certId || ''];
    var full = certsById[c.certId];
    if (full && full.names) { hay = hay.concat(full.names); }
    return hay.join(' ').toLowerCase().indexOf(q.toLowerCase()) !== -1;
  }

  function inWindow(c){
    var w = WINDOWS.filter(function(x){ return x.value === win; })[0];
    if (!w || w.days === null) { return true; }
    if (c.due) { return true; }              // due now is inside every window
    var d = daysUntil(c.renewAfter);
    /* A certificate with no date is NOT swept into a narrow window. It might be
       due tomorrow or in a year, and claiming either would be inventing a fact.
       It stays visible under "All", where the absence is the point. */
    if (d === null) { return false; }
    return d <= w.days;
  }

  function render(){
    var host = document.getElementById('view-renewals');
    host.textContent = '';

    var res = CC.automationCache;
    if (!res) {
      host.appendChild(el('p', 'mini', 'Working out renewals...'));
      api('GET', '/api/automation', null, function(err, r){
        if (err || !r) {
          host.textContent = '';
          host.appendChild(el('p', 'mini', err || 'Could not read the renewal forecast.'));
          return;
        }
        CC.automationCache = r;
        render();
      });
      return;
    }

    var back = el('a', 'backlink', 'Back to overview');
    back.href = '#/home';
    host.appendChild(back);

    var h = el('h2', null, 'Automated renewals');
    h.appendChild(el('span', 'rule'));
    host.appendChild(h);

    var f = res.forecast;
    if (!f || !f.considered || !f.considered.length) {
      host.appendChild(el('p', 'mini', 'Not worked out yet. The nightly run records this.'));
      return;
    }

    var state = CC.state || {};
    var deployment = state.deployment || {};
    var certsById = {};
    (state.certs || []).forEach(function(c){ certsById[c.certId] = c; });
    var lastRenewTask = taskOf(res.automation, 'renew');

    function targetLabel(id){
      var found = id;
      ((state.settings && state.settings.targets) || []).some(function(t){
        if (t.id === id) { found = t.label || id; return true; }
        return false;
      });
      return found;
    }
    /* A certificate issued AFTER the forecast ran has no date in it, and the
       forecast is not wrong - it simply predates the certificate. Saying only
       'Renewal date not known yet' there reads as a failure to read the
       expiry, when the actual answer is 'ask again'. Three lab certificates
       were issued three hours after a sweep and looked exactly like that. */
    var forecastAt = f.finishedAt ? new Date(f.finishedAt).getTime() : 0;
    function issuedAfterForecast(certId){
      var c = certsById[certId];
      if (!c || !c.issuedAt || !forecastAt) { return false; }
      var t = new Date(c.issuedAt).getTime();
      return !isNaN(t) && t > forecastAt;
    }

    function isTracker(certId){
      var c = certsById[certId];
      return !!(c && c.tracker);
    }

    // --- controls -----------------------------------------------------------
    var bar = el('div', 'toolbar');

    var search = document.createElement('input');
    search.type = 'search';
    search.className = 'input grow';
    search.id = 'renew-search';
    search.placeholder = 'Search certificates and domains';
    search.value = q;
    search.addEventListener('input', function(){ q = search.value.trim(); paint(); });
    bar.appendChild(search);

    var sel = document.createElement('select');
    sel.className = 'input';
    sel.id = 'renew-window';
    WINDOWS.forEach(function(x){
      var o = document.createElement('option');
      o.value = x.value;
      o.textContent = x.label;
      if (x.value === win) { o.selected = true; }
      sel.appendChild(o);
    });
    sel.addEventListener('change', function(){ win = sel.value; paint(); });
    bar.appendChild(sel);

    /* Always offered here, unlike on Home where it appears only when the card
       decides the forecast is stale. This is the page somebody opens BECAUSE a
       date looks wrong, so the way to fix it belongs in reach. Issues nothing. */
    var refresh = el('button', 'btn sm', 'Work it out now');
    refresh.type = 'button';
    refresh.id = 'renew-refresh';
    refresh.setAttribute('data-busy-disable', '');
    refresh.title = 'Works out what would renew and stops. Issues nothing, deploys nothing.';
    refresh.addEventListener('click', function(){
      CC.automationCache = null;   // so the next render reads the new answer
      CC.runJob('Working out what would renew', 'POST', '/api/forecast');
    });
    bar.appendChild(refresh);

    var tally = el('span', 'selcount', '');
    tally.id = 'renew-tally';
    bar.appendChild(tally);
    host.appendChild(bar);

    var list = el('div', 'card wide');
    list.id = 'renew-list';
    host.appendChild(list);

    host.appendChild(el('p', 'mini',
      'Worked out ' + (f.finishedAt ? fmtDateTime(f.finishedAt) : 'by the scheduled run') +
      '. Dates come from the certificate authority and can move.'));

    // --- rows ---------------------------------------------------------------
    // The same shape the home card used, so the two read as one thing in two
    // places rather than two designs.
    function row(c){
      var b = el('div', 'renewal');
      b.appendChild(el('div', 'n', c.name || c.certId));

      if (c.due) {
        b.appendChild(el('div', 'w', 'Due now — ' + (c.reason || 'the CA says so')));
      } else if (c.renewAfter) {
        /* Two separate facts. The CA's window opening is a floor - nothing runs
           at that moment - and the run is when this tool acts on it. */
        var run = CC.renewalRun(c.renewAfter, lastRenewTask);
        if (run) {
          b.appendChild(el('div', 'd', 'Renews ' + fmtDateTime(run)));
          b.appendChild(el('div', 'g', 'CA window opens ' + fmtDateTime(c.renewAfter)));
        } else {
          b.appendChild(el('div', 'd', 'CA window opens ' + fmtDateTime(c.renewAfter)));
        }
      } else if (issuedAfterForecast(c.certId)) {
        b.appendChild(el('div', 'w', 'Issued since this forecast ran - work it out again for its date'));
      } else {
        b.appendChild(el('div', 'd', 'Renewal date not known yet'));
      }

      var tg = (deployment[c.certId] && deployment[c.certId].targets) || [];
      if (tg.length) {
        b.appendChild(el('div', 'g', 'deploys to ' + tg.map(targetLabel).join(', ')));
      } else if (isTracker(c.certId)) {
        b.appendChild(el('div', 'g', 'serves this console — nothing to deploy'));
      } else {
        b.appendChild(el('div', 'w', 'no load balancer assigned, so it will not deploy'));
      }
      return b;
    }

    function paint(){
      var items = f.considered.slice().sort(function(x, y){
        if (!x.renewAfter) { return 1; }
        if (!y.renewAfter) { return -1; }
        return new Date(x.renewAfter) - new Date(y.renewAfter);
      }).filter(function(c){ return matches(c, certsById) && inWindow(c); });

      list.textContent = '';
      if (!items.length) {
        list.appendChild(el('p', 'mini',
          'Nothing matches. ' +
          (win === 'all' ? 'Try a different search.' : 'Try a wider window, or All.')));
      } else {
        items.forEach(function(c){ list.appendChild(row(c)); });
      }
      tally.textContent = items.length + ' of ' + f.considered.length;
    }

    paint();
  }

  CC.registerView('renewals', {render: render});
})();
