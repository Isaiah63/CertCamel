/* Cert Camel - app shell: routing, the API client, shared state, and the job
   runner. Views register themselves and are shown/hidden by hash; there is no
   framework and no build step, so this is what a router looks like here. */
(function(){
  "use strict";

  var RENEW_DAYS = 30;   // flag for renewal at or under this many days left
  var STALE_DAYS = 2;    // nag to re-run the checker after this long

  var TOKEN = (function(){
    var m = /(?:^|[?&])t=([a-f0-9]+)/.exec(location.search);
    return m ? m[1] : null;
  })();

  if (!TOKEN) {
    // Every view needs the API; there is no read-only fallback any more.
    // serve.ps1 always hands the token to the page it opens, so arriving
    // without one means this was not opened via Open Tracker.bat.
    document.body.innerHTML =
      '<div style="max-width:34rem;margin:4rem auto;padding:1.5rem;font:15px/1.5 sans-serif;">' +
      '<h2>No session</h2><p>Open this page via <code>Open Tracker.bat</code>, not by browsing to ' +
      'the file directly. The server hands each session its own token.</p></div>';
    throw new Error('no session token');
  }

  var CertCamel = window.CertCamel = {
    RENEW_DAYS: RENEW_DAYS,
    STALE_DAYS: STALE_DAYS,
    TOKEN: TOKEN,
    state: null,      // last /api/state response
    sslData: window.SSL_DATA || null,   // raw checker output, unchanged data source
    views: {}
  };

  // --- DOM helpers --------------------------------------------------------- //

  function el(tag, cls, text){
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    // textContent throughout: issuer strings and error messages come from
    // remote servers, so they never get treated as markup.
    if (text !== undefined && text !== null) n.textContent = text;
    return n;
  }
  CertCamel.el = el;

  CertCamel.daysUntil = function(iso){
    return Math.floor((new Date(iso) - new Date()) / 86400000);
  };
  CertCamel.fmtDate = function(iso){
    var d = new Date(iso);
    return d.toLocaleDateString(undefined, {year:'numeric', month:'short', day:'numeric'});
  };
  CertCamel.ago = function(iso){
    var mins = Math.floor((new Date() - new Date(iso)) / 60000);
    if (mins < 1)    return 'just now';
    if (mins < 60)   return mins + (mins === 1 ? ' minute ago' : ' minutes ago');
    var hrs = Math.floor(mins / 60);
    if (hrs < 24)    return hrs + (hrs === 1 ? ' hour ago' : ' hours ago');
    var days = Math.floor(hrs / 24);
    return days + (days === 1 ? ' day ago' : ' days ago');
  };

  // --- API client ----------------------------------------------------------- //
  // Unchanged from the single-page version: the token travels as a header, the
  // server also accepts it as a query param for the one GET that is a browser
  // navigation (the file download link) rather than an XHR.

  function api(method, path, body, cb){
    var x = new XMLHttpRequest();
    x.open(method, path, true);
    x.setRequestHeader('X-Tracker-Token', TOKEN);
    if (body) { x.setRequestHeader('Content-Type', 'application/json'); }
    x.onreadystatechange = function(){
      if (x.readyState !== 4) { return; }
      var parsed = null;
      try { parsed = JSON.parse(x.responseText); } catch (e) { /* not JSON */ }
      if (x.status >= 200 && x.status < 300) { cb(null, parsed); }
      else { cb((parsed && parsed.error) || ('The local server returned ' + (x.status || 'no response')), parsed); }
    };
    x.send(body ? JSON.stringify(body) : null);
  }
  CertCamel.api = api;

  // --- Shared state ----------------------------------------------------------- //
  // One /api/state fetch, shared by every view, so navigating between views does
  // not each re-fetch it and does not go stale relative to each other.

  var stateListeners = [];
  CertCamel.onStateChanged = function(fn){ stateListeners.push(fn); };

  CertCamel.loadState = function(cb){
    api('GET', '/api/state', null, function(err, s){
      if (err) {
        setLiveHint(err);
        if (cb) { cb(err); }
        return;
      }
      CertCamel.state = s;
      var staging = ((s.settings && s.settings.cas) || []).filter(function(ca){ return ca.useStaging; });
      setLiveHint(staging.length
        ? 'Staging: ' + staging.map(function(ca){ return ca.label; }).join(', ')
        : '');
      stateListeners.forEach(function(fn){ try { fn(s); } catch (e) { /* one bad listener should not break the rest */ } });
      if (cb) { cb(null, s); }
    });
  };

  function setLiveHint(text){
    var h = document.getElementById('livehint');
    if (h) { h.textContent = text || ''; }
  }

  // --- Job runner ------------------------------------------------------------- //
  // Lives in the shell, not in a view, so a renewal survives navigating away from
  // Certificates while it runs rather than being torn down with the view.

  var jobTimer = null;

  function setBusy(busy){
    document.querySelectorAll('[data-busy-disable]').forEach(function(b){ b.disabled = busy; });
  }
  CertCamel.setBusy = setBusy;

  CertCamel.runJob = function(title, method, path, body){
    if (jobTimer) { return; }

    var panel = document.getElementById('jobpanel');
    var log   = document.getElementById('joblog');
    document.getElementById('jobtitle').firstChild.nodeValue = title;
    log.textContent = 'Starting...';
    panel.classList.remove('hidden');
    setBusy(true);

    api(method, path, body, function(err, res){
      if (err || !res || !res.jobId) {
        log.textContent = err || 'The server did not start the job.';
        setBusy(false);
        return;
      }
      pollJob(res.jobId, log);
    });
  };

  function pollJob(id, log){
    var atBottom = true;

    jobTimer = window.setInterval(function(){
      api('GET', '/api/job/' + id, null, function(err, j){
        if (err) {
          log.textContent += '\n' + err;
          window.clearInterval(jobTimer); jobTimer = null; setBusy(false);
          return;
        }

        // Only auto-scroll while the person is already following the tail;
        // yanking the view back down while they read older lines is hostile.
        atBottom = (log.scrollTop + log.clientHeight >= log.scrollHeight - 4);
        if (j.log && j.log !== log.textContent) { log.textContent = j.log; }
        if (atBottom) { log.scrollTop = log.scrollHeight; }

        if (!j.running) {
          window.clearInterval(jobTimer); jobTimer = null; setBusy(false);
          // A check job rewrote ssl-data.js, which only arrives as a fresh
          // <script> tag - a full reload is the honest way to pick that up.
          if (j.kind === 'check') { window.setTimeout(function(){ location.reload(); }, 900); }
          else { CertCamel.loadState(); }
        }
      });
    }, 1500);
  }

  // --- Theme ---------------------------------------------------------------- //
  // A dropdown over a small registry rather than a cycle button, so a future
  // theme is one CSS block (:root[data-theme="name"]{...} in app.css) plus one
  // entry here - not a redesign of the control. The pre-paint choice is applied
  // by an inline script in <head> so a saved theme never flashes the default on
  // the way in; this wires the dropdown and keeps it in sync.
  var THEMES = [
    {value: 'auto',  label: 'Auto (system)'},
    {value: 'light', label: 'Light'},
    {value: 'dark',  label: 'Dark'}
  ];
  CertCamel.THEMES = THEMES;   // extend from here if a view ever wants to offer it too

  (function(){
    var root = document.documentElement;
    var sel  = document.getElementById('theme-select');
    if (!sel) { return; }

    var KEY = 'certcamel-theme';

    THEMES.forEach(function(t){
      var o = document.createElement('option');
      o.value = t.value;
      o.textContent = t.label;
      sel.appendChild(o);
    });

    function read(){
      var v = localStorage.getItem(KEY);
      return THEMES.some(function(t){ return t.value === v; }) ? v : 'auto';
    }
    function apply(mode){
      if (mode === 'auto') { root.removeAttribute('data-theme'); }
      else { root.setAttribute('data-theme', mode); }
      if (mode === 'auto') { localStorage.removeItem(KEY); }
      else { localStorage.setItem(KEY, mode); }
    }

    sel.value = read();
    apply(sel.value);
    sel.addEventListener('change', function(){ apply(sel.value); });
  })();

  // --- Sidebar collapse ------------------------------------------------------- //

  (function(){
    var KEY = 'certcamel-sidebar-collapsed';
    var btn = document.getElementById('btn-sidebar-toggle');
    if (localStorage.getItem(KEY) === '1') { document.body.classList.add('sidebar-collapsed'); }
    if (!btn) { return; }
    btn.addEventListener('click', function(){
      var collapsed = document.body.classList.toggle('sidebar-collapsed');
      localStorage.setItem(KEY, collapsed ? '1' : '0');
    });
  })();

  // --- Router ----------------------------------------------------------------- //
  // A view registers a render(sub) function, called every time its route becomes
  // active; "sub" is whatever followed the second slash (e.g. "authorities" in
  // "#/settings/authorities"). Views rebuild their DOM from CertCamel.state on
  // every visit rather than trying to diff it, matching how the single-page
  // version always re-rendered from scratch.

  CertCamel.registerView = function(name, def){ CertCamel.views[name] = def; };

  function currentRoute(){
    var h = location.hash.replace(/^#\/?/, '');
    if (!h) { return {view: 'home', sub: null}; }
    var parts = h.split('/');
    return {view: parts[0] || 'home', sub: parts[1] || null};
  }
  CertCamel.currentRoute = currentRoute;

  function navigate(){
    var r = currentRoute();
    var viewName = CertCamel.views[r.view] ? r.view : 'home';

    document.querySelectorAll('.view').forEach(function(v){ v.classList.add('hidden'); });
    document.querySelectorAll('.navitem').forEach(function(n){
      var owns = n.getAttribute('data-view') === viewName;
      n.setAttribute('aria-current', owns ? 'page' : 'false');
    });

    var container = document.getElementById('view-' + viewName);
    if (container) { container.classList.remove('hidden'); }

    var view = CertCamel.views[viewName];
    if (view && view.render) { view.render(r.sub); }
  }
  CertCamel.navigate = function(hash){
    if (hash) { location.hash = hash; }   // triggers hashchange -> navigate()
    else { navigate(); }
  };

  window.addEventListener('hashchange', navigate);

  // --- Boot ------------------------------------------------------------------- //

  document.addEventListener('DOMContentLoaded', function(){
    CertCamel.loadState(function(){
      navigate();
    });
  });
})();
