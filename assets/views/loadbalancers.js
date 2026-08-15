/* Load balancers: what each node is running, and - the reason this page exists -
   whether any frontend actually READS the crt-list each certificate is deployed
   to.

   Cert Camel writes certificate storage and crt-list entries and never a bind
   line. So a wrong crt-list path gives a green deployment, a certificate on
   disk, and nothing served. Neither verification tier catches it: the wire check
   needs a per-node TLS address that a one-frontend-per-public-IP topology cannot
   offer, and the runtime check proves a certificate is loaded, not that anything
   references it. Reading the configuration back is the only way to see it.

   Reads a cache. The sweep that fills it runs out of process, because an
   unreachable node costs ten seconds and the server handles one connection at a
   time. */
(function(){
  "use strict";
  var CC = window.CertCamel;
  var el = CC.el, api = CC.api, ago = CC.ago;

  // Kept across re-renders so a background job finishing does not move the tab
  // out from under someone.
  var activeGroup = null;

  function render(){
    var host = document.getElementById('view-loadbalancers');
    host.textContent = '';

    var head = el('div', 'viewhead');
    head.appendChild(el('h2', null, 'Load balancers'));
    host.appendChild(head);

    var body = el('div');
    host.appendChild(body);
    body.appendChild(el('p', 'mini', 'Loading...'));

    api('GET', '/api/loadbalancers', null, function(err, res){
      body.textContent = '';
      if (err) { body.appendChild(el('div', 'callout crit', err)); return; }

      if (!res || !res.haveTargets) {
        body.appendChild(el('div', 'empty',
          'No load balancers configured. Add one under Settings → Certificate Deployments to deploy certificates and see them here.'));
        return;
      }
      draw(body, res);
    });
  }

  function draw(host, res){
    var groups = res.groups || [];

    if (res.groupError) {
      host.appendChild(el('div', 'callout warn', 'Could not work out which frontends serve what: ' + res.groupError));
    }

    // A tab per group, same idiom as the Logs view. Skipped entirely for a
    // single group - one tab is furniture, not navigation.
    if (groups.length > 1) {
      var nav = el('div', 'subnav');
      nav.setAttribute('role', 'tablist');
      groups.forEach(function(g){
        var a = el('a', null, g.label);
        a.href = '#/loadbalancers';
        a.setAttribute('role', 'tab');
        a.setAttribute('aria-current', g.id === currentGroupId(groups) ? 'page' : 'false');
        a.addEventListener('click', function(e){ e.preventDefault(); activeGroup = g.id; render(); });
        nav.appendChild(a);
      });
      host.appendChild(nav);
    }

    var g = null;
    groups.forEach(function(x){ if (x.id === currentGroupId(groups)) { g = x; } });
    if (!g) {
      host.appendChild(el('div', 'empty', 'This group has not been checked yet.'));
      host.appendChild(foot(res.checkedAt));
      return;
    }

    host.appendChild(nodeCard(g));
    certificateSections(host, g);
    unmanagedSection(host, g);
    host.appendChild(foot(res.checkedAt));
  }

  function currentGroupId(groups){
    var found = null;
    groups.forEach(function(g){ if (g.id === activeGroup) { found = g.id; } });
    return found || (groups.length ? groups[0].id : null);
  }

  function nodeCard(g){
    var card = el('div', 'card wide');
    card.appendChild(el('h4', null, 'Nodes'));

    if (!(g.nodes || []).length) {
      card.appendChild(el('p', 'mini', 'Not checked yet.'));
      return card;
    }

    g.nodes.forEach(function(n){
      var row = el('div', 'lbnode' + (n.reachable ? '' : ' down'));
      row.appendChild(el('span', 'dot ' + (n.reachable ? 'ok' : 'bad')));
      row.appendChild(el('span', 'lbname', n.name));
      row.appendChild(el('span', 'lbid', n.node || '—'));

      var d = el('span', 'lbdetail');
      if (n.reachable) {
        d.textContent = 'HAProxy ' + (n.haproxyVersion || 'unknown') +
                        '  ·  ' + ((n.frontends || []).length) + ' frontends';
        if (n.frontendError) {
          d.textContent += '  ·  configuration unreadable';
          d.className = 'lbdetail bad';
        }
      } else {
        d.textContent = n.error || 'did not answer';
        d.className = 'lbdetail bad';
      }
      row.appendChild(d);
      row.appendChild(el('span', 'lburl', n.url));
      card.appendChild(row);
    });
    return card;
  }

  /* Grouped by CERTIFICATE, not by frontend. Frontends are rarely built in
     certificate order, and working out which ones belong together is the part
     that wastes time. */
  function certificateSections(host, g){
    var certs = g.certificates || [];
    if (!certs.length) {
      host.appendChild(el('p', 'mini', 'No certificates are assigned to this group yet.'));
      return;
    }

    // Anything wrong first. A page that reads top to bottom in configuration
    // order buries the one row that needs attention.
    var order = {unreferenced: 0, unknown: 1, served: 2};
    certs = certs.slice().sort(function(a, b){
      return (order[a.state] - order[b.state]) || String(a.name).localeCompare(String(b.name));
    });

    var h = el('h2', null, 'Certificates');
    h.appendChild(el('span', 'rule'));
    host.appendChild(h);

    certs.forEach(function(c){ host.appendChild(certCard(c, g)); });
  }

  function certCard(c, g){
    var card = el('div', 'card wide lbcert ' + c.state);

    var head = el('div', 'lbcerthead');
    head.appendChild(el('span', 'lbcertname', c.name));
    head.appendChild(stateBadge(c.state));
    card.appendChild(head);

    var path = el('p', 'mini lbpath');
    path.appendChild(document.createTextNode('crt-list: '));
    path.appendChild(el('code', null, c.crtList || '(none set)'));
    card.appendChild(path);

    if (c.note) { card.appendChild(el('p', 'mini', c.note)); }

    if (c.state === 'served') {
      (c.frontends || []).forEach(function(f){
        var r = el('div', 'lbfe');
        r.appendChild(el('span', 'dot ok'));
        r.appendChild(el('span', 'lbfename', f.frontend));
        r.appendChild(el('span', 'lbfeaddr', f.address + ':' + f.port));
        r.appendChild(el('span', 'lbfenode', f.node));
        if (f.viaDirectory) {
          // A directory bind serves everything in it, so the certificate IS
          // served - but a brand-new one is not picked up until a reload.
          r.appendChild(el('span', 'lbfenote', 'via a directory bind — a new certificate needs a reload'));
        }
        card.appendChild(r);
      });
    }
    else if (c.state === 'unreferenced') {
      var warn = el('p', 'mini bad');
      warn.textContent = 'No frontend reads this crt-list. The certificate is deployed and will never be served.';
      card.appendChild(warn);

      var p = el('p', 'mini');
      var btn = el('button', 'btn sm', 'How to fix this');
      btn.type = 'button';
      btn.addEventListener('click', function(){ showFix(c, g); });
      p.appendChild(btn);
      card.appendChild(p);
    }

    return card;
  }

  function stateBadge(state){
    var text = state === 'served'       ? 'served'
             : state === 'unreferenced' ? 'not referenced'
             : 'unknown';
    return el('span', 'lbstate ' + state, text);
  }

  function unmanagedSection(host, g){
    var um = g.unmanaged || [];
    if (!um.length) { return; }

    var h = el('h2', null, 'Not managed here');
    h.appendChild(el('span', 'rule'));
    host.appendChild(h);

    host.appendChild(el('p', 'mini',
      'TLS frontends reading a crt-list Cert Camel does not write. Not a problem — this is what is still outside the tool.'));

    var card = el('div', 'card wide');
    um.forEach(function(f){
      var r = el('div', 'lbfe');
      r.appendChild(el('span', 'dot'));
      r.appendChild(el('span', 'lbfename', f.frontend));
      r.appendChild(el('span', 'lbfeaddr', f.address + ':' + f.port));
      r.appendChild(el('span', 'lbfenode', f.node));
      var c = el('span', 'lbfenote');
      c.appendChild(el('code', null, f.crtList || f.crtDir || '(no crt-list)'));
      r.appendChild(c);
      card.appendChild(r);
    });
    host.appendChild(card);
  }

  /* Both directions, deliberately. Which side is wrong depends on intent and
     the tool cannot know: a new deployment usually wants HAProxy pointed at
     Cert Camel's list, while adopting an existing load balancer usually wants
     Cert Camel pointed at HAProxy's. Cert Camel never writes a bind line, so
     this produces instructions, never an applied change. */
  function showFix(c, g){
    var dlg = document.getElementById('lbfix');
    if (!dlg) { return; }
    var body = dlg.querySelector('.fixbody');
    body.textContent = '';

    body.appendChild(el('p', null,
      'Cert Camel deploys ' + c.name + ' to a crt-list that no frontend reads. ' +
      'One of the two paths below is wrong — which one depends on what you intended.'));

    var cmp = el('div', 'fixcompare');
    var a = el('div', 'fixside');
    a.appendChild(el('div', 'k', 'Cert Camel writes to'));
    a.appendChild(el('code', null, c.crtList || '(none set)'));
    cmp.appendChild(a);

    var b = el('div', 'fixside');
    b.appendChild(el('div', 'k', 'Frontends on this group read'));
    var reads = (g.unmanaged || []).map(function(u){ return u.crtList; })
                  .filter(function(v, i, arr){ return v && arr.indexOf(v) === i; });
    if (reads.length) {
      reads.forEach(function(p){ b.appendChild(el('code', null, p)); });
    } else {
      b.appendChild(el('code', null, '(no other TLS frontend found)'));
    }
    cmp.appendChild(b);
    body.appendChild(cmp);

    body.appendChild(el('h4', null, 'Either — point HAProxy at Cert Camel’s list'));
    body.appendChild(el('p', 'mini',
      'Right when this certificate has its own frontend and the bind was mistyped. Edit the bind on every node, then reload:'));
    body.appendChild(el('pre', 'log',
      'bind <address>:443 ssl crt-list ' + (c.crtList || '<path>') + '\n\n' +
      '# check the config parses, then reload without dropping connections\n' +
      'haproxy -c -f /etc/haproxy/haproxy.cfg\n' +
      'systemctl reload haproxy'));

    body.appendChild(el('h4', null, 'Or — point Cert Camel at HAProxy’s list'));
    body.appendChild(el('p', 'mini',
      'Usually right when adopting a load balancer that already works. No HAProxy change and no reload — set the crt-list path under ' +
      'Settings → Certificate Deployments, on the group or on this certificate’s row to override just this one.'));
    if (reads.length) {
      body.appendChild(el('pre', 'log', reads[0]));
    }

    body.appendChild(el('p', 'mini',
      'Cert Camel never edits your HAProxy configuration — it writes certificate storage and crt-list entries only. The bind line is always yours.'));

    dlg.showModal();
  }

  function foot(checkedAt){
    var f = el('div', 'cardfoot');
    f.appendChild(el('p', 'mini', checkedAt ? 'Checked ' + ago(checkedAt) + '.' : 'Not checked yet.'));

    var p = el('p', 'mini');
    var btn = el('button', 'btn sm', 'Check now');
    btn.type = 'button';
    btn.title = 'Asks each node what it is running and what its frontends bind. Changes nothing.';
    btn.addEventListener('click', function(){ refresh(btn); });
    p.appendChild(btn);
    f.appendChild(p);
    return f;
  }

  function refresh(btn){
    btn.disabled = true;
    btn.textContent = 'Checking...';
    api('POST', '/api/loadbalancers/refresh', null, function(err, res){
      if (err || !res || !res.jobId) { btn.disabled = false; btn.textContent = 'Check now'; return; }
      var tries = 0;
      (function poll(){
        if (++tries > 60) { btn.disabled = false; btn.textContent = 'Check now'; return; }
        window.setTimeout(function(){
          api('GET', '/api/job/' + res.jobId, null, function(e2, st){
            if (e2) { btn.disabled = false; btn.textContent = 'Check now'; return; }
            if (st && st.running) { poll(); return; }
            render();
          });
        }, 700);
      })();
    });
  }

  CC.registerView('loadbalancers', {render: render});
  CC.onStateChanged(function(){
    if (CC.currentRoute().view === 'loadbalancers') { render(); }
  });
})();
