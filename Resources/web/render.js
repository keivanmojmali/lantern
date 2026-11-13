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

  // [^id] footnotes: pull definitions out of the body, number the references, append a list at the end
  function footnotes(body) {
    const defs = new Map();
    let text = body.replace(/^\[\^([^\]\s]+)\]:[ \t]*(.*(?:\n(?:[ \t]+.*))*)$/gm, (_, id, t) => { defs.set(id, t.replace(/\n\s+/g, ' ').trim()); return ''; });
    if (!defs.size) return body;
    const order = [];
    text = text.split(/(^```[\s\S]*?^```)/m).map((part, i) => i % 2 ? part : part.replace(/\[\^([^\]\s]+)\]/g, (m, id) => {
      if (!defs.has(id)) return m;
      let n = order.indexOf(id) + 1; if (!n) n = order.push(id);
      return '<sup class="fn" id="fnref-' + id + '">' + n + '</sup>';
    })).join('');
    if (!order.length) return text;
    return text.trimEnd() + '\n\n---\n\n<ol class="footnotes">\n' + order.map(id => '<li>' + marked.parseInline(defs.get(id)) + '</li>').join('\n') + '\n</ol>\n';
  }

  function parse(content) {
    const { meta, body: rawBody } = frontmatter(content);
    const body = footnotes(rawBody);
    const toks = marked.lexer(body);
    const blocks = [];
    const render = t => { const arr = [t]; arr.links = toks.links; return marked.parser(arr); };
    for (let i = 0; i < toks.length; i++) {
      const t = toks[i];
      if (t.type === 'space') continue;
      let raw = t.raw, html;
      try {
        const ask = t.type === 'code' && /^answer\s+(\S+)/.exec(t.lang || '');
        html = ask ? '<div class="ask" data-id="' + U.esc(ask[1]) + '"><div class="ask-q">' + marked.parse(t.text) + '</div></div>' : render(t);
        // <details> is split by blank lines into several tokens: glue them back into one block
        if (t.type === 'html' && /^\s*<details[\s>]/i.test(t.raw) && !/<\/details>/i.test(t.raw)) {
          let j = i + 1, parts = [html], raws = [t.raw], closed = false;
          for (; j < toks.length; j++) {
            if (toks[j].type !== 'space') { parts.push(render(toks[j])); }
            raws.push(toks[j].raw);
            if (toks[j].type === 'html' && /<\/details>/i.test(toks[j].raw)) { closed = true; break; }
          }
          if (closed) { html = parts.join(''); raw = raws.join(''); i = j; }
        }
        html = DOMPurify.sanitize(html);
      } catch (e) { html = '<pre>' + U.esc(t.raw) + '</pre>'; }
      blocks.push({ raw: raw.trimEnd(), html, type: t.type });
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
    m.initialize({ startOnLoad: false, securityLevel: 'strict', theme: 'base', fontFamily: 'Inter, -apple-system, sans-serif', themeVariables: dark()
        ? { darkMode: true, background: '#222', primaryColor: '#4a2f25', primaryBorderColor: '#ff8356', primaryTextColor: '#ebe8e4', secondaryColor: '#24413f', tertiaryColor: '#2a2a2a', lineColor: '#8f8f8f', textColor: '#ebe8e4', pie1: '#ff8356', pie2: '#b6dedb', pie3: '#f7f780', pie4: '#8f8f8f', pie5: '#c4684a', pie6: '#6fa8a3' }
        : { primaryColor: '#ffe6dc', primaryBorderColor: '#ff8356', primaryTextColor: '#2D3748', secondaryColor: '#dff0ee', tertiaryColor: '#f7f4ef', lineColor: '#7a8394', textColor: '#2D3748', pie1: '#ff8356', pie2: '#b6dedb', pie3: '#f7f780', pie4: '#7a8394', pie5: '#ffb89d', pie6: '#6fa8a3' } });
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
      img.addEventListener('error', () => img.replaceWith(U.el('span', { class: 'imgerr' }, '🖼 ' + (img.alt || 'image not found'))), { once: true });
      const s = img.getAttribute('src') || '';
      if (/^(https?:|data:|lantern-asset:)/.test(s)) return;
      const abs = s.startsWith('/') ? s : dir + '/' + s;
      img.src = 'lantern-asset://f/' + encodeURIComponent(abs).replace(/%2F/g, '/');
    });
    root.querySelectorAll('.ask').forEach(a => {
      const id = a.dataset.id, st = (plan.answers ||= {})[id] ||= { text: '', sent: false };
      const ta = U.el('textarea', { class: 'ask-ta', 'data-id': id, rows: 3, placeholder: 'Type your answer…' });
      ta.value = st.text;
      const btn = U.el('button', { class: 'ask-send' });
      const note = U.el('span', { class: 'ask-note' });
      const paint = () => {
        btn.textContent = st.sent ? 'Sent ✓' : 'Send'; btn.classList.toggle('done', st.sent);
        note.textContent = st.sent ? '' : st.text ? 'Draft: Claude sees it after you press Send (⌘↩)' : '';
        ta.rows = Math.max(3, Math.min(14, ta.value.split('\n').length + 1));
      };
      const save = () => U.post({ t: 'answer', path: plan.path, id, text: st.text, sent: st.sent });
      let timer;
      ta.addEventListener('input', () => { st.text = ta.value; st.sent = false; paint(); clearTimeout(timer); timer = setTimeout(save, 300); });
      const send = () => { clearTimeout(timer); st.text = ta.value; st.sent = st.text.trim() !== ''; paint(); save(); };
      btn.addEventListener('click', send);
      ta.addEventListener('keydown', e => { if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); send(); } });
      paint();
      a.append(ta, U.el('div', { class: 'ask-row' }, note, btn));
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
    if (typeof C !== "undefined") C.highlight(root, plan.comments || []);
    renderMermaid(root);
  }

  return { parse, mount, changed, renderMermaid, svgCache };
})();
