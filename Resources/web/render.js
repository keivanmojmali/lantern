// Markdown -> blocks -> DOM (highlighting, mermaid, refs, tasks, frontmatter).
const R = (() => {
  marked.setOptions({ gfm: true, breaks: false });
  const EXT = 'ts|tsx|js|jsx|mjs|cjs|py|swift|go|rs|rb|java|kt|c|cc|cpp|h|hpp|m|mm|vue|svelte|css|scss|html|json|yml|yaml|toml|sh|zsh|md|sql|php|lua|ex|exs';
  const REF = new RegExp('(^|[\\s(\\[`"\'])((?:[\\w.@~-]+/)*[\\w.@-]+\\.(?:' + EXT + ')):(\\d+)(?:-(\\d+))?', 'g');

  function frontmatter(md) {
    const m = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(md);
    if (!m) return { meta: null, body: md };
    const meta = [];
    for (const l of m[1].split(/\r?\n/)) {
      const k = /^([A-Za-z0-9_ .-]+):\s*(.*)$/.exec(l);
      if (k && !/^\s/.test(l)) meta.push([k[1].trim(), k[2].trim().replace(/^\[|\]$/g, '')]);
      else if (meta.length && l.trim()) { const last = meta[meta.length - 1]; last[1] += (last[1] ? ', ' : '') + l.trim().replace(/^-\s*/, ''); }
    }
    return { meta, body: md.slice(m[0].length) };
  }

  function parse(content) {
    const { meta, body } = frontmatter(content);
    const toks = marked.lexer(body);
    const blocks = [];
    for (const t of toks) {
      if (t.type === 'space') continue;
      const arr = [t]; arr.links = toks.links;
      let html;
      try { html = DOMPurify.sanitize(marked.parser(arr)); } catch (e) { html = '<pre>' + U.esc(t.raw) + '</pre>'; }
      blocks.push({ raw: t.raw.trimEnd(), html, type: t.type });
    }
    const tasks = { done: 0, total: 0 };
    for (const m of body.matchAll(/^\s*[-*+]\s+\[( |x|X)\]/gm)) { tasks.total++; if (m[1] !== ' ') tasks.done++; }
    const words = (body.match(/\S+/g) || []).length;
    return { meta, blocks, tasks, words };
  }

  // indices of blocks in `next` that were not present in `prev` (multiset compare)
  function changed(prevRaws, nextRaws) {
    const bag = new Map(); for (const r of prevRaws) bag.set(r, (bag.get(r) || 0) + 1);
    const out = new Set();
    nextRaws.forEach((r, i) => { const c = bag.get(r) || 0; if (c > 0) bag.set(r, c - 1); else out.add(i); });
    return out;
  }

  const svgCache = new Map(); let mmCount = 0, mmP;
  const dark = () => document.documentElement.dataset.theme === 'dark';
  function loadMermaid() {
    return mmP ||= new Promise((res, rej) => {
      const s = document.createElement('script'); s.src = 'vendor/mermaid.min.js';
      s.onload = () => res(window.mermaid); s.onerror = rej; document.head.append(s);
    });
  }
  async function renderMermaid(root) {
    const nodes = [...root.querySelectorAll('.mermaid-wrap:not(.done)')];
    if (!nodes.length) return;
    const m = await loadMermaid();
    const css = getComputedStyle(document.documentElement);
    m.initialize({ startOnLoad: false, securityLevel: 'strict', theme: dark() ? 'dark' : 'neutral', fontFamily: 'Inter, -apple-system, sans-serif' });
    for (const n of nodes) {
      const src = n.dataset.src, key = (dark() ? 'd' : 'l') + src;
      try {
        if (!svgCache.has(key)) { const id = 'mm' + (++mmCount); const { svg } = await m.render(id, src); svgCache.set(key, svg); document.getElementById('d' + id)?.remove(); }
        n.innerHTML = svgCache.get(key); n.classList.add('done');
      } catch (e) {
        document.querySelectorAll('[id^=dmm]').forEach(x => x.remove());
        n.innerHTML = '<div class="mm-err"><b>Mermaid error</b><pre>' + U.esc(String(e.message || e)) + '</pre></div>'; n.classList.add('done');
      }
    }
  }

  function frontCard(meta) {
    const card = U.el('div', { class: 'front' });
    for (const [k, v] of meta) card.append(U.el('div', { class: 'fk' }, k), U.el('div', { class: 'fv' }, v || '—'));
    return card;
  }

  function postProcess(root, plan) {
    const dir = U.dirname(plan.path);
    root.querySelectorAll('img').forEach(img => {
      const s = img.getAttribute('src') || '';
      if (/^(https?:|data:|lantern-asset:)/.test(s)) return;
      const abs = s.startsWith('/') ? s : dir + '/' + s;
      img.src = 'lantern-asset://f/' + encodeURIComponent(abs).replace(/%2F/g, '/');
    });
    root.querySelectorAll('pre').forEach(pre => {
      const code = pre.querySelector('code'); if (!code) return;
      const lang = ((code.className.match(/language-([\w+-]+)/) || [])[1] || '').toLowerCase();
      const text = code.textContent;
      if (lang === 'mermaid') {
        const w = U.el('div', { class: 'mermaid-wrap', 'data-src': text }, U.el('div', { class: 'mm-loading' }, 'Rendering diagram…'));
        const key = (dark() ? 'd' : 'l') + text;
        if (svgCache.has(key)) { w.innerHTML = svgCache.get(key); w.classList.add('done'); }
        pre.replaceWith(w); return;
      }
      let html = U.esc(text);
      try { if (lang && hljs.getLanguage(lang)) html = hljs.highlight(text, { language: lang }).value; } catch (e) {}
      code.innerHTML = html; code.classList.add('hljs');
      const btn = U.el('button', { class: 'copy', title: 'Copy code' }, 'Copy');
      btn.addEventListener('click', () => { U.post({ t: 'copy', text }); btn.textContent = 'Copied'; setTimeout(() => btn.textContent = 'Copy', 1200); });
      const wrap = U.el('div', { class: 'code' }, U.el('div', { class: 'codehead' }, U.el('span', { class: 'lang' }, lang || 'text'), btn));
      pre.replaceWith(wrap); wrap.append(pre);
    });
    root.querySelectorAll('table').forEach(t => { const w = U.el('div', { class: 'tablewrap' }); t.replaceWith(w); w.append(t); });
    root.querySelectorAll('li').forEach(li => { if (li.querySelector(':scope > input[type=checkbox], :scope > p > input[type=checkbox]')) li.classList.add('task'); });
    root.querySelectorAll('input[type=checkbox]').forEach(c => c.disabled = true);
    // clickable file.ts:123 references
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: n => n.parentElement.closest('a, .codehead, .ref, .mermaid-wrap, .front') || (n.parentElement.closest('pre')) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT });
    const nodes = []; while (walker.nextNode()) nodes.push(walker.currentNode);
    for (const n of nodes) {
      const txt = n.nodeValue; REF.lastIndex = 0;
      if (!REF.test(txt)) continue;
      REF.lastIndex = 0;
      const frag = document.createDocumentFragment(); let last = 0, m;
      while ((m = REF.exec(txt))) {
        const start = m.index + m[1].length;
        frag.append(txt.slice(last, start));
        const ref = m[2] + ':' + m[3] + (m[4] ? '-' + m[4] : '');
        frag.append(U.el('span', { class: 'ref', 'data-ref': ref, title: 'Open in editor' }, ref));
        last = start + ref.length;
      }
      frag.append(txt.slice(last)); n.replaceWith(frag);
    }
  }

  function mount(root, parsed, plan, glow) {
    root.innerHTML = '';
    if (parsed.meta && parsed.meta.length) root.append(frontCard(parsed.meta));
    let section = '';
    parsed.blocks.forEach((b, i) => {
      const d = U.el('div', { class: 'blk b-' + b.type, 'data-i': i });
      d.innerHTML = b.html;
      if (b.type === 'heading') { section = d.textContent.trim(); d.classList.add('hd'); }
      d.dataset.sec = section;
      if (glow && glow.has(i)) d.classList.add('glow');
      root.append(d);
    });
    postProcess(root, plan);
    renderMermaid(root);
  }

  return { parse, mount, changed, renderMermaid, svgCache };
})();
