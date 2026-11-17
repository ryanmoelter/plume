  const Yaxis = new THREE.Vector3(0, 1, 0);
  function segAnchors(T, sg) {
    const out = [];
    for (const q of [ptAnchor(T, sg.a), ...sg.members.map(memberAnchor), ptAnchor(T, sg.b)]) if (q && (!out.length || out[out.length - 1].distanceTo(q) > 1e-6)) out.push(q);
    return out;
  }
  function linePieces(anchors, list, w, col, style, wpp) {
    const piece = (a, z) => { const d = z.clone().sub(a), len = d.length(); if (len < 1e-6) return; list.push([a.clone().add(z).multiplyScalar(0.5), new THREE.Quaternion().setFromUnitVectors(Yaxis, d.normalize()), len, w, col]); };
    for (let i = 0; i + 1 < anchors.length; i++) {
      const a = anchors[i], z = anchors[i + 1];
      if (style === 'solid') { piece(a, z); continue; }
      const [dash, gap] = style === 'dash' ? [7 * wpp, 4 * wpp] : [1.6 * wpp, 3.4 * wpp];
      const len = a.distanceTo(z), dir = z.clone().sub(a).normalize();
      for (let t = 0; t < len; t += dash + gap) piece(a.clone().addScaledVector(dir, t), a.clone().addScaledVector(dir, Math.min(len, t + dash)));
    }
  }
  // Persistent arrowheads, one per drawn segment long enough on screen, at the middle of its longest piece, so the
  // direction reads with pulses off.
  const coneGeo = new THREE.ConeGeometry(1, 1, 3); SHARED_GEO.add(coneGeo);
  let arrows = [];
  function arrowOn(anchors, w, col, wpp) {
    let best = null, bl = 0;
    for (let i = 0; i + 1 < anchors.length; i++) { const l = anchors[i].distanceTo(anchors[i + 1]); if (l > bl) { bl = l; best = i; } }
    if (best == null || bl < 26 * wpp) return;
    const a = anchors[best], z = anchors[best + 1];
    arrows.push([a.clone().lerp(z, 0.5), new THREE.Quaternion().setFromUnitVectors(Yaxis, z.clone().sub(a).normalize()), Math.max(w * 2.6, 4.5 * wpp), col]);
  }
  function drawArrows(wpp) {
    if (!arrows.length) return;
    const im = new THREE.InstancedMesh(coneGeo, new THREE.MeshBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0.9, depthTest: false }), arrows.length), d = new THREE.Object3D();
    arrows.forEach(([p, q, r, col], i) => { d.position.copy(p); d.quaternion.copy(q); d.scale.set(r, r * 2.1, r); d.updateMatrix(); im.setMatrixAt(i, d.matrix); im.setColorAt(i, col); });
    im.instanceMatrix.needsUpdate = true; if (im.instanceColor) im.instanceColor.needsUpdate = true;
    im.renderOrder = 12.2; im.frustumCulled = false; memGroup.add(im); arrowMesh = im; arrows = [];
  }
  let arrowMesh = null;
  function addPieces(pieces, style) {
    const d = new THREE.Object3D();
    for (const [name, list] of Object.entries(pieces)) {
      if (!list.length) continue;
      const [op, ord] = style[name];
      const im = new THREE.InstancedMesh(cylGeo, new THREE.MeshBasicMaterial({ color: 0xffffff, transparent: true, opacity: op, depthTest: false }), list.length);
      list.forEach(([pos, q, len, w, col], i) => { d.position.copy(pos); d.quaternion.copy(q); d.scale.set(w, len, w); d.updateMatrix(); im.setMatrixAt(i, d.matrix); im.setColorAt(i, col); });
      im.instanceMatrix.needsUpdate = true; if (im.instanceColor) im.instanceColor.needsUpdate = true;
      im.renderOrder = ord; im.frustumCulled = false; memGroup.add(im);
    }
  }
  // Markers that land on one spot, stacked on a class centre at fit zoom, fan out round it in rings with the most
  // important in the middle, so each stays visible and clickable. The lines still meet at the centre.
  function placeMarks(marks, g, wpp) {
    const groups = new Map();
    marks.forEach((mk, i) => { if (mk.fixed) return; const k =[mk.q.x, mk.q.y, mk.q.z].map(v => v.toFixed(2)).join(','); if (!groups.has(k)) groups.set(k, []); groups.get(k).push(i); });
    for (const ids of groups.values()) {
      if (ids.length < 2) continue;
      ids.sort((a, b) => marks[a].prio - marks[b].prio || a - b);
      let ring = 1, slot = 0;
      for (let j = 1; j < ids.length; j++) {
        const cap = 6 * ring, a = 2 * Math.PI * slot / cap + ring * 0.4, r = 11 * ring * wpp, mk = marks[ids[j]];
        mk.q = mk.q.clone().add(side() ? new THREE.Vector3(r * Math.cos(a), r * Math.sin(a), 0) : new THREE.Vector3(r * Math.cos(a), 0, r * Math.sin(a)));
        if (++slot >= cap) { ring++; slot = 0; }
      }
    }
    const per = {}, d = new THREE.Object3D();
    for (const mk of marks) {
      (per[mk.shape] = per[mk.shape] || []).push(mk);
      if (mk.info) markers.push(Object.assign({ p: mk.q, px: Math.max(mk.px, 5) }, mk.info));
    }
    for (const [shape, list] of Object.entries(per)) {
      const im = new THREE.InstancedMesh(g[shape], new THREE.MeshBasicMaterial({ color: 0xffffff, depthTest: false, side: THREE.DoubleSide }), list.length);
      list.forEach((mk, i) => { d.position.copy(mk.q); d.quaternion.identity(); d.scale.setScalar(mk.px * wpp); d.updateMatrix(); im.setMatrixAt(i, d.matrix); im.setColorAt(i, mk.col); });
      im.instanceMatrix.needsUpdate = true; if (im.instanceColor) im.instanceColor.needsUpdate = true;
      im.renderOrder = 13; im.frustumCulled = false; memGroup.add(im);
    }
  }
  const TERM_STYLE = { boundary: ['prop', '--role-boundary'], cellWrite: ['init', '--role-state'], cellRead: ['cell', '--cell-read'], ui: ['fn', '--role-ui'], entry: ['sq', '--role-screen'], sink: ['cell', '--grey'] };
  const lineStyle = sg => (sg.approx.includes('fieldMismatch') ? 'dot' : sg.approx.includes('anyInstance') || sg.approx.includes('anyContainer') ? 'dash' : 'solid');
  // The highlighted tree, drawn on the current layout: faint branches, the chosen strand strong, markers on top.
  // A selection's strands replace it while they exist.
  function drawTree(wpp, g) {
    const T = V.T; if (!T || (V.pick && V.pick.R.core.length)) return;
    const tv = V.tv, strandSegs = tv.strandSegs || new Set();
    const segs = drawLevel() === 0 ? [...strandSegs] : [...new Set([...tv.segs, ...strandSegs])];
    const pieces = { faint: [], strong: [] }, branchCol = color('--branch'), greyCol = color('--grey');
    const byB = new Map(); for (const k of segs) { const b = T.segs[k].b; if (!byB.has(b)) byB.set(b, []); byB.get(b).push(k); }
    for (const k of segs) {
      const sg = T.segs[k], strong = strandSegs.has(k);
      const w = (strong ? 2.2 : 0.8) * wpp, col = sg.approx.includes('staged') ? greyCol : branchCol, style = lineStyle(sg), anchors = segAnchors(T, sg);
      linePieces(anchors, strong ? pieces.strong : pieces.faint, w, col, style, wpp);
      if (strong || !strandSegs.size) arrowOn(anchors, w, col, wpp);
      if (strong) pulseLine('T' + k, anchors, w, col, style, (byB.get(sg.a) || []).map(j => 'T' + j), 'T' + T.i);
    }
    addPieces(pieces, { strong: [0.95, 12], faint: [strandSegs.size ? 0.3 : 0.7, 8] });
    const marks = [];
    const mark = (p, shape, col, px, info, prio) => { const q = ptAnchor(T, p); if (q) marks.push({ q, shape, col, px, info, prio }); };
    mark(T.rootPt, 'hi', branchCol, 7, { kind: 'point', T, point: T.rootPt }, 0);
    const strandPts = new Set([T.rootPt, ...[...strandSegs].flatMap(k => [T.segs[k].a, T.segs[k].b])]);
    for (const p of drawLevel() === 0 ? strandPts : tv.points) if (['branch', 'split', 'merge', 'join'].includes(T.pt.kind[p])) mark(p, 'dot', branchCol, 2.4, { kind: 'point', T, point: p }, 3);
    const termKs = drawLevel() === 0 && tv.strandSegs ? tv.terms.filter(k => T.terms[k].point === S.endpoint) : tv.terms;
    for (const k of termKs) {
      const term = T.terms[k], [shape, tok] = TERM_STYLE[term.kind] || ['fn', '--grey'];
      mark(term.point, shape, color(tok), term.point === S.endpoint ? 6.5 : 4.5, { kind: 'term', T, point: term.point }, term.point === S.endpoint ? 1 : 2);
    }
    placeMarks(marks, g, wpp);
  }

  // Selection strands, computed on every highlight and cached by the selection and the toggles.
  let pickCache = { key: '', P: null };
  function whatOf(sel) {
    if (!sel) return null;
    if (sel.kind === 'member') return { m: sel.m };
    if (sel.kind === 'cell') return { ci: sel.ci, m: sel.m != null && sel.m >= 0 ? sel.m : cellMember(sel.ci) };
    if (sel.kind === 'node') return { n: sel.n };
    if (sel.kind === 'seg') { const T = M.br.trees[sel.t], g = T.segs[sel.s], x = T.pt.node[g.a]; return { t: sel.t, s: sel.s, m: -1, n: x >= 0 ? x : g.nodes[0] }; }
    return null;
  }
  const sameWhat = (a, b) => !!a && !!b && JSON.stringify(a) === JSON.stringify(b);
  // An occurrence { t, s } names its member or class too; its anchor is where the clicked segment meets it.
  function occAnchor(w) {
    const T = M.br.trees[w.t], g = T.segs[w.s], an = segAnchors(T, g), x = w.n != null ? w.n : M.mem.n[w.m];
    if (w.m >= 0) { const q = memberAnchor(w.m); if (q) return q; }
    for (const p of [g.a, g.b]) if (T.pt.node[p] === x) return ptAnchor(T, p);
    return an.length ? an[an.length >> 1] : null;
  }
  function whatNode(w) {
    if (w.s != null) return w.n != null ? w.n : M.mem.n[w.m];
    if (w.n != null) return w.n;
    if (w.m != null && w.m >= 0) return M.mem.n[w.m];
    if (w.ci != null) { const c = M.cells[w.ci]; return c && c.o >= 0 ? c.o : -1; }
    if (w.t != null) return M.br.trees[w.t].pt.node[w.point];
    return -1;
  }
  function whatAnchor(w) {
    if (w.s != null) return occAnchor(w);
    if (w.t != null) return ptAnchor(M.br.trees[w.t], w.point);
    if (w.m != null && w.m >= 0) { const q = memberAnchor(w.m); if (q) return q; }
    const x = whatNode(w); if (x < 0 || !V.shown(M.nodes[x])) return null;
    const q = npos(M.nodes[x]); if (q && !side()) q.y += 2; return q;
  }
  function whatLabel(w) {
    if (w.s != null) return whatLabel(w.n != null ? { n: w.n } : { m: w.m }) + ' (the occurrence clicked)';
    if (w.t != null) return pointLabel(M.br.trees[w.t], w.point);
    if (w.ci != null) return 'cell ' + (M.cells[w.ci] ? M.cells[w.ci].n : '?');
    if (w.m != null && w.m >= 0) return M.mem.name[w.m] + ' in ' + M.nodes[M.mem.n[w.m]].n;
    return M.nodes[w.n].n;
  }
  // Which way a selection's strands run: the reader's choice for this selection, else the Settings default.
  const pickDirFor = () => S.pickDir || S.pickDirDefault || 'both';
  // The segments of the chosen direction: the core cut at the selection, plus that side's stitched chains.
  function dirSegs(R, G, what, dir) {
    if (dir === 'both') return new Set(G.segs.keys());
    const touch = touchSet(M, G, what), out = new Set();
    for (const c of R.coreDrawn) {
      const ss = c.x.segs; let xi = ss.findIndex(s => touch.has(c.t + ':' + s)); if (xi < 0) xi = dir === 'down' ? 0 : ss.length - 1;
      for (let i = dir === 'down' ? xi : 0; i <= (dir === 'up' ? xi : ss.length - 1); i++) out.add(c.t + ':' + ss[i]);
    }
    for (const e of dir === 'up' ? R.up : R.down) for (const s of e.c.x.segs) out.add(e.c.t + ':' + s);
    return out;
  }
  // A selection's strands. With one point, every drawn route through it in the chosen direction is strong, all at one
  // level; a segment shared by many routes is one segment, drawn once. With a second point, the routes joining the two
  // are strong, their continuations beyond either end faint, and the rest drop away.
  function computePick() {
    const what = whatOf(S.sel); if (!what) return null;
    const dir = pickDirFor();
    const key = JSON.stringify([what, S.sel2, S.clean !== false, !!S.sinks, dir]);
    if (pickCache.key === key) return pickCache.P;
    const R = stitchStrands(M, what, { clean: S.clean !== false, sinks: !!S.sinks });
    const G = strandGraph(M, R);
    const conn = S.sel2 && R.core.length ? connectStrands(M, G, what, S.sel2) : null;
    const P = { what, R, G, conn, dir, roles: new Map() };
    const C = conn && conn.earlier ? conn : null, sib = conn && !conn.earlier && conn.shared.size ? conn : null;
    if (C) { for (const k of C.strong) P.roles.set(k, 'strong'); for (const k of C.faint) if (!C.strong.has(k)) P.roles.set(k, 'faint'); }
    else if (sib) for (const k of sib.shared) P.roles.set(k, 'strong');
    else if (!conn) for (const k of dirSegs(R, G, what, dir)) P.roles.set(k, 'strong');
    const strong = new Set([...P.roles].filter(([, r]) => r === 'strong').map(([k]) => k));
    P.pulse = strong;
    const nodesOf = keys => {
      const out = [], seen = new Set(), addN = x => { if (x >= 0 && !seen.has(x)) { seen.add(x); out.push(x); } };
      for (const k of flowOrder(G, [...keys])) G.segs.get(k) && M.br.trees[G.segs.get(k).t].segs[G.segs.get(k).s].nodes.forEach(addN);
      addN(whatNode(what)); if (S.sel2) addN(whatNode(S.sel2));
      return out;
    };
    P.strongNodes = nodesOf(strong);
    P.nodes = nodesOf(P.roles.keys());
    P.mems = new Set();
    for (const k of P.roles.keys()) { const { t, s } = G.segs.get(k), T = M.br.trees[t], g = T.segs[s]; for (const m of [T.pt.m[g.a], ...g.members, T.pt.m[g.b]]) if (m >= 0) P.mems.add(m); }
    // How many drawn chains use each highlighted segment, for the hover tip.
    P.uses = new Map();
    for (const e of G.entries) for (const s of e.c.x.segs) { const k = e.c.t + ':' + s; if (P.roles.has(k)) P.uses.set(k, (P.uses.get(k) || 0) + 1); }
    const t = R.total, drawnIn = side => (side === 'up' ? R.up : R.down).length;
    P.count = {
      segments: P.roles.size, through: R.coreDrawn.length, up: dir === 'down' ? 0 : drawnIn('up'), down: dir === 'up' ? 0 : drawnIn('down'),
      totalThrough: t.core, totalUp: t.up, totalDown: t.down,
    };
    P.hidden = conn ? null : dir === 'up' ? { side: 'downstream', n: t.down } : dir === 'down' ? { side: 'upstream', n: t.up } : null;
    pickCache = { key, P };
    return P;
  }
  const onPick = w => !!(w && V.pick && V.pick.R.core.length && [...touchSet(M, V.pick.G, w)].some(k => V.pick.roles.has(k)));
  // A segment's floor: the layer both its ends sit on, or -1 when it crosses floors.
  function segFloor(T, sg) { const a = T.pt.node[sg.a], b = T.pt.node[sg.b]; const sa = a >= 0 ? M.nodes[a].slot : -1, sb = b >= 0 ? M.nodes[b].slot : -1; return sa === sb ? sa : -1; }
  const onFloor = (T, sg) => S.floor == null || S.floor === 'all' || segFloor(T, sg) === S.floor;
  // A selection's strands: strong with arrowheads and pulses; with a second point, continuations faint with
  // arrowheads only. On a chosen floor, strong segments elsewhere step back. The selection carries a fixed-size halo.
  function drawPick(wpp, g) {
    const P = V.pick; if (!P || !P.R.core.length) return;
    const G = P.G, branchCol = color('--branch'), greyCol = color('--grey'), ink = color('--ink');
    const W = { faint: 1.3, strong: 2.2, strongOff: 1.4 };
    const pieces = { faint: [], strong: [], strongOff: [], joint: [] };
    const crossJ = new Set(G.jlinks.map(j => j.a + '>' + j.b));
    for (const [key, role] of P.roles) {
      const { t, s } = G.segs.get(key), T = M.br.trees[t], sg = T.segs[s];
      const col = sg.approx.includes('staged') ? greyCol : branchCol, style = lineStyle(sg), anchors = segAnchors(T, sg);
      const r = role === 'strong' && !onFloor(T, sg) ? 'strongOff' : role;
      linePieces(anchors, pieces[r], W[r] * wpp, col, style, wpp);
      hitLines.push({ pts: anchors, kind: 'seg', key, t, s, role, off: r === 'strongOff' });
      arrowOn(anchors, W[r] * wpp, col.clone().lerp(ink, 0.4), wpp);
      if (role !== 'strong') continue;
      // A pulse never runs through a cell: phase carries along a chain only, so each side of a junction moves on its own.
      pulseLine(key, anchors, W[r] * wpp, col, style, [...(G.prev.get(key) || [])].filter(p => !crossJ.has(p + '>' + key) && P.pulse.has(p)), 'T' + t);
    }
    // A cell junction is a possible channel, drawn as a joint from the write to the read: broken for unknown, whole
    // for match. Both ends sit on the cell, so it is often short; the junction ring marks it regardless.
    const stateCol = color('--role-state'), jdrawn = new Set();
    for (const J of G.junctions) for (const j of J.links) {
      if (!P.roles.has(j.a) || !P.roles.has(j.b)) continue;
      jdrawn.add(J.cell);
      const a = ptAnchor(M.br.trees[j.from.t], j.from.point), z = ptAnchor(M.br.trees[j.to.t], j.to.point);
      if (a && z) { linePieces([a, z], pieces.joint, 1.2 * wpp, stateCol, STITCH_COMPAT[j.compat].draw === 'joint' ? 'solid' : 'dash', wpp); hitLines.push({ pts: [a, z], kind: 'junction', cell: J.cell, link: j }); }
    }
    addPieces(pieces, { faint: [0.5, 8.5], strongOff: [0.4, 9], strong: [0.95, 12], joint: [0.9, 12.1] });
    const marks = [], done = new Set(), isStrong = key => P.roles.get(key) === 'strong';
    const mark = (T, p, shape, col, px, info, prio) => { const k = T.i + ':' + p; if (done.has(k)) return; done.add(k); const q = ptAnchor(T, p); if (q) marks.push({ q, shape, col, px, info, prio }); };
    for (const J of G.junctions) if (jdrawn.has(J.cell)) for (const at of J.at) mark(M.br.trees[at.t], at.point, 'cell', color('--role-state'), 6, { kind: 'junction', ci: J.cell, T: M.br.trees[at.t], point: at.point }, 1);
    for (const e of G.entries) {
      const c = e.c, T = M.br.trees[c.t], ss = c.x.segs; if (!ss.length) continue;
      const first = isStrong(c.t + ':' + ss[0]), last = isStrong(c.t + ':' + ss[ss.length - 1]);
      const termEnd = T.dir === 'forward' ? last : first, rootEnd = T.dir === 'forward' ? first : last;
      if (termEnd) { const [shape, tok] = TERM_STYLE[c.x.kind] || ['fn', '--grey']; mark(T, c.x.point, shape, color(tok), 4.5, { kind: 'term', T, point: c.x.point }, 2); }
      if (rootEnd) mark(T, T.rootPt, T.kind === 'boundary' ? 'prop' : 'hi', color(T.kind === 'boundary' ? '--role-boundary' : '--branch'), T.kind === 'boundary' ? 5 : 6, { kind: 'point', T, point: T.rootPt }, 2);
    }
    for (const w of [P.what, S.sel2]) {
      if (!w) continue; const q = whatAnchor(w); if (!q) continue;
      marks.push({ q, shape: 'hi', col: color('--accent'), px: 8.5, info: { kind: 'x', what: w }, prio: 0, fixed: true });
      marks.push({ q, shape: 'hi', col: color('--accent'), px: 16, prio: 0, fixed: true });
    }
    placeMarks(marks, g, wpp);
  }
  // Where the strong strands leave the chosen floor: one chevron per class it leaves from, pointing to the floor it
  // goes to. Clicking one steps to that floor.
  function floorExits(P) {
    const out = new Map();
    if (!P || S.floor == null || S.floor === 'all') return [];
    for (const [k, role] of P.roles) {
      if (role !== 'strong') continue;
      const { t, s } = P.G.segs.get(k), T = M.br.trees[t], sg = T.segs[s];
      const a = T.pt.node[sg.a], b = T.pt.node[sg.b]; if (a < 0 || b < 0) continue;
      const sa = M.nodes[a].slot, sb = M.nodes[b].slot;
      if (sa === S.floor && sb !== S.floor) out.set(a + '>' + sb, { n: a, to: sb });
      if (sb === S.floor && sa !== S.floor) out.set(b + '>' + sa, { n: b, to: sa });
    }
    return [...out.values()];
  }

  // Flow pulses: soft brighter dashes drift along highlighted strands and the trace, the way data flows, at a constant
  // speed on screen. A pulse's phase follows the distance from the strand's upstream start, so it runs on from one
  // segment into the next. On a dashed or dotted line a pulse is a short run of dots, so the line's pattern stays
  // readable. Only time moves them, and nothing about the layout depends on them.
  const PULSE = { speed: 70, spacing: 180, dash: 12 };
  const reduceMotion = (() => { try { return !!matchMedia('(prefers-reduced-motion: reduce)').matches; } catch (e) { return false; } })();
  let pulseLines = [], pulseMesh = null, pulseDots = null, pulseWpp = 1;
  const clock = () => (typeof performance !== 'undefined' ? performance.now() : Date.now()) / 1000;
  function pulseLine(key, pts, w, col, style, prevKeys, group) {
    if (pts.length < 2) return;
    const cum = [0]; for (let i = 1; i < pts.length; i++) cum.push(cum[i - 1] + pts[i].distanceTo(pts[i - 1]));
    if (cum[cum.length - 1] < 1e-6) return;
    pulseLines.push({ key, pts, cum, len: cum[cum.length - 1], w, col, style, prevKeys, group: group || key, off: 0 });
  }
  // A start phase per tree, so runs that do not join never pulse in step.
  const groupPhase = s => { let h = 2166136261; for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619); return ((h >>> 0) % 1000) / 1000; };
  const pulsesOn = () => !!S.pulses && !reduceMotion && pulseLines.length > 0 && !document.hidden;
  function buildPulses(wpp, g) {
    pulseWpp = wpp; pulseMesh = pulseDots = null;
    if (!S.pulses || reduceMotion || !pulseLines.length) { pulseLines = []; return; }
    const byKey = new Map(pulseLines.map(l => [l.key, l])), memo = new Map(), visiting = new Set();
    const off = l => {
      if (memo.has(l.key)) return memo.get(l.key);
      if (visiting.has(l.key)) return 0;
      visiting.add(l.key);
      let o = groupPhase(l.group) * PULSE.spacing * wpp; for (const p of l.prevKeys) { const pl = byKey.get(p); if (pl) { o = off(pl) + pl.len; break; } }
      visiting.delete(l.key); memo.set(l.key, o); return o;
    };
    const bg = color('--bg'), ink = color('--ink'), toward = bg.r + bg.g + bg.b > 1.5 ? bg : ink;
    let nd = 0, nt = 0; const sp = PULSE.spacing * wpp;
    for (const l of pulseLines) { l.off = off(l); l.pc = l.col.clone().lerp(toward, 0.55); const k = Math.ceil(l.len / sp) + 1; if (l.style === 'solid') nd += k; else nt += 3 * k; }
    const mk = (geo, n) => {
      const im = new THREE.InstancedMesh(geo, new THREE.MeshBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0.8, depthTest: false }), n);
      for (let i = 0; i < n; i++) im.setColorAt(i, bg);
      im.renderOrder = 12.5; im.frustumCulled = false; memGroup.add(im); return im;
    };
    if (nd) pulseMesh = mk(cylGeo, nd);
    if (nt) pulseDots = mk(g.dot, nt);
    updatePulses(clock());
  }
  function updatePulses(t) {
    const wpp = pulseWpp, sp = PULSE.spacing * wpp, dl = PULSE.dash * wpp, phase = (t * PULSE.speed * wpp) % sp, d = new THREE.Object3D();
    let nd = 0, nt = 0;
    const at = (l, s) => {
      let i = 1; while (i < l.cum.length - 1 && l.cum[i] < s) i++;
      const a = l.pts[i - 1], z = l.pts[i], seg = l.cum[i] - l.cum[i - 1], f = seg > 0 ? Math.min(1, Math.max(0, (s - l.cum[i - 1]) / seg)) : 0;
      return [a.clone().lerp(z, f), z.clone().sub(a).normalize()];
    };
    for (const l of pulseLines) {
      for (let s = ((phase - l.off) % sp + sp) % sp; s < l.len; s += sp) {
        if (l.style === 'solid') {
          if (!pulseMesh || nd >= pulseMesh.instanceMatrix.count) continue;
          const [p, dir] = at(l, s), len = Math.min(dl, 2 * s, 2 * (l.len - s));
          if (len < 1e-6) continue;
          d.position.copy(p); d.quaternion.setFromUnitVectors(Yaxis, dir); d.scale.set(l.w * 1.35, len, l.w * 1.35); d.updateMatrix();
          pulseMesh.setMatrixAt(nd, d.matrix); pulseMesh.setColorAt(nd, l.pc); nd++;
        } else {
          for (let j = -1; j <= 1; j++) {
            if (!pulseDots || nt >= pulseDots.instanceMatrix.count) continue;
            const [q] = at(l, Math.min(l.len, Math.max(0, s + j * 4 * wpp)));
            d.position.copy(q); d.quaternion.identity(); d.scale.setScalar(Math.max(l.w, 1.4 * wpp)); d.updateMatrix();
            pulseDots.setMatrixAt(nt, d.matrix); pulseDots.setColorAt(nt, l.pc); nt++;
          }
        }
      }
    }
    for (const [im, n] of [[pulseMesh, nd], [pulseDots, nt]]) if (im) { im.count = n; im.instanceMatrix.needsUpdate = true; if (im.instanceColor) im.instanceColor.needsUpdate = true; }
    return nd + nt;
  }
