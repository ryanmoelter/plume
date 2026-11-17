import sys, os
p = sys.argv[1]
here = os.path.dirname(os.path.abspath(__file__)) + '/'
s = open(p).read()
def rep(old, new, n=1):
    global s
    c = s.count(old)
    if c != n: sys.exit('expected %d of %r, found %d' % (n, old[:90], c))
    s = s.replace(old, new)

# ---- data: hops, links, variables, sink counts ----
rep('function prepareBranches(data, mem) {', open(here + 'core9.js').read() + 'function prepareBranches(data, mem) {')
rep("const segs = t.s.map(([a, b, hc, bits, cost, members]) => {", "const segs = t.s.map(([a, b, hc, bits, cost, members, hops]) => {")
rep("return { a, b, hc, cost, members, nodes, approx: B.approx.filter((x, j) => bits & (1 << j)) };",
    "return { a, b, hc, cost, members, nodes, hops: hops || [], approx: B.approx.filter((x, j) => bits & (1 << j)) };")
rep("const terms = t.t.map(([point, kind, ref, eq, clean, cost, sg]) => ({ point, kind: B.termKinds[kind], ref, eq, clean: !!clean, cost, segs: sg || chainTo(point) }));",
    "const terms = t.t.map(([point, kind, ref, eq, clean, cost, sg, at]) => ({ point, kind: B.termKinds[kind], ref, eq, clean: !!clean, cost, segs: sg || chainTo(point), at: at == null ? -1 : at }));\n"
    "    const sk = new Map(); if (t.sk) for (let k = 0; k + 1 < t.sk.length; k += 2) sk.set(t.sk[k], t.sk[k + 1]);")
rep("return { i, kind: B.rootKinds[rk], dir: dir ? 'backward' : 'forward', ref, rootPt, label, rootNode: pt.node[rootPt], rootMember: pt.m[rootPt], pt, segs, terms, sibs, chainTo };",
    "return { i, kind: B.rootKinds[rk], dir: dir ? 'backward' : 'forward', ref, rootPt, label, rootNode: pt.node[rootPt], rootMember: pt.m[rootPt], pt, segs, terms, sibs, chainTo, sk };")
rep("  return { trees, byNode, byMember, byTrace };\n}", "  return Object.assign({ trees, byNode, byMember, byTrace }, prepareHopsAndLinks(data, B));\n}")
rep("return { nodes, featLabel, adj, cellsOwned, cells: data.cells,", "return { vars: prepareVars(data, mem), nodes, featLabel, adj, cellsOwned, cells: data.cells,")

# ---- core: compat, variables, walk per cell ----
rep("// listed as a rejected candidate. The export carries no codes yet, so every stitch is unknown.",
    "// listed as a rejected candidate. Codes come from the export's links; a pair it does not name is unknown.")
rep("function segTouches(T, g, w) {\n", "function segTouches(T, g, w) {\n  if (w.v != null && !w.vf) { const H = BR_HOPS; return !!H && g.hops.some(h => H.fv[h] === w.v || H.tv[h] === w.v); }\n")
rep("  if (what.t != null && what.s != null) {\n    M.br.trees[what.t].terms",
    "  if (what.v != null && !what.vf) {\n    for (const [t, s] of varSegs(M, what.v)) M.br.trees[t].terms.forEach((x, k) => { if (x.segs.includes(s)) out.add(C.byTerm.get(t + ':' + k)); });\n  } else if (what.t != null && what.s != null) {\n    M.br.trees[what.t].terms")
old_walk = """      const cand = [];
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
      }"""
new_walk = """      const cand = [], at = new Map();
      for (const c of frontier) { const cell = cellOf(c); if (cell < 0 || cells.has(cell)) continue; if (!at.has(cell)) at.set(cell, []); at.get(cell).push(c); }
      // A candidate joins through the frontier chain at its cell that it fits, a match before an unknown, and is
      // rejected only when it mismatches every one of them.
      for (const [cell, here] of at) {
        cells.add(cell);
        for (const id of (dir === 'up' ? C.writers : C.readers).get(cell) || []) {
          const e = C.list[id];
          if (seen.has(id) || !ok(e)) continue;
          let via = null, compat = null, rej = null;
          for (const c of here) {
            const k = dir === 'up' ? stitchCompat(M, e, c, cell) : stitchCompat(M, c, e, cell);
            if (!STITCH_COMPAT[k].draw) { if (!rej) rej = c; continue; }
            if (!via || (k === 'match' && compat !== 'match')) { via = c; compat = k; }
          }
          if (via) { seen.add(id); cand.push({ c: e, parent: via.id, cell, depth: d, compat }); }
          else rejected.push({ c: e, parent: rej.id, cell, depth: d, compat: 'mismatch' });
        }
      }"""
rep(old_walk, new_walk)
rep("    return { got, rejected, steps, stopped, cells: hit.size };", "    return { got, rejected: rejected.filter(x => !seen.has(x.c.id)), steps, stopped, cells: hit.size };")
rep("link(a, b); const j = { a, b, cell, compat, from: { t: wt, point: wp }, to: { t: rt, point: rp } };",
    "link(a, b); const j = { a, b, cell, compat, wi, ri, from: { t: wt, point: wp }, to: { t: rt, point: rp } };")

# ---- view: variable selection ----
rep("    if (sel.kind === 'member') return { m: sel.m };\n",
    "    if (sel.kind === 'member') return { m: sel.m };\n    if (sel.kind === 'var') return varSegs(M, sel.v).length ? { v: sel.v, m: sel.m } : { v: sel.v, m: sel.m, vf: 1 };\n")
rep("  function whatLabel(w) {\n", "  function whatLabel(w) {\n    if (w.v != null) return M.vars.name[w.v] + ' in ' + M.mem.name[w.m] + ' (' + M.nodes[M.mem.n[w.m]].n + ')';\n")
rep("    drawPick(wpp, g);\n    drawArrows(wpp);", "    drawPick(wpp, g);\n    slBuild();\n    drawArrows(wpp);")

# ---- ui: hop detail, compat, rejected ----
rep("const APPROX_TEXT = { anyInstance: 'any instance', anyContainer: 'any container', fieldMismatch: 'field mismatch', staged: 'staged' };",
    "const APPROX_TEXT = { anyInstance: 'any instance', anyContainer: \"other caller's container\", fieldMismatch: 'field mismatch', staged: 'staged', unmatchedReturn: 'unmatched return', nonProduction: 'non-production' };")
rep("""<div class="k">${esc(i.tree)}</div><div class="k">Hop kinds are not in the export yet.</div>`;""",
    """<div class="k">${esc(i.tree)}</div>${hopSummary(i.g, 5)}`;""")
rep("""<div class="k">Compat: ${esc(j.compat)}. Unproven: the write may set another field or another instance.</div>`;""",
    """${stitchText(j)}`;""")
rep("""      + `<div>${i.hops} hop${i.hops === 1 ? '' : 's'} · approximations: ${esc(i.approx.join(', ') || 'none')}</div><div class="sub">${esc(i.tree)}</div>`""",
    """      + `<div>${i.hops} hop${i.hops === 1 ? '' : 's'} · approximations: ${esc(i.approx.join(', ') || 'none')}</div><div class="sub">${esc(i.tree)}</div>`
      + sec(`Hops (${i.g.hops.length || i.hops})`, hopSummary(i.g, 80))""")
old_rej = """  function rejectedHtml(R) {
    const rej = [...R.rejected.up, ...R.rejected.down];
    if (!rej.length) return '';
    return `<h4>Rejected candidates</h4>` + rej.slice(0, 6).map(e => routeHtml([e.cell, endText(chainEnds(M, e.c)[R.rejected.up.includes(e) ? 'src' : 'dst'])])).join('');
  }"""
new_rej = """  // A rejected candidate: the cell, the far end, and the two access paths that name different fields.
  function rejectedHtml(R) {
    const C = chainIndex(M), rows = [];
    for (const side of ['up', 'down']) for (const e of R.rejected[side]) {
      const other = C.list[e.parent], [wr, rd] = side === 'up' ? [e.c, other] : [other, e.c];
      const inf = M.br.stitchInfo[wr.t + ':' + wr.k + '>' + rd.t + ':' + rd.k];
      rows.push(routeHtml([e.cell, endText(chainEnds(M, e.c)[side === 'up' ? 'src' : 'dst'])])
        + `<div class="sub" style="font-size:12px">${side === 'up' ? 'writer' : 'reader'} not followed · writer path <span class="mono">${esc(inf ? inf.wa : '?')}</span> · reader path <span class="mono">${esc(inf && inf.ra != null ? inf.ra : '?')}</span></div>`);
    }
    if (!rows.length) return '';
    return `<h4>Rejected candidates (${rows.length})</h4><div class="sub">Mismatch: the write and the read name different fields, so the stitch is not followed.</div>` + rows.slice(0, 8).join('') + (rows.length > 8 ? `<span class="sub">and ${rows.length - 8} more</span>` : '');
  }
  // Access paths and fit for one cell stitch.
  function stitchInfoOf(j) { const C = chainIndex(M), w = C.list[j.wi], r = C.list[j.ri]; return w && r ? M.br.stitchInfo[w.t + ':' + w.k + '>' + r.t + ':' + r.k] || null : null; }
  const COMPAT_TEXT = { match: 'match: one access path is a prefix of the other', unknown: 'unknown: a container, an unnamed field or the depth limit decides it', mismatch: 'mismatch: they name different fields' };
  function stitchText(j) {
    const inf = stitchInfoOf(j), any = M.br.cellAny.has(j.cell);
    return `<div>Fit: ${esc(COMPAT_TEXT[j.compat] || j.compat)}${inf && inf.ra == null ? ' (a backward reader has no exported access path)' : ''}</div>`
      + `<div>Writer path: <span class="mono">${esc(inf ? inf.wa : 'not exported')}</span></div><div>Reader path: <span class="mono">${esc(inf && inf.ra != null ? inf.ra : 'not exported')}</span></div>`
      + (any ? `<div>Any instance: the cell is a class property, so the write and the read may be on different instances.</div>` : '')
      + `<div class="k">Possible provenance across state, not proven.</div>`;
  }"""
rep(old_rej, new_rej)
rep("const prev = S.sel && ['node', 'member', 'cell'].includes(S.sel.kind) ? S.sel : S.segPrev || null;",
    "const prev = S.sel && ['node', 'member', 'cell', 'var'].includes(S.sel.kind) ? S.sel : S.segPrev || null;")
rep("for (const a of g.approx) { const x = T.pt.node[g.a], z = T.pt.node[g.b]; approx.set(a + k, `${a} between",
    "for (const a of g.approx) { const x = T.pt.node[g.a], z = T.pt.node[g.b]; approx.set(a + k, `${APPROX_TEXT[a] || a} between")
rep("""    if (!R.core.length) return sec('Strands',""",
    """    const vf = P.what.vf ? '<p>No exported route names this variable; showing routes through its function.</p>' : '';
    if (!R.core.length) return sec('Strands', vf + """)
rep("""    return sec('Strands', controls + drawnLine + hid""", """    return sec('Strands', vf + controls + drawnLine + `<p class="sub" id="slabel-stat">${esc(slStatText())}</p>` + hid""")

# ---- strand labels ----
rep("  // labels: a container label shows only when its footprint", open(here + 'sl9.js').read() + "  // labels: a container label shows only when its footprint")
rep("    hideCollidingLabels();\n  }\n", "    slFrame();\n    hideCollidingLabels();\n  }\n")
rep("  function hideCollidingLabels() {\n    const placed = [];", "  function hideCollidingLabels() {\n    const placed = slPlacedList.map(p => p.r);")
rep("dimOthers: store.get('dimOthers', true),", "dimOthers: store.get('dimOthers', true), strandLabels: store.get('strandLabels', 'best'),")
rep("""<label class="row"><input type="checkbox" id="dim-others"><span>Dim other connections while selecting</span></label>""",
    """<label class="row"><input type="checkbox" id="dim-others"><span>Dim other connections while selecting</span></label>
        <div class="field"><span>Strand labels</span>
          <select id="slabels-mode"><option value="off">Off</option><option value="sel">Selection only</option><option value="best">Best effort</option></select></div>""")
rep("""<label class="row"><input type="checkbox" id="sinks"><span>Show sinks</span></label>""",
    """<label class="row" title="Sink terminals are left out of this page to keep it small; tree points keep their sink counts"><input type="checkbox" id="sinks" disabled><span>Show sinks <span class="sub">(left out of this page)</span></span></label>""")
rep("""  $('pick-dir').value = S.pickDirDefault;""",
    """  S.sinks = false;
  $('slabels-mode').value = S.strandLabels;
  $('slabels-mode').onchange = e => { S.strandLabels = e.target.value; store.set('strandLabels', S.strandLabels); slDirty = true; wake(); };
  $('pick-dir').value = S.pickDirDefault;""")
rep(""".lbl.picked { color: var(--accent); font-weight: 700; }""",
    """.lbl.picked { color: var(--accent); font-weight: 700; }
.lbl.inert { cursor: default; }
.lbl.inert:hover { color: inherit; }
.slabels { position: absolute; inset: 0; pointer-events: none; overflow: hidden; z-index: 3; }
.slabels svg { position: absolute; inset: 0; width: 100%; height: 100%; pointer-events: none; stroke: var(--muted); stroke-width: 1; }
.slbl { position: absolute; box-sizing: border-box; height: 16px; line-height: 14px; padding: 0 4px; font: 500 11px var(--font-mono); white-space: nowrap; overflow: hidden; color: var(--ink); background: color-mix(in srgb, var(--bg) 88%, transparent); border: 1px solid var(--rule); border-radius: 3px; pointer-events: auto; cursor: pointer; }
.slbl:hover { color: var(--accent); border-color: var(--accent); }
.slbl.sel { font-weight: 700; color: var(--accent); border-color: var(--accent); background: var(--bg); }
.slbl.k1 { border-color: color-mix(in srgb, var(--ink) 45%, var(--rule)); }
.slbl.grp { border-style: dashed; }
.det .hop { font-size: 12px; overflow-wrap: anywhere; }""")

# ---- 8.2 gap: a container label whose classes are all dimmed is not clickable ----
rep("    renderLabels(true);\n    for (const o of overlay) if (o.cont && o.el)",
    """    renderLabels(true);
    for (const o of overlay) if (o.cont && o.cont !== 'pillar' && o.el) {
      const ns = groupNodes(o.cont).filter(n => meshByNode.has(n.i)), inert = ns.length > 0 && ns.every(n => inactiveNodes.has(n.i));
      o.inert = inert; o.el.classList.toggle('inert', inert); o.el.style.pointerEvents = inert ? 'none' : '';
    }
    for (const o of overlay) if (o.cont && o.el)""")

# ---- details: variables, hops, sink counts, junction paths ----
details9 = r"""  function hopRowHtml(h) {
    const H = M.br.hops, fm = H.fm[h], tm = H.tm[h], fv = H.fv[h], tv = H.tv[h];
    const vn = x => (x >= 0 ? M.vars.name[x] : '');
    const vars = fv >= 0 || tv >= 0 ? ` · ${esc(vn(fv) || '?')}${tv !== fv ? ' → ' + esc(vn(tv) || '?') : ''}` : '';
    const bits = HOP_BITS.filter(([b]) => H.x[h] & b).map(([, a]) => APPROX_TEXT[a] || a);
    const mems = fm >= 0 ? esc(memLabel(fm)) + (tm !== fm ? ' → ' + esc(tm >= 0 ? memLabel(tm) : 'library') : '') : '';
    return `<div class="hop"><b class="mono">${esc(H.kind[h])}</b> <span class="mono">${esc(H.site[h])}</span> <span class="sub">${mems}${vars}${bits.length ? ' · ' + esc(bits.join(', ')) : ''}${H.note[h] ? ' · ' + esc(H.note[h]) : ''}</span></div>`;
  }
  function hopSummary(g, cap) {
    if (!g.hops.length) return `<div class="k">${M.br.hopDetailDropped && (g.approx.includes('anyInstance') || g.approx.includes('staged')) ? 'The export leaves out hop records on segments with an any-instance read or a staged hop.' : 'No hop records for this segment.'}</div>`;
    return `<div class="hops">${g.hops.slice(0, cap).map(hopRowHtml).join('')}${g.hops.length > cap ? `<div class="k">and ${g.hops.length - cap} more hops${cap < 10 ? ' · click the segment for all' : ''}</div>` : ''}</div>`;
  }
  function varListSection(m) {
    const VV = M.vars, list = (VV.byMem.get(m) || []).slice();
    if (!list.length) return sec('Variables', '<span class="sub">none in the export</span>');
    const on = i => varSegs(M, i).length;
    list.sort((a, b) => (on(b) > 0) - (on(a) > 0) || VAR_RANK_ORDER[VV.rank[a]] - VAR_RANK_ORDER[VV.rank[b]] || VV.line[a] - VV.line[b] || a - b);
    const n = list.filter(i => on(i)).length, all = S.moreVars === m, cap = all ? list.length : 14;
    const row = i => `<button data-var="${i}"><span>${esc(VV.name[i])} <span class="sub">${esc(VV.kind[i])} · line ${VV.line[i]}${VV.rank[i] !== 'other' ? ' · ' + esc(VV.rank[i]) : ''}</span></span><span class="c">${on(i) ? on(i) + ' seg' : 'no route'}</span></button>`;
    return sec(`Variables (${list.length}; ${n} named by a route)`, `<div class="sub">Click one to select it: its strands are the routes whose hops name it.</div>` + listOf(list.map(row), cap)
      + (list.length > cap ? `<button class="lnk" data-more-vars="${m}">Show all ${list.length}</button>` : ''));
  }
  function varDetails(s) {
    const VV = M.vars, v = s.v, m = s.m, own = VV.m[v], H = M.br.hops, n = M.nodes[M.mem.n[m]];
    const hops = []; for (let h = 0; h < H.n; h++) if (H.fv[h] === v || H.tv[h] === v) hops.push(h);
    const segs = varSegs(M, v), fl = [VV.fl[v] & 1 ? 'declared with by' : '', VV.fl[v] & 2 ? 'remember' : ''].filter(Boolean);
    return head(`variable · ${VV.kind[v]}`, `${n.n}.${M.mem.name[m]} › ${VV.name[v]}`)
      + crumbs(n.chain, `<button data-n="${M.mem.n[m]}">${esc(n.n)}</button><span>›</span><button data-m="${m}">${esc(M.mem.name[m])}</button>`)
      + `<div>Line ${VV.line[v]} · rank ${esc(VV.rank[v])}${fl.length ? ' · ' + esc(fl.join(', ')) : ''}${VV.cap[v] ? ` · captured by ${VV.cap[v]} lambda${VV.cap[v] === 1 ? '' : 's'}` : ''}</div>`
      + (VV.type[v] ? `<div class="mono sub" style="overflow-wrap:anywhere">${esc(VV.type[v])}</div>` : '')
      + (VV.lbl[v] ? `<div class="sub">${esc(VV.lbl[v])}</div>` : '')
      + (own !== m && own >= 0 ? `<div>Held by the local cell <button class="lnk" style="display:inline" data-m="${own}">${esc(M.mem.name[own])}</button></div>` : '')
      + `<div>${hops.length} hop${hops.length === 1 ? '' : 's'} name it, on ${segs.length} tree segment${segs.length === 1 ? '' : 's'}.</div>`
      + (M.br.hopDetailDropped ? '<p class="sub">The export leaves out hop records on segments with an any-instance read or a staged hop, so routes through those cannot name a variable.</p>' : '')
      + sec(`Hops naming it (${hops.length})`, hops.length ? hops.slice(0, 16).map(hopRowHtml).join('') + (hops.length > 16 ? `<span class="sub">and ${hops.length - 16} more</span>` : '') : '<span class="sub">none</span>');
  }
"""
rep("  function memberDetails(m) {", details9 + "  function memberDetails(m) {")
rep("      + `<p class=\"sub\">Variables inside functions arrive with the next export.</p>`\n", "      + varListSection(m)\n")
rep("    else if (s.kind === 'member') html = memberDetails(s.m);", "    else if (s.kind === 'member') html = memberDetails(s.m);\n    else if (s.kind === 'var') html = varDetails(s);")
rep("if (s && V.pick && ['node', 'member', 'cell', 'seg'].includes(s.kind)) {", "if (s && V.pick && ['node', 'member', 'cell', 'seg', 'var'].includes(s.kind)) {")
rep("const b = e.target.closest('[data-n],[data-m],", "const b = e.target.closest('[data-var],[data-more-vars],[data-n],[data-m],")
rep("    const d = b.dataset;\n    if (d.n != null) setSel({ kind: 'node', n: +d.n });",
    "    const d = b.dataset;\n    if (d.var != null) { const v = +d.var; S.selHist.push({ sel: S.sel, sel2: S.sel2 }); setSel({ kind: 'var', v, m: M.vars.home(v) }); }\n    else if (d.moreVars != null) { S.moreVars = +d.moreVars; renderDetails(); }\n    else if (d.n != null) setSel({ kind: 'node', n: +d.n });")
# A class chosen from a grouped label lists the members the label stood for.
rep("    return head(n.k + ' · class', n.n) + crumbs(n.chain)",
    "    const grp = S.sel && S.sel.kind === 'node' && S.sel.n === i && S.sel.group && S.sel.group.length ? sec(`From the label (${S.sel.group.length})`, listOf(S.sel.group.map(m => memBtn(m)), 40)) : '';\n    return head(n.k + ' · class', n.n) + grp + crumbs(n.chain)")
rep("""    if (mk.kind === 'junction') return `<b>Cell junction · possible provenance across state</b><div class="mono">${esc(refLabel('cellWrite', mk.ci))}</div><div class="k">A strand that writes this cell may continue into one that reads it. Unproven: the write may set another field or another instance.</div>`;""",
    """    if (mk.kind === 'junction') {
      const J = V.pick ? V.pick.G.junctions.find(x => x.cell === mk.ci) : null, links = J ? J.links.filter(j => V.pick.roles.has(j.a) && V.pick.roles.has(j.b)) : [];
      const by = {}; for (const j of links) by[j.compat] = (by[j.compat] || 0) + 1;
      const any = M.br.cellAny.has(mk.ci);
      return `<b>Cell junction${any ? ' · any instance' : ''}</b><div class="mono">${esc(refLabel('cellWrite', mk.ci))}</div>`
        + (links.length ? `<div>${links.length} stitch${links.length === 1 ? '' : 'es'} drawn: ${Object.entries(by).map(([k, n]) => `${n} ${k}`).join(', ')}</div>` + stitchText(links[0]) : `<div class="k">Possible provenance across state, not proven.</div>`);
    }""")
rep("""    if (!term) return `<b>${mk.point === T.rootPt ? 'Root' : esc(T.pt.kind[mk.point])}</b><div>${esc(where)}</div>""",
    """    const skn = T.sk && T.sk.get(mk.point), skLine = skn ? `<div class="k">${skn} sink path${skn === 1 ? '' : 's'} pass here (sinks are left out of this page)</div>` : '';
    if (!term) return `<b>${mk.point === T.rootPt ? 'Root' : esc(T.pt.kind[mk.point])}</b><div>${esc(where)}</div>${skLine}""")
rep("""    if (g.approx.includes('fieldMismatch') ? ' <span class="sub">(field names are only in the golden traces)</span>' : ''}""", "", 0)
s = s.replace("""return `<div style="font-size:12px">${esc(g.approx.join(', '))} between""", """return `<div style="font-size:12px">${esc(g.approx.map(a => APPROX_TEXT[a] || a).join(', '))} between""")
s = s.replace("""${g.approx.includes('fieldMismatch') ? ' <span class="sub">(field names are only in the golden traces)</span>' : ''}""",
              """${g.hops.filter(h => M.br.hops.x[h] & 2).map(h => ` <span class="sub">${esc(M.br.hops.note[h] || 'field mismatch')} at ${esc(M.br.hops.site[h])}</span>`).join('')}""")
rep("""Any-instance or any-container read</div>`""", """Any-instance or other caller's container read</div>`""")
rep("lineAt, lineTip, hoverRows, clickLine, targetOf, inactiveNodes,",
    "lineAt, lineTip, hoverRows, clickLine, targetOf, inactiveNodes, whatOf, slPlace, slBuild, get slPlaced() { return slPlacedList; }, get slCands() { return slCands; }, get slStat() { return slStat; }, varSegs: v => varSegs(M, v), chainIndex: () => chainIndex(M), stitchInfoOf, rejectedHtml, segInfo, markerTip,")
# Cells read by their short label: mechanism, holder name and site.
rep("return c ? c.n + (c.h ? ' (' + c.h + ')' : '') : '?';", "return c ? c.l || c.n + (c.h ? ' (' + c.h + ')' : '') : '?';", 2)
rep("if (w.ci != null) return 'cell ' + (M.cells[w.ci] ? M.cells[w.ci].n : '?');", "if (w.ci != null) return 'cell ' + (M.cells[w.ci] ? M.cells[w.ci].l || M.cells[w.ci].n : '?');", 2)
rep("<span>${esc(M.cells[ci].n)}</span><span class=\"c\">${esc(M.cells[ci].m || M.cells[ci].sc)}</span>", "<span>${esc(M.cells[ci].l || M.cells[ci].n)}</span><span class=\"c\">${esc(M.cells[ci].m || M.cells[ci].sc)}</span>")
open(p, 'w').write(s)
print('ok 9')
