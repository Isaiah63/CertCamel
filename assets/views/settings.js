/* Settings: General, Certificate Authorities, DNS Automation, Certificate
   Deployments, Alerts. One view, five sub-pages addressed by hash
   (#/settings/<name>), all built into the DOM at once so Save can still write
   every panel regardless of which one is visible - exactly the reason the
   original modal's tabs worked that way. The cards are only rebuilt from
   server state on first arrival at Settings, not on every sub-page switch,
   so moving between panels never discards an edit in the one you left. */
(function(){
  "use strict";
  var CC = window.CertCamel;
  var el = CC.el, api = CC.api;

  var SUBPAGES = ['general', 'authorities', 'dns', 'deployments', 'alerts'];
  var mounted = false;

  window.addEventListener('hashchange', function(){
    if (CC.currentRoute().view !== 'settings') { mounted = false; }
  });

  function render(sub){
    var name = SUBPAGES.indexOf(sub) === -1 ? 'general' : sub;
    var host = document.getElementById('view-settings');

    if (!mounted) {
      buildSkeleton(host);
      populate();
      mounted = true;
    }

    document.querySelectorAll('.subnav a[data-view="settings-sub"]').forEach(function(a){
      a.setAttribute('aria-current', a.getAttribute('data-sub') === name ? 'page' : 'false');
    });
    document.querySelectorAll('.sidebar .navitem[data-view="settings"]').forEach(function(a){
      a.setAttribute('aria-current', a.getAttribute('data-sub') === name ? 'page' : 'false');
    });
    document.querySelectorAll('#settings-panels .tabpanel').forEach(function(p){
      p.classList.toggle('hidden', p.getAttribute('data-panel') !== name);
    });
    setStatus('');
  }

  function buildSkeleton(host){
    host.textContent = '';
    host.appendChild(el('h2', null, 'Settings'));

    var nav = el('div', 'subnav');
    nav.setAttribute('role', 'tablist');
    [['general', 'General'], ['authorities', 'Certificate Authorities'], ['dns', 'DNS Automation'],
     ['deployments', 'Certificate Deployments'], ['alerts', 'Alerts']].forEach(function(pair){
      var a = el('a', null, pair[1]);
      a.href = '#/settings/' + pair[0];
      a.setAttribute('data-view', 'settings-sub');
      a.setAttribute('data-sub', pair[0]);
      a.setAttribute('role', 'tab');
      nav.appendChild(a);
    });
    host.appendChild(nav);

    var panels = el('div');
    panels.id = 'settings-panels';
    host.appendChild(panels);

    panels.appendChild(buildGeneralPanel());
    panels.appendChild(buildAuthoritiesPanel());
    panels.appendChild(buildDnsPanel());
    panels.appendChild(buildDeploymentsPanel());
    panels.appendChild(buildAlertsPanel());

    var statusLine = el('p', 'status-line');
    statusLine.id = 'set-status';
    host.appendChild(statusLine);

    var actions = el('div', 'page-actions');
    var save = el('button', 'btn primary', 'Save');
    save.type = 'button';
    save.addEventListener('click', saveSettings);
    actions.appendChild(save);
    host.appendChild(actions);
  }

  function panel(name){
    var p = el('div', 'tabpanel hidden card');
    p.setAttribute('data-panel', name);
    return p;
  }

  function setStatus(text, cls){
    var s = document.getElementById('set-status');
    if (!s) { return; }
    s.className = 'status-line' + (cls ? ' ' + cls : '');
    s.textContent = text || '';
  }

  // --- General ---------------------------------------------------------------- //

  function buildGeneralPanel(){
    var p = panel('general');
    var f = el('div', 'field');
    f.appendChild(el('label', null, 'Contact email'));
    var i = document.createElement('input');
    i.type = 'email'; i.id = 'set-contact'; i.autocomplete = 'off';
    f.appendChild(i);
    f.appendChild(el('p', 'hint', 'The certificate authority sends expiry warnings here. Required.'));
    p.appendChild(f);
    p.appendChild(el('p', 'hint',
      'Credentials on the other pages are encrypted with Windows DPAPI and stored in secrets.xml ' +
      'beside this page. They never leave this PC, and they do not travel if you copy this folder ' +
      'to another machine.'));

    p.appendChild(el('h4', null, 'Log retention'));
    p.appendChild(el('p', 'hint',
      'Applies to run logs — the narrative of each check, renewal and deployment. Whichever limit ' +
      'is reached first, the oldest are removed. Every trim is itself recorded in the audit trail, ' +
      'so a gap is always accounted for.'));

    var grid = el('div', 'fields');
    var days = el('div', 'field');
    days.appendChild(el('label', null, 'Keep run logs for (days)'));
    var di = document.createElement('input');
    di.type = 'number'; di.min = '1'; di.max = '3650'; di.id = 'set-log-days'; di.autocomplete = 'off';
    days.appendChild(di);
    grid.appendChild(days);

    var size = el('div', 'field');
    size.appendChild(el('label', null, 'Maximum log folder size (MB)'));
    var si = document.createElement('input');
    si.type = 'number'; si.min = '1'; si.max = '51200'; si.id = 'set-log-mb'; si.autocomplete = 'off';
    size.appendChild(si);
    grid.appendChild(size);
    p.appendChild(grid);

    p.appendChild(el('p', 'hint',
      'The audit trail is deliberately not covered by either limit. It records who changed what and ' +
      'when, and deleting that to reclaim disk is the opposite of what it is for — it rotates to a ' +
      'dated file instead, and the older files are kept.'));

    p.appendChild(buildAddressSection());
    return p;
  }

  // --- Tracker address ---------------------------------------------------------- //
  /* Serving this page over HTTPS. Off unless asked for, because someone looking
     at Cert Camel for the first time has no DNS credential and no wish to change
     their network — they should be able to open it and look.

     Four preconditions, each reported on its own row rather than collapsed into
     one "ready" flag. They fail in four different places — a DNS credential, a
     certificate, another program holding a port, and a file only administrators
     can write — and a single red cross would send someone hunting through all
     four. */

  function buildAddressSection(){
    var wrap = el('div');
    wrap.appendChild(el('h4', null, 'Tracker address'));
    wrap.appendChild(el('p', 'hint',
      'By default this page is served over plain HTTP at 127.0.0.1 on whichever port is free — ' +
      'nothing to set up, and it never leaves this PC. Give it a name Cert Camel already holds a ' +
      'certificate for and it will serve itself over HTTPS instead, using a certificate it issued.'));

    var on = el('label', 'check');
    var box = document.createElement('input');
    box.type = 'checkbox'; box.id = 'set-web-https';
    on.appendChild(box);
    on.appendChild(el('span', null, 'Serve this page over HTTPS'));
    wrap.appendChild(on);

    var fields = el('div', 'hidden');
    fields.id = 'set-web-fields';

    var grid = el('div', 'fields');
    var hf = el('div', 'field');
    hf.appendChild(el('label', null, 'Hostname'));
    var hi = document.createElement('input');
    hi.type = 'text'; hi.id = 'set-web-host'; hi.autocomplete = 'off';
    hi.placeholder = 'tracker.example.com';
    hf.appendChild(hi);
    hf.appendChild(el('p', 'hint', 'One name, not a wildcard. It resolves to 127.0.0.1 through this machine’s hosts file — no public DNS record is needed or wanted.'));
    grid.appendChild(hf);

    var pf = el('div', 'field');
    pf.appendChild(el('label', null, 'Port'));
    var pi = document.createElement('input');
    pi.type = 'number'; pi.min = '1'; pi.max = '65535'; pi.id = 'set-web-port'; pi.autocomplete = 'off';
    pi.placeholder = '8787';
    pf.appendChild(pi);
    pf.appendChild(el('p', 'hint', 'Fixed, not chosen at random like the default — a name is no use on a port that moves every launch.'));
    grid.appendChild(pf);
    fields.appendChild(grid);

    var actions = el('div', 'page-actions');
    var check = el('button', 'btn', 'Check');
    check.type = 'button';
    check.addEventListener('click', function(){ runPreflight(true); });
    actions.appendChild(check);
    fields.appendChild(actions);

    var rows = el('div', 'addrcheck');
    rows.id = 'set-web-check';
    fields.appendChild(rows);

    fields.appendChild(el('p', 'hint',
      'The hostname is published to public Certificate Transparency logs the moment a certificate ' +
      'covers it, whether or not it has a DNS record. That is how CT works for every certificate ' +
      'from every authority — worth knowing before picking a name you would rather not advertise.'));

    wrap.appendChild(fields);

    box.addEventListener('change', function(){
      fields.classList.toggle('hidden', !box.checked);
      if (box.checked) { runPreflight(false); }
    });
    return wrap;
  }

  function addrRow(label, ok, detail){
    var r = el('div', 'addrrow' + (ok ? ' ok' : ''));
    r.appendChild(el('span', 'addrmark', ok ? '✓' : '•'));
    r.appendChild(el('span', 'addrlabel', label));
    r.appendChild(el('span', 'addrdetail', detail || ''));
    return r;
  }

  function runPreflight(loud){
    var host = document.getElementById('set-web-host').value.trim();
    var port = parseInt(document.getElementById('set-web-port').value, 10);
    var out  = document.getElementById('set-web-check');
    if (!out) { return; }
    if (!host) { out.textContent = ''; if (loud) { setStatus('Enter a hostname first.', 'bad'); } return; }

    out.textContent = '';
    out.appendChild(el('p', 'hint', 'Checking…'));

    api('POST', '/api/web/preflight', {hostname: host, port: isNaN(port) ? 0 : port}, function(err, r){
      out.textContent = '';
      if (err) { out.appendChild(el('p', 'hint bad', err)); return; }

      out.appendChild(addrRow('DNS zone', r.zone.ok, r.zone.detail));

      var certRow = addrRow('Certificate', r.certificate.ok, r.certificate.detail);
      // Only offer the domains.txt entry when nothing already covers the name.
      // Adding one for a name a wildcard covers would pull it off that wildcard
      // and onto the zone's other certificate, which is strictly worse.
      if (!r.certificate.covered && r.zone.ok && !r.certificate.watched) {
        var add = el('button', 'btn sm', 'Add to domains.txt');
        add.type = 'button';
        add.addEventListener('click', function(){
          add.disabled = true;
          api('POST', '/api/web/domains', {hostname: r.hostname, port: r.port}, function(e2, res){
            add.disabled = false;
            if (e2) { setStatus(e2, 'bad'); return; }
            setStatus(res.changed
              ? 'Added ' + res.entry + ' to domains.txt. Renew it from the Certificates page — that takes a few minutes while DNS propagates.'
              : res.note, 'good');
            runPreflight(false);
          });
        });
        certRow.appendChild(add);
      } else if (r.certificate.watched && !r.certificate.covered) {
        certRow.appendChild(el('span', 'addrnote', 'already in domains.txt — renew it from the Certificates page'));
      }
      out.appendChild(certRow);

      out.appendChild(addrRow('Port', r.portCheck.ok, r.portCheck.detail));

      var hostsRow = addrRow('Hosts file', r.hosts.ok, r.hosts.detail);
      if (!r.hosts.ok) {
        var line = '127.0.0.1\t' + r.hostname;
        if (r.elevated) {
          var write = el('button', 'btn sm', 'Add it');
          write.type = 'button';
          write.addEventListener('click', function(){
            write.disabled = true;
            api('POST', '/api/web/hosts', {hostname: r.hostname}, function(e3){
              write.disabled = false;
              if (e3) { setStatus(e3, 'bad'); return; }
              setStatus('Added to the hosts file.', 'good');
              runPreflight(false);
            });
          });
          hostsRow.appendChild(write);
        } else {
          hostsRow.appendChild(el('span', 'addrnote', 'needs administrator — add this line yourself:'));
          var code = el('code', null, '127.0.0.1  ' + r.hostname);
          hostsRow.appendChild(code);
        }
        // No port on this line, ever. The hosts file has no port field: a
        // "name:8787" entry does not error, it simply never matches, and the
        // name then fails to resolve with nothing to explain why.
        void line;
      }
      out.appendChild(hostsRow);

      if (loud) {
        setStatus(r.ready
          ? 'Ready. Save, then restart the tracker to serve over HTTPS.'
          : 'Not ready yet — see the rows above.', r.ready ? 'good' : '');
      }
    });
  }

  // --- Certificate Authorities -------------------------------------------------- //

  function buildAuthoritiesPanel(){
    var p = panel('authorities');
    p.appendChild(el('p', 'hint',
      'Each certificate picks an issuer on its own row in Certificates. Anything not pinned uses ' +
      'the default below. Staging is per authority - staging certificates are not trusted by ' +
      'browsers, but they do not count against rate limits, so leave it on until a renewal ' +
      'completes cleanly.'));
    var cas = el('div'); cas.id = 'cas';
    p.appendChild(cas);
    var add = el('button', 'btn sm', 'Add a certificate authority');
    add.type = 'button';
    add.addEventListener('click', function(){ addCaCard(null); });
    p.appendChild(add);
    var f = el('div', 'field');
    f.appendChild(el('label', null, 'Default for new certificates'));
    var sel = document.createElement('select'); sel.id = 'set-default-ca';
    f.appendChild(sel);
    p.appendChild(f);
    return p;
  }

  function refreshDefaultCaOptions(selectedId){
    var sel = document.getElementById('set-default-ca');
    var want = selectedId || sel.value;
    sel.textContent = '';
    document.querySelectorAll('#cas .ca').forEach(function(card){
      var o = document.createElement('option');
      o.value = card.getAttribute('data-cid');
      o.textContent = card.querySelector('.ca-label').value || '(unnamed)';
      if (o.value === want) { o.selected = true; }
      sel.appendChild(o);
    });
  }

  // Recipients arrive as an array, but settings.json has been seen holding a
  // bare string - and once held the literal "[object Object]", from an object
  // stringified on the way in. Calling .join on that throws, which would take
  // the whole Alerts panel down with it, so accept either shape and drop
  // anything that is not a usable address rather than displaying wreckage.
  function addressList(value){
    var items = Array.isArray(value) ? value
              : (typeof value === 'string' ? value.split(',') : []);
    return items
      .map(function(v){ return (typeof v === 'string' ? v : '').trim(); })
      .filter(function(v){ return v && v.indexOf('@') !== -1; })
      .join(', ');
  }

  function field(card, cls, label, value, type, hint, placeholder){
    var f = el('div', 'field');
    f.appendChild(el('label', null, label));
    var i = document.createElement('input');
    i.type = type || 'text';
    i.className = cls;
    i.autocomplete = 'off';
    i.value = value || '';
    if (placeholder) { i.placeholder = placeholder; }
    f.appendChild(i);
    if (hint) { f.appendChild(el('p', 'hint', hint)); }
    card.appendChild(f);
    return i;
  }

  function addCaCard(c){
    var card = el('div', 'provider ca');
    card.setAttribute('data-cid', (c && c.id) || ('ca' + Date.now().toString(36) + Math.floor(Math.random() * 1000)));

    var head = el('div', 'phead');
    head.appendChild(el('strong', null, (c && c.label) || 'New authority'));
    var rm = el('button', 'btn sm', 'Remove');
    rm.type = 'button';
    rm.addEventListener('click', function(){ card.parentNode.removeChild(card); refreshDefaultCaOptions(); });
    head.appendChild(rm);
    card.appendChild(head);

    var lab = field(card, 'ca-label', 'Name', c && c.label, 'text', null, 'e.g. DigiCert CertCentral');
    lab.addEventListener('input', function(){
      head.firstChild.textContent = lab.value || 'New authority';
      refreshDefaultCaOptions();
    });
    field(card, 'ca-directory', 'Production directory URL', c && c.directoryUrl, 'text',
      'DigiCert: CertCentral > Automation > ACME Directory URLs.');
    field(card, 'ca-staging-url', 'Staging directory URL', c && c.stagingUrl, 'text',
      'Leave blank if this authority has no test environment.');

    var stagingField = el('div', 'field');
    var stagingLabel = el('label', 'check');
    var stagingBox = document.createElement('input');
    stagingBox.type = 'checkbox'; stagingBox.className = 'ca-staging';
    stagingBox.checked = !!(c && c.useStaging);
    stagingLabel.appendChild(stagingBox);
    stagingLabel.appendChild(el('span', null, 'Use staging for this authority'));
    stagingField.appendChild(stagingLabel);
    card.appendChild(stagingField);

    field(card, 'ca-eab-kid', 'External account key ID', c && c.eabKid, 'text',
      'Only for authorities that require external account binding: DigiCert, ZeroSSL, Sectigo. ' +
      'Let’s Encrypt does not use it.');
    field(card, 'ca-eab-hmac', 'External account HMAC key', '', 'password', null,
      (c && c.eabHmacSet) ? 'Saved — leave blank to keep' : '');

    document.getElementById('cas').appendChild(card);
    refreshDefaultCaOptions();
  }

  // --- DNS Automation ------------------------------------------------------------ //

  function buildDnsPanel(){
    var p = panel('dns');
    p.appendChild(el('p', 'hint',
      'Renewal proves you control a domain by writing a DNS record. Each profile below is one ' +
      'DNS account; every zone it manages becomes renewable automatically.'));
    var providers = el('div'); providers.id = 'providers';
    p.appendChild(providers);
    var add = el('button', 'btn sm', 'Add a DNS profile');
    add.type = 'button';
    add.addEventListener('click', function(){ addProviderCard(null); });
    p.appendChild(add);
    var test = el('button', 'btn sm', 'Test DNS providers');
    test.type = 'button'; test.id = 'btn-test-dns';
    test.addEventListener('click', testConnection);
    p.appendChild(test);
    return p;
  }

  function addProviderCard(pv){
    var catalog = (CC.state && CC.state.catalog) || {};
    var plugins = Object.keys(catalog).sort();
    if (!plugins.length) { return; }

    var plugin = (pv && pv.plugin) || plugins[0];
    if (!catalog[plugin]) { plugin = plugins[0]; }

    var card = el('div', 'provider');
    var pid = (pv && pv.id) || ('p' + Date.now().toString(36) + Math.floor(Math.random() * 1000));
    card.setAttribute('data-pid', pid);
    card.setAttribute('data-plugin', plugin);

    var head = el('div', 'phead');
    var title = el('strong', null, catalog[plugin].label);
    head.appendChild(title);
    var rm = el('button', 'btn sm', 'Remove');
    rm.type = 'button';
    rm.addEventListener('click', function(){ card.parentNode.removeChild(card); });
    head.appendChild(rm);
    card.appendChild(head);

    var nameField = el('div', 'field');
    nameField.appendChild(el('label', null, 'Profile name'));
    var nameInput = document.createElement('input');
    nameInput.type = 'text'; nameInput.className = 'p-label';
    nameInput.value = (pv && pv.label) || '';
    nameInput.placeholder = 'e.g. Work DNS Made Easy';
    nameField.appendChild(nameInput);
    card.appendChild(nameField);

    var pluginField = el('div', 'field');
    pluginField.appendChild(el('label', null, 'Provider'));
    var sel = document.createElement('select'); sel.className = 'p-plugin';
    plugins.forEach(function(k){
      var o = document.createElement('option');
      o.value = k; o.textContent = catalog[k].label;
      if (k === plugin) { o.selected = true; }
      sel.appendChild(o);
    });
    pluginField.appendChild(sel);
    card.appendChild(pluginField);

    var argHost = el('div', 'fields');
    card.appendChild(argHost);

    function renderArgs(){
      var current = sel.value;
      card.setAttribute('data-plugin', current);
      title.textContent = catalog[current].label;
      argHost.textContent = '';
      catalog[current].args.forEach(function(a){
        var existing = (pv && pv.args && pv.plugin === current) ? pv.args[a.Name] : null;
        var f = el('div', 'field');
        if (a.Type === 'bool') {
          var lab = el('label', 'check');
          var box = document.createElement('input');
          box.type = 'checkbox'; box.setAttribute('data-arg', a.Name);
          box.checked = !!existing;
          lab.appendChild(box); lab.appendChild(el('span', null, a.Label));
          f.appendChild(lab);
        } else {
          f.appendChild(el('label', null, a.Label));
          var input = document.createElement('input');
          input.type = a.Secret ? 'password' : 'text';
          input.setAttribute('data-arg', a.Name);
          input.autocomplete = 'off';
          if (a.Secret) { input.value = ''; input.placeholder = existing === true ? 'Saved — leave blank to keep' : ''; }
          else { input.value = existing || ''; }
          f.appendChild(input);
        }
        if (a.Hint) { f.appendChild(el('p', 'hint', a.Hint)); }
        argHost.appendChild(f);
      });
    }
    sel.addEventListener('change', renderArgs);
    renderArgs();

    document.getElementById('providers').appendChild(card);
  }

  function testConnection(){
    var c = collectSettings();
    if (c.error) { setStatus(c.error, 'bad'); return; }
    setStatus('Saving and testing...');
    api('POST', '/api/settings', c.payload, function(err){
      if (err) { setStatus(err, 'bad'); return; }
      api('POST', '/api/settings/test', {}, function(err2, res){
        if (err2) { setStatus(err2, 'bad'); return; }
        if (res && res.errors && res.errors.length) {
          setStatus(res.errors.map(function(e){ return e.providerLabel + ': ' + e.error; }).join('  |  '), 'bad');
          return;
        }
        var zones = (res && res.zones) || [];
        var wrote = ((res && res.writes) || []).filter(function(w){ return w.canWrite; }).length;
        setStatus('Connected. ' + zones.length + ' zones (' +
          zones.slice(0, 6).join(', ') + (zones.length > 6 ? '...' : '') + '). ' +
          (wrote ? 'Record write verified on ' + wrote + ' provider(s).' : 'No zones to write-test.'), 'good');
        CC.loadState();
      });
    });
  }

  // --- Certificate Deployments ---------------------------------------------------- //

  function buildDeploymentsPanel(){
    var p = panel('deployments');
    p.appendChild(el('p', 'hint',
      'Where issued certificates get pushed. One entry per group of load balancers that share ' +
      'credentials — each node is still pushed to, and verified, individually. Assign a group ' +
      'to a certificate on its row in Certificates.'));
    var hint = el('p', 'hint', 'Never set one of these up before? See the ');
    var link = el('a', null, 'HAProxy setup guide');
    link.href = 'haproxy-setup.html'; link.target = '_blank'; link.rel = 'noopener';
    hint.appendChild(link);
    hint.appendChild(document.createTextNode('.'));
    p.appendChild(hint);
    var targets = el('div'); targets.id = 'targets';
    p.appendChild(targets);
    var add = el('button', 'btn sm', 'Add a load balancer group');
    add.type = 'button';
    add.addEventListener('click', function(){ addTargetCard(null); });
    p.appendChild(add);
    return p;
  }

  function renderTestRows(container, nodes){
    container.textContent = '';
    var box = el('div', 'testrows');
    nodes.forEach(function(n){
      var row = el('div', 'testrow');
      row.appendChild(el('span', 'n', n.node || n.url));
      row.appendChild(el('span', 'v ' + (n.ok ? 'ok' : 'bad'), n.ok ? 'ok' : 'fail'));
      row.appendChild(el('span', 'd', n.ok
        ? 'API ' + n.apiVersion + ', ' + (n.certificates || []).length + ' certificate(s) on disk'
        : (n.error || 'failed')));
      box.appendChild(row);
    });
    container.appendChild(box);
  }

  function testTarget(targetId, resultBox){
    var c = collectSettings();
    if (c.error) { setStatus(c.error, 'bad'); return; }
    setStatus('Saving, then testing...');
    resultBox.textContent = '';
    api('POST', '/api/settings', c.payload, function(err){
      if (err) { setStatus(err, 'bad'); return; }
      api('POST', '/api/targets/test', {targetId: targetId}, function(err2, res){
        if (err2) { setStatus(err2, 'bad'); return; }
        var nodes = (res && res.nodes) || [];
        renderTestRows(resultBox, nodes);
        var bad = nodes.filter(function(n){ return !n.ok; }).length;
        if (bad) { setStatus(bad + ' of ' + nodes.length + ' node(s) failed.', 'bad'); }
        else     { setStatus('All ' + nodes.length + ' node(s) reachable.', 'good'); }
        CC.loadState();
      });
    });
  }

  // Ask the nodes what they actually have, instead of asking a person to retype
  // it. Strictly read-only: this reads frontends and their binds and never
  // writes config, so it is safe next to whatever manages haproxy.cfg.
  function discoverTarget(card, resultBox){
    var c = collectSettings();
    if (c.error) { setStatus(c.error, 'bad'); return; }

    // Save first, same reason Test does: the password lives in the encrypted
    // store, so an unsaved card has no credential to connect with.
    setStatus('Saving, then asking the nodes...');
    resultBox.textContent = '';
    api('POST', '/api/settings', c.payload, function(err){
      if (err) { setStatus(err, 'bad'); return; }
      api('POST', '/api/targets/discover', {targetId: card.getAttribute('data-tid')}, function(err2, res){
        if (err2) { setStatus(err2, 'bad'); return; }

        var nodes = (res && res.nodes) || [];
        var failed = nodes.filter(function(n){ return !n.ok; });
        if (failed.length) {
          renderTestRows(resultBox, nodes.map(function(n){
            return {node: n.node, url: n.url, ok: n.ok, error: n.error,
                    apiVersion: null, certificates: []};
          }));
          setStatus(failed.length + ' of ' + nodes.length + ' node(s) could not be read.', 'bad');
          return;
        }

        // Offer what every node agrees on. A frontend present on only one node
        // of a pair is a configuration difference worth seeing, not something to
        // quietly pick for someone.
        var counts = {};
        nodes.forEach(function(n){
          (n.frontends || []).forEach(function(f){
            var key = f.frontend + '|' + (f.port || '') + '|' + (f.crtList || f.crt || '');
            counts[key] = (counts[key] || 0) + 1;
            counts[key + '|obj'] = f;
          });
        });

        var common = [], partial = [];
        Object.keys(counts).forEach(function(k){
          if (k.indexOf('|obj') >= 0) { return; }
          (counts[k] === nodes.length ? common : partial).push(counts[k + '|obj']);
        });

        renderDiscovery(card, resultBox, common, partial, nodes.length);
        var n = common.length;
        setStatus(n ? (n + ' TLS frontend(s) found on every node.')
                    : 'No TLS frontend is common to every node.', n ? 'good' : 'bad');
      });
    });
  }

  function renderDiscovery(card, container, common, partial, nodeCount){
    container.textContent = '';
    var box = el('div', 'testrows');

    common.forEach(function(f){
      var row = el('div', 'testrow');
      row.appendChild(el('span', 'n', f.frontend));
      row.appendChild(el('span', 'v ok', ':' + (f.port || '?')));
      var d = el('span', 'd', f.crtList ? f.crtList : (f.crt ? f.crt + '  (single crt, not a list)' : 'no crt-list'));
      row.appendChild(d);

      // Only offer to fill in what Cert Camel can actually drive. A single
      // "crt" bind can have its certificate replaced but nothing can be added
      // to it, so there is no crt-list path to write.
      if (f.crtList) {
        var use = el('button', 'btn sm', 'Use this');
        use.type = 'button';
        use.addEventListener('click', function(){
          var listInput = card.querySelector('input[data-arg="crtList"]');
          var portInput = card.querySelector('input[data-arg="verifyPort"]');
          if (listInput) { listInput.value = f.crtList; }
          if (portInput && f.port) { portInput.value = f.port; }
          setStatus('Filled in from ' + f.frontend + '. Press Save to keep it.', 'good');
        });
        row.appendChild(use);
      }
      box.appendChild(row);
    });

    partial.forEach(function(f){
      var row = el('div', 'testrow');
      row.appendChild(el('span', 'n', f.frontend));
      row.appendChild(el('span', 'v bad', 'partial'));
      row.appendChild(el('span', 'd',
        'not on all ' + nodeCount + ' nodes — the pair is configured differently, which is worth fixing first'));
      box.appendChild(row);
    });

    container.appendChild(box);
  }

  function addTargetCard(t){
    var catalog = (CC.state && CC.state.targetCatalog) || {};
    var types = Object.keys(catalog).sort();
    if (!types.length) { return; }

    var type = (t && t.type) || types[0];
    if (!catalog[type]) { type = types[0]; }

    var card = el('div', 'provider target');
    card.setAttribute('data-tid', (t && t.id) || ('t' + Date.now().toString(36) + Math.floor(Math.random() * 1000)));
    card.setAttribute('data-type', type);

    var head = el('div', 'phead');
    head.appendChild(el('strong', null, catalog[type].label));
    var headBtns = el('span');
    var test = el('button', 'btn sm', 'Test');
    test.type = 'button';
    test.title = 'Save these settings, then check every node in this group answers';
    headBtns.appendChild(test);
    var disco = el('button', 'btn sm', 'Discover');
    disco.type = 'button';
    disco.title = 'Ask the nodes which frontends terminate TLS, and fill in the crt-list and port from what they report';
    headBtns.appendChild(disco);
    var rm = el('button', 'btn sm', 'Remove');
    rm.type = 'button';
    rm.addEventListener('click', function(){ card.parentNode.removeChild(card); });
    headBtns.appendChild(rm);
    head.appendChild(headBtns);
    card.appendChild(head);

    var lab = field(card, 't-label', 'Group name', t && t.label, 'text', null, 'e.g. Office prod');
    lab.addEventListener('input', function(){ head.firstChild.textContent = lab.value || catalog[type].label; });

    var nodesField = el('div', 'field');
    nodesField.appendChild(el('label', null, 'Nodes — one per line'));
    var nodesBox = document.createElement('textarea');
    nodesBox.className = 't-nodes'; nodesBox.rows = 4; nodesBox.spellcheck = false;
    nodesBox.value = ((t && t.nodes) || []).map(function(n){
      return n.name + ' ' + n.url + (n.verifyHost ? ' ' + n.verifyHost : '');
    }).join('\n');
    nodesBox.placeholder = 'lb1 https://10.0.0.11:5555\nlb2 https://10.0.0.12:5555';
    nodesField.appendChild(nodesBox);
    nodesField.appendChild(el('p', 'hint',
      'name, then the Data Plane API base URL — host and port only, with no /v3 or /v2 on the ' +
      'end. Optionally a third value: the address to verify against, if the site is not served ' +
      'from the same host as the API. That one may carry its own port (host:8443) when a node ' +
      'does not use the group’s verify port. Verification always connects to each node ' +
      'directly, never through a VIP.'));
    card.appendChild(nodesField);

    var argHost = el('div', 'fields');
    card.appendChild(argHost);
    catalog[type].args.forEach(function(a){
      var existing = (t && t.args) ? t.args[a.Name] : null;
      var f = el('div', 'field');
      if (a.Type === 'bool') {
        var lb = el('label', 'check');
        var box = document.createElement('input');
        box.type = 'checkbox'; box.setAttribute('data-arg', a.Name);
        box.checked = !!existing;
        lb.appendChild(box); lb.appendChild(el('span', null, a.Label));
        f.appendChild(lb);
      } else {
        f.appendChild(el('label', null, a.Label));
        var input = document.createElement('input');
        input.type = a.Secret ? 'password' : 'text';
        input.setAttribute('data-arg', a.Name);
        input.autocomplete = 'off';
        if (a.Secret) { input.value = ''; input.placeholder = existing === true ? 'Saved — leave blank to keep' : ''; }
        else { input.value = existing || ''; }
        f.appendChild(input);
      }
      if (a.Hint) { f.appendChild(el('p', 'hint', a.Hint)); }
      argHost.appendChild(f);
    });

    var results = el('div');
    card.appendChild(results);
    test.addEventListener('click', function(){ testTarget(card.getAttribute('data-tid'), results); });
    disco.addEventListener('click', function(){ discoverTarget(card, results); });

    document.getElementById('targets').appendChild(card);
  }

  // --- Alerts ------------------------------------------------------------------ //
  // Additive: none of this touches the 12 existing endpoints. /api/settings
  // gains an "alerts" key alongside contact/cas/providers/targets, and
  // /api/settings/test-email is new.

  function buildAlertsPanel(){
    var p = panel('alerts');
    p.appendChild(el('p', 'hint',
      'Send email when a certificate needs attention. The password, if you use one, is stored the ' +
      'same encrypted way as every other credential here.'));

    var card = el('div', 'card');
    card.appendChild(el('h4', null, 'Outgoing mail server'));

    var grid = el('div', 'fields');
    var host = field(grid, 'al-smtp-host', 'SMTP host', '', 'text', null, 'mail.example.com');
    var port = field(grid, 'al-smtp-port', 'Port', '', 'text', null, '587');

    var encField = el('div', 'field');
    encField.appendChild(el('label', null, 'Encryption'));
    var encSel = document.createElement('select'); encSel.className = 'al-smtp-enc';
    [['starttls', 'STARTTLS (port 587, typical)'], ['none', 'None (internal relay only)']].forEach(function(o){
      var opt = document.createElement('option'); opt.value = o[0]; opt.textContent = o[1];
      encSel.appendChild(opt);
    });
    encField.appendChild(encSel);
    encField.appendChild(el('p', 'hint',
      'Implicit TLS (a server that expects encryption from the first byte, historically port ' +
      '465) is not offered - PowerShell’s mail client does not support it reliably. If your ' +
      'provider offers both, use STARTTLS on 587.'));
    grid.appendChild(encField);

    var from = field(grid, 'al-smtp-from', 'From address', '', 'email', null, 'certcamel@example.com');
    var to = field(grid, 'al-smtp-to', 'Send to', '', 'text',
      'One or more addresses, comma-separated.', 'you@example.com, oncall@example.com');
    card.appendChild(grid);

    var authField = el('div', 'field');
    var authLab = el('label', 'check');
    var authBox = document.createElement('input');
    authBox.type = 'checkbox'; authBox.className = 'al-smtp-auth';
    authLab.appendChild(authBox);
    authLab.appendChild(el('span', null, 'This server requires a username and password'));
    authField.appendChild(authLab);
    authField.appendChild(el('p', 'hint',
      'Leave unticked for an internal relay that accepts mail from this machine with no login — ' +
      'common on a corporate network. Tick it for Gmail, Office 365, or any hosted mailbox.'));
    card.appendChild(authField);

    var authGrid = el('div', 'fields al-auth-fields hidden');
    field(authGrid, 'al-smtp-user', 'Username', '', 'text', null, '');
    var pass = field(authGrid, 'al-smtp-pass', 'Password', '', 'password', null, '');
    card.appendChild(authGrid);
    authBox.addEventListener('change', function(){
      authGrid.classList.toggle('hidden', !authBox.checked);
    });

    var testRow = el('div', 'toolbar');
    var testBtn = el('button', 'btn sm', 'Send test email');
    testBtn.type = 'button';
    testBtn.title = 'Save these settings, then send a test message to the address(es) above';
    testBtn.addEventListener('click', testEmail);
    testRow.appendChild(testBtn);
    card.appendChild(testRow);
    var testResult = el('div'); testResult.id = 'al-test-result';
    card.appendChild(testResult);

    p.appendChild(card);

    // --- Which alerts ------------------------------------------------------- //
    var card2 = el('div', 'card');
    card2.appendChild(el('h4', null, 'Which alerts'));

    function toggle(cls, label, hint){
      var f = el('div', 'field');
      var lab = el('label', 'check');
      var box = document.createElement('input');
      box.type = 'checkbox'; box.className = cls;
      lab.appendChild(box);
      lab.appendChild(el('span', null, label));
      f.appendChild(lab);
      if (hint) { f.appendChild(el('p', 'hint', hint)); }
      card2.appendChild(f);
      return box;
    }

    var expiryBox = toggle('al-expiry-enabled', 'Certificate expiring soon',
      'One email per certificate per threshold crossed, not repeated every day after.');
    var thresholdsField = el('div', 'field');
    thresholdsField.appendChild(el('label', null, 'Days before expiry'));
    var thresholdsInput = document.createElement('input');
    thresholdsInput.type = 'text'; thresholdsInput.className = 'al-expiry-thresholds';
    thresholdsInput.placeholder = '30, 14, 7';
    thresholdsInput.autocomplete = 'off';
    thresholdsField.appendChild(thresholdsInput);
    thresholdsField.appendChild(el('p', 'hint', 'Comma-separated. One alert is sent the first time a check finds a certificate at or under each number.'));
    card2.appendChild(thresholdsField);

    toggle('al-renewal-success', 'Renewal succeeded', 'Confirms both issuance and every deployment check passed.');
    toggle('al-deployment-failure', 'Automated deployment failed',
      'The most important one: the only signal an unattended renewal has stopped working.');
    toggle('al-monthly-summary', 'Monthly summary', 'Sent on the 1st: everything due that month, and anything currently failing.');

    p.appendChild(card2);
    return p;
  }

  function collectAlerts(){
    var root = document.getElementById('settings-panels');
    if (!root) { return null; }

    var toAddrs = root.querySelector('.al-smtp-to').value.split(',')
      .map(function(s){ return s.trim(); }).filter(function(s){ return s; });

    var authRequired = root.querySelector('.al-smtp-auth').checked;

    var thresholds = root.querySelector('.al-expiry-thresholds').value.split(',')
      .map(function(s){ return parseInt(s.trim(), 10); })
      .filter(function(n){ return !isNaN(n) && n >= 0; });

    var alerts = {
      smtp: {
        host: root.querySelector('.al-smtp-host').value.trim(),
        port: parseInt(root.querySelector('.al-smtp-port').value.trim(), 10) || 0,
        encryption: root.querySelector('.al-smtp-enc').value,
        from: root.querySelector('.al-smtp-from').value.trim(),
        to: toAddrs,
        authRequired: authRequired,
        username: authRequired ? root.querySelector('.al-smtp-user').value.trim() : ''
      },
      expiry: {
        enabled: root.querySelector('.al-expiry-enabled').checked,
        thresholds: thresholds.length ? thresholds : [30, 14, 7]
      },
      renewalSuccess:    {enabled: root.querySelector('.al-renewal-success').checked},
      deploymentFailure: {enabled: root.querySelector('.al-deployment-failure').checked},
      monthlySummary:    {enabled: root.querySelector('.al-monthly-summary').checked}
    };

    // Blank means "keep what is stored" - the same rule every other secret in
    // this app follows. Only send a password when something was actually typed.
    var pw = root.querySelector('.al-smtp-pass').value;
    if (pw) { alerts.smtp.password = pw; }

    var anyEnabled = alerts.expiry.enabled || alerts.renewalSuccess.enabled ||
      alerts.deploymentFailure.enabled || alerts.monthlySummary.enabled;
    if (anyEnabled && !alerts.smtp.host) {
      return {error: 'An SMTP host is required to send any alert.'};
    }
    if (anyEnabled && !alerts.smtp.to.length) {
      return {error: 'At least one "send to" address is required to send any alert.'};
    }

    return {value: alerts};
  }

  /* Saves first, deliberately: the endpoint reads settings.json from disk, so
     testing an unsaved form would report on the previous profile. */
  function testEmail(){
    var c = collectSettings();
    if (c.error) { setStatus(c.error, 'bad'); return; }
    setStatus('Saving, then sending a test email...');
    var box = document.getElementById('al-test-result');
    box.textContent = '';
    api('POST', '/api/settings', c.payload, function(err){
      if (err) { setStatus(err, 'bad'); return; }
      api('POST', '/api/settings/test-email', {}, function(err2, res){
        if (err2) { setStatus(err2, 'bad'); return; }
        showTestEmailResult(box, res && res.receipt);
      });
    });
  }

  /* It used to say "Test email sent." It does not know that.

     A send that returns without throwing means the SMTP server ACCEPTED the
     message. Whether it was delivered, filed as spam, or dropped for failing
     SPF is decided afterwards and elsewhere, and nothing visible from here can
     tell those apart - which is exactly how a "sent" test email never arrives
     and leaves nobody anything to go on. So it reports what was established,
     and names the thing that would answer the next question. */
  function showTestEmailResult(box, r){
    setStatus('Accepted by the mail server.', 'good');
    if (!box) { return; }
    box.textContent = '';

    if (!r) { box.appendChild(el('p', 'hint', 'The server accepted the message.')); return; }

    var line = el('p', 'hint');
    line.appendChild(el('strong', null, r.host + ':' + r.port));
    line.appendChild(document.createTextNode(
      ' accepted it for ' + (r.to || []).join(', ') + ', from ' + r.from + '.'));
    box.appendChild(line);

    // Short on purpose. The full list of reasons a message can be accepted and
    // still not arrive lives in the Read me, where somebody actually
    // troubleshooting will look for it. Here it only needs to stop the word
    // "accepted" being read as "delivered".
    var note = el('p', 'hint');
    note.appendChild(el('strong', null, 'Accepted is not the same as delivered.'));
    note.appendChild(document.createTextNode(
      ' If it does not turn up, wait a few minutes, then check the spam folder.'));
    box.appendChild(note);

    // The one handle that survives into the receiving server's logs. Whoever
    // runs that mail server can search for it, which is the difference between
    // a guess and an answer. Worth the line even though most people will never
    // need it - when it IS needed, nothing else will do.
    var id = el('p', 'hint');
    id.appendChild(document.createTextNode('Message ID, if you need to trace it: '));
    id.appendChild(el('code', null, r.messageId));
    box.appendChild(id);

    box.appendChild(el('p', 'hint', 'Recorded on the Logs page, along with every alert the tool sends.'));
  }

  // --- Save (writes every panel, including hidden ones) ------------------------ //

  function collectSettings(){
    var providers = [];
    var bad = null;

    document.querySelectorAll('#providers .provider').forEach(function(card){
      var args = {};
      card.querySelectorAll('input[data-arg]').forEach(function(i){
        args[i.getAttribute('data-arg')] = (i.type === 'checkbox') ? i.checked : i.value.trim();
      });
      var label = card.querySelector('.p-label').value.trim();
      if (!label) { bad = 'Every DNS profile needs a name.'; }
      providers.push({id: card.getAttribute('data-pid'), label: label, plugin: card.querySelector('.p-plugin').value, args: args});
    });

    var cas = [];
    document.querySelectorAll('#cas .ca').forEach(function(card){
      function v(cls){ return card.querySelector(cls).value.trim(); }
      var label = v('.ca-label');
      if (!label) { bad = 'Every certificate authority needs a name.'; }
      if (!v('.ca-directory')) { bad = '"' + (label || 'A certificate authority') + '" needs a production directory URL.'; }
      cas.push({
        id: card.getAttribute('data-cid'), label: label, directoryUrl: v('.ca-directory'),
        stagingUrl: v('.ca-staging-url'), useStaging: card.querySelector('.ca-staging').checked,
        eabKid: v('.ca-eab-kid'), eabHmacKey: card.querySelector('.ca-eab-hmac').value
      });
    });
    if (!cas.length) { bad = 'At least one certificate authority is required.'; }

    var targets = [];
    document.querySelectorAll('#targets .target').forEach(function(card){
      var args = {};
      card.querySelectorAll('input[data-arg]').forEach(function(i){
        args[i.getAttribute('data-arg')] = (i.type === 'checkbox') ? i.checked : i.value.trim();
      });
      var label = card.querySelector('.t-label').value.trim();
      if (!label) { bad = 'Every load balancer group needs a name.'; }

      var nodes = [];
      var lineError = null;
      card.querySelector('.t-nodes').value.split('\n').forEach(function(line){
        var s = line.trim();
        if (!s) { return; }
        var parts = s.split(/\s+/);
        if (parts.length < 2) { lineError = lineError || 'Node line needs a name and a URL: "' + s + '"'; return; }
        if (!/^https?:\/\//i.test(parts[1])) { lineError = lineError || 'Node URL must start with http:// or https://: "' + s + '"'; return; }
        nodes.push({name: parts[0], url: parts[1], verifyHost: parts[2] || ''});
      });
      if (lineError)          { bad = lineError; }
      else if (!nodes.length) { bad = '"' + (label || 'A load balancer group') + '" has no nodes.'; }

      targets.push({id: card.getAttribute('data-tid'), label: label, type: card.getAttribute('data-type'), nodes: nodes, args: args});
    });

    if (bad) { return {error: bad}; }

    var alertsResult = collectAlerts();
    if (alertsResult && alertsResult.error) { return {error: alertsResult.error}; }

    var logDays = parseInt(document.getElementById('set-log-days').value, 10);
    var logMb   = parseInt(document.getElementById('set-log-mb').value, 10);
    if (isNaN(logDays) || logDays < 1) { return {error: 'Log retention needs a number of days, at least 1.'}; }
    if (isNaN(logMb)   || logMb   < 1) { return {error: 'The maximum log folder size needs to be at least 1 MB.'}; }

    var webOn   = document.getElementById('set-web-https').checked;
    var webHost = document.getElementById('set-web-host').value.trim().toLowerCase().replace(/\.$/, '');
    var webPort = parseInt(document.getElementById('set-web-port').value, 10);
    if (isNaN(webPort)) { webPort = 0; }
    if (webOn) {
      if (!webHost) { return {error: 'HTTPS needs a hostname for the tracker.'}; }
      if (webPort < 1 || webPort > 65535) {
        return {error: 'HTTPS needs a fixed port. A hostname is no use on a port that changes every launch.'};
      }
    }

    return {
      payload: {
        contact:     document.getElementById('set-contact').value.trim(),
        cas:         cas,
        defaultCaId: document.getElementById('set-default-ca').value,
        providers:   providers,
        targets:     targets,
        alerts:      alertsResult ? alertsResult.value : null,
        logs:        {retentionDays: logDays, maxSizeMb: logMb},
        web:         {https: webOn, hostname: webHost, port: webPort}
      }
    };
  }

  /* The certificate is loaded once when the server starts, so turning HTTPS on
     cannot take effect on the running one. Said here rather than only after
     Check, because Save is where someone actually is when they expect it to
     have happened — and a setting that silently does nothing until a restart
     nobody mentioned is how this looks broken. */
  function restartNote(payload){
    if (!payload.web || !payload.web.https) { return ''; }
    var serving = (CC.state && CC.state.serving) || {};
    if (serving.scheme === 'https' && serving.host === payload.web.hostname) { return ''; }
    return ' Restart Cert Camel to serve over HTTPS at ' +
           payload.web.hostname + ':' + payload.web.port + '.';
  }

  function saveSettings(){
    var c = collectSettings();
    if (c.error) { setStatus(c.error, 'bad'); return; }
    if (!c.payload.contact) { setStatus('A contact email is required.', 'bad'); return; }

    setStatus('Saving...');
    api('POST', '/api/settings', c.payload, function(err){
      if (err) { setStatus(err, 'bad'); return; }
      setStatus('Saved. Reading DNS zones...');
      api('POST', '/api/settings/test', {}, function(err2, res){
        if (err2) { setStatus('Saved, but the DNS check failed: ' + err2, 'bad'); CC.loadState(); return; }
        if (res && res.errors && res.errors.length) {
          setStatus(res.errors.map(function(e){ return e.providerLabel + ': ' + e.error; }).join('  |  '), 'bad');
          CC.loadState();
          return;
        }
        setStatus('Saved. ' + ((res && res.zoneCount) || 0) + ' DNS zones found.' + restartNote(c.payload), 'good');
        CC.loadState();
      });
    });
  }

  // --- Populate from server state, once per Settings visit --------------------- //

  function populate(){
    var s = (CC.state && CC.state.settings) || {};

    document.getElementById('set-contact').value = s.contact || '';
    document.getElementById('set-log-days').value = (s.logs && s.logs.retentionDays) || 90;
    document.getElementById('set-log-mb').value   = (s.logs && s.logs.maxSizeMb) || 200;

    var w = s.web || {};
    var webBox = document.getElementById('set-web-https');
    webBox.checked = !!w.https;
    document.getElementById('set-web-host').value = w.hostname || '';
    document.getElementById('set-web-port').value = w.port || '';
    document.getElementById('set-web-fields').classList.toggle('hidden', !webBox.checked);
    document.getElementById('set-web-check').textContent = '';
    if (webBox.checked) { runPreflight(false); }

    var caHost = document.getElementById('cas');
    caHost.textContent = '';
    (s.cas || []).forEach(addCaCard);
    refreshDefaultCaOptions(s.defaultCaId);

    var pHost = document.getElementById('providers');
    pHost.textContent = '';
    (s.providers || []).forEach(addProviderCard);

    var tHost = document.getElementById('targets');
    tHost.textContent = '';
    (s.targets || []).forEach(addTargetCard);

    var a = s.alerts || {};
    var smtp = a.smtp || {};
    var root = document.getElementById('settings-panels');
    root.querySelector('.al-smtp-host').value = smtp.host || '';
    root.querySelector('.al-smtp-port').value = smtp.port || '';
    root.querySelector('.al-smtp-enc').value = smtp.encryption || 'starttls';
    root.querySelector('.al-smtp-from').value = smtp.from || '';
    root.querySelector('.al-smtp-to').value = addressList(smtp.to);
    var authBox = root.querySelector('.al-smtp-auth');
    authBox.checked = !!smtp.authRequired;
    root.querySelector('.al-auth-fields').classList.toggle('hidden', !authBox.checked);
    root.querySelector('.al-smtp-user').value = smtp.username || '';
    root.querySelector('.al-smtp-pass').placeholder = smtp.passwordSet ? 'Saved — leave blank to keep' : '';

    root.querySelector('.al-expiry-enabled').checked = !!(a.expiry && a.expiry.enabled);
    root.querySelector('.al-expiry-thresholds').value = ((a.expiry && a.expiry.thresholds) || [30, 14, 7]).join(', ');
    root.querySelector('.al-renewal-success').checked = !!(a.renewalSuccess && a.renewalSuccess.enabled);
    root.querySelector('.al-deployment-failure').checked = !!(a.deploymentFailure && a.deploymentFailure.enabled);
    root.querySelector('.al-monthly-summary').checked = !!(a.monthlySummary && a.monthlySummary.enabled);
  }

  CC.registerView('settings', {render: render});
})();
