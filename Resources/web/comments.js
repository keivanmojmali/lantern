// Highlight text → add a comment. Comments live next to the plan (never in the .md); Claude reads them with lantern_comments.
const C = (() => {
  const norm = s => String(s).replace(/\s+/g, ' ').trim();
  const SKIP = '.ask, .codehead, .mermaid-wrap, .front';

  // Rendered text of the document with whitespace collapsed, plus a map from each character back to its DOM text node.
  function flatten(root) {
    const out = [], map = []; let lastBlk = null;
    const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, { acceptNode: n => n.parentElement.closest(SKIP) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT });
    while (w.nextNode()) {
      const n = w.currentNode, blk = n.parentElement.closest('.blk');
      if (blk !== lastBlk && out.length && out[out.length - 1] !== ' ') { out.push(' '); map.push({ node: n, off: 0 }); }
      lastBlk = blk;
      const v = n.nodeValue;
      for (let i = 0; i < v.length; i++) {
        if (/\s/.test(v[i])) { if (out.length && out[out.length - 1] === ' ') continue; out.push(' '); } else out.push(v[i]);
        map.push({ node: n, off: i });
      }
    }
    return { s: out.join(''), map };
  }

  function locate(s, c) {
    const q = norm(c.quote); if (!q) return -1;
    if (c.before) { const k = s.indexOf(c.before + q); if (k >= 0) return k + c.before.length; }
    return s.indexOf(q);
  }

  // Wrap every comment's quote in <mark class="cmt">. A comment whose text no longer exists is marked detached.
  function highlight(root, comments) {
    for (const c of comments) {
      const { s, map } = flatten(root), idx = locate(s, c), len = norm(c.quote).length;
      c.detached = idx < 0;
      if (idx < 0) continue;
      const per = new Map();
      for (let i = idx; i < idx + len; i++) { const m = map[i], r = per.get(m.node); if (r) { r[0] = Math.min(r[0], m.off); r[1] = Math.max(r[1], m.off); } else per.set(m.node, [m.off, m.off]); }
      for (const [node, [a, b]] of per) {
        let t = a > 0 ? node.splitText(a) : node;
        if (b - a + 1 < t.length) t.splitText(b - a + 1);
        const mk = U.el('mark', { class: 'cmt', 'data-id': c.id });
        t.replaceWith(mk); mk.append(t);
      }
    }
  }

  const save = (p, submitted = false) => { p.submitted = submitted; U.post({ t: 'comments', path: p.path, notes: p.comments, submitted }); render(false); bar(); };

  // ───────── selection → floating "Comment" button ─────────
  let pending = null;   // { quote, before, section, rect }
  const btn = U.el('button', { id: 'cbtn', hidden: true }, '💬 Comment');
  const pop = U.el('div', { id: 'cpop', hidden: true });
  const barEl = U.el('div', { id: 'cbar', hidden: true });
  const list = U.el('div', { id: 'clist', hidden: true });
  document.body.append(btn, pop, barEl, list);

  function selection() {
    const sel = getSelection(), doc = document.getElementById('docin');
    if (!sel.rangeCount || sel.isCollapsed || !doc) return null;
    const r = sel.getRangeAt(0);
    if (!doc.contains(r.commonAncestorContainer)) return null;
    const el = r.commonAncestorContainer.nodeType === 1 ? r.commonAncestorContainer : r.commonAncestorContainer.parentElement;
    if (el.closest('.ask, textarea, .mermaid-wrap, .front')) return null;
    const quote = norm(sel.toString()).slice(0, 800); if (!quote) return null;
    const { s, map } = flatten(doc);
    let at = map.findIndex(m => m.node === r.startContainer && m.off >= r.startOffset);
    if (at < 0 || !s.startsWith(quote, at)) at = s.indexOf(quote);
    const startEl = r.startContainer.nodeType === 1 ? r.startContainer : r.startContainer.parentElement;
    return { quote, before: at > 0 ? s.slice(Math.max(0, at - 24), at) : '', section: startEl.closest('.blk')?.dataset.sec || '', rect: r.getBoundingClientRect() };
  }

  function place(el, rect, below) {
    el.hidden = false;
    const w = el.offsetWidth, h = el.offsetHeight;
    let x = Math.min(Math.max(8, rect.left + rect.width / 2 - w / 2), innerWidth - w - 8);
    let y = below ? rect.bottom + 8 : rect.top - h - 8;
    if (y < 8) y = rect.bottom + 8; if (y + h > innerHeight - 8) y = Math.max(8, innerHeight - h - 8);
    el.style.left = x + 'px'; el.style.top = y + 'px';
  }
  const hideAll = () => { btn.hidden = true; pop.hidden = true; pending = null; };

  document.addEventListener('mouseup', e => {
    if (e.target.closest('#cbtn, #cpop, #cbar, #clist')) return;
    setTimeout(() => {
      const s = selection();
      if (s) { pending = s; place(btn, s.rect, false); pop.hidden = true; }
      else if (!e.target.closest('mark.cmt')) hideAll();
    }, 0);
  });
  document.addEventListener('keydown', e => { if (e.key === 'Escape') { hideAll(); list.hidden = true; } });
  document.getElementById('doc').addEventListener('scroll', () => { btn.hidden = true; if (!pop.hidden) pop.hidden = true; }, { passive: true });
  btn.addEventListener('mousedown', e => e.preventDefault());   // keep the selection alive
  btn.addEventListener('click', () => { if (pending) { btn.hidden = true; editor(pending, null); } });

  // click an existing highlight → edit / delete
  document.addEventListener('click', e => {
    const mk = e.target.closest('mark.cmt'); if (!mk || !getSelection().isCollapsed) return;
    const p = cur(), c = p && p.comments.find(x => x.id === mk.dataset.id); if (!c) return;
    editor({ rect: mk.getBoundingClientRect() }, c);
  });

  function editor(ctx, existing) {
    const p = cur(); if (!p) return;
    const quote = existing ? existing.quote : ctx.quote;
    const ta = U.el('textarea', { class: 'ask-ta', rows: 3, placeholder: 'Your comment or decision…' });
    ta.value = existing ? existing.text : '';
    const done = () => { pop.hidden = true; pending = null; getSelection().removeAllRanges(); };
    const ok = U.el('button', { class: 'ask-send' }, existing ? 'Update' : 'Add');
    const cancel = U.el('button', { class: 'cx' }, 'Cancel');
    const del = existing && U.el('button', { class: 'cx danger' }, 'Delete');
    const commit = () => {
      const text = ta.value.trim(); if (!text) return;
      if (existing) existing.text = text;
      else p.comments.push({ id: Math.random().toString(36).slice(2, 10), quote: ctx.quote, before: ctx.before, section: ctx.section, text, ts: Date.now() / 1000 });
      done(); save(p);
    };
    ok.addEventListener('click', commit);
    cancel.addEventListener('click', done);
    if (del) del.addEventListener('click', () => { p.comments = p.comments.filter(x => x !== existing); done(); save(p); });
    ta.addEventListener('keydown', e => { if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); commit(); } });
    pop.replaceChildren(U.el('div', { class: 'cq' }, '“' + (quote.length > 140 ? quote.slice(0, 140) + '…' : quote) + '”'), ta, U.el('div', { class: 'ask-row' }, del || '', cancel, ok));
    place(pop, ctx.rect, true); ta.focus();
  }

  // ───────── bottom bar: count, list, Done ─────────
  function bar() {
    const p = cur(), n = p ? p.comments.length : 0;
    barEl.hidden = !n; if (!n) { list.hidden = true; return; }
    const count = U.el('button', { class: 'cx', title: 'Show all comments' }, n + (n === 1 ? ' comment' : ' comments'));
    count.addEventListener('click', () => { list.hidden = !list.hidden; if (!list.hidden) fillList(); });
    const done = U.el('button', { class: 'ask-send' + (p.submitted ? ' done' : '') }, p.submitted ? 'Done ✓ Claude can read them' : 'Done — send to Claude');
    done.addEventListener('click', () => save(p, true));
    barEl.replaceChildren(count, done);
    if (!list.hidden) fillList();
  }
  function fillList() {
    const p = cur(); if (!p) return;
    list.replaceChildren(...p.comments.map(c => {
      const row = U.el('div', { class: 'crow' + (c.detached ? ' gone' : '') },
        U.el('div', { class: 'cq' }, '“' + (c.quote.length > 90 ? c.quote.slice(0, 90) + '…' : c.quote) + '”' + (c.detached ? ' (text changed)' : '')),
        U.el('div', {}, c.text));
      const x = U.el('button', { class: 'cx danger', title: 'Delete' }, '✕');
      x.addEventListener('click', e => { e.stopPropagation(); p.comments = p.comments.filter(y => y !== c); save(p); });
      row.append(x);
      row.addEventListener('click', () => { const mk = document.querySelector('mark.cmt[data-id="' + c.id + '"]'); if (mk) { mk.scrollIntoView({ block: 'center', behavior: 'smooth' }); mk.classList.add('pulse'); setTimeout(() => mk.classList.remove('pulse'), 1500); } });
      return row;
    }));
  }

  return { highlight, bar };
})();
