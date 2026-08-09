/* Home: stat tiles, warnings, the tracked-domains table (from the checker's raw
   output), and a short recent-activity list. This is the read-only report the
   single-page version always was, now living in its own view; the rendering
   logic below is a direct port of that page's original body, not a rewrite. */
(function(){
  "use strict";
  var CC = window.CertCamel;
  var el = CC.el, api = CC.api, daysUntil = CC.daysUntil, fmtDate = CC.fmtDate, ago = CC.ago;
  var fmtDateTime = CC.fmtDateTime;
  var RENEW_DAYS = CC.RENEW_DAYS, STALE_DAYS = CC.STALE_DAYS;

  var UNCATEGORIZED = 'Uncategorized';
  var LABEL = {ok:'OK', soon:'Renew soon', gone:'Expired', unknown:'Error'};

  // Both used from render() and from the automation panel, which lands later
  // than the synchronous pass, so they live out here rather than inside it.
  function tile(label, value, sub, cls){
    var t = el('div', 'pill' + (cls ? ' ' + cls : ''));
    t.appendChild(el('div', 'k', label));
    t.appendChild(el('div', 'val', String(value)));
    t.appendChild(el('div', 'sub', sub));
    return t;
  }
  function callout(cls, heading, body){
    var c = el('div', 'callout ' + cls);
    c.appendChild(el('div', 'h', heading));
    c.appendChild(el('p', null, body));
    return c;
  }

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

    // One row, two cards: the renewal schedule beside recent deployments. The
    // renewals card is appended when /api/automation answers, so it is created
    // here to hold its place in the order.
    var cardRow = el('div', 'cardrow');
    host.appendChild(cardRow);

    // The automation tile arrives from a fetch while the others are built
    // synchronously below, so its position would otherwise depend on how fast
    // the server answered. An empty placeholder claims the slot and is swapped
    // for the real tile, which fixes the row order either way.
    //
    // The slot goes in BEFORE the request starts - a cached or stubbed response
    // can arrive during the call, and a tile that has nowhere to land is a tile
    // that silently never appears.
    var autoSlot = el('div', 'pillslot');
    function startAutomation(){
      pillsBox.appendChild(autoSlot);
      renderAutomation(autoSlot, alertsBox, cardRow);
    }

    renderActivity(cardRow);

    // Load balancer health has nothing to do with whether the checker has run,
    // so it is created here and placed in BOTH paths below - an install with no
    // certificate data yet still wants to know its load balancers are alive.
    // It removes itself if no deployment targets are configured.
    var lbBox = el('section', 'lbsection');

    if (!hasData) {
      // Still worth answering "is anything automated?" when there is no checker
      // data at all - arguably that is exactly when it matters.
      startAutomation();
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
      host.appendChild(lbBox);
      renderLoadBalancers(lbBox);
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

    pillsBox.appendChild(tile('Tracked', rows.length, rows.length === 1 ? 'domain' : 'domains'));
    pillsBox.appendChild(tile('Renew soon', expiring.length, 'within ' + RENEW_DAYS + ' days', expiring.length ? 'hot' : ''));
    pillsBox.appendChild(tile('Expired', expired.length, 'past due', expired.length ? 'bad' : ''));
    if (errored.length) { pillsBox.appendChild(tile('Unreachable', errored.length, 'check failed', 'hot')); }
    startAutomation();

    updateSidebarBadge(expired.length + errored.length);

    function names(list){ return list.map(function(r){ return r.raw.host; }).join(', '); }

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

    /* Filtering lives behind one button rather than a row of category chips.
       With three categories the chips were fine; with thirty they are a wall of
       buttons above the thing you came to read, and they push the table off the
       screen on the installs that need it most. Nothing is shown until asked
       for, and the button says when a filter is active so a hidden one can
       never quietly change what you are looking at. */
    /* Placed INSIDE the heading, after the rule. The h2 is already a flex row
       with .rule{flex:1}, so the button lands hard right and centred on the
       line at no layout cost - and it costs the page no vertical space at all,
       which a row of its own did. */
    // "checked N ago" moves up here beside the control, same as Load balancers
    // below. It used to sit under the table, where it read as a footnote to the
    // last row rather than as a fact about the whole section.
    var stamp = el('span', 'filternote');
    sh.appendChild(stamp);

    var filterNote = el('span', 'filternote');
    sh.appendChild(filterNote);
    var filterBtn = el('button', 'btn sm filterbtn', 'Filter');
    filterBtn.type = 'button';
    filterBtn.setAttribute('aria-expanded', 'false');
    sh.appendChild(filterBtn);

    var filterPanel = el('div', 'filterpanel hidden');

    var searchwrap = el('div', 'searchwrap');
    var search = document.createElement('input');
    search.className = 'search'; search.type = 'search'; search.id = 'home-search';
    search.placeholder = 'Search domains'; search.autocomplete = 'off';
    search.setAttribute('aria-label', 'Search domains');
    searchwrap.appendChild(search);
    filterPanel.appendChild(searchwrap);

    var chips = el('div', 'chips');
    chips.setAttribute('role', 'group');
    chips.setAttribute('aria-label', 'Filter by category');
    filterPanel.appendChild(chips);

    section.appendChild(filterPanel);

    filterBtn.addEventListener('click', function(){
      var open = filterPanel.classList.toggle('hidden') === false;
      filterBtn.setAttribute('aria-expanded', open ? 'true' : 'false');
      if (open) { search.focus(); }
    });

    var tw = el('div', 'tablewrap');
    var table = document.createElement('table');
    table.innerHTML = '<thead><tr><th>Domain</th><th>Status</th><th>Expires</th>' +
      '<th class="n">Days left</th><th>Issuer</th></tr></thead>';
    var body = document.createElement('tbody');
    table.appendChild(body);
    tw.appendChild(table);
    section.appendChild(tw);

    host.appendChild(section);

    // Below Tracked domains, as asked. The table rows are appended into
    // `section` after this point, which is fine - it is already in the DOM, so
    // they land above this rather than after it.
    host.appendChild(lbBox);
    renderLoadBalancers(lbBox);

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
      if (describeFilter) { describeFilter(); }
    }
    // Declared before applyFilters can reach it; assigned once the controls it
    // reads exist.
    var describeFilter = null;

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

    // Always wired now. It used to appear only past twelve rows, which made
    // sense when it was permanently on screen; behind a button there is no
    // reason to withhold it, and "search is missing on small lists" was its own
    // small confusion.
    search.addEventListener('input', function(){
      searchTerm = search.value.trim().toLowerCase();
      applyFilters();
    });

    // A filter you cannot see must still announce itself, or a collapsed panel
    // silently hides rows and the table looks wrong for no visible reason.
    describeFilter = function(){
      var bits = [];
      if (activeCat) { bits.push(activeCat); }        // null means every category
      if (searchTerm) { bits.push('"' + searchTerm + '"'); }
      filterNote.textContent = bits.join(' · ');
      filterBtn.classList.toggle('on', bits.length > 0);
    };
    describeFilter();

    // Short in the heading, exact on hover - the full timestamp was useful but
    // too long to sit on one line beside a button.
    stamp.textContent = 'checked ' + ago(data.generated);
    stamp.title = new Date(data.generated).toLocaleString();

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

  function taskOf(a, key){
    var found = null;
    (a && a.tasks ? a.tasks : []).forEach(function(t){ if (t.key === key) { found = t; } });
    return found;
  }

  // The status tile: a headline word, then one row per service with the time it
  // runs. A list rather than a sentence on purpose - every prose version of this
  // left the verb dangling ("checks daily at 3:20 AM" reads as though it were
  // checking the services, not the certificates). A name and a time cannot be
  // misread, and the three services run at three different times anyway, so a
  // single shared sentence was never going to be accurate.
  function automationTile(a){
    var renew = taskOf(a, 'renew');

    var cls, word;
    if (!a || a.available === false)      { cls = 'hot'; word = 'Unknown'; }
    else if (!renew || !renew.registered) { cls = 'hot'; word = 'Not set up'; }
    else if (!renew.enabled)              { cls = 'bad'; word = 'Off'; }
    else if (renew.state === 'running')   { cls = 'good'; word = 'Running'; }
    else                                  { cls = 'good'; word = 'On'; }

    var t = el('div', 'pill auto ' + cls);
    var head = el('div', 'autohead');
    head.appendChild(el('span', 'k', 'Automation Scripts'));
    head.appendChild(el('span', 'val', word));
    t.appendChild(head);

    if (!a || a.available === false) {
      t.appendChild(el('div', 'sub', 'The Windows scheduler could not be read, so none of this can be confirmed.'));
      return t;
    }

    var list = el('div', 'svclist');
    (a.tasks || []).forEach(function(s){
      var row = el('div', 'svc');
      row.appendChild(el('span', 'n', s.label));

      var when;
      if (!s.registered)  { when = 'not set up'; }
      else if (!s.enabled){ when = 'switched off'; }
      else if (s.triggerType === 'boot') {
        // A boot trigger still carries a StartBoundary - the moment it was
        // registered - so formatting the time would claim it runs daily at
        // whatever o'clock setup happened to be run.
        when = 'at startup';
      }
      else {
        var clock = clockOf(s.schedule);
        when = clock ? 'daily ' + clock : 'scheduled';
      }
      row.appendChild(el('span', 'v', when));
      row.title = s.detail || '';
      list.appendChild(row);
    });
    t.appendChild(list);
    return t;
  }

  // The three conditions worth acting on. They are attention items rather than
  // status, so they belong with the expired/expiring callouts rather than
  // padding out a card that is otherwise just a schedule.
  function automationAlerts(box, a, callout){
    if (!a) { return; }

    if (a.available === false) {
      box.appendChild(callout('note', 'Could not read the Windows scheduler',
        (a.error || 'The Task Scheduler service did not answer.') +
        ' Automation may well still be running — this page simply cannot see it.'));
      return;
    }

    var renew = taskOf(a, 'renew');
    if (renew && !renew.registered) {
      box.appendChild(callout('note', 'Unattended renewal is not set up',
        'Nothing renews on its own. Certificates renew only when you do it from the ' +
        'Certificates page. Run First Time Setup.bat to register the daily task.'));
    } else if (renew && !renew.enabled) {
      box.appendChild(callout('warn', 'Unattended renewal is switched off',
        'The task is registered but disabled, so nothing will renew on its own.'));
    }

    // A task pointing at a script somewhere else has silently stopped driving
    // this folder. Nothing else in the tool notices.
    (a.tasks || []).forEach(function(t){
      if (t.registered && t.pathMatches === false) {
        box.appendChild(callout('warn', '“' + t.name + '” is pointing somewhere else',
          'It runs ' + (t.commandPath || 'an unknown path') + ', not the copy in this folder, ' +
          'so it is not driving this install. Run First Time Setup.bat to re-point it.'));
      }
    });
  }

  // Which certificates renew when, and whether anything happens afterwards.
  function renewalsCard(res){
    var a = res.automation || {};
    var f = res.forecast;
    var renew = taskOf(a, 'renew');
    var state = CC.state || {};
    var deployment = state.deployment || {};

    var card = el('div', 'card');
    card.appendChild(el('h4', null, 'Automated renewals scheduled'));

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
      card.appendChild(el('p', 'mini',
        'Not worked out yet. The nightly run records this.'));
      card.appendChild(cardFoot([refreshControl(true)]));
      return card;
    }

    var items = f.considered.slice().sort(function(x, y){
      if (!x.renewAfter) { return 1; }
      if (!y.renewAfter) { return -1; }
      return new Date(x.renewAfter) - new Date(y.renewAfter);
    });

    items.forEach(function(c){
      var b = el('div', 'renewal');
      b.appendChild(el('div', 'n', c.name || c.certId));

      if (c.due) {
        b.appendChild(el('div', 'w', 'Due now — ' + (c.reason || 'the CA says so')));
      } else if (c.renewAfter) {
        // The full local timestamp, not just a date: "renews Oct 4" does not say
        // whether that is tonight or tomorrow morning where you are sitting.
        b.appendChild(el('div', 'd', fmtDateTime(c.renewAfter)));
      } else {
        b.appendChild(el('div', 'd', 'Renewal date not known yet'));
      }

      // Renewal and deployment are separate things. A certificate with nothing
      // assigned renews and then sits on disk - renew.ps1 logs it and carries
      // on, so "automation is on" reads as more reassuring than it should.
      var tg = targetsFor(c.certId);
      if (tg.length) {
        b.appendChild(el('div', 'g', 'deploys to ' + tg.map(targetLabel).join(', ')));
      } else {
        b.appendChild(el('div', 'w', 'no load balancer assigned, so it will not deploy'));
      }
      card.appendChild(b);
    });

    var stamp = el('p', 'mini');
    var how  = (f.mode === 'preview') ? 'a preview you ran' : 'the scheduled run';
    var tail = (renew && renew.registered && renew.enabled)
      ? ' Dates come from the certificate authority and can move.'
      : ' Nothing is scheduled to act on these dates.';
    stamp.textContent = 'Worked out ' + (f.finishedAt ? ago(f.finishedAt) : 'at an unknown time') +
      ' by ' + how + '.' + tail;

    card.appendChild(cardFoot([stamp, refreshControl(isStale(f))]));
    return card;
  }

  // Notes about the card, not another entry in it. Without the rule these sat
  // flush under the last certificate and read as though they belonged to it.
  function cardFoot(parts){
    var foot = el('div', 'cardfoot');
    parts.forEach(function(p){ if (p) { foot.appendChild(p); } });
    return foot;
  }

  // Over a day and a half old means the nightly run has not landed, which is
  // itself worth being able to act on.
  function isStale(f){
    if (!f || !f.finishedAt) { return true; }
    return (new Date() - new Date(f.finishedAt)) > 36 * 3600 * 1000;
  }

  // Only offered when there is nothing to show or it has gone stale. In the
  // normal case the card carries no control at all.
  function refreshControl(show){
    if (!show) { return document.createDocumentFragment(); }
    var p = el('p', 'mini');
    var btn = el('button', 'btn sm', 'Work it out now');
    btn.type = 'button';
    btn.setAttribute('data-busy-disable', '');
    btn.title = 'Works out what would renew and stops. Issues nothing, deploys nothing.';
    btn.addEventListener('click', function(){
      CC.runJob('Working out what would renew', 'POST', '/api/forecast');
    });
    p.appendChild(btn);
    return p;
  }


  function renderAutomation(autoSlot, alertsBox, cardRow){
    api('GET', '/api/automation', null, function(err, res){
      // A missing panel beats a broken page - but the placeholder has to go,
      // or an empty tile-sized gap is left sitting in the row.
      if (err || !res) {
        if (autoSlot.parentNode) { autoSlot.parentNode.removeChild(autoSlot); }
        return;
      }
      var a = res.automation || {};

      if (autoSlot.parentNode) {
        autoSlot.parentNode.replaceChild(automationTile(a), autoSlot);
      }
      automationAlerts(alertsBox, a, callout);

      // Prepended so the schedule reads before the history beside it.
      cardRow.insertBefore(renewalsCard(res), cardRow.firstChild);
    });
  }

  /* --- Load balancers ------------------------------------------------------- //

     Reads a CACHE the server wrote out of process. Nothing here ever waits on a
     load balancer: an unreachable node takes ten seconds to fail and the server
     handles one connection at a time, so probing on the request thread would
     freeze every other view for as long as it took - exactly when someone is
     trying to find out what is wrong.

     Shows what the Data Plane API can actually be asked for and no more. There
     is no VRRP row because there is no honest way to fill one in: MASTER and
     BACKUP live in keepalived, which has no API, and HAProxy binds its
     frontends on every node whether or not it holds the virtual address. */

  function renderLoadBalancers(box){
    api('GET', '/api/loadbalancers', null, function(err, res){
      // No deployment targets configured means this install only watches and
      // renews. Remove the section rather than showing an empty one - plenty of
      // people will never deploy anywhere.
      if (err || !res || !res.haveTargets) {
        if (box.parentNode) { box.parentNode.removeChild(box); }
        return;
      }
      drawLoadBalancers(box, res);
    });
  }

  function drawLoadBalancers(box, res){
    box.textContent = '';

    /* Same shape as Tracked domains: the control lives in the heading, right of
       the rule, so it costs the page no vertical space and the two sections
       read as one pattern rather than two. */
    var h = el('h2', null, 'Load balancers');
    h.appendChild(el('span', 'rule'));
    h.appendChild(el('span', 'filternote',
      res.checkedAt ? 'checked ' + ago(res.checkedAt) : 'not checked yet'));

    var btn = el('button', 'btn sm filterbtn', 'Check now');
    btn.type = 'button';
    btn.title = 'Asks each node whether it is answering. Changes nothing.';
    btn.addEventListener('click', function(){ refreshLoadBalancers(box, btn); });
    h.appendChild(btn);

    box.appendChild(h);

    if (!res.checkedAt) { return; }

    (res.targets || []).forEach(function(t){
      // .wide so it runs to the same right edge as the domains table above it.
      // The default .card caps at 64rem, which left it visibly short of the
      // table and made the page read as two columns of different lengths.
      var card = el('div', 'card wide lbgroup');
      card.appendChild(el('h4', null, t.label));

      (t.nodes || []).forEach(function(n){ card.appendChild(lbNodeRow(n)); });

      var dep = lastDeployFor(t.id);
      if (dep) {
        var d = el('p', 'mini lbdeploy');
        d.appendChild(el('span', 'dot ' + (dep.ok ? 'ok' : 'bad')));
        d.appendChild(document.createTextNode(
          'Last deployment ' + ago(dep.at) + ' — ' + dep.name + (dep.ok ? ' succeeded' : ' failed')));
        card.appendChild(d);
      }

      box.appendChild(card);
    });
  }

  function lbNodeRow(n){
    var row = el('div', 'lbnode' + (n.reachable ? '' : ' down'));

    row.appendChild(el('span', 'dot ' + (n.reachable ? 'ok' : 'bad')));
    row.appendChild(el('span', 'lbname', n.name));

    // HAProxy's own `node` directive - the only identity the box gives out, and
    // the thing that tells two nodes behind one address apart.
    row.appendChild(el('span', 'lbid', n.node || '—'));

    var detail = el('span', 'lbdetail');
    if (n.reachable) {
      detail.textContent = 'HAProxy ' + (n.haproxyVersion || 'unknown') +
                           (n.apiVersion ? '  ·  API ' + n.apiVersion : '');
    } else {
      // The reason, not just the fact. "Unreachable" alone sends people looking
      // at the network when the answer is often a wrong password.
      detail.textContent = n.error || 'did not answer';
      detail.className = 'lbdetail bad';
    }
    row.appendChild(detail);

    row.appendChild(el('span', 'lburl', n.url));
    return row;
  }

  // The most recent deployment that touched this target group. Matched on the
  // group, not the node: jobs\deploy-<certId>.json keys its node entries by
  // verify host rather than by the configured node name, so a per-node match
  // would be guesswork.
  function lastDeployFor(targetId){
    var state = CC.state || {};
    var deployment = state.deployment || {};
    var best = null;

    Object.keys(deployment).forEach(function(certId){
      var last = deployment[certId] && deployment[certId].last;
      if (!last || !last.at || !last.targets) { return; }
      var mine = null;
      last.targets.forEach(function(t){ if (t && t.targetId === targetId) { mine = t; } });
      if (!mine) { return; }
      if (!best || new Date(last.at) > new Date(best.at)) {
        best = {at: last.at, ok: !!last.ok, name: last.name || certId};
      }
    });
    return best;
  }

  /* Polled here rather than through CC.runJob, which opens the full job panel
     with a scrolling log - right for a renewal that takes minutes, far too much
     for a sweep that usually finishes in under a second. */
  function refreshLoadBalancers(box, btn){
    btn.disabled = true;
    btn.textContent = 'Checking...';

    api('POST', '/api/loadbalancers/refresh', null, function(err, res){
      if (err || !res || !res.jobId) {
        btn.disabled = false;
        btn.textContent = 'Check now';
        return;
      }

      var tries = 0;
      (function poll(){
        // Bounded: two nodes that both blackhole packets take ten seconds each,
        // and something has to give up rather than spin forever on a job that
        // died.
        if (++tries > 60) {
          btn.disabled = false;
          btn.textContent = 'Check now';
          return;
        }
        window.setTimeout(function(){
          api('GET', '/api/job/' + res.jobId, null, function(e2, st){
            if (e2) { btn.disabled = false; btn.textContent = 'Check now'; return; }
            if (st && st.running) { poll(); return; }
            renderLoadBalancers(box);
          });
        }, 700);
      })();
    });
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

    // No inline width any more: it sits in the .cardrow grid, which sizes it.
    var wrap = el('div', 'card');
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
