  // ---------- strand labels ----------
  // An HTML layer over the stage. The selection is always labelled. With Best effort, the highlighted strands get
  // labels as room allows: terminals, then cell junctions, then branch points, then pass-through members, nearer the
  // selection first, then by id. Placement is greedy in screen space and depends only on the camera.
  const SL_CAP = 40, SL_H = 16, SL_CH = 6.62, SL_PAD = 10, SL_GROUP_PX = 44, SL_NEAR_PX = 160;
  let slEl = null, slCands = [], slPlacedList = [], slDirty = true, slLast = 0, slTimer = null, slStat = { shown: 0, hidden: 0 };
  const slHost = () => { if (!slEl) { slEl = document.createElement('div'); slEl.className = 'slabels'; const lab = $('labels'); if (lab.after) lab.after(slEl); } return slEl; };
  const midTrunc = (s, n) => { if (s.length <= n) return s; const k = Math.floor((n - 1) / 2); return s.slice(0, n - 1 - k) + '…' + s.slice(s.length - k); };
  const shortBoundary = s => { const t = String(s || '').replace(/\s*\[library\]$/, ''), w = t.split(' ').pop(); return w.split('/').pop(); };
  function slSelText(w) {
    const ml = m => `${M.nodes[M.mem.n[m]].n}.${M.mem.name[m]}`;
    if (w.v != null) return ml(w.m) + ' › ' + M.vars.name[w.v];
    if (w.s != null) return w.m != null && w.m >= 0 ? ml(w.m) : M.nodes[w.n].n;
    if (w.t != null) return pointLabel(M.br.trees[w.t], w.point);
    if (w.m != null && w.m >= 0) return ml(w.m);
    if (w.ci != null) return 'cell ' + (M.cells[w.ci] ? M.cells[w.ci].n : '?');
    return w.n != null ? M.nodes[w.n].n : '?';
  }
  function slSelections() {
    const s = S.sel; if (!s) return [];
    let w = whatOf(s);
    if (!w && s.kind === 'chain') w = { t: s.tree, point: s.point };
    if (!w && s.kind === 'root') w = { t: s.tree, point: M.br.trees[s.tree].rootPt };
    return [w, S.sel2].filter(Boolean);
  }
  // World anchors for every label the current selection could get; rebuilt with the strands.
  function slBuild() {
    const out = [], byId = new Map();
    slSelections().forEach((w, i) => { const q = whatAnchor(w); if (q) out.push({ id: 'sel' + i, q, prio: 0, depth: 0, node: whatNode(w), text: slSelText(w), what: w }); });
    const P = V.pick;
    if (P && P.R.core.length) {
      const G = P.G, depth = new Map();
      let fr = [...touchSet(M, G, P.what)].filter(k => P.roles.has(k)).sort();
      for (const k of fr) depth.set(k, 0);
      while (fr.length) {
        const nx = [];
        for (const k of fr) for (const j of [...(G.next.get(k) || []), ...(G.prev.get(k) || [])]) if (P.roles.has(j) && !depth.has(j)) { depth.set(j, depth.get(k) + 1); nx.push(j); }
        fr = nx.sort();
      }
      const D = k => (depth.has(k) ? depth.get(k) : 1e6);
      const add = (q, prio, d, node, extra) => {
        if (!q || (node >= 0 && (inactiveNodes.has(node) || !V.shown(M.nodes[node])))) return;
        const id = [q.x, q.y, q.z].map(x => x.toFixed(1)).join(',');
        const o = byId.get(id);
        if (o && (o.prio < prio || (o.prio === prio && o.depth <= d))) return;
        byId.set(id, Object.assign({ id, q, prio, depth: d, node }, extra));
      };
      const TAG = { boundary: 'boundary', cellWrite: 'cell', cellRead: 'cell', ui: 'UI', entry: 'entry' };
      for (const key of [...P.roles.keys()].sort()) {
        const { t, s } = G.segs.get(key), T = M.br.trees[t], g = T.segs[s], d = D(key);
        for (const p of [g.a, g.b]) {
          const node = T.pt.node[p], m = T.pt.m[p], q = ptAnchor(T, p);
          if (p === T.rootPt) {
            if (T.kind === 'boundary') add(q, 1, d, node, { tag: 'boundary', text: shortBoundary(T.label), m });
            else if (T.kind === 'cell') add(q, 1, d, node, { tag: 'cell', text: cellName(T.ref), ci: T.ref, m });
            continue;
          }
          const term = T.pt.kind[p] === 'terminal' ? termOf(T, p) : null;
          if (term && TAG[term.kind]) {
            const text = term.kind === 'boundary' ? shortBoundary(refLabel('boundary', term.ref)) : TAG[term.kind] === 'cell' ? cellName(term.ref) : term.kind === 'ui' ? memLabel(term.ref) : refLabel(term.kind, term.ref);
            add(q, 1, d, node, { tag: TAG[term.kind], text, m: term.kind === 'ui' ? term.ref : m, ci: TAG[term.kind] === 'cell' ? term.ref : null });
          } else if (['branch', 'merge', 'split', 'join'].includes(T.pt.kind[p]) && m >= 0) add(q, 3, d, node, { m, text: memLabel(m), name: M.mem.name[m] });
        }
        for (const m of g.members) if (m >= 0) add(memberAnchor(m), 4, d, M.mem.n[m], { m, text: memLabel(m), name: M.mem.name[m] });
      }
      for (const J of G.junctions) {
        const drawn = J.links.filter(j => P.roles.has(j.a) && P.roles.has(j.b)); if (!drawn.length) continue;
        const fit = drawn.some(j => j.compat === 'match') ? '' : ' · unknown fit', any = M.br.cellAny.has(J.cell) ? ' · any instance' : '';
        const d = Math.min(...drawn.map(j => D(j.b)));
        for (const at of J.at) { const T = M.br.trees[at.t]; add(ptAnchor(T, at.point), 2, d, T.pt.node[at.point], { tag: 'cell', text: cellName(J.cell) + fit + any, ci: J.cell }); }
      }
    }
    slCands = out.concat([...byId.values()]);
    slDirty = true;
  }
  const slCmp = (a, b) => a.prio - b.prio || a.depth - b.depth || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
  // Full placement for the current camera.
  function slPlace() {
    const host = slHost(), mode = S.strandLabels || 'best';
    const w = stage.clientWidth || 1, h = stage.clientHeight || 1, cam = camera(), v = new THREE.Vector3();
    const proj = q => { v.copy(q).project(cam); return [(v.x + 1) / 2 * w, (1 - v.y) / 2 * h, v.z]; };
    const items = mode === 'off' ? [] : slCands.filter(c => mode === 'best' || c.prio === 0).map(c => { const [x, y, z] = proj(c.q); return Object.assign({}, c, { x, y, vis: z >= -1 && z <= 1 && x >= 0 && x <= w && y >= 0 && y <= h }); });
    const sels = items.filter(c => c.prio === 0), rest = items.filter(c => c.prio > 0 && c.vis).sort(slCmp);
    // Branch points and pass-through members of one class sitting close together share one label.
    const groups = [];
    for (const c of rest) {
      const g = c.prio >= 3 && c.node >= 0 ? groups.find(g => g.prio >= 3 && g.node === c.node && Math.hypot(g.x - c.x, g.y - c.y) < SL_GROUP_PX) : null;
      if (g) g.items.push(c); else groups.push(Object.assign({}, c, { items: [c] }));
    }
    const placed = [], marks = [];
    for (const s of sels) if (s.vis) marks.push([s.x - 11, s.y - 11, s.x + 11, s.y + 11]);
    const over = (r, q) => r[0] < q[2] && q[0] < r[2] && r[1] < q[3] && q[1] < r[3];
    const free = r => r[0] >= 0 && r[1] >= 0 && r[2] <= w && r[3] <= h && !placed.some(p => over(r, p.r)) && !marks.some(q => over(r, q));
    const spot = (x, y, wd, dists) => {
      for (const dist of dists) for (const [dx, dy] of [[1, 0], [-1, 0], [0, -1], [0, 1]]) {
        const x0 = dx > 0 ? x + dist : dx < 0 ? x - dist - wd : x - wd / 2, y0 = dy < 0 ? y - dist - SL_H : dy > 0 ? y + dist : y - SL_H / 2;
        const r = [x0, y0, x0 + wd, y0 + SL_H]; if (free(r)) return { r, lead: dist > 9 };
      }
      return null;
    };
    const put = (c, text, tip, cls, at) => placed.push({ id: c.id, c, text, tip, cls, r: at.r, lead: at.lead, dx: at.r[0] - c.x, dy: at.r[1] - c.y, prio: c.prio, items: c.items || [c] });
    for (const s of sels) {
      const x = Math.min(Math.max(s.x, 4), w - 4), y = Math.min(Math.max(s.y, 4), h - 4), text = midTrunc(s.text, 48), wd = text.length * SL_CH + SL_PAD;
      let at = spot(x, y, wd, [9, 26, 46, 70, 100, 140]);
      for (let k = 0; !at && k < 200; k++) { const r = [4, 4 + k * (SL_H + 2), 4 + wd, 4 + k * (SL_H + 2) + SL_H]; if (free(r)) at = { r, lead: true }; }
      if (!at) at = { r: [4, 4, 4 + wd, 4 + SL_H], lead: true };
      put(Object.assign({}, s, { x, y }), text, s.text + (s.vis ? '' : ' (off screen)'), 'sel', at);
    }
    let hidden = 0;
    for (const g of groups) {
      if (placed.length >= SL_CAP) { hidden += g.items.length; continue; }
      let text, tip, cls = 'k' + g.prio;
      const names = [...new Set(g.items.map(c => c.name || c.text))];
      if (g.items.length > 1 && names.length > 1) {
        const cn = M.nodes[g.node].n;
        text = midTrunc(cn, 22) + ': ' + names.slice(0, 2).map(n => midTrunc(n, 14)).join(', ') + (names.length > 2 ? ', +' + (names.length - 2) : '');
        tip = cn + ': ' + names.join(', '); cls += ' grp';
      } else {
        const near = g.name && placed.some(p => p.c.node === g.node && Math.hypot(p.c.x - g.x, p.c.y - g.y) < SL_NEAR_PX);
        const body = near ? g.name : g.text;
        text = (g.tag ? g.tag + ' ' : '') + midTrunc(body, 30); tip = (g.tag ? g.tag + ' ' : '') + g.text;
      }
      const at = spot(g.x, g.y, text.length * SL_CH + SL_PAD, [9, 26, 46]);
      if (at) put(g, text, tip, cls, at); else hidden += g.items.length;
    }
    slPlacedList = placed;
    slStat = { shown: placed.reduce((a, p) => a + p.items.length, 0), hidden, mode };
    slRender(host);
    const st = document.getElementById('slabel-stat');
    if (st) st.textContent = slStatText();
  }
  const slStatText = () => (slStat.mode === 'off' ? 'Strand labels are off (Settings).' : `Strand labels: ${slStat.shown} shown${slStat.hidden ? `, ${slStat.hidden} hidden for room or the ${SL_CAP}-label cap` : ''}.`);
  function slRender(host) {
    const lead = slPlacedList.filter(p => p.lead).map(p => { const r = p.r, cx = Math.min(Math.max(p.c.x, r[0]), r[2]), cy = Math.min(Math.max(p.c.y, r[1]), r[3]); return `<line x1="${p.c.x.toFixed(1)}" y1="${p.c.y.toFixed(1)}" x2="${cx.toFixed(1)}" y2="${cy.toFixed(1)}"/>`; }).join('');
    host.innerHTML = `<svg aria-hidden="true">${lead}</svg>` + slPlacedList.map((p, i) => `<div class="slbl ${p.cls}" data-sl="${i}" title="${esc(p.tip)}" style="left:${p.r[0].toFixed(1)}px;top:${p.r[1].toFixed(1)}px;width:${(p.r[2] - p.r[0]).toFixed(1)}px">${esc(p.text)}</div>`).join('');
    host.onclick = e => {
      const el = e.target.closest('[data-sl]'); if (!el) return;
      if (e.stopPropagation) e.stopPropagation();
      const p = slPlacedList[+el.dataset.sl]; if (!p) return;
      slClick(p);
    };
  }
  function slClick(p) {
    const c = p.c;
    if (c.prio === 0) { if (S.pane !== 'details') setPane('details'); return; }
    S.selHist.push({ sel: S.sel, sel2: S.sel2 });
    if (p.items.length > 1) { setSel({ kind: 'node', n: c.node, group: [...new Set(p.items.map(x => x.m).filter(m => m >= 0))] }); return; }
    if (c.ci != null && c.ci >= 0) setSel({ kind: 'cell', ci: c.ci, m: cellMember(c.ci) });
    else if (c.m != null && c.m >= 0) setSel(M.mem.kind[c.m] === 'cell' && M.mem.cell[c.m] >= 0 ? { kind: 'cell', ci: M.mem.cell[c.m], m: c.m } : { kind: 'member', m: c.m });
    else if (c.node >= 0) setSel({ kind: 'node', n: c.node });
  }
  // Between full placements, labels follow their anchors at the chosen offsets.
  function slFollow() {
    if (!slEl || !slPlacedList.length) return;
    const w = stage.clientWidth || 1, h = stage.clientHeight || 1, cam = camera(), v = new THREE.Vector3();
    const els = slEl.querySelectorAll ? slEl.querySelectorAll('[data-sl]') : [];
    slPlacedList.forEach((p, i) => {
      v.copy(p.c.q).project(cam); const x = (v.x + 1) / 2 * w, y = (1 - v.y) / 2 * h;
      p.c.x = x; p.c.y = y; p.r = [x + p.dx, y + p.dy, x + p.dx + (p.r[2] - p.r[0]), y + p.dy + SL_H];
      if (els[i]) { els[i].style.left = p.r[0].toFixed(1) + 'px'; els[i].style.top = p.r[1].toFixed(1) + 'px'; }
    });
    const svg = slEl.querySelector ? slEl.querySelector('svg') : null; if (svg) svg.innerHTML = '';
  }
  function slFrame() {
    const now = typeof performance !== 'undefined' ? performance.now() : Date.now(), timers = typeof setTimeout === 'function';
    if (timers) clearTimeout(slTimer);
    if (slDirty || !timers || now - slLast > 120) { slDirty = false; slLast = now; slPlace(); return; }
    slFollow();
    slTimer = setTimeout(() => { slLast = performance.now(); slPlace(); hideCollidingLabels(); }, 130);
  }
