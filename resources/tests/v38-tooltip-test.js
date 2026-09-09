// The tooltip borrows the title attribute rather than replacing it.
//
// The browser's own tooltip appears under the pointer, after a delay it chooses,
// in a font belonging to no design - and on a help icon the pointer then covers
// the first words. This positions its own box against the element instead.
//
// Around fifty title attributes across the views are the right place for that
// text to live, so nothing at the call sites changed: the title is moved to
// data-tip on hover, which is what suppresses the native box, and put back on
// the way out. THAT is the part worth guarding - a title that does not come back
// is text silently deleted from the app.
const fs = require('fs');
const { JSDOM, VirtualConsole } = require('jsdom');

const ROOT = require('path').join(__dirname, '..') + require('path').sep;
const html = fs.readFileSync(ROOT + 'ssl-tracker.html', 'utf8');
const scripts = ['assets\\app.js'].map(p => fs.readFileSync(ROOT + p, 'utf8'));

const errors = []; const vc = new VirtualConsole();
vc.on('jsdomError', e => errors.push(e.detail ? e.detail.stack : e.message));
const dom = new JSDOM(html, {url:'http://127.0.0.1:1/?t=abc', runScripts:'outside-only',
                             pretendToBeVisual:true, virtualConsole:vc});
const w = dom.window, d = dom.window.document;
w.SSL_DATA = null;
w.XMLHttpRequest = function(){ this.open=()=>{}; this.setRequestHeader=()=>{}; this.send=()=>{}; };
const store = {};
Object.defineProperty(w, 'localStorage', {value:{getItem:k=>store[k]||null,setItem:(k,v)=>store[k]=v,removeItem:k=>delete store[k]}, configurable:true});
try { scripts.forEach(s => w.eval(s)); } catch(e){ errors.push('LOAD THREW: ' + e.message); }

let failed = 0;
function check(name, ok, detail){
  if (ok) { console.log('  ok   ' + name); }
  else { console.log('  FAIL ' + name + '  -- ' + detail); failed++; }
}
const tip = () => d.getElementById('apptip');
const shown = () => !!tip() && !tip().classList.contains('hidden');

function hover(node){
  const e = new w.MouseEvent('mouseover', {bubbles:true});
  node.dispatchEvent(e);
}

// A button with a title, and a child inside it, because the real help icons are
// nested inside the row that carries the title.
const host = d.createElement('button');
host.setAttribute('title', 'Works out what would renew and stops.');
const inner = d.createElement('span');
inner.textContent = 'i';
host.appendChild(inner);
d.body.appendChild(host);

console.log('\nhovering shows a styled box and silences the native one');
hover(host);
check('a tooltip element exists', !!tip(), 'none created');
check('it is showing', shown(), 'still hidden');
check('it carries the text', tip().textContent === 'Works out what would renew and stops.', tip().textContent);
check('the native tooltip is suppressed', !host.hasAttribute('title'), 'title still set');
check('the text is parked, not lost', host.getAttribute('data-tip') === 'Works out what would renew and stops.',
      host.getAttribute('data-tip'));
check('and it is announced to assistive tech',
      host.getAttribute('aria-describedby') === 'apptip', host.getAttribute('aria-describedby'));

console.log('\nleaving puts the title back');
hover(d.body);
check('hidden again', !shown(), 'still showing');
check('title restored', host.getAttribute('title') === 'Works out what would renew and stops.',
      host.getAttribute('title'));
check('the parked copy is cleared', !host.hasAttribute('data-tip'), host.getAttribute('data-tip'));
check('and the aria link is dropped', !host.hasAttribute('aria-describedby'), 'still described');

console.log('\nhovering a child counts as hovering the element that has the title');
hover(inner);
check('found through the child', shown() && !host.hasAttribute('title'), 'not shown');
hover(d.body);

console.log('\nan empty title is not a tooltip');
const blank = d.createElement('button');
blank.setAttribute('title', '');
d.body.appendChild(blank);
hover(blank);
check('nothing shown', !shown(), 'showed a blank box');
check('and its empty title is left alone', blank.getAttribute('title') === '', 'title was taken');

console.log('\nEscape dismisses it, like any transient thing');
hover(host);
d.dispatchEvent(new w.KeyboardEvent('keydown', {key:'Escape', bubbles:true}));
check('hidden', !shown(), 'still showing');
check('and the title came back', host.getAttribute('title') === 'Works out what would renew and stops.',
      host.getAttribute('title'));

console.log('\na title replaced while borrowed is not overwritten on the way out');
/* setEnabled() in the certificates toolbar rewrites button titles as the
   selection changes, which can happen while one is hovered. The newer value has
   to win, or the button would explain a state it is no longer in. */
hover(host);
host.setAttribute('title', 'Every selected certificate needs a local copy.');
hover(d.body);
check('the newer title survives', host.getAttribute('title') === 'Every selected certificate needs a local copy.',
      host.getAttribute('title'));

console.log('\nload errors: ' + (errors.length ? errors.join('\n') : 'none'));
if (failed) { console.log('\n' + failed + ' CHECK(S) FAILED'); process.exit(1); }
console.log('\nall checks passed');
