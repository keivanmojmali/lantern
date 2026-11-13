// Lean markdown viewer: top tab strip + rendered document. Native bridge: window.Lantern.
const L = window.Lantern = {};
const S = { plans: new Map(), order: [], active: null };
const $ = id => document.getElementById(id);
const cur = () => S.plans.get(S.active);

// ───────── native → web ─────────
L.setSettings = L.setView = () => {};
L.update = p => {
  const old = S.plans.get(p.path), parsed = R.parse(p.content);
  if (!old) {
    S.plans.set(p.path, { path: p.path, name: p.name, content: p.content, parsed, answers: p.answers || {}, comments: (p.comments || {}).notes || [], submitted: !!(p.comments || {}).submitted, glow: new Set(), unseen: !!p.isNew, missing: p.missing, scroll: 0 });
    S.order.push(p.path);
    if (!S.active) { activate(p.path); return; }
  } else {
    old.name = p.name; old.missing = p.missing;
    if (old.content !== p.content) {
      const prev = old.parsed.blocks.map(b => b.raw);
      old.content = p.content; old.parsed = parsed;
      old.glow = R.changed(prev, parsed.blocks.map(b => b.raw));
      if (S.active !== p.path) old.unseen = true;
      setTimeout(() => { if (old.parsed === parsed) old.glow = new Set(); }, 5000);
    }
  }
  if (S.active === p.path) render(true);
  tabs(); C.bar();
};
L.remove = path => {
  S.plans.delete(path); S.order = S.order.filter(x => x !== path);
  if (S.active === path) { S.active = null; if (S.order.length) activate(S.order[0]); else { render(false); } }
  tabs(); C.bar();
};
L.activate = path => { if (S.plans.has(path)) activate(path); };
L.toast = msg => { const t = $('toast'); t.textContent = msg; t.classList.add('show'); clearTimeout(L._t); L._t = setTimeout(() => t.classList.remove('show'), 1800); };
L.setAccess = denied => {
  let b = $('access');
  if (!denied.length) { if (b) b.remove(); return; }
  if (!b) {
    b = U.el('div', { id: 'access' });
    document.body.append(b);
  }
  b.replaceChildren(
    U.el('div', { class: 'accbox' },
      U.el('h2', {}, "Lantern doesn't have permission to read your files"),
      U.el('p', {}, 'macOS is blocking access to: ' + denied.join(', ') + '. Without it, plans in those folders can\u2019t be shown.'),
      U.el('p', {}, 'Go to System Settings \u203a Privacy & Security \u203a Files & Folders, find Lantern, and switch those folders on.'),
      (() => { const btn = U.el('button', { class: 'accbtn' }, 'Open System Settings'); btn.addEventListener('click', () => U.post({ t: 'openPrivacy' })); return btn; })()));
};
// Scroll to (and pulse) a heading, a text snippet or an answer box. Returns "ok <what>" or an error string.
L.goto = (path, target) => {
  if (path && S.plans.has(path) && path !== S.active) activate(path);
  const doc = $('docin'), want = String(target || '').trim().replace(/^#+\s*/, '').toLowerCase();
  if (!want) return 'no target';
  const blocks = [...doc.querySelectorAll('.blk')], txt = b => b.textContent.trim().toLowerCase();
  const heads = blocks.filter(b => b.classList.contains('hd'));
  let el = null, what = '';
  const box = [...doc.querySelectorAll('.ask')].find(a => a.dataset.id.toLowerCase() === want);
  if (box) { el = box.closest('.blk'); what = 'question ' + box.dataset.id; }
  else if ((el = heads.find(b => txt(b) === want) || heads.find(b => txt(b).includes(want)))) what = 'section "' + el.textContent.trim() + '"';
  else if ((el = blocks.find(b => txt(b).includes(want)))) what = 'matching text';
  if (!el) return 'not found in ' + (cur()?.name || 'document') + ': ' + target;
  el.scrollIntoView({ block: el.classList.contains('hd') ? 'start' : 'center', behavior: 'smooth' });
  el.classList.remove('glow'); void el.offsetWidth; el.classList.add('glow');
  setTimeout(() => el.classList.remove('glow'), 4700);
  return 'ok ' + what;
};
L.cmd = c => { if (c === 'closePlan' && S.active) U.post({ t: 'closePlan', path: S.active }); };

// ───────── theme ─────────
const mq = matchMedia('(prefers-color-scheme: dark)');
function theme() {
  const dark = mq.matches;
  document.documentElement.dataset.theme = dark ? 'dark' : 'light';
  $('hlcss').href = dark ? 'vendor/hl-dark.css' : 'vendor/hl-light.css';
}
mq.addEventListener('change', () => { theme(); render(false); });
theme();

// ───────── view ─────────
function activate(path) {
  const old = cur(); if (old) old.scroll = $('doc').scrollTop;
  S.active = path;
  const p = cur(); if (p) p.unseen = false;
  render(false); $('doc').scrollTop = p ? p.scroll : 0;
  tabs(); C.bar();
  if (p) U.post({ t: 'active', path });
}
function tabs() {
  const t = $('tabs'); t.hidden = S.order.length < 2; t.innerHTML = '';
  S.order.forEach(path => {
    const p = S.plans.get(path);
    const b = U.el('button', { class: 'tab' + (path === S.active ? ' on' : '') + (p.missing ? ' gone' : ''), title: path }, p.name, p.unseen ? U.el('i', { class: 'dot' }) : '');
    b.addEventListener('click', () => activate(path));
    t.append(b);
    if (path === S.active) b.scrollIntoView({ inline: 'nearest', block: 'nearest' });
  });
}
function render(follow) {
  const p = cur(), doc = $('docin'), top = $('doc').scrollTop;
  // a re-render (Claude edited the file) must not eat what the user is typing
  const ae = document.activeElement, typing = ae && ae.classList && ae.classList.contains('ask-ta') ? { id: ae.dataset.id, s: ae.selectionStart, e: ae.selectionEnd } : null;
  if (!p) { doc.innerHTML = '<div class="emptystate">Run <code>lantern plan.md</code> or drop a markdown file here.</div>'; return; }
  R.mount(doc, p.parsed, p, p.glow);
  if (typing) { const ta = doc.querySelector('.ask-ta[data-id="' + CSS.escape(typing.id) + '"]'); if (ta) { ta.focus({ preventScroll: true }); ta.setSelectionRange(typing.s, typing.e); } }
  const g = follow && doc.querySelector('.glow');
  if (g) g.scrollIntoView({ block: 'center', behavior: 'smooth' }); else $('doc').scrollTop = top;
}

// ⌘[ / ⌘] and ctrl-tab style switching; everything else is native scrolling
document.addEventListener('keydown', e => {
  if (!e.metaKey || S.order.length < 2) return;
  const d = e.key === ']' ? 1 : e.key === '[' ? -1 : 0; if (!d) return;
  e.preventDefault(); activate(S.order[(S.order.indexOf(S.active) + d + S.order.length) % S.order.length]);
});

render(false);
U.post({ t: 'ready' });
