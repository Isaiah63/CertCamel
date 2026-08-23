/* Home: stat tiles, warnings, the tracked-domains table (from the checker's raw
   output), and a short recent-activity list. This is the read-only report the
   single-page version always was, now living in its own view; the rendering
   logic below is a direct port of that page's original body, not a rewrite. */
(function(){
  "use strict";
  var CC = window.CertCamel;
  var el = CC.el, api = CC.api, daysUntil = CC.daysUntil, fmtDate = CC.fmtDate, ago = CC.ago;
  var fmtDateTime = CC.fmtDateTime, fmtTime = CC.fmtTime;
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

    renderFirstRun(cardRow);
    renderActivity(cardRow);
    renderRateLimits(cardRow);

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

    /* The row badges already say "Renews <date>" for anything this tool renews
       itself. The tiles and the callout below did not, so the SAME certificate
       was counted as needing attention up here and reported as scheduled three
       lines down - which is how a number in amber stops meaning anything.

       Split on the same rule the badges and the expiry emails use: amber is only
       for the ones where somebody actually has to act - renewed elsewhere, or in
       a zone no DNS provider covers.

       Before the forecast arrives scheduledRenewalFor() answers null for
       everything, so the opening paint counts them all as manual. The re-render
       renderAutomation() fires when it lands is what corrects that, exactly as
       it does for the badges. */
    var soonAll   = rows.filter(function(r){ return r.state === 'soon'; });
    var scheduled = soonAll.filter(function(r){ return isScheduled(r); });
    var expiring  = soonAll.filter(function(r){ return !isScheduled(r); });
    var expired   = rows.filter(function(r){ return r.state === 'gone'; });
    var errored   = rows.filter(function(r){ return r.state === 'unknown'; });

    pillsBox.appendChild(tile('Tracked', rows.length, rows.length === 1 ? 'domain' : 'domains'));
    pillsBox.appendChild(tile('Renew soon', expiring.length, 'within ' + RENEW_DAYS + ' days', expiring.length ? 'hot' : ''));
    // Only when there is something to say. A standing "0" here would be one more
    // number to read on an install that automates nothing.
    if (scheduled.length) {
      pillsBox.appendChild(tile('Renews itself', scheduled.length, 'already scheduled', 'sched'));
    }
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
      // Says why the list is shorter than the table looks. Without it, seeing
      // five rows in the window and two names here reads as a bug.
      alertsBox.appendChild(callout('warn',
        'Renewal needed within ' + RENEW_DAYS + ' days',
        names(expiring) + '.' + (scheduled.length
          ? ' ' + scheduled.length + ' other' + (scheduled.length === 1 ? '' : 's') +
            ' in this window renew automatically and are not listed here.'
          : '')));
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
      // Same split as the tiles: a group whose certificates all renew on their
      // own must not head itself in amber.
      g.expiring  = g.items.filter(function(r){ return r.state === 'soon' && !isScheduled(r); }).length;
      g.scheduled = g.items.filter(function(r){ return r.state === 'soon' && isScheduled(r); }).length;
      g.expired   = g.items.filter(function(r){ return r.state === 'gone'; }).length;
      g.errored   = g.items.filter(function(r){ return r.state === 'unknown'; }).length;
      g.worst     = g.items.length ? g.items[0] : null;
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

    var rowsByHost = {};

    function groupHeadRow(g){
      var tr = el('tr', 'grouphead');
      tr.setAttribute('data-cat', g.name);
      var td = el('td'); td.colSpan = 5;
      td.appendChild(el('span', 'gname', g.name));
      var meta, cls = '';
      if (g.expired)        { meta = g.expired + ' expired';       cls = 'crit'; }
      else if (g.expiring)  { meta = g.expiring + ' need renewal'; cls = 'warn'; }
      else if (g.errored)   { meta = g.errored + ' unreachable';   cls = 'warn'; }
      else if (g.scheduled) { meta = g.scheduled + ' renewing';    cls = 'sched'; }
      else                  { meta = 'all healthy'; }
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
        var due = scheduledFor(r);
        if (due) {
          // The run, not the window. They can be a day apart: the window opens
          // at whatever hour the CA chose, and nothing happens until the next
          // unattended sweep after it.
          var run  = renewalRunFor(r.raw.host);
          var auto = el('span', 'st auto',
            run ? 'Renews ' + fmtDate(run) + ', ' + fmtTime(run)
                : 'Renews ' + fmtDate(due));
          auto.title = run
            ? 'Renews ' + new Date(run).toLocaleString() +
              ' - the next scheduled run after the certificate authority opens ' +
              'the window, which it does at ' + new Date(due).toLocaleString() +
              '. The authority sets that window and it can move.'
            : 'Renewed automatically by Cert Camel, from ' + new Date(due).toLocaleString() +
              '. The certificate authority sets this window and it can move.';
          status.appendChild(auto);
        } else {
          status.appendChild(el('span', 'st ' + r.state, LABEL[r.state]));
        }
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

  /* "Renew soon" is an expiry countdown, and for anything this tool renews
     itself it says the wrong thing: it reads as work to do when the work is
     already scheduled, in amber, next to rows where amber means somebody has to
     act. That is how a real warning stops being read.

     So a host whose certificate has a renewal date shows "Renews <date>"
     instead. Hosts with nothing scheduled keep the countdown, because there it
     is the only thing that will ever tell you - the same rule the expiry emails
     now follow.

     The forecast arrives from /api/automation AFTER the first paint, so it is
     cached here and consulted by every render. The first attempt patched the
     rendered rows instead and looked right in isolation, but the table is
     rebuilt on every state refresh - so the badges reverted moments later. */
  var lastForecast = null;

  /* The renew task, cached beside the forecast for the same reason: the table is
     rebuilt on every state refresh, and the run time is half of what the badges
     now say. Without it they fall back to naming the window. */
  var lastRenewTask = null;

  // When Cert Camel will actually renew this host's certificate, as opposed to
  // when the CA's window opens. Null when that is not knowable.
  function renewalRunFor(host){
    return CC.renewalRun(scheduledRenewalFor(host), lastRenewTask);
  }

  /* The single rule the row badges, the tiles, the callout and the group
     headers all ask, so they cannot drift apart again - which is exactly what
     had happened: the badges were taught the split and the counts above them
     were not.

     Expired and unreachable are excluded whatever is scheduled. Something has
     already gone wrong on those rows and it has to keep reading as wrong. */
  function scheduledFor(r){
    if (r.state !== 'soon' && r.state !== 'ok') { return null; }
    return scheduledRenewalFor(r.raw.host);
  }
  function isScheduled(r){ return !!scheduledFor(r); }

  function scheduledRenewalFor(host){
    if (!lastForecast || !lastForecast.considered) { return null; }
    var h = String(host).toLowerCase();

    var when = null;
    ((CC.state && CC.state.certs) || []).forEach(function(c){
      if (when || c.external) { return; }     // renewed elsewhere: countdown still earns its place
      /* names, not hosts. hosts is every watched host in the DNS ZONE and is
         identical on every certificate in it, so matching on it returned
         whichever certificate happened to come first - the console row showed
         the SAN certificate's renewal date while the card three inches above it
         showed the console certificate's own, two months apart.

         names is what this certificate actually covers, which is the question
         being asked. Same confusion the expiry column had: a shared zone is not
         a shared certificate. */
      var covers = (c.names || []).some(function(x){ return String(x).toLowerCase() === h; });
      if (!covers) { return; }
      lastForecast.considered.forEach(function(e){
        if (e && e.certId === c.certId && e.renewAfter) { when = e.renewAfter; }
      });
    });
    return when;
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

  /* "every 6 hours" from a repetition interval in minutes, or null when the
     trigger does not repeat. Whole hours and whole minutes are spelled out
     because those are the only shapes a schedule here actually takes; anything
     else falls back to minutes rather than inventing a unit. */
  function everyText(mins){
    var m = Number(mins);
    if (!isFinite(m) || m <= 0) { return null; }
    if (m % 60 === 0) {
      var h = m / 60;
      return 'every ' + (h === 1 ? 'hour' : h + ' hours');
    }
    return 'every ' + m + (m === 1 ? ' minute' : ' minutes');
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
      /* The web page task is absent by design on a desktop, and "not set up"
         reads as a fault rather than a choice - it is the one row somebody
         scans and thinks something went wrong.

         Setup only offers it on Windows Server, so on a desktop it was never
         declined; it was never proposed. Saying "manual launch" describes what
         is actually happening: the console runs while Open Tracker.bat is open.

         The tooltip differs by machine on purpose. Telling a desktop user to
         re-run setup would send them round a loop - setup checks ProductType
         and will not offer the step there either. */
      if (!s.registered && s.key === 'server') {
        when = 'manual launch';
      }
      else if (!s.registered)  { when = 'not set up'; }
      else if (!s.enabled){ when = 'switched off'; }
      else if (s.triggerType === 'boot') {
        // A boot trigger still carries a StartBoundary - the moment it was
        // registered - so formatting the time would claim it runs daily at
        // whatever o'clock setup happened to be run.
        when = 'at startup';
      }
      else {
        var clock = clockOf(s.schedule);
        /* A repeating trigger fires several times from one StartBoundary, so
           "daily <clock>" would understate a task that runs four times a day.
           The clock is still worth naming: it is where the repeats start from,
           and it is the field somebody changes. */
        var every = everyText(s.repeatMinutes);
        if (every && clock)  { when = every + ', from ' + clock; }
        else if (every)      { when = every; }
        else if (clock)      { when = 'daily ' + clock; }
        else                 { when = 'scheduled'; }
      }
      row.appendChild(el('span', 'v', when));

      if (!s.registered && s.key === 'server') {
        row.title = 'The console runs while Open Tracker.bat is open, and stops when you close it.'
          + '\n\n' +
          (a.isServer
            ? 'This is Windows Server, where nobody stays signed in - run First Time Setup again to ' +
              'register it to start at boot instead.'
            : 'Starting it at boot is offered by setup on Windows Server only. On a desktop you open ' +
              'the console when you want it, so there is nothing missing here.');
      }
      else { row.title = s.detail || ''; }
      list.appendChild(row);
    });
    t.appendChild(list);
    return t;
  }

  // The three conditions worth acting on. They are attention items rather than
  // status, so they belong with the expired/expiring callouts rather than
  // padding out a card that is otherwise just a schedule.
  // f is the sweep outcome from /api/automation, used only to quote the
  // reason a failed run gave; the failure itself comes from the scheduler.
  function automationAlerts(box, a, callout, f){
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

    /* An unattended run that failed - the one thing on this page that was
       invisible. A renewal dying mid-run left the schedule reading normally,
       the renewals card listing what it still intends to do, and nothing at all
       saying the last attempt had not worked.

       Driven by the scheduler's own exit code, NOT by the sweep file. A preview
       started from this page writes that same file, so keying on it would mean
       pressing refresh erased the evidence of a real failure without fixing
       anything - a check that can be silently cleared, which is the shape of
       the bug this warning exists to report.

       The sweep error is still the best sentence available, so it is used when
       the file still describes that failed run rather than a later preview.

       267009 is "currently running" and 267011 is "has not run yet". Neither is
       a failure, and a fresh install sits on the second one. */
    var TASK_RUNNING = 267009, TASK_NEVER_RUN = 267011;
    if (renew && renew.registered && renew.enabled && renew.lastRun &&
        renew.lastResult !== 0 && renew.lastResult !== null &&
        renew.lastResult !== TASK_RUNNING && renew.lastResult !== TASK_NEVER_RUN) {
      var why = (f && f.mode === 'run' && f.ok === false && f.error) ? f.error : null;
      box.appendChild(callout('warn', 'The last unattended renewal did not finish',
        'It ran ' + ago(renew.lastRun) + ' and stopped with an error. ' +
        (why ? why + ' ' : '') +
        'Certificates it meant to renew have not been renewed. It tries again on the ' +
        'next scheduled run; the full run is on the Logs page.'));
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
    // Read off the certificate itself rather than compared against the
    // configured hostname: the split that produced this certificate already
    // decided it, and re-deriving the answer here is one more place for the two
    // to disagree.
    function isTracker(certId){
      return ((state && state.certs) || []).some(function(c){
        return c.certId === certId && c.tracker;
      });
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
        // Two separate facts, and conflating them was the bug. The CA's window
        // opening is a floor - nothing runs at that moment - and the run is when
        // this tool acts on it. Showing only the first read as an appointment.
        var run = CC.renewalRun(c.renewAfter, lastRenewTask);
        if (run) {
          b.appendChild(el('div', 'd', 'Renews ' + fmtDateTime(run)));
          b.appendChild(el('div', 'g', 'CA window opens ' + fmtDateTime(c.renewAfter)));
        } else {
          // No usable schedule to work from, so the window is all that can be
          // said honestly - naming a run time would be inventing one.
          b.appendChild(el('div', 'd', 'CA window opens ' + fmtDateTime(c.renewAfter)));
        }
      } else {
        b.appendChild(el('div', 'd', 'Renewal date not known yet'));
      }

      // Renewal and deployment are separate things. A certificate with nothing
      // assigned renews and then sits on disk - renew.ps1 logs it and carries
      // on, so "automation is on" reads as more reassuring than it should.
      var tg = targetsFor(c.certId);
      if (tg.length) {
        b.appendChild(el('div', 'g', 'deploys to ' + tg.map(targetLabel).join(', ')));
      } else if (isTracker(c.certId)) {
        // Deployed nowhere BY DESIGN - this is the certificate serving this
        // page, and it belongs to the tool rather than to a load balancer.
        // Warning about it would train people to ignore a warning that is real
        // on every other row.
        b.appendChild(el('div', 'g', 'serves this console — nothing to deploy'));
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
      automationAlerts(alertsBox, a, callout, res.forecast);

      // Prepended so the schedule reads before the history beside it.
      cardRow.insertBefore(renewalsCard(res), cardRow.firstChild);

      // Cached for the domain table, which renders before this returns. The
      // re-render is what makes the badges pick it up on the first paint too.
      lastRenewTask = taskOf(a, 'renew');
      if (res.forecast && !lastForecast) { lastForecast = res.forecast; render(); }
      else { lastForecast = res.forecast; }
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

  /* What is still missing on a new install.

     Setup collects the things that must exist before a certificate can - an
     administrator, a DNS credential, the console's own name. Everything after
     that lives here, and until now nothing said so: a fresh install rendered a
     working-looking console with no domains, no alert address, and no way to
     know either was expected.

     A checklist rather than a wizard, deliberately. A wizard owns the order and
     has to be finished or abandoned; this is a list of what is not done yet
     that disappears as it gets done, and never blocks anybody who wants to go
     straight to the page they came for.

     It removes itself when the essential rows are complete. Nothing to dismiss,
     because a dismiss button is a way to hide an incomplete install from
     yourself - and the next person to open it would see a console that looks
     finished. */
  function renderFirstRun(host){
    var s = CC.state;
    if (!s) { return; }

    var data = CC.sslData;
    var watching = !!(data && data.results && data.results.length);
    var haveCert = !!((s.certs || []).length);

    var alerts = (s.settings && s.settings.alerts) || {};
    var smtp = alerts.smtp || {};

    /* Configured, or explicitly declined. Both are decisions; only the absence
       of one is unfinished business.
       Without the second half this row could never be satisfied by somebody who
       does not want email, and a card headed "Finish setting up" would sit on
       their Home page for the life of the install - which is the exact failure
       this panel is supposed to avoid, since a card that is always there is one
       nobody reads on the day it has something new to say. */
    var alerting = !!(smtp.host && (smtp.to || []).length) || !!alerts.none;

    var rows = [
      {done: watching, label: 'Watch some certificates',
       note: 'Add the names you want tracked.', href: '#/certificates'},
      {done: haveCert, label: 'Issue a certificate',
       note: 'Cert Camel renews what it has issued, and what it has been told to watch.', href: '#/certificates'},
      {done: alerting, label: 'Decide about alerts',
       note: 'Expiry and failure warnings go nowhere until an address is set — or tick "this install does not send email".',
       href: '#/settings/alerts'}
    ];

    // Everything essential is done - say nothing at all.
    if (rows.every(function(r){ return r.done; })) { return; }

    var wrap = el('div', 'card');
    wrap.appendChild(el('h4', null, 'Finish setting up'));
    wrap.appendChild(el('p', 'hint',
      'Setup handled the parts that need administrator. These are the rest, and they can be done ' +
      'in any order.'));

    rows.forEach(function(r){
      var line = el('div', 'mini');
      line.appendChild(el('span', 'st ' + (r.done ? 'ok' : 'unknown'), r.done ? 'done' : 'to do'));
      line.appendChild(document.createTextNode(' '));
      if (r.done) {
        line.appendChild(document.createTextNode(r.label));
      } else {
        var a = el('a', null, r.label);
        a.href = r.href;
        line.appendChild(a);
        line.appendChild(document.createTextNode(' — ' + r.note));
      }
      wrap.appendChild(line);
    });

    host.appendChild(wrap);
  }

  /* How much of the authority's weekly allowance has been spent.

     Shown only once something is close to a limit. A row of "2 of 50" on a
     healthy install is noise, and a panel that is almost always green teaches
     people not to look at it — so it appears when it has something to say and
     is otherwise absent.

     The duplicate limit is the one that matters. Five identical certificates a
     week sounds like plenty until a retry loop spends them in an afternoon, and
     the failure at the far end is a certificate authority refusing to issue
     while the console reports nothing wrong.

     The caveat is not a footnote here. This counts what THIS install recorded;
     another machine, another tool or a colleague issuing for the same domain
     spends the same allowance invisibly. A number that reads as authoritative
     and is not would be trusted at exactly the wrong moment. */
  function renderRateLimits(box){
    var rl = CC.state && CC.state.rateLimits;
    if (!rl) { return; }

    var rows = [];
    (rl.duplicates || []).forEach(function(d){
      if (d.used >= Math.ceil(d.limit * 0.6)) {
        rows.push({name: d.name, used: d.used, limit: d.limit, kind: 'identical certificates'});
      }
    });
    (rl.perDomain || []).forEach(function(d){
      if (d.used >= Math.ceil(d.limit * 0.6)) {
        rows.push({name: d.name, used: d.used, limit: d.limit, kind: 'certificates for this domain'});
      }
    });
    if (!rows.length) { return; }

    var wrap = el('div', 'card');
    wrap.appendChild(el('h4', null, 'Approaching a rate limit'));

    rows.forEach(function(r){
      var line = el('div', 'mini' + (r.used >= r.limit ? ' bad' : ''));
      line.textContent = r.name + ' — ' + r.used + ' of ' + r.limit + ' ' + r.kind +
                         ' in the last ' + rl.days + ' days';
      wrap.appendChild(line);
    });

    wrap.appendChild(el('p', 'hint',
      'Counted from this install’s own audit trail. The certificate authority publishes no way to ' +
      'ask, so anything issued for these names elsewhere — another machine, another tool, a ' +
      'colleague — spends the same allowance and is not counted here. Treat these as a minimum.'));

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
