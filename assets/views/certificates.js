/* Certificates: the renewal table, Check Now, Renew All, and the target-picker
   dialog shared by assign/renew/deploy. Ported from the single-page version's
   live-mode logic with the same behaviour - the picker dialog markup lives once
   in the shell (ssl-tracker.html) since it is a modal, not part of this view's
   own DOM, so its listeners are wired once rather than on every visit. */
(function(){
  "use strict";
  var CC = window.CertCamel;
  var el = CC.el, api = CC.api, daysUntil = CC.daysUntil, fmtDate = CC.fmtDate, ago = CC.ago;
  var RENEW_DAYS = CC.RENEW_DAYS;

  function certDays(c){ return c.notAfter ? daysUntil(c.notAfter) : null; }

  // --- Row actions menu -------------------------------------------------- //
  // Only one open at a time, and it lives on document.body rather than inside
  // the cell: .tablewrap sets overflow-x:auto, which per spec makes overflow-y
  // auto too, so a menu rendered inside a row would be clipped by the table.
  var openMenu = null;

  function closeRowMenu(){
    if (!openMenu) { return; }
    if (openMenu.el.parentNode) { openMenu.el.parentNode.removeChild(openMenu.el); }
    openMenu.trigger.setAttribute('aria-expanded', 'false');
    openMenu = null;
    document.removeEventListener('keydown', onMenuKey, true);
    document.removeEventListener('mousedown', onMenuOutside, true);
    window.removeEventListener('scroll', closeRowMenu, true);
    window.removeEventListener('resize', closeRowMenu);
  }

  function onMenuKey(e){
    if (e.key === 'Escape') {
      var t = openMenu && openMenu.trigger;
      closeRowMenu();
      if (t) { t.focus(); }   // Escape should land you back where you opened it
    }
  }
  function onMenuOutside(e){
    if (!openMenu) { return; }
    if (openMenu.el.contains(e.target) || openMenu.trigger.contains(e.target)) { return; }
    closeRowMenu();
  }

  function buildRowMenu(items, forName){
    var trigger = el('button', 'btn sm menu-trigger', '⋯');
    trigger.type = 'button';
    trigger.setAttribute('aria-haspopup', 'true');
    trigger.setAttribute('aria-expanded', 'false');
    trigger.title = 'More actions for ' + forName;
    trigger.setAttribute('aria-label', 'More actions for ' + forName);

    trigger.addEventListener('click', function(){
      // A second click on the same trigger closes rather than reopening.
      if (openMenu && openMenu.trigger === trigger) { closeRowMenu(); return; }
      closeRowMenu();

      var menu = el('div', 'rowmenu');
      menu.setAttribute('role', 'menu');

      items.forEach(function(it){
        var node;
        if (it.kind === 'link') {
          node = el('a', null, it.label);
          node.href = it.href;
          // The browser handles the download; just get the menu out of the way.
          node.addEventListener('click', function(){ closeRowMenu(); });
        } else {
          node = el('button', null, it.label);
          node.type = 'button';
          node.addEventListener('click', function(){ closeRowMenu(); it.run(); });
        }
        node.title = it.title || '';
        node.setAttribute('role', 'menuitem');
        menu.appendChild(node);
      });

      document.body.appendChild(menu);

      // Positioned from the trigger, then nudged back inside the viewport if it
      // would hang off the bottom or the right edge.
      var r = trigger.getBoundingClientRect();
      var mw = menu.offsetWidth, mh = menu.offsetHeight;
      var left = Math.min(r.right - mw, window.innerWidth - mw - 8);
      var top  = (r.bottom + mh + 8 > window.innerHeight) ? (r.top - mh - 4) : (r.bottom + 4);
      menu.style.left = Math.max(8, left) + 'px';
      menu.style.top  = Math.max(8, top) + 'px';

      trigger.setAttribute('aria-expanded', 'true');
      openMenu = { el: menu, trigger: trigger };

      document.addEventListener('keydown', onMenuKey, true);
      document.addEventListener('mousedown', onMenuOutside, true);
      // Capture phase: the scroll that matters is the table's, not the window's.
      window.addEventListener('scroll', closeRowMenu, true);
      window.addEventListener('resize', closeRowMenu);

      var first = menu.querySelector('button,a');
      if (first) { first.focus(); }
    });

    return trigger;
  }

  // Anything another system renews is excluded from bulk renewal, so "Renew all
  // expiring" can never quietly issue a second certificate for something already
  // looked after elsewhere.
  function isExpiring(c){
    if (c.external) { return false; }
    var d = certDays(c);
    return d === null || d <= RENEW_DAYS;
  }

  // Edits domains.txt in the browser rather than requiring a text editor and a
  // trip back to this folder. Collapsed by default - it is not needed on every
  // visit, and a raw textarea sitting open above the certificate table would
  // fight the table for attention.
  //
  // render() rebuilds this view's whole DOM from scratch on every visit AND
  // whenever server state changes underneath it - a background job finishing
  // is enough to trigger that. Module-level state, not a render-local
  // variable, is what lets an in-progress edit survive that rebuild: a job
  // completing while someone is mid-edit here must not silently discard what
  // they typed, the same reasoning the settings pages already apply to
  // switching between panels.
  var domainsOpen    = false;
  var domainsText     = null;   // last known content; null until first load completes
  var domainsLoading  = false;

  function buildDomainsEditor(toggleBtn){
    var card = el('div', 'card wide' + (domainsOpen ? '' : ' hidden'));
    card.appendChild(el('h4', null, 'domains.txt'));
    card.appendChild(CC.guideHint(
      'One host per line. "[Category Name]" groups everything below it, "#" starts a comment, ' +
      'and certificates group by DNS zone on their own.', 'domains'));
    /* NOT condensed, and the comment below is why: this is the one rule that is
       not self-evident from the file, and it exists to reach people who already
       have a domains.txt and so never see the shipped sample's header. Those are
       exactly the people who will not click through to the guide either, so a
       link here would reach nobody it was written for. */
    card.appendChild(el('p', 'hint',
      'Listing a domain and its wildcard together (example.com and *.example.com) is fine. ' +
      'The apex goes on the wildcard certificate, because *.example.com does not match a bare ' +
      'example.com — the other certificate leaves it out so the two never compete for one name. ' +
      'Both stay watched.'));

    var ta = document.createElement('textarea');
    ta.className = 'domains-text';
    ta.spellcheck = false;
    if (domainsText !== null) { ta.value = domainsText; }
    ta.addEventListener('input', function(){ domainsText = ta.value; });
    card.appendChild(ta);

    var status = el('p', 'status-line');
    card.appendChild(status);
    if (domainsLoading) { status.textContent = 'Loading...'; }

    function setStatus(text, cls){
      status.className = 'status-line' + (cls ? ' ' + cls : '');
      status.textContent = text || '';
    }

    var actions = el('div', 'toolbar');
    var saveBtn = el('button', 'btn primary', 'Save & check now');
    saveBtn.type = 'button';
    var cancelBtn = el('button', 'btn', 'Cancel');
    cancelBtn.type = 'button';
    actions.appendChild(saveBtn);
    actions.appendChild(cancelBtn);
    card.appendChild(actions);

    function close(){ domainsOpen = false; domainsText = null; card.classList.add('hidden'); }

    cancelBtn.addEventListener('click', close);

    saveBtn.addEventListener('click', function(){
      setStatus('Saving...');
      saveBtn.disabled = true;
      api('POST', '/api/domains', {content: ta.value}, function(err){
        saveBtn.disabled = false;
        if (err) { setStatus(err, 'bad'); return; }
        close();
        CC.runJob('Checking certificates', 'POST', '/api/check', null);
      });
    });

    function load(){
      domainsLoading = true;
      api('GET', '/api/domains', null, function(err, res){
        domainsLoading = false;
        if (err) { setStatus(err, 'bad'); return; }
        domainsText = (res && res.content) || '';
        ta.value = domainsText;
        setStatus('');
        ta.focus();
      });
    }

    toggleBtn.addEventListener('click', function(){
      if (domainsOpen) { close(); return; }
      domainsOpen = true;
      card.classList.remove('hidden');
      load();
    });

    // Reopened by a rebuild rather than a click - state changed while it was
    // open, and load() has already run once, so re-fetching would only race
    // an in-progress edit against a network round trip for no reason.
    if (domainsOpen && domainsText === null && !domainsLoading) { load(); }

    return card;
  }

  function render(){
    // The menu lives on document.body, so a re-render (a finished job, a state
    // refresh) would otherwise strip its trigger out of the table and leave the
    // menu floating with nothing behind it.
    closeRowMenu();

    var host = document.getElementById('view-certificates');
    host.textContent = '';

    var head = el('div', 'viewhead');
    head.appendChild(el('h2', null, 'Certificates'));
    var toolbar = el('div', 'toolbar');
    var checkBtn = el('button', 'btn', 'Check now');
    checkBtn.type = 'button'; checkBtn.id = 'btn-check'; checkBtn.setAttribute('data-busy-disable', '');
    checkBtn.addEventListener('click', function(){
      CC.runJob('Checking certificates', 'POST', '/api/check', null);
    });
    toolbar.appendChild(checkBtn);
    var editBtn = el('button', 'btn', 'Edit domains');
    editBtn.type = 'button';
    toolbar.appendChild(editBtn);
    head.appendChild(toolbar);
    host.appendChild(head);

    host.appendChild(buildDomainsEditor(editBtn));

    var state = CC.state;
    var certs = (state && state.certs) || [];

    if (!certs.length) {
      var empty = el('div', 'empty');
      empty.appendChild(el('h3', null, 'No certificates yet'));
      empty.appendChild(el('p', null,
        'Run Check now, then add at least one certificate authority and DNS profile under Settings.'));
      host.appendChild(empty);
      return;
    }

    /* The console's own certificate comes out of the table entirely and gets
       its own card below it. In a row it had to answer columns that make no
       sense for it — "Deployed" said "not deployed", which reads as a fault when
       it is the design: it belongs to this tool, not to any load balancer. */
    var trackerCerts = certs.filter(function(c){ return c.tracker; });
    certs = certs.filter(function(c){ return !c.tracker; });

    certs = certs.slice().sort(function(a, b){
      var da = certDays(a), db = certDays(b);
      if (da === null && db === null) { return String(a.displayName || a.zone).localeCompare(String(b.displayName || b.zone)); }
      if (da === null) { return 1; }
      if (db === null) { return -1; }
      return da - db;
    });

    /* Not "one per DNS zone" any more — a zone can produce three: the SAN
       certificate, a wildcard, and this console's own. Says what is actually
       true instead, which is the part that matters when deciding what a Renew
       will take with it. */
    var intro = el('p', 'mini',
      certs.length + (certs.length === 1 ? ' certificate' : ' certificates') +
      '. Renewing one renews every name on it.');
    host.appendChild(intro);

    var actionsRow = el('div', 'toolbar');
    var renewAll = el('button', 'btn primary', 'Renew all expiring');
    renewAll.type = 'button'; renewAll.id = 'btn-renew-all'; renewAll.setAttribute('data-busy-disable', '');
    renewAll.addEventListener('click', function(){
      var expiring = certs.filter(isExpiring);
      if (expiring.length) { openPicker('renew', expiring.map(function(c){ return c.certId; })); }
    });
    actionsRow.appendChild(renewAll);
    host.appendChild(actionsRow);

    var tw = el('div', 'tablewrap');
    var table = document.createElement('table');
    table.id = 'certtable';
    table.innerHTML = '<thead><tr><th>Certificate</th><th>Covers</th><th>Issuer</th>' +
      '<th>Expires</th><th class="n">Days left</th><th>Deployed</th><th></th></tr></thead>';
    var body = document.createElement('tbody');
    table.appendChild(body);
    tw.appendChild(table);
    host.appendChild(tw);

    certs.forEach(function(c){
      var days = certDays(c);
      var tr = el('tr');

      var name = el('td', 'host');
      name.appendChild(document.createTextNode(c.displayName || c.zone));
      if (c.wildcard)   { name.appendChild(el('span', 'badge cool', 'wildcard')); }
      if (c.overridden) { name.appendChild(el('span', 'badge', 'custom')); }
      if (c.external) {
        var eb = el('span', 'badge cool', 'managed elsewhere');
        eb.title = 'Renewed by another system. Watched here, never issued from here.';
        name.appendChild(eb);
      }
      tr.appendChild(name);

      var covers = el('td', 'names', (c.names || []).join(', '));
      if (c.deferredNames && c.deferredNames.length) {
        covers.appendChild(el('div', 'mini', 'Not included: ' + c.deferredNames.join(', ')));
      }
      // Deliberately its own line, not folded into "Not included". That one is a
      // warning - the live certificate has names this renewal would drop. This
      // is the opposite: the name IS covered, by the sibling wildcard, on
      // purpose.
      if (c.apexOnWildcard) {
        covers.appendChild(el('div', 'mini', c.zone + ' is on the wildcard certificate for this zone'));
      }
      // The rule has changed what will be issued, but the certificate on disk
      // predates it and still carries the moved name - so it is still competing
      // for it wherever it is deployed.
      if (c.staleNames && c.staleNames.length) {
        var stale = el('div', 'mini warnline',
          'Issued copy still carries ' + c.staleNames.join(', ') + ' — renew to apply');
        stale.title = 'The certificate currently on disk was issued before this zone gained a wildcard. ' +
                      'Until it is renewed it still claims that name, and whichever certificate HAProxy ' +
                      'matches first will serve it.';
        covers.appendChild(stale);
      }
      tr.appendChild(covers);

      var caCell = el('td');
      var caSel = document.createElement('select');
      caSel.className = 'ca-pick';
      ((state.settings && state.settings.cas) || []).forEach(function(ca){
        var o = document.createElement('option');
        o.value = ca.id;
        o.textContent = ca.label + (ca.useStaging ? ' (staging)' : '');
        if (ca.id === c.caId) { o.selected = true; }
        caSel.appendChild(o);
      });
      caSel.disabled = !!c.external;
      caSel.title = c.caInherited ? 'Following the default certificate authority' : 'Pinned to this certificate authority';
      caSel.addEventListener('change', function(){
        api('POST', '/api/cert/' + encodeURIComponent(c.certId) + '/ca', {caId: caSel.value}, function(err){
          if (err) { window.alert(err); }
          CC.loadState();
        });
      });
      caCell.appendChild(caSel);
      if (c.caInherited) { caCell.appendChild(el('div', 'mini', 'default')); }
      tr.appendChild(caCell);

      tr.appendChild(el('td', 'dim', c.notAfter ? fmtDate(c.notAfter) : '—'));

      var d = el('td', 'n days', days === null ? '—' : days + ' d');
      if (days !== null && days < 0)                { tr.className = 'gone'; }
      else if (days !== null && days <= RENEW_DAYS)  { tr.className = 'soon'; }
      tr.appendChild(d);

      tr.appendChild(deploymentCell(c));

      // Renew stays a visible button - it is the action people come here for,
      // and burying the common case behind two clicks is a downgrade. The rest
      // go in the menu, which is what removes four buttons from every row.
      var acts = el('td', 'acts');
      var items = [];

      if (c.hasLocalCert) {
        items.push({
          kind: 'link',
          label: 'Download certificate files',
          title: 'Download the certificate, chain and private key as one PEM file',
          href: '/api/download/' + encodeURIComponent(c.certId) + '?t=' + encodeURIComponent(CC.TOKEN)
        });
      }
      /* The deployment cell used to be the ONLY way to reach this, with nothing
         saying so - a status column that happened to be clickable. That is not
         somewhere anybody looks for an action, and it cost a real misdiagnosis:
         a group read as needing a push when the certificate was simply never
         assigned to it. It is offered here whether or not anything is assigned
         yet, because "none yet" is exactly the case that needs finding. */
      if (!c.external) {
        var hasTargets = (c.targets || []).length;
        items.push({
          label: hasTargets ? 'Change load balancers' : 'Assign load balancers',
          title: hasTargets
            ? 'Change which load balancer groups this certificate deploys to'
            : 'Choose which load balancer groups this certificate deploys to. ' +
              'Until one is chosen, renewal pushes it nowhere.',
          run: function(){ openPicker('assign', [c.certId]); }
        });
      }
      if (!c.external && c.hasLocalCert && (c.targets || []).length) {
        items.push({
          label: 'Deploy to load balancers',
          title: 'Push this certificate to its load balancers and verify each one is serving it',
          run: function(){ openPicker('deploy', [c.certId]); }
        });
      }
      items.push({
        label: c.external ? 'Renew here' : 'Managed elsewhere',
        title: c.external
          ? 'Bring this certificate back under this tool'
          : 'Mark this as renewed by another system: keep watching it, but never issue it from here',
        run: function(){
          api('POST', '/api/cert/' + encodeURIComponent(c.certId) + '/external', {external: !c.external}, function(err){
            if (err) { window.alert(err); return; }
            CC.loadState();
          });
        }
      });

      if (!c.external) {
        var rb = el('button', 'btn sm primary', 'Renew');
        rb.type = 'button';
        rb.addEventListener('click', function(){ openPicker('renew', [c.certId]); });
        acts.appendChild(rb);
      }
      acts.appendChild(buildRowMenu(items, c.displayName || c.zone));
      tr.appendChild(acts);
      body.appendChild(tr);
    });

    var expiring = certs.filter(isExpiring);
    var skipped  = certs.filter(function(c){ return c.external; }).length;
    renewAll.disabled = !expiring.length;
    renewAll.textContent = expiring.length ? 'Renew ' + expiring.length + ' expiring' : 'Nothing expiring';
    renewAll.title = skipped ? skipped + ' certificate(s) marked "managed elsewhere" are never included' : '';

    trackerCerts.forEach(function(c){ host.appendChild(trackerCard(c)); });
  }

  /* The console's own certificate, on its own. Separate from the table because
     it answers different questions: not "where is this deployed and when do I
     renew it", but "what is serving this page, is it still being looked after,
     and where is the file". Nothing here needs deciding, which is the point. */
  function trackerCard(c){
    var card = el('div', 'card wide trackercard');

    var h = el('h3', null, 'This console');
    h.appendChild(el('span', 'badge cool', c.displayName || c.certId));
    card.appendChild(h);

    card.appendChild(el('p', 'mini',
      'The address this page is served on. It has its own certificate so that editing your ' +
      'production list can never affect it, and it is deployed nowhere — it belongs to this tool, ' +
      'not to a load balancer.'));

    var days = certDays(c);
    var grid = el('div', 'trackerfacts');

    function fact(k, v, cls){
      var d = el('div', 'fact');
      d.appendChild(el('div', 'k', k));
      d.appendChild(el('div', 'v' + (cls ? ' ' + cls : ''), v));
      return d;
    }
    grid.appendChild(fact('Covers', (c.names || []).join(', ')));
    grid.appendChild(fact('Issuer', c.caLabel || '—'));
    grid.appendChild(fact('Expires', c.notAfter ? new Date(c.notAfter).toLocaleDateString() : '—'));
    grid.appendChild(fact('Days left', days === null ? '—' : String(days),
                          (days !== null && days <= 14) ? 'bad' : ''));
    grid.appendChild(fact('Renewal',
      c.external ? 'NOT renewed here — this certificate is marked managed elsewhere'
                 : 'Automatic. Renewed and applied without anything to press.',
      c.external ? 'bad' : 'good'));
    card.appendChild(grid);

    var acts = el('div', 'page-actions');
    if (!c.external) {
      var rb = el('button', 'btn sm primary', 'Renew now');
      rb.type = 'button';
      /* Straight to the job, deliberately NOT through openPicker('renew', ...).
         That dialog exists to ask which load balancer groups to push to
         afterwards, and for this certificate the answer is always none - it
         deploys nowhere, which is the entire reason it is split out. Asking
         anyway made the one certificate that CANNOT be deployed the only one
         you had to answer a deployment question for.

         Nothing is lost by skipping it. Its summary line was the name and the
         issuer, both already in the grid above, and its rate-limit warning now
         sits under the button - where it is read before clicking rather than
         after. */
      rb.addEventListener('click', function(){
        CC.runJob('Renewing ' + (c.displayName || c.certId), 'POST', '/api/renew',
                  {zones: [c.certId], targets: []});
      });
      acts.appendChild(rb);
    }
    if (c.hasLocalCert) {
      var dl = el('a', 'btn sm', 'Download');
      dl.href = '/api/download/' + encodeURIComponent(c.certId) + '?t=' + encodeURIComponent(CC.TOKEN);
      acts.appendChild(dl);
    }
    card.appendChild(acts);
    if (!c.external && !c.caStaging) {
      card.appendChild(el('p', 'hint',
        'Renewing places a production order, which counts against the certificate authority rate limits.'));
    }
    return card;
  }

  function deploymentCell(c){
    var td = el('td', 'deploy');
    var state = CC.state;
    var dep = (state.deployment || {})[c.certId] || {};
    var assigned = c.targets || dep.targets || [];

    function assignButton(label, title){
      var b = el('button', 'btn sm', label);
      b.type = 'button';
      b.title = title;
      b.addEventListener('click', function(){ openPicker('assign', [c.certId]); });
      return b;
    }

    if (!assigned.length) {
      /* "not deployed" and "not assigned" are different facts, and reading the
         first when the second is true is what sends somebody hunting for a push
         that was never going to happen. Renewal only pushes to ASSIGNED groups,
         so an unassigned certificate is not waiting to be deployed - it is
         waiting to be told where, and nothing will ever change that on its own.

         Only worth distinguishing when there is somewhere to assign it to. With
         no groups configured at all, "not deployed" is simply the truth. */
      var haveGroups = (((state.settings || {}).targets) || []).length > 0;
      td.appendChild(assignButton(
        haveGroups ? 'not assigned' : 'not deployed',
        haveGroups
          ? 'Not assigned to any load balancer, so renewal will never push it anywhere. ' +
            'Click to choose where it should go.'
          : 'No load balancers configured yet. Click to set one up.'));
      return td;
    }
    if (!dep.last) {
      td.appendChild(assignButton('never pushed',
        'Assigned to ' + assigned.join(', ') + ', but not pushed yet. Click to change.'));
      return td;
    }

    /* ONE PIP PER ASSIGNED GROUP, not per node of the last run.
       Rendering the last run's nodes meant a certificate deployed to prod and
       then to test showed only test - which reads as "prod still needs doing"
       when prod was done first. Now every group this certificate is assigned to
       appears, coloured by what is known about THAT group, with its own last
       deployed time on hover. A group never pushed to says so outright. */
    var stack = el('div', 'deploy-stack');
    var wrap = el('div', 'pips');
    var byTarget = (dep.last && dep.last.byTarget) || {};

    /* Records written before per-group history existed have no byTarget, so
       rebuild what can be known from the last run rather than reporting every
       group as "never pushed" — which would be a fresh lie told to every
       existing install on upgrade. Groups outside that run stay unknown, which
       is honest: nothing on disk says when they were last deployed to. */
    if (!Object.keys(byTarget).length && dep.last && dep.last.targets) {
      dep.last.targets.forEach(function(t){
        byTarget[t.targetId] = {
          targetId: t.targetId, label: t.label, ok: t.ok, at: dep.last.at,
          nodes: (t.nodes || []).map(function(n){
            var checks = n.verify || [];
            var hardFailed = checks.filter(function(v){
              return !v.ok && !(v.contested && v.role === 'coverage');
            }).length;
            var proved = checks.filter(function(v){ return v.ok && v.role === 'identity'; }).length;
            return { name: n.name,
                     ok: !!(n.push && n.push.ok) && !!checks.length && hardFailed === 0 && !!proved };
          })
        };
      });
    }
    var labels = {};
    ((CC.state && CC.state.settings && CC.state.settings.targets) || []).forEach(function(t){
      labels[t.id] = t.label || t.id;
    });

    /* Assigned groups, PLUS any group this certificate has actually been
       deployed to. Looping the assignment alone hid a real deployment: pushing
       from the deploy dialog can target a group the certificate is not assigned
       to, and that push is exactly the one worth showing - it happened, and
       nothing will repeat it. */
    var shown = assigned.slice();
    Object.keys(byTarget).forEach(function(tid){
      if (shown.indexOf(tid) === -1) { shown.push(tid); }
    });

    var newest = null;
    shown.forEach(function(tid){
      var rec = byTarget[tid];
      var label = (rec && rec.label) || labels[tid] || tid;
      var isAssigned = assigned.indexOf(tid) !== -1;

      /* Deployed to, but not assigned. Renewal only pushes to assigned groups,
         so this certificate is live there now and will silently stop being
         updated - the group keeps serving whatever was last pushed by hand
         until it expires. Amber rather than red: nothing is broken yet, and
         that is precisely why it is easy to miss. */
      if (rec && !isAssigned) {
        var pw = el('span', 'pip warn', label);
        pw.title = label + ': deployed here ' + new Date(rec.at).toLocaleString() +
                   ', but NOT assigned to this certificate.\n' +
                   'Renewal pushes only to assigned groups, so this one will not be ' +
                   'updated automatically. Click the time to assign it.';
        wrap.appendChild(pw);
        if (!newest || new Date(rec.at) > new Date(newest)) { newest = rec.at; }
        return;
      }

      if (!rec) {
        var p0 = el('span', 'pip', label);
        p0.title = label + ': never pushed. This certificate is assigned here but has not been ' +
                   'deployed to it yet.';
        wrap.appendChild(p0);
        return;
      }

      var bad = (rec.nodes || []).filter(function(n){ return !n.ok; });
      var cls = rec.ok && !bad.length ? 'good' : 'bad';
      var pip = el('span', 'pip ' + cls, label);

      var why = [label + ': last deployed ' + new Date(rec.at).toLocaleString()];
      (rec.nodes || []).forEach(function(n){
        why.push('  ' + n.name + ': ' + (n.ok ? 'serving it' : 'NOT serving it'));
      });
      if (!rec.nodes || !rec.nodes.length) { why.push('  no node detail recorded'); }
      pip.title = why.join('\n');
      wrap.appendChild(pip);

      if (!newest || new Date(rec.at) > new Date(newest)) { newest = rec.at; }
    });
    stack.appendChild(wrap);

    var when = el('button', 'btn sm', ago(newest || dep.last.at));
    when.type = 'button';
    when.title = 'Most recent deployment ' + new Date(newest || dep.last.at).toLocaleString() +
                 '. Hover a group for its own time. Click to change where this goes.';
    when.addEventListener('click', function(){ openPicker('assign', [c.certId]); });
    stack.appendChild(when);
    td.appendChild(stack);
    return td;
  }

  // --- The target picker (assign / renew / deploy) --------------------------- //
  // Lives in the shell's DOM (#picker), wired once, driven from here.

  var pickMode = null, pickCerts = [];
  var pickerWired = false;

  function openPicker(mode, certIds){
    wirePicker();

    var byId = {};
    ((CC.state && CC.state.certs) || []).forEach(function(c){ byId[c.certId] = c; });

    pickMode = mode;
    pickCerts = certIds;

    var groups = ((CC.state && CC.state.settings && CC.state.settings.targets) || []);
    var titles = {assign: 'Where should this deploy?', renew: 'Renew', deploy: 'Deploy'};
    var subs = {
      assign: 'Saved against the certificate. Unattended renewals use this, so it is also what runs at 3am when nobody is here to choose.',
      renew:  'Renew now, then push to these. Leave everything unticked to renew only and push nothing.',
      deploy: 'Push the certificate already on disk to these, then check each node is really serving it.'
    };

    document.getElementById('picktitle').textContent = titles[mode];
    document.getElementById('pick-sub').textContent  = subs[mode];
    document.getElementById('pick-ok').textContent   =
      mode === 'assign' ? 'Save' : (mode === 'renew' ? 'Renew' : 'Deploy');

    var certBox = document.getElementById('pick-certs');
    certBox.textContent = '';
    var anyProd = false;
    certIds.forEach(function(id){
      var c = byId[id];
      if (!c) { return; }
      var line = el('div', 'mini');
      line.appendChild(el('strong', null, c.displayName));
      if (mode === 'renew') {
        line.appendChild(document.createTextNode('  ' + c.caLabel + (c.caStaging ? '  (staging)' : '  (PRODUCTION)')));
        if (!c.caStaging) { anyProd = true; }
      }
      certBox.appendChild(line);
    });
    if (mode === 'renew' && anyProd) {
      certBox.appendChild(el('p', 'hint', 'Production orders count against the certificate authority rate limits.'));
    }

    var assigned = {};
    certIds.forEach(function(id){
      ((byId[id] && byId[id].targets) || []).forEach(function(t){ assigned[t] = true; });
    });

    var box = document.getElementById('pick-targets');
    box.textContent = '';

    if (!groups.length) {
      var none = el('div', 'callout warn');
      none.appendChild(el('div', 'h', 'No load balancers configured'));
      var p = el('p', null, 'Add one under Certificate Deployments first. ');
      var go = el('a', 'btn sm', 'Open settings');
      go.href = '#/settings/deployments';
      go.addEventListener('click', closePicker);
      p.appendChild(go);
      none.appendChild(p);
      box.appendChild(none);
    } else {
      // What this certificate has already pinned for each group, so reopening
      // the dialog shows the overrides rather than silently dropping them.
      var boundOverrides = {};
      if (mode === 'assign' && certIds.length === 1) {
        var depNow = ((CC.state && CC.state.deployment) || {})[certIds[0]] || {};
        (depNow.bindings || []).forEach(function(b){ boundOverrides[b.id] = b.overrides || {}; });
      }

      groups.forEach(function(g){
        var f = el('div', 'field');
        var lab = el('label', 'check');
        var cb = document.createElement('input');
        cb.type = 'checkbox';
        cb.className = 'pick-target';
        cb.value = g.id;
        cb.checked = !!assigned[g.id];
        lab.appendChild(cb);
        var txt = el('span', null, g.label);
        txt.appendChild(el('span', 'mini', '  ' + ((g.nodes || []).map(function(n){ return n.name; }).join(', ') || 'no nodes')));
        lab.appendChild(txt);
        f.appendChild(lab);

        // Per-certificate overrides, assign mode only. A group answers "which
        // nodes and what credentials"; a crt-list answers "where is this
        // certificate referenced" - so one pair of nodes can front two
        // frontends without defining the nodes twice.
        if (mode === 'assign' && certIds.length === 1) {
          var ov = boundOverrides[g.id] || {};
          var hasOv = Object.keys(ov).length > 0;

          var det = document.createElement('details');
          det.className = 'pick-advanced';
          det.open = hasOv;                       // already pinned: show it
          var sum = document.createElement('summary');
          sum.textContent = hasOv ? 'Overrides for this certificate (set)' : 'Overrides for this certificate';
          det.appendChild(sum);

          // Inherited values shown as placeholders, so blank plainly means
          // "whatever the group says" rather than "empty".
          [['crtList', 'crt-list path'], ['verifyPort', 'Verify port'], ['remoteName', 'Certificate filename']]
            .forEach(function(pair){
              var key = pair[0], label = pair[1];
              var wrap = el('div', 'field');
              wrap.appendChild(el('label', null, label));
              var inp = document.createElement('input');
              inp.type = 'text';
              inp.className = 'pick-ov';
              inp.setAttribute('data-target', g.id);
              inp.setAttribute('data-key', key);
              inp.autocomplete = 'off';
              inp.value = (ov[key] !== undefined && ov[key] !== null) ? String(ov[key]) : '';
              var inherited = (g.args && g.args[key] !== undefined && g.args[key] !== null && g.args[key] !== '')
                ? String(g.args[key]) : '';
              inp.placeholder = inherited ? ('inherits ' + inherited) : 'inherits the group setting';
              wrap.appendChild(inp);
              det.appendChild(wrap);
            });

          f.appendChild(det);
        }

        box.appendChild(f);
      });
    }

    setPickStatus('');
    document.getElementById('picker').classList.remove('hidden');
  }

  function closePicker(){ document.getElementById('picker').classList.add('hidden'); }

  function setPickStatus(text, cls){
    var s = document.getElementById('pick-status');
    s.className = 'status-line' + (cls ? ' ' + cls : '');
    s.textContent = text || '';
  }

  // Bare ids by default. A target only becomes an object when this certificate
  // actually pins something for it, so a settings file grows objects exactly
  // where someone asked for one and stays readable everywhere else.
  function pickedTargets(){
    return Array.prototype.slice.call(document.querySelectorAll('#pick-targets .pick-target'))
      .filter(function(c){ return c.checked; })
      .map(function(c){
        var id = c.value;
        var overrides = {};
        Array.prototype.slice.call(document.querySelectorAll('#pick-targets .pick-ov'))
          .filter(function(i){ return i.getAttribute('data-target') === id; })
          .forEach(function(i){
            var v = i.value.trim();
            if (v) { overrides[i.getAttribute('data-key')] = v; }
          });
        if (!Object.keys(overrides).length) { return id; }
        overrides.id = id;
        return overrides;
      });
  }

  // Renew and Deploy send a plain id list - they are choosing WHERE to run now,
  // not editing what is stored, and the backend takes ids there.
  function pickedTargetIds(){
    return pickedTargets().map(function(t){ return (typeof t === 'string') ? t : t.id; });
  }

  function confirmPicker(){
    if (pickMode === 'assign') {
      // Assign is the only mode that edits what is stored, so it is the only
      // one that sends overrides.
      setPickStatus('Saving...');
      api('POST', '/api/cert/' + encodeURIComponent(pickCerts[0]) + '/targets',
          {targets: pickedTargets()}, function(err){
        if (err) { setPickStatus(err, 'bad'); return; }
        closePicker();
        CC.loadState();
      });
      return;
    }

    var chosen = pickedTargetIds();

    if (pickMode === 'deploy' && !chosen.length) {
      setPickStatus('Pick at least one load balancer, or cancel.', 'bad');
      return;
    }

    closePicker();
    if (pickMode === 'renew') {
      CC.runJob('Renewing ' + pickCerts.join(', '), 'POST', '/api/renew', {zones: pickCerts, targets: chosen});
    } else {
      CC.runJob('Deploying ' + pickCerts.join(', '), 'POST', '/api/deploy', {certs: pickCerts, targets: chosen});
    }
  }

  function wirePicker(){
    if (pickerWired) { return; }
    pickerWired = true;
    document.getElementById('pick-cancel').addEventListener('click', closePicker);
    document.getElementById('pick-ok').addEventListener('click', confirmPicker);
    document.addEventListener('keydown', function(e){
      if (e.key === 'Escape' && !document.getElementById('picker').classList.contains('hidden')) { closePicker(); }
    });
  }

  CC.registerView('certificates', {render: render});
  CC.onStateChanged(function(){
    if (CC.currentRoute().view === 'certificates') { render(); }
  });
})();
