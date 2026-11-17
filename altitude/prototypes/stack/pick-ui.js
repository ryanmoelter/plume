  // What a click lands on: a marker, then a member, then a class.
  function targetOf(e) {
    const mk = markerAt(e);
    if (mk) {
      if (mk.kind === 'mismatch' || mk.kind === 'x') return { mk };
      if (mk.kind === 'junction') return { mk, what: { ci: mk.ci, m: cellMember(mk.ci) } };
      return { mk, what: { t: mk.T.i, point: mk.point } };
    }
    const mm = memberAt(e);
    if (mm >= 0) return { mm, what: M.mem.kind[mm] === 'cell' && M.mem.cell[mm] >= 0 ? { ci: M.mem.cell[mm], m: mm } : { m: mm } };
    const ln = lineAt(e);
    if (ln && ln.kind !== 'conn') return { ln };
    const n = pick(e);
    return n ? { n, what: { n: n.i } } : null;
  }
  const selOf = w => (w.ci != null ? { kind: 'cell', ci: w.ci, m: w.m } : w.m != null ? { kind: 'member', m: w.m } : { kind: 'node', n: w.n });
  // A single click selects: a member, cell or class shows the strands through it; a second click on those strands
  // joins the two points. It only highlights. Esc steps back one selection.
  function handleClick(e) {
    const tg = targetOf(e);
    if (!tg) { clearSelection(); return; }
    if (tg.ln) { clickLine(tg.ln, e); return; }
    const tipHtml = tg.mk ? (tg.mk.kind === 'x' ? null : markerTip(tg.mk)) : tg.mm != null ? describeMember(tg.mm) : null;
    if (tg.mk && tg.mk.kind === 'mismatch') { setSel({ kind: 'trace', trace: S.trace }); showTip(null, e, tipHtml); return; }
    if (tg.mk && tg.mk.kind === 'x') return;
    if (V.pick && !sameWhat(tg.what, V.pick.what) && onPick(tg.what)) {
      S.selHist.push({ sel: S.sel, sel2: S.sel2 }); S.sel2 = occurrenceAt(tg.what, e);
      if (S.pane !== 'details') setPane('details');
      applyHighlight(); showTip(tg.n || null, e, tipHtml); return;
    }
    if (tg.mk) { chooseEndpoint(tg.mk.T, tg.mk.point); showTip(null, e, tipHtml); return; }
    S.selHist.push({ sel: S.sel, sel2: S.sel2 });
    setSel(selOf(tg.what));
    showTip(tg.n || null, e, tipHtml);
  }
  // A member or class that a strand visits more than once is chosen as the one occurrence nearest the pointer: the
  // drawn segment through it that passes closest on screen, ties going to the earlier segment in key order.
  function occurrenceAt(w, e) {
    if (w.t != null || w.ci != null) return w;
    const P = V.pick, r = renderer.domElement.getBoundingClientRect(), x = e.clientX - r.left, y = e.clientY - r.top;
    const near = (a, z) => { const [ax, ay] = toScreen(a), [zx, zy] = toScreen(z), dx = zx - ax, dy = zy - ay, l2 = dx * dx + dy * dy, f = l2 ? Math.max(0, Math.min(1, ((x - ax) * dx + (y - ay) * dy) / l2)) : 0; return Math.hypot(x - ax - f * dx, y - ay - f * dy); };
    let best = null, bd = Infinity;
    for (const k of [...touchSet(M, P.G, w)].sort()) {
      if (!P.roles.has(k)) continue;
      const { t, s } = P.G.segs.get(k), T = M.br.trees[t], an = segAnchors(T, T.segs[s]);
      let d = Infinity; for (let i = 0; i + 1 < an.length; i++) d = Math.min(d, near(an[i], an[i + 1]));
      if (d < bd) { bd = d; best = { t, s, m: w.m != null ? w.m : -1, n: w.n } ; }
    }
    if (!best) return w;
    if (best.n == null) delete best.n;
    return best;
  }
  function handleDouble(e) {
    if (V.pick && V.pick.R.core.length) { focusPick(); return; }
    const mk = markerAt(e);
    if (mk && mk.kind !== 'mismatch') { focusOn(S.endpoint >= 0 ? 'strand' : 'tree'); return; }
    const mm = memberAt(e), pn = mm >= 0 ? null : pick(e);
    const ni = mm >= 0 ? M.mem.n[mm] : pn ? pn.i : -1;
    if (ni < 0) return;
    if (V.T) { focusOn(V.treeNodes.has(ni) && S.endpoint >= 0 ? 'strand' : 'tree'); return; }
    const chain = M.nodes[ni].ancBy[V.tk], home = chain[chain.length - 1];
    if (home) toggleIso(home.key, e.shiftKey);
  }
  // Re-packs the view around the classes of the strong strands: every route through the selection, or with a second
  // point the routes joining the two.
  function focusPick() {
    const P = V.pick; if (!P || !P.R.core.length) return;
    S.history.push({ focus: S.focus, root: S.root, endpoint: S.endpoint });
    S.focus = { kind: 'pick', nodes: P.strongNodes.slice(), root: -1 };
    view.fitted = ''; rebuild();
  }
  function stepBackSelection() {
    const h = S.selHist.pop();
    if (!h) { setSel(null, false); return; }
    setSel(h.sel, false); S.sel2 = h.sel2; applyHighlight();
  }

  // Details for a selection's strands
  const cellName = ci => { const c = M.cells[ci]; return c ? c.n + (c.h ? ' (' + c.h + ')' : '') : '?'; };
  const endText = e => (e.kind === 'cell' ? 'cell ' + cellName(e.ref) : e.label ? `${e.kind} ${e.label}` : `${e.kind} ${refLabel(e.kind, e.ref)}`);
  const routeHtml = parts => `<div class="route">${parts.map(p => (typeof p === 'number' ? `<button class="lnk" data-cell="${p}">cell ${esc(cellName(p))}</button>` : `<span>${esc(p)}</span>`)).join('<span class="sub"> → </span>')}</div>`;
  // Routes to the far ends of one side, for reading only: boundaries first, then the longest, then by rank. Cells in
  // data-flow order. ids are the chains the route is made of, so hovering a segment can find its rows.
  function pickRoutes(P, side) {
    const list = side === 'up' ? P.R.up : P.R.down, byId = new Map(list.map(e => [e.c.id, e])), parents = new Set(list.map(e => e.parent));
    const endOf = e => (side === 'up' ? chainEnds(M, e.c).src : chainEnds(M, e.c).dst);
    return list.filter(e => !parents.has(e.c.id))
      .sort((a, b) => (endOf(a).kind !== 'boundary') - (endOf(b).kind !== 'boundary') || b.depth - a.depth || chainRank(a.c, b.c))
      .map(e => {
        const cells = [], ids = []; let core = null;
        for (let cur = e; cur; cur = byId.get(cur.parent)) { cells.push(cur.cell); ids.push(cur.c.id); core = cur.parent; }
        return { end: endOf(e), cells: side === 'up' ? cells : cells.reverse(), ids: [core, ...ids] };
      });
  }
  const routeRow = (parts, ids) => routeHtml(parts).replace('<div class="route">', `<div class="route" data-chains="${ids.join(',')}">`);
  function pickBoundaries(P) {
    const out = new Set();
    for (const e of P.G.entries) { const { src, dst } = chainEnds(M, e.c); if (src.kind === 'boundary' && e.role !== 'down' && P.dir !== 'down') out.add(endText(src)); if (dst.kind === 'boundary' && e.role !== 'up' && P.dir !== 'up') out.add(endText(dst)); }
    return [...out].sort();
  }
  function pickSection(P, sel) {
    const R = P.R, m = P.what.m;
    const connBtn = m != null && m >= 0 ? `<button class="btn" data-conn="${m}">Possible connections</button>` : '';
    if (!R.core.length) return sec('Strands', `<p>No exported route covers this selection; showing ${m != null && m >= 0 ? 'possible connections' : 'its edges'}.</p>${connBtn ? `<div class="row">${connBtn}</div>` : ''}`);
    const pl = (n, w) => `${n} ${w}${n === 1 ? '' : 's'}`, dir = P.dir, c = P.count;
    const seg = (attr, opts, cur) => `<div class="segd" role="group">${opts.map(([v, l]) => `<button class="btn${v === cur ? ' on' : ''}" ${attr}="${v}" aria-pressed="${v === cur}">${l}</button>`).join('')}</div>`;
    const controls = `<div class="pctl"><span class="sub">Direction</span>${seg('data-pdir', [['up', 'Upstream'], ['down', 'Downstream'], ['both', 'Both']], dir)}</div>`;
    // The count line: what is drawn, of how many, and what the other direction holds.
    const of = (a, b) => (a < b ? `${a} of ${b}` : String(a));
    const parts = [`${of(c.through, c.totalThrough)} through this`];
    if (dir !== 'down') parts.push(`${of(c.up, c.totalUp)} upstream`);
    if (dir !== 'up') parts.push(`${of(c.down, c.totalDown)} downstream`);
    const hid = P.hidden && P.hidden.n ? `<p class="sub">${pl(P.hidden.n, P.hidden.side + ' route')} hidden · <button class="lnk" style="display:inline" data-pdir="both">show</button></p>` : '';
    const capped = c.through < c.totalThrough || (dir !== 'down' && c.up < c.totalUp) || (dir !== 'up' && c.down < c.totalDown);
    const up = dir !== 'down' ? pickRoutes(P, 'up') : [], down = dir !== 'up' ? pickRoutes(P, 'down') : [], bounds = pickBoundaries(P);
    const limits = side => {
      const E = sideEnds(M, R, side), rej = R.rejected[side].length, out = [], far = side === 'up' ? 'origin' : 'reader';
      if (E.stopped) out.push(`${pl(E.stopped, 'route')} stopped at ${STITCH_STEPS} cell steps; more stitches lie beyond.`);
      if (E.capped) out.push((side === "up" ? R.up.length < R.total.up : R.down.length < R.total.down) ? `${pl(E.capped, "route")} not followed further: at most ${STITCH_CAP[side]} ${side === "up" ? "upstream" : "downstream"} chains are drawn.` : `${pl(E.capped, "route")} stop at a cell already followed from another route.`);
      if (E.unwritten) out.push(`${pl(E.unwritten, 'route')} end at a cell with no exported ${side === 'up' ? 'writer' : 'reader'}: no ${far} found.`);
      if (E.rejoin) out.push(`${pl(E.rejoin, 'route')} rejoin a route already drawn.`);
      if (rej) out.push(`${pl(rej, 'rejected candidate')} at cells marked mismatch.`);
      return out.length ? `<p class="sub">${side === 'up' ? 'Upstream' : 'Downstream'}: ${out.join(' ')}</p>` : '';
    };
    const ends = side => [...new Map(R.coreDrawn.map(x => { const e = chainEnds(M, x)[side]; return [endText(e), [e, x.id]]; })).values()];
    const N = 6;
    const upRows = up.length ? up.slice(0, N).map(r => routeRow([endText(r.end), ...r.cells, 'this'], r.ids)) : dir !== 'down' ? ends('src').slice(0, 3).map(([e, id]) => routeRow([endText(e), 'this'], [id])) : [];
    const downRows = down.length ? down.slice(0, N).map(r => routeRow(['this', ...r.cells, endText(r.end)], r.ids)) : dir !== 'up' ? ends('dst').slice(0, 3).map(([e, id]) => routeRow(['this', endText(e)], [id])) : [];
    const more = (shown, total) => (total > shown ? `<span class="sub">and ${total - shown} more</span>` : '');
    const drawnLine = P.conn ? '' : `<p>Highlighting every drawn route: ${parts.join(' · ')}${capped ? ' (drawn cap reached)' : ''}, ${pl(c.segments, 'segment')} drawn once each.</p>`;
    return sec('Strands', controls + drawnLine + hid
      + `<p>${bounds.length ? `Reaches ${bounds.length === 1 ? 'a boundary' : bounds.length + ' boundaries'}: <span class="mono">${bounds.slice(0, 4).map(esc).join(' · ')}</span>${bounds.length > 4 ? ' and more' : ''}.` : 'Reaches no boundary on the routes drawn.'}</p>`
      + (dir !== 'down' ? limits('up') : '') + (dir !== 'up' ? limits('down') : '')
      + (R.up.length || R.down.length ? `<p class="sub">Routes through a cell are possible provenance across state, not proven: the write may set another field or another instance.</p>` : '')
      + (upRows.length || downRows.length ? `<div class="sub routes-head">Routes below are ranked for reading only; all are highlighted.</div>` : '')
      + (upRows.length ? `<h4>From the source</h4>${upRows.join('')}${more(Math.min(N, up.length), up.length)}` : '')
      + (downRows.length ? `<h4>To the end</h4>${downRows.join('')}${more(Math.min(N, down.length), down.length)}` : '')
      + rejectedHtml(R)
      + `<p class="sub">Click a point on these strands to join it to this one. Hover a line for what it is.</p>`
      + `<div class="row"><button class="btn" data-focus="pick">Focus (${P.strongNodes.length} classes)</button>${connBtn}</div>`);
  }
  // ---------- drawn lines: hover and click ----------
  // A line under the pointer, within LINE_SLACK px: strand segments, cell junctions, the trace and possible connections,
  // and with no selection the context edges. Markers and members are tested before this, so they win.
  const LINE_SLACK = 5;
  function lineAt(ev) {
    const r = renderer.domElement.getBoundingClientRect(), x = ev.clientX - r.left, y = ev.clientY - r.top;
    const cam = camera(), v = new THREE.Vector3(), w = stage.clientWidth || 1, h = stage.clientHeight || 1;
    const scr = p => { v.copy(p).project(cam); return [(v.x + 1) / 2 * w, (1 - v.y) / 2 * h, v.z]; };
    const dist = pts => {
      let d = Infinity, prev = null;
      for (const p of pts) {
        const q = scr(p); if (q[2] < -1 || q[2] > 1) { prev = null; continue; }
        if (prev) { const dx = q[0] - prev[0], dy = q[1] - prev[1], l2 = dx * dx + dy * dy, f = l2 ? Math.max(0, Math.min(1, ((x - prev[0]) * dx + (y - prev[1]) * dy) / l2)) : 0; d = Math.min(d, Math.hypot(x - prev[0] - f * dx, y - prev[1] - f * dy)); }
        else d = Math.min(d, Math.hypot(x - q[0], y - q[1]));
        prev = q;
      }
      return d;
    };
    const rank = l => (l.kind === 'junction' ? 0 : l.kind === 'seg' ? (l.role === 'strong' ? 1 : 2) : 3);
    let best = null, bd = Infinity;
    for (const l of hitLines) { if (l.off) continue; const d = dist(l.pts); if (d > LINE_SLACK) continue; const sc = rank(l) * LINE_SLACK + d; if (sc < bd) { bd = sc; best = l; } }
    return best;
  }
  const memLabel = m => (m >= 0 ? `${M.nodes[M.mem.n[m]].n}.${M.mem.name[m]}` : '?');
  const ptLabel = (T, p) => { const m = T.pt.m[p], x = T.pt.node[p]; return m >= 0 ? memLabel(m) : x >= 0 ? M.nodes[x].n : '?'; };
  const APPROX_TEXT = { anyInstance: 'any instance', anyContainer: 'any container', fieldMismatch: 'field mismatch', staged: 'staged' };
  function segInfo(t, s) {
    const T = M.br.trees[t], g = T.segs[s], P = V.pick, key = t + ':' + s;
    const routes = P && P.uses ? P.uses.get(key) || 0 : 0;
    return { T, g, from: ptLabel(T, g.a), to: ptLabel(T, g.b), hops: g.hc, routes, approx: g.approx.map(a => APPROX_TEXT[a] || a), tree: `${T.kind} root ${T.label} · ${T.dir}` };
  }
  function lineTip(l) {
    if (l.kind === 'seg') {
      const i = segInfo(l.t, l.s);
      return `<b>Strand segment</b><div class="mono">${esc(i.from)} → ${esc(i.to)}</div><div>${i.hops} hop${i.hops === 1 ? '' : 's'} · ${i.routes} highlighted route${i.routes === 1 ? '' : 's'} use it</div>`
        + `<div>Approximations: ${esc(i.approx.join(', ') || 'none')}</div><div class="k">${esc(i.tree)}</div><div class="k">Hop kinds are not in the export yet.</div>`;
    }
    if (l.kind === 'junction') {
      const j = l.link, Tw = M.br.trees[j.from.t], Tr = M.br.trees[j.to.t];
      return `<b>Cell junction · possible provenance across state</b><div class="mono">cell ${esc(cellName(l.cell))}</div><div>Writer: ${esc(ptLabel(Tw, j.from.point))}</div><div>Reader: ${esc(ptLabel(Tr, j.to.point))}</div><div class="k">Compat: ${esc(j.compat)}. Unproven: the write may set another field or another instance.</div>`;
    }
    if (l.kind === 'trace') return `<b>Golden trace · hop ${l.i + 1}</b><div>${esc(l.from)} → ${esc(l.to)}</div>`;
    if (l.kind === 'conn') return `<b>Possible connection</b><div class="mono">${esc(memLabel(l.a))} → ${esc(memLabel(l.b))}</div><div>${esc(l.k)}${l.c > 1 ? ' ×' + l.c : ''}</div>`;
    return null;
  }
  // The Details rows a hovered line belongs to get a mark: route rows by chain, cell buttons by cell, steps by index.
  function hoverRows(l) {
    const pane = $('pane-details'); if (!pane.querySelectorAll) return 0;
    for (const el of pane.querySelectorAll('.hov')) el.classList.remove('hov');
    const pin = pane.querySelector('.hovpin'); if (pin) pin.remove();
    if (!l) return 0;
    let n = 0;
    const mark = el => { el.classList.add('hov'); n++; };
    if (l.kind === 'seg' && V.pick) {
      const ids = new Set(V.pick.G.entries.filter(e => e.c.t === l.t && e.c.x.segs.includes(l.s)).map(e => e.c.id));
      for (const el of pane.querySelectorAll('[data-chains]')) if (el.dataset.chains.split(',').some(x => ids.has(+x))) mark(el);
      if (!n) {
        const head = pane.querySelector('.routes-head');
        const k = segInfo(l.t, l.s).routes, el = document.createElement('div');
        el.className = 'hovpin hov'; el.textContent = `Hovered segment: ${k} route${k === 1 ? '' : 's'} use${k === 1 ? 's' : ''} it, none of them listed here.`;
        if (head) head.after(el); else pane.prepend(el);
        n++;
      }
    } else if (l.kind === 'junction') for (const el of pane.querySelectorAll(`[data-cell="${l.cell}"]`)) mark(el);
    else if (l.kind === 'trace') { const li = $('steps').querySelectorAll ? $('steps').querySelectorAll('li')[l.i] : null; if (li) mark(li); }
    return n;
  }
  // Clicking a line: a segment is selected (highlight only), a junction selects its cell, a trace hop its step.
  function clickLine(l, e) {
    if (l.kind === 'seg') {
      const prev = S.sel && ['node', 'member', 'cell'].includes(S.sel.kind) ? S.sel : S.segPrev || null;
      S.selHist.push({ sel: S.sel, sel2: S.sel2 }); setSel({ kind: 'seg', t: l.t, s: l.s }); S.segPrev = prev; renderDetails();
    } else if (l.kind === 'junction') { S.selHist.push({ sel: S.sel, sel2: S.sel2 }); setSel({ kind: 'cell', ci: l.cell, m: cellMember(l.cell) }); }
    else if (l.kind === 'trace' && l.node >= 0) setSel({ kind: 'node', n: l.node });
    showTip(null, e, lineTip(l));
  }
  function segDetails(sel) {
    const i = segInfo(sel.t, sel.s), prev = S.segPrev, T = i.T;
    const routes = V.pick ? V.pick.G.entries.filter(e => e.c.t === sel.t && e.c.x.segs.includes(sel.s)) : [];
    const offer = prev ? [[i.g.a, 'start'], [i.g.b, 'end']].map(([p, w]) => `<button class="btn" data-sel2="${sel.t}:${p}">Set its ${w} as second point</button>`).join('') : '';
    return `<div><div class="kind">strand segment</div><h3>${esc(i.from)} → ${esc(i.to)}</h3></div>`
      + `<div>${i.hops} hop${i.hops === 1 ? '' : 's'} · approximations: ${esc(i.approx.join(', ') || 'none')}</div><div class="sub">${esc(i.tree)}</div>`
      + sec(`Chains through this segment (${V.pick ? V.pick.R.total.core : 0})`, routes.slice(0, 8).map(e => { const { src, dst } = chainEnds(M, e.c); return routeRow([endText(src), endText(dst)], [e.c.id]); }).join('') || '<span class="sub">none</span>')
      + (prev ? `<p class="sub">Join one of its ends to ${esc(whatLabel(whatOf(prev)))}:</p><div class="row">${offer}</div>` : '<p class="sub">Select a class or member first to offer this segment\'s ends as a second point.</p>');
  }
  function rejectedHtml(R) {
    const rej = [...R.rejected.up, ...R.rejected.down];
    if (!rej.length) return '';
    return `<h4>Rejected candidates</h4>` + rej.slice(0, 6).map(e => routeHtml([e.cell, endText(chainEnds(M, e.c)[R.rejected.up.includes(e) ? 'src' : 'dst'])])).join('');
  }
  function connectSection(P) {
    const C = P.conn, X = P.what, Y = S.sel2;
    const top = `<div><div class="kind">connecting strand</div><h3>${esc(whatLabel(X))} ↔ ${esc(whatLabel(Y))}</h3></div>`;
    if (C && !C.earlier && C.shared && C.shared.size) return top + `<p>Shared origin, no connecting route shown: no single route, stitched or not, passes through both in order. The ${C.shared.size} segments upstream of both are drawn strong.</p>`;
    if (!C || !C.earlier) return top + '<p>No exported route passes through both points in order, and they share no upstream segment on the strands drawn.</p>';
    const order = flowOrder(P.G, [...C.strong]), pos = new Map(order.map((k, i) => [k, i]));
    const chains = P.G.entries.filter(e => e.c.x.segs.some(s => C.strong.has(e.c.t + ':' + s))).map(e => e.c).sort(chainRank);
    let hops = 0; const approx = new Map(), nodes = [], seenN = new Set();
    for (const k of order) {
      const { t, s } = P.G.segs.get(k), T = M.br.trees[t], g = T.segs[s];
      hops += g.hc;
      for (const a of g.approx) { const x = T.pt.node[g.a], z = T.pt.node[g.b]; approx.set(a + k, `${a} between ${x >= 0 ? M.nodes[x].n : '?'} and ${z >= 0 ? M.nodes[z].n : '?'}`); }
      for (const x of g.nodes) if (!seenN.has(x)) { seenN.add(x); nodes.push(x); }
    }
    const cells = [];
    for (const j of P.G.jlinks.filter(j => C.strong.has(j.a) && C.strong.has(j.b)).sort((a, b) => pos.get(a.a) - pos.get(b.a))) if (!cells.includes(j.cell)) cells.push(j.cell);
    const [from, to] = C.earlier === 'x' ? [X, Y] : [Y, X], best = chains[0];
    return top + `<div>${chains.length} chain${chains.length === 1 ? '' : 's'} · ${hops} hops · ${order.length} segments · ${cells.length} cell junction${cells.length === 1 ? '' : 's'}</div>`
      + (best ? `<div>Best chain: cost ${esc(costText(best.x.cost))} · best of ${best.x.eq} path${best.x.eq === 1 ? '' : 's'} · <span class="${best.x.clean ? 'clean' : 'unclean'}">${best.x.clean ? 'clean' : 'needs an any-instance read or staged code'}</span></div>` : '')
      + sec(cells.length ? 'Cells crossed, in flow order · possible provenance across state' : 'Route',routeHtml([whatLabel(from), ...cells, whatLabel(to)]) + (cells.length ? '<div class="sub">Each cell step is a possible channel, not proven.</div>' : ''))
      + sec('Approximations', approx.size ? [...approx.values()].map(s => `<div style="font-size:12px">${esc(s)}</div>`).join('') : '<span class="sub">none</span>')
      + sec(`Classes crossed (${nodes.length})`, listOf(nodes.map((x, k) => nodeBtn(x, String(k + 1))), 30))
      + `<div class="row"><button class="btn" data-focus="pick">Focus strand</button></div>`;
  }
