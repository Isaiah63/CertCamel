/* Cert Camel - app shell: routing, the API client, shared state, and the job
   runner. Views register themselves and are shown/hidden by hash; there is no
   framework and no build step, so this is what a router looks like here. */
(function(){
  "use strict";

  var RENEW_DAYS = 30;   // flag for renewal at or under this many days left
  var STALE_DAYS = 2;    // nag to re-run the checker after this long

  /* The token arrives in the query string - that is the only way serve.ps1 can
     hand it to a page it is opening - and is taken straight back out of the
     address again.

     A URL is the leakiest place a live credential can sit: it is written to
     history, synced to a signed-in browser profile, restored with the session,
     and caught in every screenshot of the window. That would be tolerable for
     a secret that died with the tab, but the server task starts at boot and
     mints one token for the machine's whole uptime, so an address copied out
     of history three weeks later still opens the API.

     sessionStorage, so a reload survives without the query string having to
     come back. It is per-tab and per-origin, and the whole origin is this app;
     anything able to read it is already running as you and can read
     secrets.xml directly. replaceState rather than pushState, because pushing
     would leave the ?t= entry sitting in history - the exact thing being
     removed. */
  var TOKEN = (function(){
    var key = 'certcamel.token';
    var m = /(?:^|[?&])t=([a-f0-9]+)/.exec(location.search);
    if (m) {
      var stored = false;
      try { window.sessionStorage.setItem(key, m[1]); stored = true; } catch (e) { /* storage disabled */ }
      // Only clean the address once the token has somewhere else to live.
      // Stripping it with nowhere to put it would turn F5 into "No session".
      if (stored) {
        try { window.history.replaceState(null, '', location.pathname + location.hash); }
        catch (e) { /* old browser: a token in the URL beats a page that cannot reload */ }
      }
      return m[1];
    }
    try { return window.sessionStorage.getItem(key); } catch (e) { return null; }
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

  /* A one-line summary plus a link into the guide, for panes that had grown
     into documentation - paragraphs of explanation standing where a field
     should be. The guide carries all of it already and carries it better.

     Deliberately NOT for every long blurb. Where the text warns about a
     consequence of the control beside it, or states a rule that is not
     self-evident from the thing being edited, it belongs on the page in full:
     moving that behind a click is not tidying, it is hiding. Nor is it for
     anything the guide has no section on - a link that lands at the top of the
     page answers nothing.

     target=_blank so a half-filled form is never navigated away from, and
     rel=noopener because the new tab has no business reaching back. */
  CertCamel.guideHint = function(text, anchor, linkText){
    var p = el('p', 'hint', text + ' ');
    var a = el('a', null, linkText || 'Read more');
    a.href = anchor.indexOf('.html') === -1 ? 'readme.html#' + anchor : anchor;
    a.target = '_blank';
    a.rel = 'noopener';
    p.appendChild(a);
    return p;
  };

  CertCamel.daysUntil = function(iso){
    return Math.floor((new Date(iso) - new Date()) / 86400000);
  };
  CertCamel.fmtDate = function(iso){
    var d = new Date(iso);
    return d.toLocaleDateString(undefined, {year:'numeric', month:'short', day:'numeric'});
  };
  // Full local date AND time, with the zone spelled out. Renewal windows arrive
  // as UTC instants, and "renews Oct 4" is not enough to know whether that is
  // tonight or tomorrow morning where you are sitting.
  //
  // No timezone setting sits behind this: the server binds 127.0.0.1, so the
  // browser and the scheduled tasks are always the same machine. A setting could
  // only ever hold the value the OS already reports, and would need changing
  // twice a year for daylight saving. The zone label moves on its own instead.
  CertCamel.fmtDateTime = function(iso){
    var d = new Date(iso);
    if (isNaN(d)) { return ''; }
    return d.toLocaleString(undefined, {
      weekday:'short', year:'numeric', month:'short', day:'numeric',
      hour:'numeric', minute:'2-digit', timeZoneName:'short'
    });
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
  // The token travels as a header on every call without exception. The server
  // still accepts ?t= for the initial page load, which has nowhere else to put
  // it, but no /api/ call relies on that and /api/download refuses it outright.

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

  /* The one response that is a file rather than JSON, so it cannot go through
     api() above - and the one that must never be reachable from an address
     alone, which is why it is an XHR carrying the header instead of an <a>
     carrying ?t=. The server refuses the query form on this route; see the
     comment there for what it is protecting.

     A blob and a synthetic click: the bytes go straight from the response into
     the file the browser saves, and nothing replayable lands in the download
     list. The object URL is revoked on a timer rather than immediately -
     released in the same tick as the click, Firefox cancels the save. */
  function download(path, filename, cb){
    var x = new XMLHttpRequest();
    x.open('GET', path, true);
    x.setRequestHeader('X-Tracker-Token', TOKEN);
    x.responseType = 'blob';
    x.onreadystatechange = function(){
      if (x.readyState !== 4) { return; }
      if (x.status < 200 || x.status >= 300) {
        // The body is a blob here, so the server's own message cannot be read
        // back out without more machinery than one status line is worth.
        if (cb) { cb('The download failed: the local server returned ' + (x.status || 'no response')); }
        return;
      }
      var url = window.URL.createObjectURL(x.response);
      var a = document.createElement('a');
      a.href = url;
      a.download = filename;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      window.setTimeout(function(){ window.URL.revokeObjectURL(url); }, 60000);
      if (cb) { cb(null); }
    };
    x.send(null);
  }
  CertCamel.download = download;

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
      setTally(s.tally);
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

  /* Lifetime renewals, from the audit trail.
     Hidden at zero rather than shown as "0 renewed": a fresh install has not
     failed at anything, and a zero in the sidebar reads like a warning. It
     appears the moment there is something to count.
     The tooltip says WHAT it counts from, because the audit trail is younger
     than some installs and a total that quietly means something narrower than
     it says would be worse than none. */
  function setTally(t){
    var box = document.getElementById('sidebar-tally');
    if (!box) { return; }
    var n = (t && t.renewed) || 0;
    if (!n) { box.classList.add('hidden'); return; }

    // Grouped: this is a number that only grows, and 12847 is harder to read at
    // a glance than 12,847.
    document.getElementById('tally-n').textContent = n.toLocaleString();
    box.title = t.since
      ? 'Certificates renewed successfully since ' + new Date(t.since).toLocaleDateString() +
        ', counted from the audit trail.'
      : 'Certificates renewed successfully, counted from the audit trail.';
    box.classList.remove('hidden');
  }

  // --- Job runner ------------------------------------------------------------- //
  // Lives in the shell, not in a view, so a renewal survives navigating away from
  // Certificates while it runs rather than being torn down with the view.

  var jobTimer = null;

  function setBusy(busy){
    document.querySelectorAll('[data-busy-disable]').forEach(function(b){ b.disabled = busy; });
  }
  CertCamel.setBusy = setBusy;

  /* A run log, coloured by the level each line already carries.

     The scripts print "[17:51:52] [error] ...", and the level is the thing you
     scan for - one failed node twenty lines up is easy to lose in a single grey
     block, and that is exactly the line the log exists to show you.

     Nothing is inferred beyond what the line already says. check-ssl.ps1 does
     not use the bracket format, so its wording is matched with the same
     patterns jobHadTrouble uses, which keeps "is this line red" and "should the
     page offer a reload" from ever disagreeing.

     The result's textContent is identical to the input, which is what lets
     pollJob keep comparing against it to decide whether anything changed. */
  function logLevel(line){
    if (/\[error\]/i.test(line)) { return 'error'; }
    if (/\[warn\]/i.test(line))  { return 'warn'; }
    if (/\[ok\]/i.test(line))    { return 'ok'; }
    if (jobHadTrouble(line))     { return 'error'; }
    return '';
  }

  function renderLog(pre, text){
    var parts = String(text === null || text === undefined ? '' : text).split('\n');
    var frag = document.createDocumentFragment();
    for (var i = 0; i < parts.length; i++) {
      if (i) { frag.appendChild(document.createTextNode('\n')); }
      var level = logLevel(parts[i]);
      if (!level) { frag.appendChild(document.createTextNode(parts[i])); continue; }
      var span = document.createElement('span');
      span.className = 'll-' + level;
      span.textContent = parts[i];
      frag.appendChild(span);
    }
    pre.textContent = '';
    pre.appendChild(frag);
  }
  CertCamel.renderLog = renderLog;

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
          // Re-rendered rather than appended: assigning to textContent would
          // flatten every coloured line back into one plain block.
          renderLog(log, log.textContent + '\n' + err);
          window.clearInterval(jobTimer); jobTimer = null; setBusy(false);
          return;
        }

        // Only auto-scroll while the person is already following the tail;
        // yanking the view back down while they read older lines is hostile.
        atBottom = (log.scrollTop + log.clientHeight >= log.scrollHeight - 4);
        if (j.log && j.log !== log.textContent) { renderLog(log, j.log); }
        if (atBottom) { log.scrollTop = log.scrollHeight; }

        if (!j.running) {
          window.clearInterval(jobTimer); jobTimer = null; setBusy(false);

          // A check job rewrote ssl-data.js, which only arrives as a fresh
          // <script> tag - a full reload is the honest way to pick that up.
          //
          // But NOT when the run reported a problem. Reloading takes the log
          // off the screen, and the log is the only place the reason appears -
          // so the one run you most need to read is the one that vanishes
          // after 900ms. When something failed, hold the panel and let the
          // person press it themselves.
          if (j.kind === 'check') {
            if (jobHadTrouble(j.log)) { offerReload(); }
            else { window.setTimeout(function(){ location.reload(); }, 900); }
          }
          else { CertCamel.loadState(); }
        }
      });
    }, 1500);
  }

  /* Did the run report anything worth reading before the page reloads?

     Matched against check-ssl.ps1's own output, which is in this repository and
     changes only when somebody changes it deliberately - "ERROR" per host and
     "N domain(s) could not be reached" in the summary. Text matching is
     ordinarily a poor signal, but the alternative here is a result file the
     checker does not write, and the cost of a false positive is merely that
     somebody presses a button. The cost of a false negative is an error nobody
     ever sees. */
  function jobHadTrouble(text){
    if (!text) { return false; }
    return /\bERROR\b/.test(text) ||
           /could not be reached/i.test(text) ||
           /\bFAILED\b/i.test(text);
  }

  // Replaces the automatic reload with a deliberate one, and says why the page
  // is still showing old numbers.
  function offerReload(){
    var log = document.getElementById('joblog');
    if (!log || !log.parentNode) { return; }
    if (document.getElementById('job-reload')) { return; }   // one is enough

    var bar = document.createElement('p');
    bar.className = 'mini';
    bar.id = 'job-reload';

    var btn = document.createElement('button');
    btn.className = 'btn sm';
    btn.type = 'button';
    btn.textContent = 'Reload the page';
    btn.addEventListener('click', function(){ location.reload(); });
    bar.appendChild(btn);

    var note = document.createElement('span');
    note.className = 'jobnote';
    note.textContent = 'Something above needs reading. The table still shows the previous check until you reload.';
    bar.appendChild(note);

    log.parentNode.appendChild(bar);
  }

  // --- Theme ---------------------------------------------------------------- //
  // ADDING A THEME IS ONE CSS BLOCK (:root[data-theme="name"]{...} in app.css)
  // plus one entry here. Nothing else in the app knows a theme exists.
  //
  // The row used to cycle on click, with a note saying a menu would beat
  // cycling past four or five entries. Three themes arrived at once and made it
  // six, so the menu is here: cycling to reach the last item meant five clicks,
  // and offered no way to see what you were choosing between.
  //
  // The pre-paint choice is applied by an inline script in <head> so a saved
  // theme never flashes the default on the way in; this wires the button.
  var THEMES = [
    {value: 'auto',         label: 'Auto'},
    {value: 'light',        label: 'Light'},
    {value: 'dark',         label: 'Dark'},
    {value: 'dawn',         label: 'Dawn'},
    {value: 'thunderstorm', label: 'Thunderstorm'},
    {value: 'matrix',       label: 'Matrix'},
    {value: 'usa',          label: 'USA'},
    {value: 'synthwave',    label: 'Synthwave'}
  ];
  CertCamel.THEMES = THEMES;   // extend from here if a view ever wants to offer it too

  (function(){
    var root = document.documentElement;
    var btn  = document.getElementById('btn-theme');
    var now  = document.getElementById('theme-now');
    if (!btn) { return; }

    var KEY = 'certcamel-theme';

    function read(){
      var v = localStorage.getItem(KEY);
      return THEMES.some(function(t){ return t.value === v; }) ? v : 'auto';
    }
    function labelOf(mode){
      var hit = null;
      THEMES.forEach(function(t){ if (t.value === mode) { hit = t; } });
      return hit ? hit.label : mode;
    }
    function apply(mode){
      if (mode === 'auto') {
        root.removeAttribute('data-theme');
        localStorage.removeItem(KEY);
      } else {
        root.setAttribute('data-theme', mode);
        localStorage.setItem(KEY, mode);
      }
      if (now) { now.textContent = labelOf(mode); }
      btn.title = 'Theme: ' + labelOf(mode) + '. Click to change.';
    }

    /* The menu is a .rowmenu, the same element the certificate rows use, so it
       inherits that styling rather than inventing a second popup with its own
       look. It renders on document.body and is positioned from the button:
       the sidebar foot is the bottom-left corner of the screen, so it opens
       UPWARD, and falls back to downward only if it somehow would not fit. */
    var menu = null;

    function closeMenu(){
      if (!menu) { return; }
      if (menu.parentNode) { menu.parentNode.removeChild(menu); }
      menu = null;
      btn.setAttribute('aria-expanded', 'false');
      document.removeEventListener('keydown', onKey, true);
      document.removeEventListener('mousedown', onOutside, true);
      window.removeEventListener('resize', closeMenu);
    }
    function onKey(e){
      if (e.key === 'Escape') { e.stopPropagation(); closeMenu(); btn.focus(); }
    }
    function onOutside(e){
      if (!menu) { return; }
      if (menu.contains(e.target) || btn.contains(e.target)) { return; }
      closeMenu();
    }

    function openMenu(){
      closeMenu();
      var current = read();
      menu = el('div', 'rowmenu');
      menu.setAttribute('role', 'menu');

      THEMES.forEach(function(t){
        var item = el('button', null, t.label);
        item.type = 'button';
        item.setAttribute('role', 'menuitem');
        // The current one is marked rather than hidden or disabled: knowing
        // which you are on is most of why the menu exists.
        if (t.value === current) { item.setAttribute('aria-current', 'true'); }
        item.addEventListener('click', function(){ apply(t.value); closeMenu(); btn.focus(); });
        menu.appendChild(item);
      });

      document.body.appendChild(menu);

      var r  = btn.getBoundingClientRect();
      var mh = menu.offsetHeight;
      var top = (r.top - mh - 6 >= 8) ? (r.top - mh - 6) : (r.bottom + 6);
      menu.style.left = Math.max(8, r.left) + 'px';
      menu.style.top  = Math.max(8, top) + 'px';

      btn.setAttribute('aria-expanded', 'true');
      document.addEventListener('keydown', onKey, true);
      document.addEventListener('mousedown', onOutside, true);
      window.addEventListener('resize', closeMenu);

      var first = menu.querySelector('button[aria-current]') || menu.querySelector('button');
      if (first) { first.focus(); }
    }

    btn.setAttribute('aria-haspopup', 'true');
    btn.setAttribute('aria-expanded', 'false');

    apply(read());
    btn.addEventListener('click', function(){
      if (menu) { closeMenu(); } else { openMenu(); }
    });
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

  // --- The Settings nav group folds up ----------------------------------------- //
  // Five sub-pages is a lot of sidebar for something visited occasionally.

  (function(){
    var KEY   = 'certcamel-navgroup-settings-collapsed';
    var group = document.getElementById('navgroup-settings');
    var btn   = document.getElementById('btn-settings-group');
    if (!group || !btn) { return; }

    function apply(collapsed){
      group.classList.toggle('collapsed', collapsed);
      btn.setAttribute('aria-expanded', collapsed ? 'false' : 'true');
      localStorage.setItem(KEY, collapsed ? '1' : '0');
    }

    apply(localStorage.getItem(KEY) === '1');
    btn.addEventListener('click', function(){
      apply(!group.classList.contains('collapsed'));
    });

    // Landing on a settings page (deep link, refresh, the picker's "open
    // settings" shortcut) unfolds the group - the active item must never be
    // hidden inside a shut drawer.
    CertCamel.expandSettingsGroup = function(){ apply(false); };
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

    if (viewName === 'settings' && CertCamel.expandSettingsGroup) { CertCamel.expandSettingsGroup(); }

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
