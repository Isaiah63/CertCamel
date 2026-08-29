/* Docs: an index of the standalone guide pages. They stay separate documents
   rather than being pulled into the app - each has its own layout and is meant
   to be read on its own, printed, or linked to directly. */
(function(){
  "use strict";
  var CC = window.CertCamel;
  var el = CC.el;

  var DOCS = [
    {href: 'readme.html', title: 'Read me', desc: 'The complete manual: how certificates are grouped, wildcards, certificate authorities, staging, logs and the audit trail, alerts, and every status the page can show you.'},
    {href: 'certificate-path.html', title: 'How a certificate reaches the wire', desc: 'The mechanism, end to end: how watched hostnames become certificates, why a wildcard is kept apart from the rest, when renewal actually fires, which crt-list a certificate lands in, and how a node is proved to be serving it rather than merely holding it.'},
    {href: 'haproxy-setup.html', title: 'HAProxy setup guide', desc: 'Step by step: the Data Plane API, a dedicated user, TLS on the API itself, and pointing Cert Camel at it.'},
    {href: 'windows-server-setup.html', title: 'Windows Server install', desc: 'Installing where nobody is signed in: which account owns the scheduled tasks and the encrypted credentials, why that cannot be changed afterwards, and who can open the console once it is running.'},
    {href: 'security.html', title: 'Security', desc: 'What the loopback binding and the token actually protect against, where credentials are stored and what breaks when the account changes, what reaches the logs and what never does.'},
    {href: 'console-certificate.html', title: 'The console certificate', desc: 'The certificate this page is served with: where it lives on disk, how to put a replacement there by hand, and the ways back in when it stops working — which is exactly when this console cannot tell you anything.'}
  ];

  /* Deep links into the guides above, framed as the job rather than the
     chapter. Three pages is an honest count and also a short-looking one; the
     manual is eighteen sections and nothing on this page said so. These are
     the four people arrive looking for. */
  var JUMPS = [
    {href: 'readme.html#dns',      label: 'Connect your DNS'},
    {href: 'readme.html#auto',     label: 'Renew unattended'},
    {href: 'readme.html#output',   label: 'What you get on disk'},
    {href: 'readme.html#trouble',  label: 'When it breaks'}
  ];

  function render(){
    var host = document.getElementById('view-docs');
    host.textContent = '';
    host.appendChild(el('h2', null, 'Docs'));
    /* No note about tabs any more. They still open in their own tab, but the
       guides no longer link back here - the way back is the tab you came from,
       which needs no explaining until something claims otherwise. */
    host.appendChild(el('p', 'mini', 'Everything ships in the folder and is served from it, so the guides work with no internet.'));

    var list = el('div', 'doclist');
    DOCS.forEach(function(d){
      var a = el('a', 'doclink');
      a.href = d.href; a.target = '_blank'; a.rel = 'noopener';
      a.appendChild(el('div', 't', d.title));
      a.appendChild(el('div', 'd', d.desc));
      list.appendChild(a);
    });
    host.appendChild(list);

    host.appendChild(el('div', 'docsec', 'Straight to a section'));
    var jumps = el('div', 'jumps');
    JUMPS.forEach(function(j){
      var a = el('a', null, j.label);
      a.href = j.href; a.target = '_blank'; a.rel = 'noopener';
      jumps.appendChild(a);
    });
    host.appendChild(jumps);

    /* What ACME client is actually installed.
       Pinned once fetched and it does not move on its own - deliberately, since
       this is the component every renewal runs through. Said here because
       otherwise the only way to find out is to go looking in lib\. */
    var v = (CC.state && CC.state.acmeVersion) || null;
    var foot = el('p', 'mini');
    if (v) {
      foot.appendChild(document.createTextNode('Renewal runs on Posh-ACME '));
      foot.appendChild(el('strong', null, v));
      foot.appendChild(document.createTextNode(
        ', installed in this folder. It stays on that version until you update it — see the Read me.'));
    } else {
      foot.textContent = 'Posh-ACME is not installed yet. Run First Time Setup to fetch it; without it nothing can be renewed.';
    }
    host.appendChild(foot);
  }

  CC.registerView('docs', {render: render});
})();
