/* Home: stat tiles, warnings, the tracked-domains table (from the checker's raw
   output), and a short recent-activity list. This is the read-only report the
   single-page version always was, now living in its own view; the rendering
   logic below is a direct port of that page's original body, not a rewrite. */
(function(){
  "use strict";
  var CC = window.CertCamel;
  var el = CC.el, api = CC.api, daysUntil = CC.daysUntil, fmtDate = CC.fmtDate, ago = CC.ago;
  var RENEW_DAYS = CC.RENEW_DAYS, STALE_DAYS = CC.STALE_DAYS;

  var UNCATEGORIZED = 'Uncategorized';
  var LABEL = {ok:'OK', soon:'Renew soon', gone:'Expired', unknown:'Error'};

  function byUrgency(a, b){
    if (a.days === null && b.days === null) { return a.raw.host.localeCompare(b.raw.host); }
    if (a.days === null) { return 1; }
    if (b.days === null) { return -1; }
    return a.days - b.days;
  }

  function render(){
    var host = document.getElementById('view-home');
    host.textContent = '';

    var data = CC.sslData;
    var hasData = !!(data && data.results && data.results.length);

    var head = el('div', 'viewhead');
    head.appendChild(el('h2', null, 'Home'));
    host.appendChild(head);

    var pillsBox = el('div', 'pills');
    host.appendChild(pillsBox);
    var alertsBox = el('div');
    host.appendChild(alertsBox);
    var autoBox = el('div');
    host.appendChild(autoBox);
    var activityBox = el('div');
    host.appendChild(activityBox);

    renderAutomation(autoBox);
    renderActivity(activityBox);

    if (!hasData) {
      var empty = el('div', 'empty');
      empty.appendChild(el('h3', null, 'No certificate data yet'));
      var p = el('p', null, '');
      p.appendChild(document.createTextNode('Run a check from the '));
      var link = el('a', null, 'Certificates');
      link.href = '#/certificates';
      p.appendChild(link);
      p.appendChild(document.createTextNode(' page to see tracked domains here.'));
      empty.appendChild(p);
      host.appendChild(empty);
      return;
    }

    var now = new Date();
    var watched = data.results.filter(function(r){ return !r.renewOnly; });

    var rows = watched.map(function(r){
      var days = r.ok && r.notAfter ? daysUntil(r.notAfter) : null;
      var state;
      if (!r.ok)                   { state = 'unknown'; }
      else if (days < 0)           { state = 'gone'; }
      else if (days <= RENEW_DAYS) { state = 'soon'; }
      else                         { state = 'ok'; }
      return {raw: r, days: days, state: state};
    });
    rows.sort(byUrgency);

    var expiring = rows.filter(function(r){ return r.state === 'soon'; });
    var expired  = rows.filter(function(r){ return r.state === 'gone'; });
    var errored  = rows.filter(function(r){ return r.state === 'unknown'; });

    function tile(label, value, sub, cls){
      var t = el('div', 'pill' + (cls ? ' ' + cls : ''));
      t.appendChild(el('div', 'k', label));
      t.appendChild(el('div', 'val', String(value)));
      t.appendChild(el('div', 'sub', sub));
      return t;
    }
    pillsBox.appendChild(tile('Tracked', rows.length, rows.length === 1 ? 'domain' : 'domains'));
    pillsBox.appendChild(tile('Renew soon', expiring.length, 'within ' + RENEW_DAYS + ' days', expiring.length ? 'hot' : ''));
    pillsBox.appendChild(tile('Expired', expired.length, 'past due', expired.length ? 'bad' : ''));
    if (errored.length) { pillsBox.appendChild(tile('Unreachable', errored.length, 'check failed', 'hot')); }

    updateSidebarBadge(expired.length + errored.length);

    function names(list){ return list.map(function(r){ return r.raw.host; }).join(', '); }
    function callout(cls, heading, body){
      var c = el('div', 'callout ' + cls);
      c.appendChild(el('div', 'h', heading));
      c.appendChild(el('p', null, body));
      return c;
    }

    if (expired.length) {
      alertsBox.appendChild(callout('crit',
        expired.length === 1 ? 'Certificate expired' : 'Certificates expired',
        names(expired) + ' — visitors are seeing a browser security warning right now.'));
    }
    if (expiring.length) {
      alertsBox.appendChild(callout('warn',
        'Renewal needed within ' + RENEW_DAYS + ' days', names(expiring) + '.'));
    }
    if (errored.length) {
      alertsBox.appendChild(callout('note',
        errored.length === 1 ? 'One domain could not be checked' : errored.length + ' domains could not be checked',
        names(errored) + ' — see the reason in the table below. A typo in domains.txt is the usual cause.'));
    }

    var staleFor = (now - new Date(data.generated)) / 86400000;
    if (staleFor > STALE_DAYS) {
      var sc = el('div', 'callout note');
      sc.appendChild(el('div', 'h', 'This data is getting old'));
      var sp = el('p', null, 'Last checked ' + ago(data.generated) + '. Run a check from the ');
      var lnk = el('a', null, 'Certificates');
      lnk.href = '#/certificates';
      sp.appendChild(lnk);
      sp.appendChild(document.createTextNode(' page to refresh.'));
      sc.appendChild(sp);
      alertsBox.appendChild(sc);
    }

    // --- Group by category, from [Header] lines in domains.txt ------------- //
    var groups = [], byName = {};
    rows.forEach(function(r){
      var name = r.raw.category || UNCATEGORIZED;
      if (!Object.prototype.hasOwnProperty.call(byName, name)) {
        byName[name] = {name: name, items: []};
        groups.push(byName[name]);
      }
      byName[name].items.push(r);
    });
    var grouped = groups.length > 1 || (groups.length === 1 && groups[0].name !== UNCATEGORIZED);

    groups.forEach(function(g){
      g.items.sort(byUrgency);
      g.expiring = g.items.filter(function(r){ return r.state === 'soon'; }).length;
      g.expired  = g.items.filter(function(r){ return r.state === 'gone'; }).length;
      g.errored  = g.items.filter(function(r){ return r.state === 'unknown'; }).length;
      g.worst    = g.items.length ? g.items[0] : null;
    });
    groups.sort(function(a, b){ return byUrgency(a.worst, b.worst) || a.name.localeCompare(b.name); });

    // --- Table --------------------------------------------------------------- //
    var section = el('section');
    var sh = el('h2', null, 'Tracked domains');
    sh.appendChild(el('span', 'rule'));
    section.appendChild(sh);

    var chips = el('div', 'chips');
    chips.setAttribute('role', 'group');
    chips.setAttribute('aria-label', 'Filter by category');
    section.appendChild(chips);

    var searchwrap = el('div', 'searchwrap hidden');
    var search = document.createElement('input');
    search.className = 'search'; search.type = 'search'; search.id = 'home-search';
    search.placeholder = 'Search domains'; search.autocomplete = 'off';
    search.setAttribute('aria-label', 'Search domains');
    searchwrap.appendChild(search);
    section.appendChild(searchwrap);

    var tw = el('div', 'tablewrap');
    var table = document.createElement('table');
    table.innerHTML = '<thead><tr><th>Domain</th><th>Status</th><th>Expires</th>' +
      '<th class="n">Days left</th><th>Issuer</th></tr></thead>';
    var body = document.createElement('tbody');
    table.appendChild(body);
    tw.appendChild(table);
    section.appendChild(tw);

    var stamp = el('p', 'mini');
    section.appendChild(stamp);
    host.appendChild(section);

    var rowsByHost = {};

    function groupHeadRow(g){
      var tr = el('tr', 'grouphead');
      tr.setAttribute('data-cat', g.name);
      var td = el('td'); td.colSpan = 5;
      td.appendChild(el('span', 'gname', g.name));
      var meta, cls = '';
      if (g.expired)       { meta = g.expired + ' expired';       cls = 'crit'; }
      else if (g.expiring) { meta = g.expiring + ' need renewal'; cls = 'warn'; }
      else if (g.errored)  { meta = g.errored + ' unreachable';   cls = 'warn'; }
      else                 { meta = 'all healthy'; }
      td.appendChild(el('span', 'gmeta' + (cls ? ' ' + cls : ''),
        g.items.length + (g.items.length === 1 ? ' domain · ' : ' domains · ') + meta));
      tr.appendChild(td);
      return tr;
    }

    function renderRows(list, catName){
      list.forEach(function(r){
        var tr = el('tr', r.state);
        tr.setAttribute('data-cat', catName);
        tr.setAttribute('data-host', r.raw.host);
        rowsByHost[String(r.raw.host).toLowerCase()] = tr;

        var hcell = el('td', 'host');
        hcell.appendChild(document.createTextNode(r.raw.host));
        if (r.raw.port && r.raw.port !== 443) { hcell.appendChild(el('span', 'port', ':' + r.raw.port)); }
        tr.appendChild(hcell);

        var status = el('td');
        status.appendChild(el('span', 'st ' + r.state, LABEL[r.state]));
        tr.appendChild(status);

        if (r.raw.ok) {
          tr.appendChild(el('td', 'dim', fmtDate(r.raw.notAfter)));
          tr.appendChild(el('td', 'n days', r.days + ' d'));
          tr.appendChild(el('td', 'issuer', r.raw.issuer || '—'));
        } else {
          var reason = el('td', 'err', r.raw.error || 'Unreachable');
          reason.colSpan = 3;
          reason.title = r.raw.error || '';
          tr.appendChild(reason);
        }
        body.appendChild(tr);
      });
    }

    if (grouped) {
      groups.forEach(function(g){ body.appendChild(groupHeadRow(g)); renderRows(g.items, g.name); });
    } else {
      renderRows(rows, UNCATEGORIZED);
    }

    var activeCat = null, searchTerm = '';
    function applyFilters(){
      var visibleByCat = {};
      body.querySelectorAll('tr[data-host]').forEach(function(tr){
        var cat = tr.getAttribute('data-cat');
        var show = (!activeCat || cat === activeCat) &&
                   (!searchTerm || tr.getAttribute('data-host').toLowerCase().indexOf(searchTerm) !== -1);
        tr.classList.toggle('hidden', !show);
        if (show) { visibleByCat[cat] = (visibleByCat[cat] || 0) + 1; }
      });
      body.querySelectorAll('tr.grouphead').forEach(function(tr){
        tr.classList.toggle('hidden', !visibleByCat[tr.getAttribute('data-cat')]);
      });
    }

    if (grouped && groups.length > 1) {
      var all = [{name: null, label: 'All', count: rows.length}].concat(groups.map(function(g){
        return {name: g.name, label: g.name, count: g.items.length};
      }));
      all.forEach(function(c, i){
        var b = el('button', 'chip');
        b.type = 'button';
        b.setAttribute('aria-pressed', i === 0 ? 'true' : 'false');
        b.appendChild(document.createTextNode(c.label));
        b.appendChild(el('span', 'n', c.count));
        b.addEventListener('click', function(){
          chips.querySelectorAll('.chip').forEach(function(other){
            other.setAttribute('aria-pressed', other === b ? 'true' : 'false');
          });
          activeCat = c.name;
          applyFilters();
        });
        chips.appendChild(b);
      });
    }

    if (rows.length > 12) {
      searchwrap.classList.remove('hidden');
      search.addEventListener('input', function(){
        searchTerm = search.value.trim().toLowerCase();
        applyFilters();
      });
    }

    stamp.textContent = 'Last checked ' + ago(data.generated) + ' (' +
      new Date(data.generated).toLocaleString() + ').';

    markUnmapped(rowsByHost, alertsBox);
  }

  // Domains no configured DNS provider can renew - the same badge and callout
  // the single-page version showed, driven by /api/state rather than the raw
  // checker file.
  function markUnmapped(rowsByHost, alertsBox){
    var state = CC.state;
    if (!state) { return; }
    var unmapped = state.unmapped || [];
    unmapped.forEach(function(u){
      var tr = rowsByHost[String(u.host).toLowerCase()];
      if (!tr) { return; }
      var cell = tr.querySelector('td.host');
      if (!cell) { return; }
      var b = el('span', 'badge', 'no DNS');
      b.title = 'No configured DNS provider manages this domain, so it cannot be renewed here.';
      cell.appendChild(b);
    });
    if (!unmapped.length) { return; }

    var c = el('div', 'callout warn');
    c.appendChild(el('div', 'h', unmapped.length === 1
      ? 'One domain cannot be renewed' : unmapped.length + ' domains cannot be renewed'));
    var p = el('p', null, unmapped.map(function(u){ return u.host; }).join(', ') + ' — ');
    p.appendChild(document.createTextNode(state.haveZones
      ? 'no configured DNS provider manages these zones. '
      : 'no DNS provider is configured yet. '));
    var link = el('a', null, 'Open DNS settings');
    link.href = '#/settings/dns';
    p.appendChild(link);
    c.appendChild(p);
    alertsBox.appendChild(c);
  }

  // A short, honest "recent activity": when the checker last ran, and the most
  // recently deployed certificates. Not a persisted activity log - there isn't
  // one - just what /api/state already knows.
  // --- Automation ------------------------------------------------------------ //
  // What the Windows scheduler actually has registered, and what the last sweep
  // worked out about when each certificate is next due. Read-only: the panel
  // reports, it does not administer.

  function clockOf(iso){
    // A trigger's StartBoundary carries a full date; only the time of day is
    // meaningful for a daily trigger.
    var d = new Date(iso);
    if (isNaN(d)) { return null; }
    return d.toLocaleTimeString(undefined, {hour:'numeric', minute:'2-digit'});
  }

  function nextRunText(iso){
    var d = new Date(iso);
    if (isNaN(d)) { return ''; }
    var mins = Math.round((d - new Date()) / 60000);
    if (mins < 0)   { return 'overdue'; }
    if (mins < 60)  { return 'in ' + mins + (mins === 1 ? ' minute' : ' minutes'); }
    var hrs = Math.round(mins / 60);
    if (hrs < 24)   { return 'in ' + hrs + (hrs === 1 ? ' hour' : ' hours'); }
    return d.toLocaleString(undefined, {weekday:'short', hour:'numeric', minute:'2-digit'});
  }

  function taskRow(t){
    var row = el('div', 'autorow');

    var who = el('div', 'who');
    who.appendChild(el('div', 't', t.label));
    who.appendChild(el('div', 'lvl', t.level));
    row.appendChild(who);

    // The state word carries the meaning; the dot only repeats it. Colour on
    // its own is not a status anyone can rely on.
    var cls, word;
    if (!t.registered)   { cls = 'off'; word = 'Not set up'; }
    else if (!t.enabled) { cls = 'bad'; word = 'Disabled'; }
    else if (t.state === 'running') { cls = 'on'; word = 'Running now'; }
    else                 { cls = 'on'; word = 'On'; }

    var st = el('div', 'autostate ' + cls);
    st.appendChild(el('span', 'dot ' + cls));
    st.appendChild(document.createTextNode(word));
    row.appendChild(st);

    var when = el('div', 'when');
    if (t.registered && t.schedule) {
      var clock = clockOf(t.schedule);
      when.appendChild(document.createTextNode(clock ? 'daily ' + clock : 'scheduled'));
      if (t.enabled && t.nextRun) {
        when.appendChild(el('span', 'next', 'next ' + nextRunText(t.nextRun)));
      }
    } else if (!t.registered) {
      when.appendChild(document.createTextNode('—'));
    }
    row.appendChild(when);

    return row;
  }

  function renderAutomation(box){
    api('GET', '/api/automation', null, function(err, res){
      if (err || !res) { return; }   // a missing panel beats a broken page

      var card = el('div', 'card');
      var head = el('div', 'toolbar');
      head.appendChild(el('h4', null, 'Automation'));
      head.appendChild(el('span', 'spacer'));

      var btn = el('button', 'btn sm', 'Preview what would renew');
      btn.type = 'button';
      btn.setAttribute('data-busy-disable', '');
      btn.title = 'Works out what would renew and stops. Issues nothing, deploys nothing.';
      btn.addEventListener('click', function(){
        CC.runJob('Previewing what would renew', 'POST', '/api/forecast');
      });
      head.appendChild(btn);
      card.appendChild(head);

      var a = res.automation || {};

      // "Could not read the scheduler" is not the same as "automation is off",
      // and showing the second when the first is true would be a lie in the
      // direction that gets certificates expired.
      if (a.available === false) {
        var c = el('div', 'callout note');
        c.appendChild(el('div', 'h', 'Could not read the Windows scheduler'));
        c.appendChild(el('p', null,
          (a.error || 'The Task Scheduler service did not answer.') +
          ' Automation may well still be running — this panel simply cannot see it.'));
        card.appendChild(c);
        box.appendChild(card);
        return;
      }

      var tasks = a.tasks || [];
      tasks.forEach(function(t){ card.appendChild(taskRow(t)); });

      var renew = null;
      tasks.forEach(function(t){ if (t.key === 'renew') { renew = t; } });

      // A task pointing at a script somewhere else has silently stopped working
      // on this folder. Nothing else in the tool notices.
      tasks.forEach(function(t){
        if (t.registered && t.pathMatches === false) {
          var w = el('p', 'mini warnline');
          w.textContent = '“' + t.name + '” runs a script in a different folder (' +
            (t.commandPath || 'unknown path') + '). It is not driving this copy. ' +
            'Run First Time Setup.bat to re-point it.';
          card.appendChild(w);
        }
      });

      if (renew && (!renew.registered || !renew.enabled)) {
        var note = el('p', 'mini warnline');
        note.textContent = renew.registered
          ? 'Unattended renewal is registered but switched off. Nothing will renew on its own.'
          : 'Unattended renewal is not set up. Nothing renews unless you do it from this page. ' +
            'Run First Time Setup.bat to register it.';
        card.appendChild(note);
      }

      card.appendChild(forecastBlock(res, renew));
      box.appendChild(card);
    });
  }

  // Which certificates renew when, and whether anything happens afterwards.
  function forecastBlock(res, renew){
    var wrap = el('div', 'forecast');
    var f = res.forecast;
    var state = CC.state || {};
    var deployment = state.deployment || {};

    function targetsFor(certId){
      var d = deployment[certId];
      return (d && d.targets) ? d.targets : [];
    }
    function targetLabel(id){
      var found = id;
      ((state.settings && state.settings.targets) || []).some(function(t){
        if (t.id === id) { found = t.label || id; return true; }
        return false;
      });
      return found;
    }

    if (!f || !f.considered || !f.considered.length) {
      var p = el('p', 'mini');
      p.textContent = 'No renewal forecast yet. The nightly run records one, or press ' +
        '“Preview what would renew” to work it out now.';
      wrap.appendChild(p);
      return wrap;
    }

    wrap.appendChild(el('div', 't', 'Next renewal'));

    var items = f.considered.slice().sort(function(x, y){
      if (!x.renewAfter) { return 1; }
      if (!y.renewAfter) { return -1; }
      return new Date(x.renewAfter) - new Date(y.renewAfter);
    });

    items.forEach(function(c){
      var line = el('div', 'fc');
      line.appendChild(el('span', 'n', c.name || c.certId));

      if (c.due) {
        line.appendChild(el('span', 'warn', 'due now — ' + (c.reason || 'the CA says so')));
      } else if (c.renewAfter) {
        line.appendChild(el('span', 'd', 'renews ' + fmtDate(c.renewAfter)));
      } else {
        line.appendChild(el('span', 'd', 'renewal date not known yet'));
      }

      // Renewal and deployment are separate things. A certificate with nothing
      // assigned renews and then sits on disk - renew.ps1 logs it and carries
      // on, so "automation is on" reads as more reassuring than it should.
      var tg = targetsFor(c.certId);
      if (tg.length) {
        line.appendChild(el('span', 'd', '→ deploys to ' +
          tg.map(targetLabel).join(', ')));
      } else {
        line.appendChild(el('span', 'warn', '→ no load balancer assigned, so it will not deploy'));
      }
      wrap.appendChild(line);
    });

    var stamp = el('p', 'mini');
    var when = f.finishedAt ? ago(f.finishedAt) : 'at an unknown time';
    var how  = (f.mode === 'preview') ? 'a preview you ran' : 'the scheduled run';
    var tail = (renew && renew.registered && renew.enabled)
      ? ' Dates come from the certificate authority and can move; they are rechecked every night.'
      : ' Nothing is scheduled to act on these dates.';
    stamp.textContent = 'Worked out ' + when + ' by ' + how + '.' + tail;
    wrap.appendChild(stamp);

    return wrap;
  }

  function renderActivity(box){
    var state = CC.state;
    if (!state || !state.deployment) { return; }

    var events = [];
    Object.keys(state.deployment).forEach(function(certId){
      var d = state.deployment[certId];
      if (d && d.last && d.last.at) { events.push({certId: certId, at: d.last.at}); }
    });
    if (!events.length) { return; }

    events.sort(function(a, b){ return new Date(b.at) - new Date(a.at); });
    events = events.slice(0, 5);

    var wrap = el('div', 'card');
    wrap.style.maxWidth = '44rem';
    wrap.appendChild(el('h4', null, 'Recently deployed'));
    var list = el('div');
    events.forEach(function(e){
      var certLabel = e.certId;
      (state.certs || []).some(function(c){
        if (c.certId === e.certId) { certLabel = c.displayName || c.zone; return true; }
        return false;
      });
      var line = el('div', 'mini');
      line.textContent = certLabel + ' — ' + ago(e.at);
      list.appendChild(line);
    });
    wrap.appendChild(list);
    box.appendChild(wrap);
  }

  function updateSidebarBadge(n){
    var b = document.getElementById('nav-badge-home');
    if (!b) { return; }
    if (n > 0) { b.textContent = String(n); b.classList.remove('hidden'); }
    else       { b.classList.add('hidden'); }
  }

  CC.registerView('home', {render: render});
  CC.onStateChanged(function(){
    // Only re-render in place if Home is the active view; otherwise it will
    // rebuild naturally next time it is visited.
    if (CC.currentRoute().view === 'home') { render(); }
  });
})();
