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
    card.appendChild(el('p', 'hint',
      'One host per line. A line like "[Category Name]" groups everything below it until the ' +
      'next one; lines before the first header are Uncategorized. "#" starts a comment. ' +
      'Certificates are grouped by DNS zone, so a new hostname joins the right certificate on ' +
      'its own - no other setup needed here.'));

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

    certs = certs.slice().sort(function(a, b){
      var da = certDays(a), db = certDays(b);
      if (da === null && db === null) { return String(a.displayName || a.zone).localeCompare(String(b.displayName || b.zone)); }
      if (da === null) { return 1; }
      if (db === null) { return -1; }
      return da - db;
    });

    var intro = el('p', 'mini',
      certs.length + (certs.length === 1 ? ' certificate' : ' certificates') +
      ', one per DNS zone. Renewing one renews every name on it.');
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
      td.appendChild(assignButton('not deployed',
        'No load balancer assigned. Click to choose where this certificate should go.'));
      return td;
    }
    if (!dep.last) {
      td.appendChild(assignButton('never pushed',
        'Assigned to ' + assigned.join(', ') + ', but not pushed yet. Click to change.'));
      return td;
    }

    var stack = el('div', 'deploy-stack');
    var wrap = el('div', 'pips');
    (dep.last.targets || []).forEach(function(t){
      (t.nodes || []).forEach(function(n){
        var pushed = n.push && n.push.ok;
        var served = (n.verify || []).length ? (n.verify || []).every(function(v){ return v.ok; }) : null;
        var cls = (pushed && served === true) ? 'good' : (pushed && served === null) ? 'warn' : 'bad';
        var pip = el('span', 'pip ' + cls, n.name);
        var why = [];
        why.push(pushed ? 'push ok' : 'push failed' + (n.push && n.push.error ? ': ' + n.push.error : ''));
        if (n.crtList) {
          why.push(n.crtList.ok
            ? 'crt-list: ' + (n.crtList.action === 'added' ? 'appended and loaded' : 'already referenced')
            : 'crt-list failed: ' + (n.crtList.error || 'not referenced'));
        }
        (n.verify || []).forEach(function(v){
          why.push(v.sni + ': ' + (v.ok ? 'serving it, ' + v.daysRemaining + ' days left' : (v.error || 'not serving it')));
        });
        pip.title = why.join('\n');
        wrap.appendChild(pip);
      });
    });
    stack.appendChild(wrap);

    var when = el('button', 'btn sm', ago(dep.last.at));
    when.type = 'button';
    when.title = 'Last deployed ' + new Date(dep.last.at).toLocaleString() +
                 '. Assigned to ' + assigned.join(', ') + '. Click to change.';
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

  function pickedTargets(){
    return Array.prototype.slice.call(document.querySelectorAll('#pick-targets .pick-target'))
      .filter(function(c){ return c.checked; })
      .map(function(c){ return c.value; });
  }

  function confirmPicker(){
    var chosen = pickedTargets();

    if (pickMode === 'assign') {
      setPickStatus('Saving...');
      api('POST', '/api/cert/' + encodeURIComponent(pickCerts[0]) + '/targets', {targets: chosen}, function(err){
        if (err) { setPickStatus(err, 'bad'); return; }
        closePicker();
        CC.loadState();
      });
      return;
    }

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
