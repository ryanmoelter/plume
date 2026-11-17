// Hop records and cell links. A stitch's compat comes per writer chain and reader chain of a cell: match when one
// access path is a prefix of the other, mismatch when they name different fields, unknown otherwise. A backward
// chain that reads the cell has no access path in the export, so its stitches are unknown.
let BR_HOPS = null;
const STITCH_CODE = { m: 'match', x: 'mismatch', u: 'unknown' };
function prepareHopsAndLinks(data, B) {
  const strs = data.strs || [], H = { n: 0, kind: [], site: [], fm: [], tm: [], fv: [], tv: [], x: [], note: [] };
  for (const [k, s, fm, tm, fv, tv, x, note] of B.hops || []) {
    H.kind.push(strs[k]); H.site.push(strs[s]); H.fm.push(fm); H.tm.push(tm); H.fv.push(fv); H.tv.push(tv); H.x.push(x); H.note.push(strs[note] || '');
  }
  H.n = H.kind.length; BR_HOPS = H;
  const stitch = Object.create(null), stitchInfo = Object.create(null), cellAny = new Set();
  for (const L of B.links || []) {
    if (L.i) cellAny.add(L.c);
    L.w.forEach((w, wi) => {
      if (!w) return;
      const wa = strs[L.wa[wi]] || '';
      L.rc.forEach((r, ri) => {
        if (!r) return;
        const key = w[0] + ':' + w[1] + '>' + r[0] + ':' + r[1];
        stitch[key] = STITCH_CODE[(L.cp[wi] || '')[ri]] || 'unknown';
        stitchInfo[key] = { wa, ra: strs[L.ra[ri]] || '', any: !!L.i, cell: L.c };
      });
      for (const r of L.rd) {
        const key = w[0] + ':' + w[1] + '>' + r[0] + ':' + r[1];
        if (!stitch[key]) { stitch[key] = 'unknown'; stitchInfo[key] = { wa, ra: null, any: !!L.i, cell: L.c }; }
      }
    });
  }
  return { hops: H, stitch, stitchInfo, cellAny, hopDetailDropped: !!B.hopDetailDropped };
}
const HOP_BITS = [[1, 'anyContainer'], [2, 'fieldMismatch'], [4, 'nonProduction'], [8, 'unmatchedReturn']];
// Variables, column-wise like members. byMem lists a member's own variables; a local cell member's variables are
// listed under the function the cell lives in too, since that is where they are declared.
const VAR_RANK_ORDER = { stateRead: 0, eventCapture: 1, output: 2, other: 3 };
function prepareVars(data, mem) {
  const rows = data.vars || [], kinds = data.varKinds || [], ranks = data.varRanks || [];
  const V = { N: rows.length, m: [], kind: [], name: [], line: [], lam: [], rank: [], fl: [], lbl: [], type: [], cap: [], byMem: new Map(), lambdas: data.lambdas || [] };
  rows.forEach(([m, k, n, l, lam, r, fl, lbl, t, cap], i) => {
    V.m.push(m); V.kind.push(kinds[k]); V.name.push(n); V.line.push(l); V.lam.push(lam); V.rank.push(ranks[r]); V.fl.push(fl); V.lbl.push(lbl || ''); V.type.push(t || ''); V.cap.push(cap || 0);
    if (m < 0) return;
    const put = x => { let a = V.byMem.get(x); if (!a) V.byMem.set(x, a = []); a.push(i); };
    put(m);
    if (mem.kind[m] === 'cell' && mem.p[m] >= 0) put(mem.p[m]);
  });
  // The member a variable is shown under: a local cell's function, else its own member.
  V.home = i => { const m = V.m[i]; return m >= 0 && mem.kind[m] === 'cell' && mem.p[m] >= 0 ? mem.p[m] : m; };
  return V;
}
// Segments whose hops name a variable, as [tree, segment] pairs; built once.
function varSegs(M, v) {
  if (!M.varSegIx) {
    const ix = new Map(), H = M.br.hops, put = (x, t, s) => { if (x < 0) return; let a = ix.get(x); if (!a) ix.set(x, a = []); const l = a[a.length - 1]; if (!l || l[0] !== t || l[1] !== s) a.push([t, s]); };
    for (const T of M.br.trees) T.segs.forEach((g, s) => { for (const h of g.hops) { put(H.fv[h], T.i, s); if (H.tv[h] !== H.fv[h]) put(H.tv[h], T.i, s); } });
    M.varSegIx = ix;
  }
  return M.varSegIx.get(v) || [];
}
