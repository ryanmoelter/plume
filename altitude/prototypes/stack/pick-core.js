
// Selection strands. A chain is one root-to-terminal path of a tree. Along every segment data flows from a to b,
// so a forward chain runs root to terminal and a backward chain terminal to root. A chain reads a cell when it is a
// forward cell tree's chain or a backward chain ending in a cellRead, and writes one when a forward chain ends in a
// cellWrite. Strands through X are the chains that touch X, stitched at cells: upstream through every chain that
// writes the cell the strand reads, downstream through every chain that reads the cell it writes. The walk goes by
// breadth, one cell step at a time, up to STITCH_STEPS steps, and never expands a cell twice in one direction. Each
// side is capped; candidates rank clean first, then by cost, then by tree and terminal index.
// A stitch at a cell is a possible channel, not a proven one: the write may set another field or another instance.
// Each stitch carries a compat code. match draws as a joint, unknown as a broken joint, and mismatch is left out and
// listed as a rejected candidate. The export carries no codes yet, so every stitch is unknown.
const STITCH_STEPS = 6, STITCH_CAP = { core: 200, up: 200, down: 300 };
const STITCH_COMPAT = { match: { draw: 'joint' }, unknown: { draw: 'broken' }, mismatch: { draw: null } };
function stitchCompat(M, writer, reader, cell) {
  const codes = M.br.stitch;
  const code = codes && (codes[writer.t + ':' + writer.k + '>' + reader.t + ':' + reader.k] || codes['cell:' + cell]);
  return STITCH_COMPAT[code] ? code : 'unknown';
}
function chainIndex(M) {
  if (M.chainIx) return M.chainIx;
  const list = [], writers = new Map(), readers = new Map(), byTerm = new Map();
  const put = (map, key, v) => { let a = map.get(key); if (!a) map.set(key, a = []); a.push(v); };
  for (const T of M.br.trees) T.terms.forEach((x, k) => {
    const fwd = T.dir === 'forward';
    const c = { id: list.length, t: T.i, k, x, srcCell: fwd ? (T.kind === 'cell' ? T.ref : -1) : (x.kind === 'cellRead' ? x.ref : -1), dstCell: fwd && x.kind === 'cellWrite' ? x.ref : -1 };
    list.push(c); byTerm.set(T.i + ':' + k, c.id);
    if (c.dstCell >= 0) put(writers, c.dstCell, c.id);
    if (c.srcCell >= 0) put(readers, c.srcCell, c.id);
  });
  return (M.chainIx = { list, writers, readers, byTerm });
}
const chainRank = (a, b) => (b.x.clean - a.x.clean) || costCmp(a.x.cost, b.x.cost) || a.t - b.t || a.k - b.k;
// Where a chain's value comes from and where it goes: { kind, ref, label }.
function chainEnds(M, c) {
  const T = M.br.trees[c.t], root = { kind: T.kind, ref: T.ref, label: T.label, point: T.rootPt }, term = { kind: c.x.kind, ref: c.x.ref, point: c.x.point };
  return T.dir === 'forward' ? { src: root, dst: term } : { src: term, dst: root };
}
// What a selection is: { m } a member, { n } a class, { ci, m } a cell and its member, { t, point } a tree point,
// { t, s, m } one occurrence of a member on one segment.
function segTouches(T, g, w) {
  if (w.t != null && w.s != null) return T.i === w.t && T.segs[w.s] === g;
  if (w.t != null) return T.i === w.t && (g.a === w.point || g.b === w.point);
  if (w.m != null && w.m >= 0 && (T.pt.m[g.a] === w.m || T.pt.m[g.b] === w.m || g.members.includes(w.m))) return true;
  if (w.n != null) return g.nodes.includes(w.n);
  return false;
}
function coreChains(M, what) {
  const ix = strandIndex(M), C = chainIndex(M), out = new Set();
  const add = l => { for (const [t, k] of l || []) out.add(C.byTerm.get(t + ':' + k)); };
  if (what.t != null && what.s != null) {
    M.br.trees[what.t].terms.forEach((x, k) => { if (x.segs.includes(what.s)) out.add(C.byTerm.get(what.t + ':' + k)); });
  } else if (what.ci != null) {
    if (what.m != null && what.m >= 0) add(ix.byMem.get(what.m));
    for (const id of [...(C.writers.get(what.ci) || []), ...(C.readers.get(what.ci) || [])]) out.add(id);
  } else if (what.m != null) add(ix.byMem.get(what.m));
  else if (what.n != null) add(ix.byNode.get(what.n));
  else if (what.t != null) {
    const T = M.br.trees[what.t];
    T.terms.forEach((x, k) => { if (what.point === T.rootPt || x.point === what.point || x.segs.some(s => segTouches(T, T.segs[s], what))) out.add(C.byTerm.get(T.i + ':' + k)); });
  }
  return [...out];
}
function stitchStrands(M, what, o) {
  const C = chainIndex(M), ok = c => (o.sinks || c.x.kind !== 'sink') && (!o.clean || c.x.clean);
  const core = coreChains(M, what).map(id => C.list[id]).filter(ok).sort(chainRank);
  // Where each side's walk ends, per far end: 'stopped' at the step limit with more stitches beyond, 'unwritten' at a
  // cell nothing exported writes (or nothing reads, downstream), 'rejoin' where it meets a route already drawn, 'capped' past the drawn cap, else the end kind.
  const walk = (start, dir, cap) => {
    const got = [], rejected = [], seen = new Set(start.map(c => c.id)), cells = new Set(), hit = new Set();
    let frontier = start, steps = 0, stopped = 0;
    const cellOf = c => (dir === 'up' ? c.srcCell : c.dstCell);
    for (let d = 1; d <= STITCH_STEPS && frontier.length; d++) {
      const cand = [];
      for (const c of frontier) {
        const cell = cellOf(c);
        if (cell < 0 || cells.has(cell)) continue;
        cells.add(cell);
        for (const id of (dir === 'up' ? C.writers : C.readers).get(cell) || []) {
          const e = C.list[id];
          if (seen.has(id) || !ok(e)) continue;
          seen.add(id);
          const compat = dir === 'up' ? stitchCompat(M, e, c, cell) : stitchCompat(M, c, e, cell);
          (STITCH_COMPAT[compat].draw ? cand : rejected).push({ c: e, parent: c.id, cell, depth: d, compat });
        }
      }
      cand.sort((a, b) => chainRank(a.c, b.c));
      const take = cap == null ? cand : cand.slice(0, Math.max(0, cap - got.length));
      if (take.length) steps = d;
      for (const x of take) hit.add(x.cell);
      got.push(...take); frontier = take.map(x => x.c);
    }
    for (const c of frontier) if (cellOf(c) >= 0 && !cells.has(cellOf(c)) && ((dir === 'up' ? C.writers : C.readers).get(cellOf(c)) || []).some(id => !seen.has(id) && ok(C.list[id]))) stopped++;
    return { got, rejected, steps, stopped, cells: hit.size };
  };
  const coreDrawn = core.slice(0, STITCH_CAP.core);
  const upAll = walk(core, 'up', null), downAll = walk(core, 'down', null);
  const up = walk(coreDrawn, 'up', STITCH_CAP.up), down = walk(coreDrawn, 'down', STITCH_CAP.down);
  return {
    what, core, coreDrawn, up: up.got, down: down.got, steps: { up: up.steps, down: down.steps },
    rejected: { up: upAll.rejected, down: downAll.rejected },
    total: { core: core.length, up: upAll.got.length, down: downAll.got.length, upSteps: upAll.steps, downSteps: downAll.steps, upCells: upAll.cells, downCells: downAll.cells, upStopped: upAll.stopped, downStopped: downAll.stopped },
  };
}
// How each far end of one side finishes: { boundary, stopped, unwritten, rejoin, capped, other } counts plus boundary labels.
function sideEnds(M, R, side) {
  const C = chainIndex(M), list = side === 'up' ? R.up : R.down, parents = new Set(list.map(e => e.parent));
  const leaves = list.filter(e => !parents.has(e.c.id));
  const drawnIds = new Set([...R.coreDrawn, ...list.map(e => e.c)].map(c => c.id));
  for (const c of R.coreDrawn) if (!parents.has(c.id)) leaves.push({ c, depth: 0 });
  const out = { boundary: 0, stopped: 0, unwritten: 0, rejoin: 0, capped: 0, other: 0 };
  for (const { c, depth } of leaves) {
    const cell = side === 'up' ? c.srcCell : c.dstCell, end = chainEnds(M, c)[side === 'up' ? 'src' : 'dst'];
    if (cell < 0) { if (end.kind === 'boundary') out.boundary++; else out.other++; continue; }
    const next = ((side === 'up' ? C.writers : C.readers).get(cell) || []).map(id => C.list[id]);
    if (!next.length) out.unwritten++;
    else if (next.every(n => drawnIds.has(n.id))) out.rejoin++;
    else if (depth >= STITCH_STEPS) out.stopped++;
    else out.capped++;
  }
  return out;
}
// The drawn strands as a graph of tree segments ('tree:segment'), linked in data-flow order along each chain and,
// at a cell junction, from the writing chain's last segment to every reading chain's first.
function strandGraph(M, R) {
  const entries = [...R.coreDrawn.map(c => ({ c, role: 'core' })), ...R.up.map(e => Object.assign({ role: 'up' }, e)), ...R.down.map(e => Object.assign({ role: 'down' }, e))];
  const segs = new Map(), next = new Map(), prev = new Map(), jlinks = [];
  const add = (map, k, v) => { let s = map.get(k); if (!s) map.set(k, s = new Set()); s.add(v); };
  const link = (a, b) => { add(next, a, b); add(prev, b, a); };
  const outs = new Map(), ins = new Map();
  for (const e of entries) {
    const c = e.c, ss = c.x.segs;
    for (let i = 0; i < ss.length; i++) { const key = c.t + ':' + ss[i]; segs.set(key, { t: c.t, s: ss[i] }); if (i) link(c.t + ':' + ss[i - 1], key); }
    if (!ss.length) continue;
    if (c.dstCell >= 0) add(outs, c.dstCell, JSON.stringify([c.id, c.t + ':' + ss[ss.length - 1], c.t, M.br.trees[c.t].dir === 'forward' ? c.x.point : M.br.trees[c.t].rootPt]));
    if (c.srcCell >= 0) add(ins, c.srcCell, JSON.stringify([c.id, c.t + ':' + ss[0], c.t, M.br.trees[c.t].dir === 'forward' ? M.br.trees[c.t].rootPt : c.x.point]));
  }
  const junctions = [], C = chainIndex(M);
  for (const [cell, os] of outs) {
    const is = ins.get(cell); if (!is) continue;
    const readers = [...is].map(s => JSON.parse(s)), writers = [...os].map(s => JSON.parse(s)), links = [];
    for (const [wi, a, wt, wp] of writers) for (const [ri, b, rt, rp] of readers) {
      const compat = stitchCompat(M, C.list[wi], C.list[ri], cell);
      if (!STITCH_COMPAT[compat].draw) continue;
      link(a, b); const j = { a, b, cell, compat, from: { t: wt, point: wp }, to: { t: rt, point: rp } }; jlinks.push(j); links.push(j);
    }
    if (links.length) junctions.push({ cell, at: readers.map(([, , t, point]) => ({ t, point })), links });
  }
  return { entries, segs, next, prev, jlinks, junctions };
}
function touchSet(M, G, what) {
  const out = new Set();
  for (const [key, { t, s }] of G.segs) if (segTouches(M.br.trees[t], M.br.trees[t].segs[s], what)) out.add(key);
  if (what.ci != null) for (const e of G.entries) {
    const c = e.c, ss = c.x.segs; if (!ss.length) continue;
    if (c.dstCell === what.ci) out.add(c.t + ':' + ss[ss.length - 1]);
    if (c.srcCell === what.ci) out.add(c.t + ':' + ss[0]);
  }
  return out;
}
function reachSegs(start, map) {
  const seen = new Set(start), q = [...start];
  while (q.length) { const k = q.pop(); for (const j of map.get(k) || []) if (!seen.has(j)) { seen.add(j); q.push(j); } }
  return seen;
}
// Two points on the strands. A directed path in this graph is one chain, or chains stitched at cells, so the
// segments on a path from the earlier point to the later are strong, and upstream of the earlier and downstream of the
// later, every branch, are the continuations. Which point is earlier comes only from the graph. When no path joins
// them, earlier is null, and shared holds the segments upstream of both: on sibling branches, their shared origin.
function connectStrands(M, G, X, Y) {
  const xs = touchSet(M, G, X), ys = touchSet(M, G, Y), strong = new Set();
  if (!xs.size || !ys.size) return { strong, faint: new Set(), shared: new Set(), earlier: null };
  const meet = (a, b) => { const f = reachSegs(a, G.next), bk = reachSegs(b, G.prev); for (const k of f) if (bk.has(k)) strong.add(k); return strong.size > 0; };
  const earlier = meet(xs, ys) ? 'x' : meet(ys, xs) ? 'y' : null;
  if (!earlier) {
    const ux = reachSegs(xs, G.prev), uy = reachSegs(ys, G.prev), shared = new Set([...ux].filter(k => uy.has(k) && !xs.has(k) && !ys.has(k)));
    return { strong, faint: new Set(), shared, earlier, xs, ys };
  }
  const [E, L] = earlier === 'x' ? [xs, ys] : [ys, xs];
  const faint = new Set();
  for (const k of reachSegs(E, G.prev)) if (!strong.has(k)) faint.add(k);
  for (const k of reachSegs(L, G.next)) if (!strong.has(k)) faint.add(k);
  return { strong, faint, shared: new Set(), earlier, xs, ys };
}
// Segments in data-flow order (Kahn's algorithm; segments on a cycle follow in key order).
function flowOrder(G, keys) {
  const set = new Set(keys), indeg = new Map();
  for (const k of set) { let d = 0; for (const p of G.prev.get(k) || []) if (set.has(p)) d++; indeg.set(k, d); }
  const ready = [...set].filter(k => !indeg.get(k)).sort(), out = [], done = new Set();
  while (ready.length) {
    const k = ready.shift(); out.push(k); done.add(k);
    const nx = [...(G.next.get(k) || [])].filter(j => set.has(j)).sort();
    for (const j of nx) { indeg.set(j, indeg.get(j) - 1); if (!indeg.get(j)) ready.push(j); }
  }
  for (const k of [...set].sort()) if (!done.has(k)) out.push(k);
  return out;
}
