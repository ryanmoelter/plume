import re
import sys

p = sys.argv[1]
s = open(p).read()
here = p.rsplit('/', 1)[0] + '/' if '/' in p else ''
core = open(here + 'pick-core.js').read()
view = open(here + 'pick-view.js').read()
ui = open(here + 'pick-ui.js').read()


def rep(old, new, n=1):
    global s
    assert s.count(old) == n, 'COUNT %d: %s' % (s.count(old), old[:120])
    s = s.replace(old, new)


def between(start, end, new):
    global s
    i = s.index(start)
    j = s.index(end, i)
    assert s.count(start) == 1, start
    s = s[:i] + new + s[j:]


# render loop wakes on demand
n0 = len(re.findall(r'(?<!, )dirty = true', s))
s = re.sub(r'(?<!, )dirty = true', 'wake()', s)
print('wake() sites', n0)
rep("""hoverLines = null, dirty = true;""", """hoverLines = null, dirty = true;
  let rafOn = false;""")

rep("""
// The container a node is grouped under""", core + """
// The container a node is grouped under""")

rep("""// - Everything is a function of the export and the state: no randomness, no timing.""",
    """// - Selection strands: a single click on a member, cell or class highlights every tree chain through it, stitched at
//   cells so a UI value reaches the database: upstream through the chains that write the cell a strand reads,
//   downstream through the chains that read the cell it writes, breadth first, at most 6 cell steps, no cell
//   expanded twice, each side capped at 20 chains, ranked clean first, then by cost, then by tree and terminal. A
//   second click on those strands joins the two points; a double click or Focus strands re-packs around them.
// - Members take their class's dimming: a member's opacity is its own times its class circle's current opacity.
// - Flow pulses drift along highlighted strands and the trace, the way data flows, at a constant speed on screen.
// - Everything is a function of the export and the state: no randomness. Time moves only the flow pulses.""")

rep("""  if (F && F.root != null && F.root >= 0) {
    focusTree = M.br.trees[F.root];""", """  if (F && F.kind === 'pick') {
    focus = 'pick';
    var path = F.nodes.slice();
  } else if (F && F.root != null && F.root >= 0) {
    focusTree = M.br.trees[F.root];""")

rep("""root: -1, endpoint: -1, focus: null, history: [], sel: null, pane: 'settings',""",
    """root: -1, endpoint: -1, focus: null, history: [], sel: null, sel2: null, selHist: [], pane: 'settings', pulses: store.get('pulses', true),""")

rep("""        <label class="row"><input type="checkbox" id="sinks"><span>Show sinks</span></label>""",
    """        <label class="row"><input type="checkbox" id="sinks"><span>Show sinks</span></label>
        <label class="row"><input type="checkbox" id="pulses"><span>Flow pulses</span></label>
        <p class="sub" id="pulse-note" hidden></p>""")

rep("""[hidden] { display: none !important; }""", """[hidden] { display: none !important; }
.route { display: flex; flex-wrap: wrap; gap: 2px 4px; align-items: baseline; font-size: 12px; margin: 2px 0 6px; min-width: 0; }
.route > * { min-width: 0; overflow-wrap: anywhere; }
.det hr { border: 0; border-top: 1px solid var(--rule); margin: 10px 0; width: 100%; }""")

# members inherit dimming, capped marks, pick members, pulses
rep("""    const g = side() ? geoSide : geoFlat, pathMem = pathMembers(), connMem = S.conn ? S.conn.shown : new Set();""",
    """    const g = side() ? geoSide : geoFlat, pathMem = pathMembers(), connMem = S.conn ? S.conn.shown : new Set();
    const pickMem = V.pick && V.pick.R.core.length ? V.pick.mems : new Set();
    pulseLines = [];""")
rep("""      const mesh = meshByNode.get(n.i); if (mesh) mesh.material.opacity = mesh.userData.cur * 0.3;""",
    """      const mesh = meshByNode.get(n.i); if (mesh) mesh.material.opacity = mesh.userData.cur * 0.3;
      // A member takes its class's dimming, in steps of 0.05 so members batch by it.
      const f = mesh ? Math.round(20 * Math.min(1, mesh.userData.cur / 0.7)) / 20 : 1;""")
rep("""        // A cell ring is capped on screen, so a big member's cell does not outshout the class.
        const rr = mark === 'cell' ? Math.min(it.r * R, 12 * wpp) : it.r * R * 0.92;
        if (!memPos.has(it.m)) memPos.set(it.m, { p: q, r: rr });
        per[mark].push([q, rr, it.m]);
        if (pathMem.has(it.m) || connMem.has(it.m)) per.hi.push([q, rr, it.m]);""",
    """        // A cell ring is capped on screen, and every mark at under half the class radius, so a big member or its
        // cell does not outshout the class.
        const rr = mark === 'cell' ? Math.min(it.r * R, 12 * wpp, 0.45 * R / 0.92) : Math.min(it.r * R * 0.92, 0.45 * R);
        if (!memPos.has(it.m)) memPos.set(it.m, { p: q, r: rr });
        per[mark].push([q, rr, it.m, f]);
        if (pathMem.has(it.m) || connMem.has(it.m) || pickMem.has(it.m)) per.hi.push([q, rr, it.m, 1]);""")
rep("""    for (const mark of ['fn', 'init', 'prop', 'cell', 'hi']) {
      const list = per[mark]; if (!list.length) continue;
      const mat = new THREE.MeshBasicMaterial({ color: 0xffffff, transparent: true, opacity: mark === 'hi' ? 0.95 : 0.85, depthWrite: false, side: THREE.DoubleSide });
      const im = new THREE.InstancedMesh(g[mark], mat, list.length);
      list.forEach(([q, rr, m], k) => {
        dummy.position.copy(q); dummy.scale.set(rr, rr, rr); dummy.updateMatrix();
        im.setMatrixAt(k, dummy.matrix); im.setColorAt(k, memberColor(m, mark, pathMem, connMem));
      });
      im.instanceMatrix.needsUpdate = true; if (im.instanceColor) im.instanceColor.needsUpdate = true;
      im.renderOrder = mark === 'hi' ? 9 : 7; im.frustumCulled = false; memGroup.add(im);
    }""",
    """    for (const mark of ['fn', 'init', 'prop', 'cell', 'hi']) {
      const byF = new Map();
      for (const e of per[mark]) { if (!byF.has(e[3])) byF.set(e[3], []); byF.get(e[3]).push(e); }
      for (const [f, list] of [...byF.entries()].sort((a, b) => a[0] - b[0])) {
        const mat = new THREE.MeshBasicMaterial({ color: 0xffffff, transparent: true, opacity: (mark === 'hi' ? 0.95 : 0.85) * f, depthWrite: false, side: THREE.DoubleSide });
        const im = new THREE.InstancedMesh(g[mark], mat, list.length);
        list.forEach(([q, rr, m], k) => {
          dummy.position.copy(q); dummy.scale.set(rr, rr, rr); dummy.updateMatrix();
          im.setMatrixAt(k, dummy.matrix); im.setColorAt(k, memberColor(m, mark, pathMem, connMem));
        });
        im.instanceMatrix.needsUpdate = true; if (im.instanceColor) im.instanceColor.needsUpdate = true;
        im.renderOrder = mark === 'hi' ? 9 : 7; im.frustumCulled = false; im.userData.dim = f; memGroup.add(im);
      }
    }""")
rep("""    if (mark === 'hi') return color(pathMem.has(m) ? '--accent' : '--conn');""",
    """    if (mark === 'hi') return color(pathMem.has(m) ? '--accent' : connMem.has(m) ? '--conn' : '--branch');""")
rep("""    drawTree(wpp, g);
""", """    drawTree(wpp, g);
    drawPick(wpp, g);
    drawArrows(wpp);
    buildPulses(wpp, g);
""")
rep("""        <div class="field"><span>Branch hops</span>
          <select id="branch"><option value="0">Strand only (0)</option><option value="1">Branches (1)</option><option value="2">Branches + siblings (2)</option></select></div>""",
    """        <div class="field"><span>Show</span>
          <select id="branch"><option value="0">Strand</option><option value="1">Branches</option><option value="2">Join inputs</option></select></div>""")
rep("""    return head(`${T.kind} root · ${T.dir}`, T.label)
""", """    return head(`${T.kind} root · ${T.dir}`, T.label)
      + `<div class="kind">Representative routes to destinations</div><div class="sub">One best route per destination; other routes exist.</div>`
""")
rep("""        dotted(curve, wpp, acc, 10); drawnMis.add(z.mis);""",
    """        dotted(curve, wpp, acc, 10); drawnMis.add(z.mis);
        pulseLine('R' + i, curve.getPoints(10), wpp * 1.5, acc, 'dot', ['R' + (i - 1)]);""")
rep("""      const curve = tube(a.p, z.p, wpp * 1.4, acc, 10, bow);""",
    """      const curve = tube(a.p, z.p, wpp * 1.4, acc, 10, bow);
      pulseLine('R' + i, curve.getPoints(10), wpp * 1.4, acc, 'solid', ['R' + (i - 1)]);""")

between("""  const TERM_STYLE = {""", """  // The marker nearest the pointer, within its size on screen.""", view)

rep("""    if (mk.kind === 'mismatch') return""", """    if (mk.kind === 'junction') return `<b>Cell junction · possible provenance across state</b><div class="mono">${esc(refLabel('cellWrite', mk.ci))}</div><div class="k">A strand that writes this cell may continue into one that reads it. Unproven: the write may set another field or another instance.</div>`;
    if (mk.kind === 'x') return `<b>Selected</b><div>${esc(whatLabel(mk.what))}</div>`;
    if (mk.kind === 'mismatch') return""")

rep("""    S.sel = sel; S.moreStrands = false;
    if (!sel || (sel.kind !== 'member' && sel.kind !== 'cell')) clearConn();""",
    """    S.sel = sel; S.sel2 = null; S.moreStrands = false;
    if (S.conn && !(sel && sel.m === S.conn.root)) clearConn();""")
rep("""    if (sel && show !== false && S.pane !== 'details') setPane('details');
    applyHighlight();
  }""", """    if (sel && show !== false && S.pane !== 'details') setPane('details');
    applyHighlight();
    // With no strand through a member or cell, its possible connections stand in.
    const P = V.pick;
    if (P && !P.R.core.length && P.what.m != null && P.what.m >= 0 && !(S.conn && S.conn.root === P.what.m)) clickMember(P.what.m);
  }""")
rep("""    S.sel = null; S.selected = null; showHoverEdges(null);""", """    S.sel = null; S.sel2 = null; S.selHist = []; S.selected = null; showHoverEdges(null);""")

between("""  function handleClick(e) {""", """  function focusOn(kind) {""", ui)

rep("""    if (V.T) {
      if (drawLevel() === 0)""", """    if (V.pick && V.pick.R.core.length) return new Set(V.pick.nodes);
    if (V.T) {
      if (drawLevel() === 0)""")
rep("""    Object.assign(V, activeTree(M, S));""", """    Object.assign(V, activeTree(M, S));
    V.pick = computePick();""")
rep("""    $('pane-details').innerHTML = html;""", """    if (s && V.pick && ['node', 'member', 'cell'].includes(s.kind)) {
      const at = html.indexOf('</h3></div>') + 11;
      html = (S.sel2 ? connectSection(V.pick) + '<hr>' : '') + html.slice(0, at) + pickSection(V.pick, s) + html.slice(at);
    }
    $('pane-details').innerHTML = html;""")
rep("""[data-focus],[data-show-trace]');""", """[data-focus],[data-show-trace],[data-conn]');""")
rep("""    else if (d.focus) focusOn(d.focus);""", """    else if (d.focus) { if (d.focus === 'pick') focusPick(); else focusOn(d.focus); }
    else if (d.conn != null) clickMember(+d.conn);""")
rep("""    if (S.conn) clearConn();
    else if (S.focus) back();""", """    if (S.conn) clearConn();
    else if (S.focus) back();
    else if (S.sel2 || (V.pick && S.sel)) stepBackSelection();""")
rep("""  $('sinks').onchange = e => { S.sinks = e.target.checked; store.set('sinks', S.sinks); if (S.focus) rebuild(); else applyHighlight(); };""",
    """  $('sinks').onchange = e => { S.sinks = e.target.checked; store.set('sinks', S.sinks); if (S.focus) rebuild(); else applyHighlight(); };
  $('pulses').checked = S.pulses;
  if (reduceMotion) { $('pulse-note').hidden = false; $('pulse-note').textContent = 'Your system asks for reduced motion, so pulses stay off.'; }
  $('pulses').onchange = e => { S.pulses = e.target.checked; store.set('pulses', S.pulses); memKey = ''; wake(); };
  if (document.addEventListener) document.addEventListener('visibilitychange', () => { if (!document.hidden) wake(); });""")
rep("""  setCam(S.cam); renderTrace(); resize(); setPane('settings');
  (function loop() {
    if (dirty) { dirty = false; applyCamera(); refreshMembers(); renderer.render(scene, camera()); renderLabels(false); }
    requestAnimationFrame(loop);
  })();""", """  // Frames run only while something changed or pulses are moving, and a hidden tab gets none.
  function wake() { dirty = true; if (!rafOn) { rafOn = true; requestAnimationFrame(loop); } }
  function loop() {
    rafOn = false;
    const changed = dirty;
    if (changed) { dirty = false; applyCamera(); refreshMembers(); }
    const moving = pulsesOn();
    if (moving) updatePulses(clock());
    if (changed || moving) renderer.render(scene, camera());
    if (changed) renderLabels(false);
    if (moving && !rafOn) { rafOn = true; requestAnimationFrame(loop); }
  }
  setCam(S.cam); renderTrace(); resize(); setPane('settings'); wake();""")
rep("""    view, zoomBy, clickMember, clearConn, npos, ptAnchor, setSel, focusOn, back, applyHighlight, toScreen, camera, outlineEm, edgeEm, nodeFloor, edgeStrength };""",
    """    view, zoomBy, clickMember, clearConn, npos, ptAnchor, setSel, focusOn, back, applyHighlight, toScreen, camera, outlineEm, edgeEm, nodeFloor, edgeStrength,
    focusPick, stepBackSelection, updatePulses, pulsesOn, cellMember, get pulseLines() { return pulseLines; }, get pulseMesh() { return pulseMesh; }, get arrowMesh() { return arrowMesh; }, containerSpans, get sceneRoot() { return root; }, get memGroupMeshes() { return memGroup ? memGroup.children : []; }, meshByNode };""")
rep("""    const core = V.focus ? `the ${V.focus === 'strand' ? 'strand' : 'tree'}'s ${byHop[0]} classes""",
    """    const core = V.focus ? `the ${V.focus === 'pick' ? "selected strands'" : V.focus === 'strand' ? "strand's" : "tree's"} ${byHop[0]} classes""")
rep("""      + `<div><span class="sw" style="border:1px dashed var(--muted);background:transparent;border-radius:2px"></span>Sibling stub (level 2)</div>`""",
    """      + `<div><span class="sw" style="border:1px dashed var(--muted);background:transparent;border-radius:2px"></span>Join-input stub (Show: Join inputs)</div>`
      + `${full}A selection's strands, stitched at cells:</div>`
      + `<div>${line('var(--branch)')}Strands through the selection</div>`
      + `<div style="display:flex;gap:6px;align-items:center">${mark('ring', '--accent')}Selected point</div>`
      + `<div style="display:flex;gap:6px;align-items:center">${mark('ring', '--role-state')}Cell junction: a possible stitch, unproven</div>`
      + `<div>${line('repeating-linear-gradient(90deg,var(--role-state) 0 5px,transparent 5px 8px)')}Broken joint from a cell write to a read</div>`
      + `<div>▲ Arrowhead: the way data flows</div>`
      + `<div>${line('color-mix(in srgb, var(--branch) 45%, var(--bg))')}Continuation, with a second point</div>`
      + `<div style="grid-column:1/-1">${line('linear-gradient(90deg,var(--branch) 0 40%,color-mix(in srgb,var(--branch) 45%,var(--bg)) 40% 65%,var(--branch) 65%)')}Flow pulse on the selected strand: a brighter dash drifting the way data flows; on a dashed or dotted line, a short run of dots. Pulses stop at each cell junction.</div>`""")
rep("""A click only selects and highlights; nothing moves.""",
    """A click on a member, cell or class highlights every strand through it, stitched at cells: upstream through the code that writes the cell it reads, back toward a boundary, and downstream through the code that reads the cell it writes. A stitch is possible provenance across state, not proven: the write may set another field or instance. A second click on those strands joins the two points. Faint pulses drift the way data flows. A click only selects and highlights; nothing moves.""")
# A container is drawn only as high as its contents.
rep("""//   heights snap to geometric steps, so a node that grows moves only its own cell until it crosses a step.
""", """//   heights snap to geometric steps, so a node that grows moves only its own cell until it crosses a step.
// - A container is packed with a footprint on every plane, but drawn only as high as its shown classes: in 3D,
//   rings from its lowest occupied plane to its highest (a single plane draws a disc), and in the side view a
//   column over just those bands. Unplaced classes never stretch a span. Drawing only; the packing is unchanged.
""")
rep("""  function outlineMat(inner, tint) {
    const m = new THREE.LineBasicMaterial({ color: tint || color('--ink'), transparent: true, opacity: Math.min(1, outlineEm(inner) + (tint ? 0.15 : 0)), depthWrite: false });
    outlineMats.push({ m, inner, tint }); return m;""", """  function outlineMat(inner, tint, k = 1) {
    const m = new THREE.LineBasicMaterial({ color: tint || color('--ink'), transparent: true, opacity: k * Math.min(1, outlineEm(inner) + (tint ? 0.15 : 0)), depthWrite: false });
    outlineMats.push({ m, inner, tint, k }); return m;""")
rep("""    for (const { m, inner, tint } of outlineMats) m.opacity = Math.min(1, outlineEm(inner) + (tint ? 0.15 : 0));""",
    """    for (const { m, inner, tint, k } of outlineMats) m.opacity = k * Math.min(1, outlineEm(inner) + (tint ? 0.15 : 0));""")
rep("""  function build3D(drawn, visibleSlots, deepest, hasPillar) {""", """  // The layers a container's shown classes occupy, as SLOT_ORDER indices: { lo, hi, occ } with occ the occupied
  // slots. Unplaced classes count only when a container has nothing placed, so they never stretch a span. Shown means
  // under the current filters and focus; a highlight never changes it, since only a rebuild calls this.
  function containerSpans(visibleSlots) {
    const spans = new Map(), vis = new Set(visibleSlots), UNPLACED = 4;
    for (const n of M.nodes) {
      if (!V.shown(n) || !vis.has(n.slot)) continue;
      for (const a of n.ancBy[V.tk]) {
        let sp = spans.get(a); if (!sp) spans.set(a, sp = { lo: Infinity, hi: -Infinity, occ: new Set(), unplaced: false });
        if (n.slot === UNPLACED) { sp.unplaced = true; continue; }
        const k = SLOT_ORDER.indexOf(n.slot); sp.lo = Math.min(sp.lo, k); sp.hi = Math.max(sp.hi, k); sp.occ.add(n.slot);
      }
    }
    for (const sp of spans.values()) if (sp.lo === Infinity) { const k = SLOT_ORDER.indexOf(UNPLACED); sp.lo = sp.hi = k; sp.occ.add(UNPLACED); }
    return spans;
  }
  const spanSlots = (sp, slots) => slots.filter(s => { const k = SLOT_ORDER.indexOf(s); return k >= sp.lo && k <= sp.hi; });
  function build3D(drawn, visibleSlots, deepest, hasPillar) {""")
rep("""    for (const { g, r } of conts) {
      const depth = g === 'pillar' ? deepest : g.depth;
      const inner = depth === deepest || (g !== 'pillar' && !g.kids.length);
      const iso = g !== 'pillar' && S.iso.has(g.key);
      const col = S.color === 'container' && inner ? containerColor(g) : (g === 'pillar' ? color('--infra') : color('--cyl'));
      const cyl = new THREE.Mesh(new THREE.CylinderGeometry(r.R, r.R, Math.max(hi - lo, 1), 72, 1, true), new THREE.MeshBasicMaterial({
        color: col, transparent: true, opacity: iso ? 0.08 : inner ? 0.035 : 0.012, depthWrite: false, side: THREE.DoubleSide }));
      cyl.position.set(r.x, (lo + hi) / 2, r.z); root.add(cyl);
      const ringGeo = circle(r.R);
      for (const s of visibleSlots) {
        const ring = new THREE.Line(ringGeo, iso ? new THREE.LineBasicMaterial({ color: color('--accent'), transparent: true, opacity: 0.9 }) : outlineMat(inner, S.color === 'container' && inner ? col : null));
        ring.position.set(r.x, P.slotY(s), r.z); root.add(ring);
      }
      overlay.push({ cls: 'lbl' + (inner ? '' : ' outer') + (iso ? ' iso' : ''), text: g === 'pillar' ? 'infrastructure' : g.label, cont: g, R: r.R,
        pos: new THREE.Vector3(r.x, hi + 2, r.z - r.R), centre: new THREE.Vector3(r.x, hi, r.z) });
    }""", """    const spans = P.flat ? null : containerSpans(visibleSlots);
    for (const { g, r } of conts) {
      const depth = g === 'pillar' ? deepest : g.depth;
      const inner = depth === deepest || (g !== 'pillar' && !g.kids.length);
      const iso = g !== 'pillar' && S.iso.has(g.key);
      const col = S.color === 'container' && inner ? containerColor(g) : (g === 'pillar' ? color('--infra') : color('--cyl'));
      // From its lowest occupied plane to its highest; a plane inside the span with none of its classes rings fainter.
      const sp = spans && g !== 'pillar' ? spans.get(g) : null, slots = sp ? spanSlots(sp, visibleSlots) : visibleSlots;
      const yLo = slots.length ? P.slotY(slots[0]) : lo, yHi = slots.length ? P.slotY(slots[slots.length - 1]) : hi;
      const wallOp = iso ? 0.08 : inner ? 0.035 : 0.012;
      if (P.flat || slots.length > 1) {
        const cyl = new THREE.Mesh(new THREE.CylinderGeometry(r.R, r.R, Math.max(yHi - yLo, 1), 72, 1, true), new THREE.MeshBasicMaterial({
          color: col, transparent: true, opacity: wallOp, depthWrite: false, side: THREE.DoubleSide }));
        cyl.position.set(r.x, (yLo + yHi) / 2, r.z); root.add(cyl);
      } else {
        const disc = new THREE.Mesh(new THREE.CircleGeometry(r.R, 72), new THREE.MeshBasicMaterial({ color: col, transparent: true, opacity: wallOp * 1.6, depthWrite: false, side: THREE.DoubleSide }));
        disc.rotation.x = -Math.PI / 2; disc.position.set(r.x, yLo - 0.2, r.z); root.add(disc);
      }
      const ringGeo = circle(r.R);
      for (const s of slots) {
        const k = sp && !sp.occ.has(s) ? 0.35 : 1;
        const ring = new THREE.Line(ringGeo, iso ? new THREE.LineBasicMaterial({ color: color('--accent'), transparent: true, opacity: 0.9 * k }) : outlineMat(inner, S.color === 'container' && inner ? col : null, k));
        ring.position.set(r.x, P.slotY(s), r.z); root.add(ring);
      }
      overlay.push({ cls: 'lbl' + (inner ? '' : ' outer') + (iso ? ' iso' : ''), text: g === 'pillar' ? 'infrastructure' : g.label, cont: g, R: r.R,
        pos: new THREE.Vector3(r.x, yHi + 2, r.z - r.R), centre: new THREE.Vector3(r.x, yHi, r.z) });
    }""")
rep("""      const y1 = top + ROW_H * (deepest - depth + 1) - 2;
      rect(r.x0, r.x1, -2, y1, iso ? new THREE.LineBasicMaterial({ color: color('--accent'), transparent: true, opacity: 0.9 }) : outlineMat(inner, S.color === 'container' && inner ? col : null));
      if (inner) {
        const fill = new THREE.Mesh(new THREE.PlaneGeometry(r.x1 - r.x0, top + 2), new THREE.MeshBasicMaterial({ color: col, transparent: true, opacity: 0.05, depthWrite: false }));
        fill.position.set((r.x0 + r.x1) / 2, top / 2 - 1, -1); root.add(fill);
      }
      overlay.push({ cls: 'lbl side' + (inner ? '' : ' outer') + (iso ? ' iso' : ''), text: g === 'pillar' ? 'infrastructure' : g.label, cont: g, x0: r.x0, x1: r.x1,
        pos: new THREE.Vector3((r.x0 + r.x1) / 2, top + ROW_H * (deepest - depth + 0.5), 0) });""", """      // The column spans the bands from its lowest occupied layer to its highest, with its header on top of that.
      const sp = g !== 'pillar' ? spans.get(g) : null, slots = sp ? spanSlots(sp, visibleSlots).filter(s => SL.bandH[s] > 0) : [];
      const y0 = slots.length ? SL.bandY[slots[0]] - 2 : -2, spanTop = slots.length ? SL.bandY[slots[slots.length - 1]] + SL.bandH[slots[slots.length - 1]] + 12 : top;
      const y1 = spanTop + ROW_H * (deepest - depth + 1) - 2;
      rect(r.x0, r.x1, y0, y1, iso ? new THREE.LineBasicMaterial({ color: color('--accent'), transparent: true, opacity: 0.9 }) : outlineMat(inner, S.color === 'container' && inner ? col : null));
      if (inner) {
        const fill = new THREE.Mesh(new THREE.PlaneGeometry(r.x1 - r.x0, spanTop - y0), new THREE.MeshBasicMaterial({ color: col, transparent: true, opacity: 0.05, depthWrite: false }));
        fill.position.set((r.x0 + r.x1) / 2, (y0 + spanTop) / 2, -1); root.add(fill);
      }
      overlay.push({ cls: 'lbl side' + (inner ? '' : ' outer') + (iso ? ' iso' : ''), text: g === 'pillar' ? 'infrastructure' : g.label, cont: g, x0: r.x0, x1: r.x1,
        pos: new THREE.Vector3((r.x0 + r.x1) / 2, spanTop + ROW_H * (deepest - depth + 0.5), 0) });""")
rep("""    const conts = drawn.map(g => ({ g, r: SL.cont.get(g) })).filter(x => x.r && x.r.w > 0);""",
    """    const conts = drawn.map(g => ({ g, r: SL.cont.get(g) })).filter(x => x.r && x.r.w > 0), spans = containerSpans(visibleSlots);""")
rep("""      + `<div class="sub">${SLOT_ORDER.filter(s => by[s]).map(s => `${LAYER_NAMES[s]} ${by[s]}`).join(' · ')}</div>`;""",
    """      + `<div class="sub">${SLOT_ORDER.filter(s => by[s]).map(s => `${LAYER_NAMES[s]} ${by[s]}`).join(' · ')}</div>`
      + `<div>Layer span: ${esc(layerSpanText(nodes))}</div>`;
  }
  // Lowest to highest layer among a container's shown classes (all of them when none is shown); unplaced classes count
  // only when nothing is placed.
  function layerSpanText(nodes) {
    const pool = nodes.some(n => V.shown(n)) ? nodes.filter(n => V.shown(n)) : nodes, placed = pool.filter(n => n.slot !== 4);
    if (!placed.length) return pool.length ? 'unplaced only' : 'empty';
    const ks = placed.map(n => SLOT_ORDER.indexOf(n.slot)), lo = SLOT_ORDER[Math.min(...ks)], hi = SLOT_ORDER[Math.max(...ks)];
    const extra = placed.length < pool.length ? ` (plus ${pool.length - placed.length} unplaced)` : '';
    return (lo === hi ? `${LAYER_NAMES[lo]} only` : `${LAYER_NAMES[lo]} → ${LAYER_NAMES[hi]}`) + extra;""")
open(p, 'w').write(s)
print('ok')
