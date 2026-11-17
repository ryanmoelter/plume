// node check.js <built.html> <d3.min.js> [svgOutDir] [previousRoundBuilt.html]
const fs = require('fs'), vm = require('vm');
const [html, d3path, svgDir, prevHtml] = process.argv.slice(2);
const d3src = fs.readFileSync(d3path, 'utf8');
function load(file) {
  const src = fs.readFileSync(file, 'utf8');
  const scripts = [...src.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
  if (scripts.length !== 1) throw new Error('expected one inline script, got ' + scripts.length);
  new vm.Script(scripts[0]);
  const ctx = { module: { exports: {} }, console };
  vm.createContext(ctx);
  vm.runInContext(d3src, ctx);
  vm.runInContext(scripts[0] + '\n;globalThis.__D = D;', ctx);
  return { X: ctx.module.exports, D: ctx.__D, src };
}
const { X, D, src } = load(html);
const EPS = 1e-6;
const fail = m => { throw new Error(m); };
const WRITE = D.traces.findIndex(t => t.name.startsWith('write'));

function baseState(o) {
  return Object.assign({ ckinds: new Set(['module', 'package']), infra: 'inline', layers: new Set([0, 1, 2, 3, 4]), kinds: new Set(['call', 'di', 'cellRead', 'cellWrite', 'navigation']),
    hopKinds: new Set(['call', 'di', 'cellRead', 'cellWrite']), hops: 1, focusOn: true, compact: false, trace: -1, iso: new Set(),
    dir: 'both', skipHubs: true, hubMin: null, synth: 'shrink', ctx: 'hops', budget: 30 }, o);
}
function run(S, data) {
  const M = X.prepare(data || D);
  const V = X.visibility(M, S);
  const o = X.layoutOpts(V);
  return { M, V, S, P: X.packLayout(M, V.tree, o), PT: X.packLayout(M, V.tree, Object.assign({ flat: true }, o)), SL: X.sideLayout(M, V.tree, o) };
}
const fx = p => (p ? p.map(v => v.toFixed(3)).join(',') : '-');
const sig = r => r.M.nodes.map(n => fx(r.P.pos.get(n)) + '/' + fx(r.SL.pos.get(n)) + '/' + fx(r.PT.pos.get(n))).join(';');
// The flat top layout: no two node circles overlap on its one plane, whatever their layers.
function checkFlat(r) {
  let bad = 0;
  const { M, V, PT } = r, rad = V.rad;
  for (const c of V.tree.all) {
    const rc = PT.cont.get(c); if (!rc || !rc.R) continue;
    const kids = c.kids.map(k => PT.cont.get(k)).filter(k => k && k.R);
    for (const k of kids) if (Math.hypot(k.x - rc.x, k.z - rc.z) + k.R > rc.R + EPS) bad++;
    for (let i = 0; i < kids.length; i++) for (let j = i + 1; j < kids.length; j++)
      if (Math.hypot(kids[i].x - kids[j].x, kids[i].z - kids[j].z) < kids[i].R + kids[j].R - EPS) bad++;
  }
  const ns = M.nodes.filter(n => PT.pos.has(n)).map(n => ({ n, p: PT.pos.get(n), r: rad(n) })).sort((a, b) => a.p[0] - b.p[0]);
  for (let i = 0; i < ns.length; i++) {
    for (let j = i + 1; j < ns.length && ns[j].p[0] - ns[i].p[0] < ns[i].r + ns[j].r; j++)
      if (Math.hypot(ns[i].p[0] - ns[j].p[0], ns[i].p[1] - ns[j].p[1]) < ns[i].r + ns[j].r - EPS) bad++;
    if (!V.pillar(ns[i].n)) for (const anc of ns[i].n.ancBy[V.tk]) { const rc = PT.cont.get(anc); if (Math.hypot(ns[i].p[0] - rc.x, ns[i].p[1] - rc.z) + ns[i].r > rc.R + EPS) bad++; }
  }
  return bad;
}

function checkPack(r) {
  let bad = 0;
  const { M, V, P, S } = r, rad = V.rad;
  for (const c of V.tree.all) {
    const rc = P.cont.get(c); if (!rc || !rc.R) continue;
    const kids = c.kids.map(k => P.cont.get(k)).filter(k => k && k.R);
    for (const k of kids) if (Math.hypot(k.x - rc.x, k.z - rc.z) + k.R > rc.R + EPS) bad++;
    for (let i = 0; i < kids.length; i++) for (let j = i + 1; j < kids.length; j++)
      if (Math.hypot(kids[i].x - kids[j].x, kids[i].z - kids[j].z) < kids[i].R + kids[j].R - EPS) bad++;
  }
  for (let s = 0; s < 5; s++) {
    const ns = M.nodes.filter(n => n.slot === s && P.pos.has(n));
    for (let i = 0; i < ns.length; i++) {
      const a = P.pos.get(ns[i]);
      for (let j = i + 1; j < ns.length; j++) { const b = P.pos.get(ns[j]); if (Math.hypot(a[0] - b[0], a[1] - b[1]) < rad(ns[i]) + rad(ns[j]) - EPS) bad++; }
      if (!V.pillar(ns[i])) for (const anc of ns[i].ancBy[V.tk]) {
        const rc = P.cont.get(anc); if (Math.hypot(a[0] - rc.x, a[1] - rc.z) + rad(ns[i]) > rc.R + EPS) bad++;
      }
    }
  }
  return bad;
}
function checkSide(r) {
  let bad = 0;
  const { M, V, SL, S } = r, rad = V.rad;
  for (const c of V.tree.all) {
    const rc = SL.cont.get(c); if (!rc || !rc.w) continue;
    const kids = c.kids.map(k => SL.cont.get(k)).filter(k => k && k.w);
    for (const k of kids) if (k.x0 < rc.x0 - EPS || k.x1 > rc.x1 + EPS) bad++;
    for (let i = 0; i < kids.length; i++) for (let j = i + 1; j < kids.length; j++)
      if (kids[i].x0 < kids[j].x1 - EPS && kids[j].x0 < kids[i].x1 - EPS) bad++;
    if (rc.ownX0 != null) for (const k of kids) if (rc.ownX0 < k.x1 - EPS && k.x0 < rc.ownX1 - EPS) bad++;
  }
  for (let s = 0; s < 5; s++) {
    const ns = M.nodes.filter(n => n.slot === s && SL.pos.has(n));
    for (let i = 0; i < ns.length; i++) {
      const a = SL.pos.get(ns[i]);
      if (a[1] - rad(ns[i]) < SL.bandY[s] - EPS || a[1] + rad(ns[i]) > SL.bandY[s] + SL.bandH[s] + 12 + EPS) bad++;
      for (let j = i + 1; j < ns.length; j++) { const b = SL.pos.get(ns[j]); if (Math.hypot(a[0] - b[0], a[1] - b[1]) < rad(ns[i]) + rad(ns[j]) - EPS) bad++; }
      if (!V.pillar(ns[i])) for (const anc of ns[i].ancBy[V.tk]) { const rc = SL.cont.get(anc); if (!rc.w) continue; if (a[0] - rad(ns[i]) < rc.x0 - EPS || a[0] + rad(ns[i]) > rc.x1 + EPS) bad++; }
    }
  }
  return bad;
}
function checkAll(S, label) {
  const a = run(S), b = run(S);
  if (sig(a) !== sig(b)) fail('nondeterministic ' + label);
  const pb = checkPack(a), sb = checkSide(a), tb = checkFlat(a);
  const unpos = a.M.nodes.filter(n => a.V.shown(n) && (!a.P.pos.has(n) || !a.SL.pos.has(n) || !a.PT.pos.has(n))).length;
  if (pb || sb || tb || unpos) fail(`overlap/placement pack=${pb} side=${sb} top=${tb} unpositioned=${unpos} ${label}`);
  if (a.V.path) for (const ix of a.V.path) { const n = a.M.nodes[ix]; if (!a.V.shown(n) || !a.P.pos.has(n) || !a.SL.pos.has(n) || !a.PT.pos.has(n) || a.V.pillar(n)) fail(`path node lost ${n.n} ${label}`); }
  return a;
}

let combos = 0;
const KINDS = D.containerKinds, kindSets = [];
for (let m = 0; m < 1 << KINDS.length; m++) kindSets.push(new Set(KINDS.filter((k, i) => m & (1 << i))));
console.log('container kinds from the export:', KINDS.join(', '));
if (!process.env.QUICK) for (const ckinds of kindSets) for (const infra of ['inline', 'pillar', 'hide']) for (const trace of [-1, WRITE]) for (const compact of [false, true]) for (const synth of ['shrink', 'show', 'hide']) {
  const label = [...ckinds].join('+') || 'none';
  const a = checkAll(baseState({ ckinds, infra, trace, compact, synth }), JSON.stringify({ label, infra, trace, compact, synth })); combos++;
  if (synth === 'shrink' && infra === 'inline' && !compact) {
    const t = a.V.tree, kinds = {}; for (const c of t.all) kinds[c.kind] = (kinds[c.kind] || 0) + 1;
    console.log(`${label.padEnd(31)} trace=${String(trace).padStart(2)}  containers ${String(t.all.length).padStart(3)} depth ${t.maxDepth}${t.lifted.length ? ' lifted ' + t.lifted.join(' › ') : ''}  packR ${a.P.extent.toFixed(0)}  side ${a.SL.box.maxX.toFixed(0)}x${a.SL.top.toFixed(0)}  ${trace < 0 ? JSON.stringify(kinds) : ''}  ok`);
  }
}
// focus: every path node kept, under every hop, direction, hub, infrastructure, generated and compact setting
if (!process.env.QUICK) for (let t = 0; t < D.traces.length; t++) for (const hops of [0, 1, 2, 3]) for (const dir of ['both', 'down', 'up']) for (const skipHubs of [true, false]) for (const infra of ['inline', 'hide']) for (const synth of ['shrink', 'hide']) for (const compact of [false, true]) {
  checkAll(baseState({ trace: t, hops, dir, skipHubs, infra, synth, compact }), `focus ${t} ${hops} ${dir} ${skipHubs} ${infra} ${synth} ${compact}`); combos++;
}
// context rules: budgeted at several budgets, and state only, with and without value edges
if (!process.env.QUICK) for (let t = 0; t < D.traces.length; t++) for (const ctx of ['budget', 'state']) for (const budget of ctx === 'budget' ? [0, 10, 30, 120] : [30]) for (const valueEdges of [false, true]) for (const compact of [false, true]) for (const synth of ['shrink', 'hide']) {
  const hopKinds = new Set(['call', 'di', 'cellRead', 'cellWrite', ...(valueEdges ? ['value'] : [])]);
  const a = checkAll(baseState({ trace: t, ctx, budget, hopKinds, compact, synth }), `ctx ${t} ${ctx} ${budget} ${valueEdges} ${compact} ${synth}`); combos++;
  if (ctx === 'budget' && a.V.dist.size > new Set(a.V.path).size + budget) fail(`budget exceeded ${t} ${budget}`);
}
console.log(`${combos} combinations: deterministic, no overlap, every shown node placed, every path node kept, budgets respected`);

// branch trees: at level 1, clean on and off, every tree's nodes kept and placed with no overlap, deterministically
{
  const MB = X.prepare(D), trees = MB.br.trees;
  let n = 0, t0 = Date.now();
  for (const T of trees) for (const clean of [true, false]) for (const compact of T.i % 4 ? [false] : [false, true]) {
    const a = checkAll(baseState({ root: T.i, branch: 1, focus: 'tree', ctx: T.i % 2 ? 'none' : 'budget', clean, sinks: false, compact }), `tree ${T.i} clean=${clean} compact=${compact}`);
    for (const ix of a.V.tv.nodes) if (!a.V.onPath.has(ix)) fail(`tree node not on core ${T.i} ${ix}`);
    n++;
  }
  // with an endpoint at level 0 and level 1, and with sinks on, for every tenth tree
  for (const T of trees.filter(T => T.i % 10 === 0)) for (const branch of [0, 1, 2]) {
    const tv = X.treeView(T, { clean: false, sinks: true, endpoint: -1 });
    const ep = tv.terms.length ? T.terms[tv.terms[tv.terms.length - 1]].point : -1;
    for (const focus of [null, 'tree', 'strand']) { checkAll(baseState({ root: T.i, branch, focus, clean: false, sinks: true, endpoint: ep }), `tree ${T.i} level ${branch} focus ${focus} endpoint ${ep}`); n++; }
  }
  // a highlight never moves anything: choosing a root and an endpoint without a focus leaves the layout as it was
  for (const compact of [false, true]) for (const trace of [-1, WRITE]) {
    const base = sig(run(baseState({ trace, compact })));
    for (const T of trees.filter(T => T.i % 20 === 0)) {
      const ep = T.terms.length ? T.terms[0].point : -1;
      const r = run(baseState({ trace, compact, root: T.i, endpoint: ep, branch: 2 }));
      if (sig(r) !== base) fail(`highlight moved the layout ${T.i} compact=${compact} trace=${trace}`);
      if (r.V.focus) fail('highlight set a focus');
    }
  }
  console.log('highlight only: a chosen root and endpoint without a focus leave every position unchanged');
  console.log(`branch trees: ${trees.length} trees, ${n} combinations at level 1 (clean on/off, compact on every fourth) and with endpoints: every tree node kept, no overlap, deterministic (${((Date.now() - t0) / 1000).toFixed(1)} s)`);

  // chains: for 5 sample trees, every terminal's segments run root to terminal without a gap
  const big = trees.slice().sort((a, b) => b.terms.length - a.terms.length || a.i - b.i);
  const pick = [big[0], big[1], trees.find(T => T.kind === 'boundary'), trees.find(T => T.kind === 'traceEnd' && T.dir === 'forward'), trees.find(T => T.dir === 'backward')].filter(Boolean);
  let chains = 0;
  for (const T of pick) for (const term of T.terms) {
    const ch = term.segs;
    if (!ch.length) { if (term.point !== T.rootPt) fail(`empty chain ${T.i} ${term.point}`); continue; }
    const [from, to] = T.dir === 'forward' ? [T.rootPt, term.point] : [term.point, T.rootPt];
    if (T.segs[ch[0]].a !== from) fail(`chain does not start at its upstream end ${T.i} ${term.point}`);
    for (let k = 0; k + 1 < ch.length; k++) if (T.segs[ch[k]].b !== T.segs[ch[k + 1]].a) fail(`chain gap ${T.i} ${term.point} at ${k}`);
    if (T.segs[ch[ch.length - 1]].b !== to) fail(`chain does not end at its downstream end ${T.i} ${term.point}`);
    const tv = X.treeView(T, { clean: false, sinks: true, endpoint: term.point });
    if (tv.strandNodes[0] !== T.rootNode && T.rootNode >= 0) fail(`strand does not start at root node ${T.i}`);
    const last = T.pt.node[term.point];
    if (last >= 0 && !tv.strandNodes.includes(last)) fail(`strand misses terminal node ${T.i} ${term.point}`);
    for (const x of tv.strandNodes) if (!tv.nodes.includes(x)) fail(`strand node outside tree ${T.i}`);
    chains++;
  }
  console.log(`chains: ${chains} terminals in ${pick.length} sample trees each connect root and terminal in data-flow order, and the strand stays inside the tree`);

  // strands through: ranked clean first, then cost, deterministic, and every listed chain really touches the member
  {
    const ix = X.strandIndex(MB);
    let tested = 0;
    for (const [m] of [...ix.byMem.entries()].filter((e, i) => i % 97 === 0).slice(0, 40)) {
      const r = X.strandsThrough(MB, { member: m });
      for (let k = 1; k < r.chains.length; k++) { const a = r.chains[k - 1].x, b = r.chains[k].x; if (a.clean < b.clean || (a.clean === b.clean && X.costCmp(a.cost, b.cost) > 0)) fail('strand rank order ' + m); }
      for (const c of r.chains) { const T = trees[c.tree]; const t = T.terms[c.term]; const touch = [T.rootPt, t.point, ...t.segs.flatMap(s => [T.segs[s].a, T.segs[s].b])].some(p => T.pt.m[p] === m) || t.segs.some(s => T.segs[s].members.includes(m)); if (!touch) fail('strand does not touch member ' + m); }
      tested++;
    }
    const sizes = [...ix.byMem.values()].map(a => a.length).sort((a, b) => a - b);
    console.log(`strands through: ${ix.byMem.size} members and ${ix.byNode.size} classes on some chain; per member median ${sizes[sizes.length >> 1]} max ${sizes[sizes.length - 1]}; ${tested} sampled members ranked and touching`);
  }
  // kept nodes for representative roots
  const reps = [big[0], trees.find(T => T.kind === 'cell' && T.terms.length > 20 && T !== big[0]), trees.find(T => T.kind === 'boundary' && T.terms.length > 5), trees.find(T => T.kind === 'traceEnd' && T.dir === 'forward'), trees.find(T => T.kind === 'traceEnd' && T.dir === 'backward')].filter(Boolean);
  for (const T of reps) {
    const row = [];
    for (const [clean, sinks] of [[true, false], [false, false], [false, true]]) {
      const tv = X.treeView(T, { clean, sinks, endpoint: -1 });
      const ep = tv.terms.length ? T.terms[tv.terms[0]].point : -1;
      const tv0 = X.treeView(T, { clean, sinks, endpoint: ep });
      const k1 = run(baseState({ root: T.i, branch: 1, focus: 'tree', ctx: 'none', clean, sinks })).V.onPath.size;
      const k0 = run(baseState({ root: T.i, branch: 0, focus: 'strand', ctx: 'none', clean, sinks, endpoint: ep })).V.onPath.size;
      const st = X.siblingStubs(T, tv, 30), st0 = X.siblingStubs(T, tv0, 30);
      const kb = run(baseState({ root: T.i, branch: 1, focus: 'tree', clean, sinks, ctx: 'budget', budget: 30 })).V.dist.size;
      row.push(`${clean ? 'clean' : 'all'}${sinks ? '+sinks' : ''}: L0 ${k0} L1 ${k1} (+budget30 ${kb}) L2 stubs ${st0.total} on strand / ${st.total} on tree; endpoints ${tv.counts.shown}/${tv.counts.total}`);
    }
    console.log(`kept #${T.i} ${T.kind} ${T.dir} "${T.label.slice(0, 60)}": ${row.join(' | ')}`);
  }
}

if (process.env.QUICK) process.exit(0);
// members: every node's members inside its unit circle, own members never overlap, rings sit on their host, repeatable
{
  const MM = X.prepare(D), M2 = X.prepare(D);
  let nodesWith = 0, items = 0, rings = 0, bad = 0, maxN = 0;
  for (let i = 0; i < MM.nodes.length; i++) {
    const L = X.memberLayout(MM, i), L2 = X.memberLayout(M2, i);
    if (JSON.stringify(L) !== JSON.stringify(L2)) fail('member layout nondeterministic ' + i);
    if (!L.items.length) continue;
    nodesWith++; items += L.items.length; rings += L.rings.length; maxN = Math.max(maxN, L.items.length);
    for (const c of L.items) if (Math.hypot(c.x, c.y) + c.r > 1 + 1e-6) bad++;
    const its = L.items.slice().sort((a, b) => a.x - b.x);
    for (let p = 0; p < its.length; p++) for (let q = p + 1; q < its.length && its[q].x - its[p].x < its[p].r + its[q].r; q++)
      if (Math.hypot(its[p].x - its[q].x, its[p].y - its[q].y) < its[p].r + its[q].r - 1e-6) bad++;
  }
  if (bad) fail('member overlap/escape ' + bad);
  const total = MM.mem.n.length;
  console.log(`members: ${total} total, ${items} packed + ${rings} cell rings in ${nodesWith} nodes (max ${maxN} in one node), all inside, no overlap, deterministic; unplaced ${total - items - rings}`);
}

const M = X.prepare(D), HK = new Set(['call', 'di', 'cellRead', 'cellWrite']);
const deg = X.degrees(M, HK);
console.log(`hub threshold (p90 of distinct neighbours over call, di, cellRead, cellWrite): ${deg.p90}; max ${Math.max(...deg)}; hubs ${deg.filter(d => d > deg.p90).length}`);
for (let t = 0; t < D.traces.length; t++) {
  const path = X.tracePath(D.traces[t]).map(s => s.ix);
  const pathHubs = new Set(path).size + ' path nodes, ' + [...new Set(path)].filter(i => deg[i] > deg.p90).length + ' hubs';
  const row = [];
  for (const dir of ['both', 'down', 'up']) {
    const cell = [1, 2, 3].map(h => {
      const off = X.neighbourhood(M, path, h, HK, { dir }).size, on = X.neighbourhood(M, path, h, HK, { dir, skipHubs: true });
      return `${off}->${on.size}`;
    });
    row.push(`${dir} ${cell.join(' ')}`);
  }
  console.log(`kept ${D.traces[t].name} (${pathHubs}) hops 1/2/3, hubs off->on: ${row.join(' | ')}`);
}

// path weighting in compact mode: the path's extent, unweighted vs weighted
for (let t = 0; t < D.traces.length; t++) {
  const out = [];
  for (const weightPath of [false, true]) {
    const r = run(baseState({ trace: t, compact: true, weightPath }));
    const ps = [...r.V.onPath].map(i => r.M.nodes[i]);
    const xs = ps.map(n => r.SL.pos.get(n)[0]);
    const W = r.SL.box.maxX - r.SL.box.minX, pw = Math.max(...xs) - Math.min(...xs);
    const rootR = r.P.cont.get(r.V.tree).R;
    const dc = ps.reduce((a, n) => { const p = r.P.pos.get(n); return a + Math.hypot(p[0], p[1]); }, 0) / ps.length;
    let span = 0; for (const a of ps) for (const b of ps) { const p = r.P.pos.get(a), q = r.P.pos.get(b); span = Math.max(span, Math.hypot(p[0] - q[0], p[1] - q[1])); }
    const fR = r.PT.cont.get(r.V.tree).R;
    let fspan = 0; for (const a of ps) for (const b of ps) { const p = r.PT.pos.get(a), q = r.PT.pos.get(b); fspan = Math.max(fspan, Math.hypot(p[0] - q[0], p[1] - q[1])); }
    const fdc = ps.reduce((a, n) => { const p = r.PT.pos.get(n); return a + Math.hypot(p[0], p[1]); }, 0) / ps.length;
    out.push(`side path ${pw.toFixed(0)}/${W.toFixed(0)} = ${(100 * pw / W).toFixed(0)}%, 3D path span ${(100 * span / (2 * rootR)).toFixed(0)}% of diameter, mean centre distance ${(100 * dc / rootR).toFixed(0)}% of R; flat top span ${(100 * fspan / (2 * fR)).toFixed(0)}%, centre ${(100 * fdc / fR).toFixed(0)}%`);
  }
  console.log(`compact ${D.traces[t].name}: unweighted ${out[0]}  ||  weighted ${out[1]}`);
}

// stability: grow one hand-written node by 40 lines, count the nodes that move, over a fixed sample
function moved(Xmod, S) {
  const sample = X.prepare(D).nodes.filter(n => n.s > 30 && !n.syn).filter((n, i) => i % 9 === 0).slice(0, 25).map(n => n.i);
  const lay = data => { const MM = Xmod.prepare(data), VV = Xmod.visibility(MM, S); const o = Xmod.layoutOpts ? Xmod.layoutOpts(VV, S) : { include: VV.include, pillar: VV.pillar, depth: S.depth }; return { MM, P: Xmod.packLayout(MM, VV.tree, o), SL: Xmod.sideLayout(MM, VV.tree, o) }; };
  const r1 = lay(D);
  const res = sample.map(v => {
    const D2 = JSON.parse(JSON.stringify(D)); D2.nodes[v].s += 40;
    const r2 = lay(D2);
    let mp = 0, ms = 0;
    r1.MM.nodes.forEach((n, i) => { const a = r1.P.pos.get(n), b = r2.P.pos.get(r2.MM.nodes[i]); if (a && b && Math.hypot(a[0] - b[0], a[1] - b[1]) > 1) mp++; const c = r1.SL.pos.get(n), d = r2.SL.pos.get(r2.MM.nodes[i]); if (c && d && Math.hypot(c[0] - d[0], c[1] - d[1]) > 1) ms++; });
    return { v, mp, ms };
  });
  const med = a => a.slice().sort((x, y) => x - y)[a.length >> 1];
  return { res, first: D.nodes[sample[0]].n, side: res.map(r => r.ms), pack: res.map(r => r.mp), med };
}
{
  // Round 2 and 3 drew module, source set and package; S.top and S.depth are what the older builds read.
  const S = baseState({ synth: 'show', ckinds: new Set(['module', 'sourceSet', 'package']), top: 'module', depth: 3 });
  const def = moved(X, baseState({ synth: 'show' }));
  console.log(`stability, default kinds module+package: side moved median ${def.med(def.side)}, max ${Math.max(...def.side)}; nested pack median ${def.med(def.pack)}, max ${Math.max(...def.pack)}`);
  const now = moved(X, S);
  console.log(`stability now, module+sourceSet+package (+40 loc, ${now.res.length} hand-written nodes): side moved median ${now.med(now.side)}, max ${Math.max(...now.side)}, zero in ${now.side.filter(x => !x).length}; nested pack median ${now.med(now.pack)}, max ${Math.max(...now.pack)}`);
  if (prevHtml) {
    const prev = load(prevHtml).X;
    const was = moved(prev, S);
    console.log(`stability round 2 (same nodes): side moved median ${was.med(was.side)}, max ${Math.max(...was.side)}, zero in ${was.side.filter(x => !x).length}; nested pack median ${was.med(was.pack)}, max ${Math.max(...was.pack)}`);
  }
  const D2 = JSON.parse(JSON.stringify(D)); const v = D2.nodes.findIndex(n => n.s > 50 && n.f >= 0); D2.nodes[v].s += 40;
  const a = run(S), b = run(S, D2);
  let ms = 0; a.M.nodes.forEach((n, i) => { const c = a.SL.pos.get(n), d = b.SL.pos.get(b.M.nodes[i]); if (Math.hypot(c[0] - d[0], c[1] - d[1]) > 1) ms++; });
  console.log(`stability, the round 2 test node (${D.nodes[v].n}): side moved ${ms} of ${D.nodes.length}`);
}
// displacement after +40 lines, as a fraction of view width (side: the band box width; top: the root diameter)
function displacement(S) {
  const sample = X.prepare(D).nodes.filter(n => n.s > 30 && !n.syn).filter((n, i) => i % 9 === 0).slice(0, 25).map(n => n.i);
  const r1 = run(S), W = r1.SL.box.maxX - r1.SL.box.minX, T = 2 * r1.P.cont.get(r1.V.tree).R, TF = 2 * r1.PT.cont.get(r1.V.tree).R;
  const side = [], top = [], flat = [];
  for (const v of sample) {
    const D2 = JSON.parse(JSON.stringify(D)); D2.nodes[v].s += 40;
    const r2 = run(S, D2);
    r1.M.nodes.forEach((n, i) => {
      const n2 = r2.M.nodes[i], a = r1.SL.pos.get(n), b = r2.SL.pos.get(n2), c = r1.P.pos.get(n), d = r2.P.pos.get(n2);
      if (a && b) side.push(Math.hypot(a[0] - b[0], a[1] - b[1]) / W);
      if (c && d) top.push(Math.hypot(c[0] - d[0], c[1] - d[1]) / T);
      const e = r1.PT.pos.get(n), f = r2.PT.pos.get(n2);
      if (e && f) flat.push(Math.hypot(e[0] - f[0], e[1] - f[1]) / TF);
    });
  }
  const q = (a, p) => { const s = a.slice().sort((x, y) => x - y); return s.length ? s[Math.min(s.length - 1, Math.floor(p * s.length))] : 0; };
  const fmt = a => { const m = a.filter(x => x > 1e-4); return `all median ${(100 * q(a, 0.5)).toFixed(2)}% p95 ${(100 * q(a, 0.95)).toFixed(2)}% max ${(100 * Math.max(...a)).toFixed(2)}%; moved only (${(100 * m.length / a.length).toFixed(1)}% of samples) median ${(100 * q(m, 0.5)).toFixed(2)}% p95 ${(100 * q(m, 0.95)).toFixed(2)}%`; };
  return `side ${fmt(side)} | 3D pack ${fmt(top)} | flat top ${fmt(flat)} | diameter 3D ${T.toFixed(0)} vs flat top ${TF.toFixed(0)} (${(100 * TF / T).toFixed(0)}%)`;
}
for (const ck of [['module', 'package'], ['package'], ['module', 'sourceSet', 'package', 'file']]) for (const compact of [false, true]) {
  const r = run(baseState({ ckinds: new Set(ck), trace: compact ? WRITE : -1, compact, ctx: 'budget' }));
  console.log(`top diameter ${ck.join('+')}${compact ? ' compact write' : ''}: 3D footprint ${(2 * r.P.cont.get(r.V.tree).R).toFixed(0)}, flat ${(2 * r.PT.cont.get(r.V.tree).R).toFixed(0)}`);
}
console.log('displacement, default layout:', displacement(baseState({})));
console.log('displacement, compact write trace (budgeted):', displacement(baseState({ trace: WRITE, compact: true, ctx: 'budget' })));

if (svgDir) {
  const theme = which => {
    const light = /:root \{([\s\S]*?)\n\}/.exec(src)[1], dark = /:root\[data-theme="dark"\] \{([\s\S]*?)\}/.exec(src)[1];
    const get = (block, k) => { const m = new RegExp(`--${k}:\\s*([^;]+);`).exec(block); return m && m[1].trim(); };
    const t = {}; for (const k of ['bg', 'ink', 'muted', 'accent', 'plane', 'cyl', 'edge', 'edge-strength', 'role-data']) t[k] = (which === 'dark' && get(dark, k)) || get(light, k);
    t.strength = parseFloat(t['edge-strength']); t.light = which === 'light';
    return t;
  };
  const hsl = (h, s, l) => `hsl(${(h * 360).toFixed(0)} ${(s * 100).toFixed(1)}% ${(l * 100).toFixed(1)}%)`;
  const ccol = g => {
    const hue = 0.17 + ((g.outer.sib * 0.618034) % 1) * 0.73;
    if (g.depth === 1) return hsl(hue, 0.5, 0.5);
    const t = ((g.order - g.outer.order) * 0.618034) % 1;
    return hsl(hue, 0.35 + 0.3 * t, 0.36 + 0.28 * ((t * 2.618) % 1));
  };
  const esc = s => String(s).replace(/[&<>]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
  const nodeStyle = (r, n, T) => {
    const on = r.V.onPath.has(n.i), muted = r.S.synth === 'shrink' && n.syn && !on;
    let op = r.V.dist ? (on ? 1 : [1, 0.5, 0.3, 0.2][r.V.dist.get(n.i)]) : r.V.path ? (on ? 1 : 0.16) : 0.7;
    if (muted) op = Math.min(op, 0.35);
    const g = X.groupAt(n, r.V.tk, Infinity, r.V.pillar);
    const fill = muted ? T['role-data'] : (g === 'root' || typeof g === 'string') ? '#8a96a3' : ccol(g);
    return `fill="${fill}" fill-opacity="${op}" ${on ? `stroke="${T.accent}" stroke-width="1.5" vector-effect="non-scaling-stroke"` : ''}`;
  };
  const edgesSvg = (r, T, pos2, grp) => {
    const out = [], { V, S, M } = r;
    if (V.dist || S.iso.size) {
      for (const [a, b, k] of M.edges) {
        if (!S.kinds.has(M.kinds[k])) continue;
        const na = M.nodes[a], nb = M.nodes[b]; if (!V.shown(na) || !V.shown(nb)) continue;
        const p = pos2(na), q = pos2(nb);
        out.push(`<line x1="${p[0].toFixed(1)}" y1="${p[1].toFixed(1)}" x2="${q[0].toFixed(1)}" y2="${q[1].toFixed(1)}" stroke="${T.edge}" stroke-opacity="${T.strength * X.EDGE_TIER[X.edgeTier(V, a, b)]}" stroke-width="1" vector-effect="non-scaling-stroke"/>`);
      }
      return out;
    }
    for (const B of X.bundles(M, V.tk, Infinity, V.shown, S.kinds, V.pillar)) {
      const p = grp(B.ga, B.sa), q = grp(B.gb, B.sb); if (!p || !q) continue;
      const mx = (p[0] + q[0]) / 2, my = (p[1] + q[1]) / 2 - (B.sa === B.sb ? 18 : 0);
      out.push(`<path d="M${p[0].toFixed(1)},${p[1].toFixed(1)} Q${mx.toFixed(1)},${my.toFixed(1)} ${q[0].toFixed(1)},${q[1].toFixed(1)}" fill="none" stroke="${T.edge}" stroke-opacity="${T.strength * (V.path ? 0.6 : 1)}" stroke-width="${Math.max(0.5, Math.min(0.32 * Math.sqrt(B.count), 4.4)).toFixed(2)}"/>`);
    }
    return out;
  };
  const pathSvg = (r, T, pos2) => {
    if (!r.V.path) return [];
    const pts = X.tracePath(D.traces[r.S.trace]).map(s => r.M.nodes[s.ix]).filter(n => r.V.shown(n)).map(pos2);
    return [`<polyline points="${pts.map(p => `${p[0].toFixed(1)},${p[1].toFixed(1)}`).join(' ')}" fill="none" stroke="${T.accent}" stroke-width="2" vector-effect="non-scaling-stroke" stroke-opacity="0.95"/>`];
  };
  const side = (name, S, T, frame) => {
    const r = run(S), SL = r.SL, depth = r.V.tree.maxDepth, ROW = 13, H = SL.top + ROW * (depth + 0.5);
    let x0 = SL.box.minX, x1 = SL.box.maxX;
    if (frame && r.V.path) { const xs = [...r.V.onPath].map(i => SL.pos.get(r.M.nodes[i])[0]); x0 = Math.min(...xs); x1 = Math.max(...xs); const m = Math.max(40, 0.25 * (x1 - x0)); x0 -= m; x1 += m; }
    const pad = 90, W = x1 - x0 + 20, fy = y => H - y;
    const out = [`<svg xmlns="http://www.w3.org/2000/svg" viewBox="${x0 - pad} -10 ${W + pad + 10} ${H + 20}" width="1600" height="${(1600 * (H + 20) / (W + pad + 10)).toFixed(0)}" style="background:${T.bg};font-family:Menlo,monospace"><rect x="${x0 - pad}" y="-10" width="${W + pad + 10}" height="${H + 20}" fill="${T.bg}"/>`];
    for (const s of X.SLOT_ORDER) { if (!SL.bandH[s]) continue; out.push(`<rect x="${x0 - 10}" y="${fy(SL.bandY[s] + SL.bandH[s] + 12)}" width="${W}" height="${SL.bandH[s] + 12}" fill="${T.plane}" opacity="${X.SLOT_ORDER.indexOf(s) % 2 ? 0.12 : 0.05}"/><text x="${x0 - 14}" y="${fy(SL.bandY[s] + SL.bandH[s] / 2 + 6)}" font-size="9" text-anchor="end" fill="${T.plane}">${['external', 'data', 'presentation', 'ui', 'unplaced'][s]}</text>`); }
    const shownCount = new Map();
    for (const n of r.M.nodes) if (r.V.shown(n)) for (const a of n.ancBy[r.V.tk]) shownCount.set(a, 1);
    for (const g of r.V.tree.all) {
      if (!shownCount.get(g)) continue;
      const rc = SL.cont.get(g); if (!rc.w) continue;
      const y1 = SL.top + ROW * (depth - g.depth + 1) - 2, inner = !g.kids.length;
      const cc = ccol(g);
      out.push(`<rect x="${rc.x0}" y="${fy(y1)}" width="${rc.w}" height="${y1 + 2}" fill="${inner ? cc : 'none'}" fill-opacity="0.05" stroke="${inner ? cc : T.cyl}" stroke-opacity="${inner ? 0.5 : 0.22}" stroke-width="0.6"/>`);
      if (rc.w > 14) out.push(`<text x="${rc.x0 + rc.w / 2}" y="${fy(SL.top + ROW * (depth - g.depth + 0.5)) + 3}" font-size="${Math.min(8, rc.w / Math.max(4, g.label.length) * 1.6)}" text-anchor="middle" fill="${inner ? T.ink : T.muted}">${esc(g.label)}</text>`);
    }
    const pos2 = n => { const p = SL.pos.get(n); return [p[0], fy(p[1])]; };
    const grp = (g, slot) => {
      const y = fy(SL.bandY[slot] + SL.bandH[slot] / 2 + 6);
      if (g === 'pillar') return [(SL.pillar.x0 + SL.pillar.x1) / 2, y];
      const rc = SL.cont.get(g === 'root' ? r.V.tree : g); return [g === 'root' ? (rc.ownX0 + rc.ownX1) / 2 : (rc.x0 + rc.x1) / 2, y];
    };
    out.push(...edgesSvg(r, T, pos2, grp));
    for (const n of r.M.nodes) if (r.V.shown(n)) { const p = pos2(n); out.push(`<circle cx="${p[0].toFixed(2)}" cy="${p[1].toFixed(2)}" r="${r.V.rad(n).toFixed(2)}" ${nodeStyle(r, n, T)}/>`); }
    out.push(...pathSvg(r, T, pos2), '</svg>');
    fs.writeFileSync(`${svgDir}/${name}.svg`, out.join('\n'));
  };
  const topView = (name, S, T, frame) => {
    const r = run(S), P = r.P;
    let cx = 0, cz = 0, R = P.box.maxX + 10;
    if (frame && r.V.path) {
      const ps = [...r.V.onPath].map(i => P.pos.get(r.M.nodes[i]));
      const xs = ps.map(p => p[0]), zs = ps.map(p => p[1]);
      cx = (Math.min(...xs) + Math.max(...xs)) / 2; cz = (Math.min(...zs) + Math.max(...zs)) / 2;
      const half = Math.max(Math.max(...xs) - Math.min(...xs), Math.max(...zs) - Math.min(...zs)) / 2; R = half + Math.max(30, 0.6 * half);
    }
    const out = [`<svg xmlns="http://www.w3.org/2000/svg" viewBox="${cx - R} ${cz - R} ${2 * R} ${2 * R}" width="1400" height="1400" style="background:${T.bg};font-family:Menlo,monospace"><rect x="${cx - R}" y="${cz - R}" width="${2 * R}" height="${2 * R}" fill="${T.bg}"/>`];
    const shownCount = new Map();
    for (const n of r.M.nodes) if (r.V.shown(n)) for (const a of n.ancBy[r.V.tk]) shownCount.set(a, 1);
    for (const g of r.V.tree.all) {
      if (!shownCount.get(g)) continue;
      const rc = P.cont.get(g); if (!rc.R) continue;
      const inner = !g.kids.length, cc = ccol(g);
      out.push(`<circle cx="${rc.x}" cy="${rc.z}" r="${rc.R}" fill="${inner ? cc : 'none'}" fill-opacity="0.07" stroke="${inner ? cc : T.cyl}" stroke-opacity="${inner ? 0.6 : 0.25}" stroke-width="0.8" vector-effect="non-scaling-stroke"/>`);
      if (rc.R > 12) out.push(`<text x="${rc.x}" y="${rc.z - rc.R + 7}" font-size="${inner ? 6 : 7}" text-anchor="middle" fill="${inner ? T.ink : T.muted}">${esc(g.label)}</text>`);
    }
    const pos2 = n => P.pos.get(n);
    const grp = g => { if (g === 'pillar') return [P.pillar.x, P.pillar.z]; const rc = P.cont.get(g === 'root' ? r.V.tree : g); return g === 'root' ? [rc.ownX, rc.ownZ] : [rc.x, rc.z]; };
    out.push(...edgesSvg(r, T, pos2, grp));
    for (const n of r.M.nodes) if (r.V.shown(n)) { const p = pos2(n); out.push(`<circle cx="${p[0].toFixed(2)}" cy="${p[1].toFixed(2)}" r="${r.V.rad(n).toFixed(2)}" ${nodeStyle(r, n, T)}/>`); }
    out.push(...pathSvg(r, T, pos2), '</svg>');
    fs.writeFileSync(`${svgDir}/${name}.svg`, out.join('\n'));
  };
  for (const th of ['light', 'dark']) {
    const T = theme(th);
    side(`side-all-${th}`, baseState({}), T);
    side(`side-write-1hop-${th}`, baseState({ trace: WRITE }), T);
    side(`side-write-compact-${th}`, baseState({ trace: WRITE, compact: true }), T, true);
    topView(`top-all-${th}`, baseState({}), T);
    topView(`top-write-compact-${th}`, baseState({ trace: WRITE, compact: true }), T, true);
  }
  const all = new Set(KINDS), noSs = new Set(KINDS.filter(k => k !== 'sourceSet'));
  side('side-kinds-all-light', baseState({ ckinds: all }), theme('light'));
  side('side-kinds-file-write-compact-light', baseState({ ckinds: noSs, trace: WRITE, compact: true }), theme('light'), true);
  topView('top-kinds-all-light', baseState({ ckinds: all }), theme('light'));
  topView('top-kinds-package-only-light', baseState({ ckinds: new Set(['package']) }), theme('light'));
  topView('top-kinds-none-light', baseState({ ckinds: new Set() }), theme('light'));
  side('side-write-compact-unweighted-light', baseState({ trace: WRITE, compact: true, weightPath: false }), theme('light'));
  side('side-write-compact-full-light', baseState({ trace: WRITE, compact: true }), theme('light'));
  console.log('svgs written to', svgDir);
}
