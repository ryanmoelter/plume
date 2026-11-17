import sys, os
p = sys.argv[1]
here = os.path.dirname(os.path.abspath(__file__)) + '/'
s = open(p).read()
def rep(old, new, n=1):
    global s
    c = s.count(old)
    if c != n: sys.exit('expected %d of %r, found %d' % (n, old[:90], c))
    s = s.replace(old, new)

# ---- colour tokens: variables are a gold between --h2 and --h3 (OKLCH midpoint); conflicts take --h0 ----
rep("  --h9: #5664c1; --h10: #7f51b1; --h11: #9d448f;\n", "  --h9: #5664c1; --h10: #7f51b1; --h11: #9d448f; --var: #a67300; --conflict: #ae3d62;\n")
rep("  --h9: #95a7ff; --h10: #be94f1; --h11: #e384d2;\n", "  --h9: #95a7ff; --h10: #be94f1; --h11: #e384d2; --var: #f8bb4c; --conflict: #f77fa0;\n", 2)
rep(".det .hop { font-size: 12px; overflow-wrap: anywhere; }", ".det .hop { font-size: 12px; overflow-wrap: anywhere; }\n.det .conflict { color: var(--conflict); }")

# ---- variables, span copies and the layer section ----
rep("  // Rings around the core, a constant width on screen", open(here + 'v9b.js').read() + "  // Rings around the core, a constant width on screen")
rep("    const per = { fn: [], init: [], prop: [], cell: [], hi: [] };", "    const per = { fn: [], init: [], prop: [], cell: [], hi: [], lam: [], var: [], vhi: [] };\n    varPos = new Map();")
rep("        per[mark].push([q, rr, it.m, f]);\n", "        per[mark].push([q, rr, it.m, f]);\n        if (mark !== 'cell') placeVars(per, it, q, rr, rr * r.s, f, n, r.s);\n")
rep("    for (const mark of ['fn', 'init', 'prop', 'cell', 'hi']) {", "    const varCol = color('--var'), accCol = color('--accent');\n    for (const mark of ['fn', 'init', 'prop', 'cell', 'hi', 'lam', 'var', 'vhi']) {")
rep("opacity: (mark === 'hi' ? 0.95 : 0.85) * f, depthWrite: false, side: THREE.DoubleSide });\n        const im = new THREE.InstancedMesh(g[mark], mat, list.length);",
    "opacity: (mark === 'hi' || mark === 'vhi' ? 0.95 : mark === 'lam' ? 0.4 : 0.85) * f, depthWrite: false, side: THREE.DoubleSide });\n        const im = new THREE.InstancedMesh(g[{ var: 'dot', vhi: 'hi', lam: 'cell' }[mark] || mark], mat, list.length);")
rep("im.setColorAt(k, memberColor(m, mark, pathMem, connMem));", "im.setColorAt(k, mark === 'var' || mark === 'lam' ? varCol : mark === 'vhi' ? accCol : memberColor(m, mark, pathMem, connMem));")
rep("im.renderOrder = mark === 'hi' ? 9 : 7;", "im.renderOrder = mark === 'hi' || mark === 'vhi' ? 9 : mark === 'var' ? 8 : 7;")
rep("    hoverLines = null; memGroup = null; memKey = '';", "    hoverLines = null; memGroup = null; memKey = ''; varPos = new Map();")
# Hover and click at variable grain; nothing on a dimmed class answers.
rep("    const mm = memberAt(e);\n    if (mm >= 0) return { mm,", "    const vv = varAt(e);\n    if (vv >= 0) return { vv, what: whatOf({ kind: 'var', v: vv, m: M.vars.home(vv) }) };\n    const mm = memberAt(e);\n    if (mm >= 0) return { mm,")
rep("    if (tg.ln) { clickLine(tg.ln, e); return; }\n",
    "    if (tg.ln) { clickLine(tg.ln, e); return; }\n    if (tg.vv != null) { S.selHist.push({ sel: S.sel, sel2: S.sel2 }); setSel({ kind: 'var', v: tg.vv, m: M.vars.home(tg.vv) }); showTip(null, e, describeVar(tg.vv)); return; }\n")
rep("    const mm = memberAt(e);\n    if (mm >= 0) { cv.style.cursor = 'pointer'; hoverRows(null);",
    "    const vv = varAt(e);\n    if (vv >= 0) { cv.style.cursor = 'pointer'; hoverRows(null); if (S.hover) { S.hover = null; showHoverEdges(S.selected); } showTip(null, e, describeVar(vv)); return; }\n    const mm = memberAt(e);\n    if (mm >= 0) { cv.style.cursor = 'pointer'; hoverRows(null);")

# ---- classes: hollow when placed by neighbours, copies on each spanned layer, conflict rings ----
rep("    nodeMeshes = []; overlay = []; meshByNode.clear();", "    nodeMeshes = []; spanMeshes = []; overlay = []; meshByNode.clear();")
rep("      else if (P.flat && !muted) ringFor(Math.max(0, r - Math.max(0.8, r * 0.12)), r, layerTone(n.slot), 1, 4);\n",
    "      else if (P.flat && !muted) ringFor(Math.max(0, r - Math.max(0.8, r * 0.12)), r, layerTone(n.slot), 1, 4);\n"
    "      if (n.li) { m.userData.hollow = HOLLOW; m.material.opacity = op * HOLLOW; ringFor(Math.max(0, r - Math.max(0.6, r * 0.1)), r, nodeColor(n), 0.95, 4); }\n"
    "      if (n.lc && S.layerConflicts) { const cw = Math.max(1.4 + r * 0.16, 3 * fitWpp()); ringFor(r + 0.6, r + 0.6 + cw, color('--conflict'), 1, 6); }\n"
    "      if (n.lys && n.lys.length > 1) spanCopies(n, m, p, r, ringFor);\n")
rep("  function buildNodes() {", "  const HOLLOW = 0.2;\n  function buildNodes() {")
rep("    for (const mesh of nodeMeshes) mesh.material.opacity = mesh.userData.cur;", "    for (const mesh of nodeMeshes) mesh.material.opacity = mesh.userData.cur * (mesh.userData.hollow || 1);")
rep("if (mesh) mesh.material.opacity = mesh.userData.cur * 0.3;", "if (mesh) mesh.material.opacity = mesh.userData.cur * 0.3 * (mesh.userData.hollow || 1);")
rep("      m.material.opacity = m.userData.cur; m.visible = !hid;", "      m.material.opacity = m.userData.cur * (m.userData.hollow || 1); m.visible = !hid;")
rep("    const hit = ray.intersectObjects(nodeMeshes, false).filter(h => h.object.visible && h.object.userData.active !== false);",
    "    const own = o => o.userData.copyOf || o;\n    const hit = ray.intersectObjects(nodeMeshes.concat(spanMeshes), false).filter(h => h.object.visible && own(h.object).visible && own(h.object).userData.active !== false);")
rep("<div>Layer ${layer}: ${esc(whyText(n.w))}</div>",
    "<div>Layer ${layer}: ${esc(whyText(n.w))}${n.li ? ' (placed by its neighbours)' : ''}</div>${n.lys && n.lys.length > 1 ? `<div>Spans ${n.lys.map(layerShort).join(' and ')}</div>` : ''}${n.lc ? '<div>Layer conflict</div>' : ''}")
rep("      + `<div>Layer ${n.L >= 0 ? n.L + ' ' + LAYER_NAMES[n.L] : 'unplaced'} <span class=\"sub\">(derived: ${esc(whyText(n.w))})</span></div>`\n",
    "      + layerSection(i)\n")

# ---- settings: mark layer conflicts ----
rep("dimOthers: store.get('dimOthers', true),", "dimOthers: store.get('dimOthers', true), layerConflicts: store.get('layerConflicts', false),")
rep("""          <select id="slabels-mode"><option value="off">Off</option><option value="sel">Selection only</option><option value="best">Best effort</option></select></div>""",
    """          <select id="slabels-mode"><option value="off">Off</option><option value="sel">Selection only</option><option value="best">Best effort</option></select></div>
        <label class="row"><input type="checkbox" id="layer-conflicts"><span>Mark layer conflicts <span class="sub" id="layer-conflicts-n"></span></span></label>""")
rep("  $('slabels-mode').value = S.strandLabels;",
    "  $('layer-conflicts').checked = !!S.layerConflicts;\n  $('layer-conflicts-n').textContent = '(' + M.nodes.filter(n => n.lc).length + ' classes)';\n"
    "  $('layer-conflicts').onchange = e => { S.layerConflicts = e.target.checked; store.set('layerConflicts', S.layerConflicts); rebuild(); };\n"
    "  $('slabels-mode').value = S.strandLabels;")

# ---- the one-time member hint goes on any selection ----
rep("    S.sel = sel; S.sel2 = null; S.moreStrands = false; S.pickDir = null; S.segPrev = null;\n",
    "    S.sel = sel; S.sel2 = null; S.moreStrands = false; S.pickDir = null; S.segPrev = null;\n"
    "    if (sel) { if (!S.memHintSeen) { S.memHintSeen = true; store.set('memHint', true); } $('memhint').hidden = true; }\n")

# ---- legend ----
rep("""      + `<div><span class="sw conn"></span>Possible connection</div>`""",
    """      + `<div><span class="sw conn"></span>Possible connection</div>`
      + `<div><span class="sw" style="background:var(--var)"></span>Variable, zoomed further in</div>`
      + `<div><span class="sw" style="border:1px solid var(--var);background:transparent;opacity:.6"></span>Lambda holding variables</div>`
      + `${full}Classes and layers:</div>`
      + `<div><span class="sw" style="border:2px solid var(--muted);background:transparent"></span>Hollow: layer from its neighbours</div>`
      + `<div><span class="sw" style="border:2px solid var(--conflict);background:transparent"></span>Layer conflict (Settings)</div>`
      + `<div style="grid-column:1/-1"><span class="sw" style="border:2px solid var(--muted);background:color-mix(in srgb,var(--muted) 15%,transparent)"></span>A class with code on two layers is drawn again on the other one, tied by a thin line</div>`""")
rep("lineAt, lineTip, hoverRows, clickLine, targetOf, inactiveNodes, whatOf,",
    "lineAt, lineTip, hoverRows, clickLine, targetOf, inactiveNodes, whatOf, varAt, meshByNode, get varPos() { return varPos; }, get spanMeshes() { return spanMeshes; }, varLayout, describeVar, layerSection, refreshMembers, get memGroup() { return memGroup; }, get revealed() { return revealed; },")
open(p, 'w').write(s)
print('ok 9b')
