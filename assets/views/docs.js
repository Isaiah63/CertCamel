/* Docs: an index of the standalone guide pages. They stay separate documents
   rather than being pulled into the app - each has its own layout and is meant
   to be read on its own, printed, or linked to directly. */
(function(){
  "use strict";
  var CC = window.CertCamel;
  var el = CC.el;

  var DOCS = [
    {href: 'readme.html', title: 'Read me', desc: 'How renewal works, what the buttons do, and the verification tiers behind the Deployed column.'},
    {href: 'haproxy-setup.html', title: 'HAProxy setup guide', desc: 'Step by step: the Data Plane API, a dedicated user, TLS on the API itself, and pointing Cert Camel at it.'}
  ];

  function render(){
    var host = document.getElementById('view-docs');
    host.textContent = '';
    host.appendChild(el('h2', null, 'Docs'));
    host.appendChild(el('p', 'mini', 'Each guide opens in its own tab.'));

    var list = el('div', 'doclist');
    DOCS.forEach(function(d){
      var a = el('a', 'doclink');
      a.href = d.href; a.target = '_blank'; a.rel = 'noopener';
      a.appendChild(el('div', 't', d.title));
      a.appendChild(el('div', 'd', d.desc));
      list.appendChild(a);
    });
    host.appendChild(list);
  }

  CC.registerView('docs', {render: render});
})();
