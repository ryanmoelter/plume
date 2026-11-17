import sys

# Round 8.1, applied after p8.py: every route highlighted, quiet context, direction, floors, side spans.
p = sys.argv[1]
s = open(p).read()


def rep(old, new, n=1):
    global s
    assert s.count(old) == n, 'COUNT %d: %s' % (s.count(old), old[:120])
    s = s.replace(old, new)


# ---------- state and settings ----------
rep("""sel2: null, selHist: [], pane: 'settings', pulses: store.get('pulses', true),""",
    """sel2: null, selHist: [], pane: 'settings', pulses: store.get('pulses', true),
    dimOthers: store.get('dimOthers', true), pickDirDefault: store.get('pickDir2', 'both'), pickDir: null, segPrev: null,
    floor: store.get('floor', 'all'), floorHide: store.get('floorHide', false),""")
rep("""        <label class="row"><input type="checkbox" id="pulses"><span>Flow pulses</span></label>""",
    """        <label class="row"><input type="checkbox" id="pulses"><span>Flow pulses</span></label>
        <div class="field"><span>Strand direction</span>
          <select id="pick-dir"><option value="both">Both</option><option value="up">Upstream</option><option value="down">Downstream</option></select></div>
        <label class="row"><input type="checkbox" id="dim-others"><span>Dim other connections while selecting</span></label>""")
rep("""  $('pulses').checked = S.pulses;""", """  $('pulses').checked = S.pulses;
  $('pick-dir').value = S.pickDirDefault; $('dim-others').checked = S.dimOthers !== false;
  $('pick-dir').onchange = e => { S.pickDirDefault = e.target.value; store.set('pickDir2', S.pickDirDefault); S.pickDir = null; applyHighlight(); };
  $('dim-others').onchange = e => { S.dimOthers = e.target.checked; store.set('dimOthers', S.dimOthers); applyHighlight(); };""")
rep("""    S.sel = sel; S.sel2 = null; S.moreStrands = false;""", """    S.sel = sel; S.sel2 = null; S.moreStrands = false; S.pickDir = null; S.segPrev = null;""")

# ---------- Details controls ----------
rep("""[data-focus],[data-show-trace],[data-conn]');""", """[data-focus],[data-show-trace],[data-conn],[data-pdir],[data-sel2]');""")
rep("""    else if (d.focus) { if (d.focus === 'pick') focusPick(); else focusOn(d.focus); }""",
    """    else if (d.focus) { if (d.focus === 'pick') focusPick(); else focusOn(d.focus); }
    else if (d.pdir) { S.pickDir = d.pdir; applyHighlight(); }
    else if (d.sel2) { const [t, point] = d.sel2.split(':').map(Number), prev = S.segPrev; if (prev) { S.selHist.push({ sel: S.sel, sel2: S.sel2 }); setSel(prev); S.sel2 = { t, point }; applyHighlight(); } }""")
rep("""    if (s && V.pick && ['node', 'member', 'cell'].includes(s.kind)) {""", """    if (s && s.kind === 'seg') html = segDetails(s);
    if (s && V.pick && ['node', 'member', 'cell', 'seg'].includes(s.kind)) {""")
rep("""      + `<div>Flags: ${esc(flags.concat(""", """      + `<p class="sub">Variables inside functions arrive with the next export.</p>`
      + `<div>Flags: ${esc(flags.concat(""")

# ---------- context edges: dimmed while selecting, gone at highlighted classes, ghosted off the floor ----------
rep("""    if (!B) map.set(key, B = { ga, sa: na.slot, gb, sb: nb.slot, count: 0, byKind: {} });
    B.count += c;""", """    if (!B) map.set(key, B = { ga, sa: na.slot, gb, sb: nb.slot, count: 0, byKind: {}, nodes: new Set() });
    B.count += c; B.nodes.add(a); B.nodes.add(b);""")
rep("""        const m = new THREE.Mesh(new THREE.TubeGeometry(curve, 16, Math.max(rad, unit * 0.12), 5, false), edgeMat(V.path ? 0.6 : 1));
        m.renderOrder = -1; root.add(m);""", """        const m = new THREE.Mesh(new THREE.TubeGeometry(curve, 16, Math.max(rad, unit * 0.12), 5, false), edgeMat(V.path ? 0.6 : 1));
        m.renderOrder = -1; root.add(m);
        Object.assign(edgeMats[edgeMats.length - 1], { mesh: m, nodes: B.nodes, sa: B.sa, sb: B.sb });""")
rep("""    const byTier = { base: [], near: [], far: [] };""", """    const byTier = { base: [], near: [], far: [] }, endsBy = { base: [], near: [], far: [] };""")
rep("""      byTier[edgeTier(V, a, b)].push(pa.x, pa.y + 1, pa.z, pb.x, pb.y + 1, pb.z);""",
    """      const tier = edgeTier(V, a, b); byTier[tier].push(pa.x, pa.y + 1, pa.z, pb.x, pb.y + 1, pb.z); endsBy[tier].push(a, b);""")
rep("""      g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
      const mat = new THREE.LineBasicMaterial({ color: em(edgeEm(EDGE_TIER[tier])), transparent: true, opacity: 1, depthWrite: false });
      edgeMats.push({ m: mat, factor: EDGE_TIER[tier] });""", """      g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
      g.setAttribute('color', new THREE.Float32BufferAttribute(new Float32Array(pos.length), 3));
      const mat = new THREE.LineBasicMaterial({ color: 0xffffff, vertexColors: true, transparent: true, opacity: 1, depthWrite: false });
      edgeMats.push({ m: mat, factor: EDGE_TIER[tier], geo: g, ends: endsBy[tier] });""")
rep("""  function retuneEdges() {
    for (const { m, factor } of edgeMats) m.color.copy(em(edgeEm(factor)));
    for (const { m, inner, tint, k } of outlineMats) m.opacity = k * Math.min(1, outlineEm(inner) + (tint ? 0.15 : 0));""",
    """  // While a selection's strand is drawn, context edges drop to EDGE_QUIET of their strength, and any edge touching a
  // highlighted class is not drawn, so nothing leaving a strand class reads as part of it. Off the chosen
  // floor an edge ghosts, or hides with "Hide other floors". An edge's strength is pre-blended, so 0 is invisible.
  const EDGE_QUIET = 0.3;
  function edgeQuiet() {
    const on = S.dimOthers !== false && V && V.pick && V.pick.R.core.length;
    return { k: on ? EDGE_QUIET : 1, hide: on ? new Set(V.pick.nodes) : null, floor: floorOn() ? S.floor : null };
  }
  const floorK = (q, sa, sb) => (q.floor == null || (sa === q.floor && sb === q.floor) ? 1 : S.floorHide ? 0 : 0.3);
  function edgeFactor(q, a, b) {
    if (q.hide && (q.hide.has(a) || q.hide.has(b))) return 0;
    return q.k * floorK(q, M.nodes[a].slot, M.nodes[b].slot);
  }
  function retuneEdges() {
    const q = edgeQuiet();
    for (const e of edgeMats) {
      if (e.ends) {
        const col = e.geo.attributes.color, arr = col.array;
        for (let i = 0; i < e.ends.length; i += 2) { const c = em(edgeEm(e.factor) * edgeFactor(q, e.ends[i], e.ends[i + 1])); arr.set([c.r, c.g, c.b, c.r, c.g, c.b], i * 3); }
        col.needsUpdate = true;
      } else if (e.nodes) {
        let f = q.k * floorK(q, e.sa, e.sb);
        if (q.hide) for (const x of e.nodes) if (q.hide.has(x)) { f = 0; break; }
        e.m.color.copy(em(edgeEm(e.factor) * f)); e.mesh.visible = f > 0;
      } else e.m.color.copy(em(edgeEm(e.factor)));
    }
    for (const { m, inner, tint, k, slot } of outlineMats) m.opacity = k * (slot == null ? 1 : floorK(q, slot, slot)) * Math.min(1, outlineEm(inner) + (tint ? 0.15 : 0));""")
# Counts for the checks: context edges drawn, and drawn edges touching a highlighted class.
rep("""  function showHoverEdges(n) {""", """  function contextEdgeStats() {
    const q = edgeQuiet(), prim = V.pick && V.pick.R.core.length ? new Set(V.pick.nodes) : new Set();
    let total = 0, drawn = 0, touching = 0, faintest = Infinity, strongest = 0;
    for (const e of edgeMats) {
      if (e.ends) for (let i = 0; i < e.ends.length; i += 2) { total++; const f = edgeFactor(q, e.ends[i], e.ends[i + 1]); if (f > 0) { drawn++; faintest = Math.min(faintest, f); strongest = Math.max(strongest, f); if (prim.has(e.ends[i]) || prim.has(e.ends[i + 1])) touching++; } }
      else if (e.nodes) { total++; if (e.mesh.visible) { drawn++; if ([...e.nodes].some(x => prim.has(x))) touching++; } }
    }
    return { total, drawn, touching, k: q.k, individual: edgeMats.some(e => e.ends), hover: !!hoverLines };
  }
  function showHoverEdges(n) {
    // A selected class's own edges stay off while its strand is drawn quiet; hovering it still shows them.
    if (n && n === S.selected && n !== S.hover && S.dimOthers !== false && V && V.pick && V.pick.R.core.length) n = null;""")

# ---------- floors ----------
rep("""      <div class="hint" id="hint"></div>
    </div>""", """      <div class="hint" id="hint"></div>
      <div class="floors" id="floors" role="group" aria-label="Floors"></div>
    </div>""")
rep("""[hidden] { display: none !important; }""", """[hidden] { display: none !important; }
.floors { position: absolute; right: 10px; bottom: 34px; display: flex; flex-direction: column; gap: 0; width: 118px; font: 12px var(--font-body); z-index: 3; }
.floors .fl { display: flex; align-items: center; gap: 6px; justify-content: space-between; border: 1px solid var(--rule); border-top-width: 0; background: color-mix(in srgb, var(--surface) 92%, transparent); color: var(--ink); padding: 4px 8px; cursor: pointer; font: inherit; text-align: left; min-height: 28px; }
.floors .fl:first-child { border-top-width: 1px; border-radius: 6px 6px 0 0; }
.floors .fl:last-of-type { border-radius: 0 0 6px 6px; }
.floors .fl[aria-pressed="true"] { background: var(--ink); color: var(--bg); }
.floors .fl .c { font: 11px var(--font-mono); opacity: .75; display: flex; align-items: center; gap: 4px; }
.floors .fl .d { width: 7px; height: 7px; border-radius: 50%; background: var(--accent); display: inline-block; }
.floors .fl .d.off { background: transparent; }
.floors label { display: flex; gap: 6px; align-items: center; margin-top: 6px; padding: 3px 6px; border-radius: 5px; background: color-mix(in srgb, var(--surface) 92%, transparent); color: var(--ink); font-size: 11px; cursor: pointer; }
.stage:focus { outline: none; }
.stage:focus-visible .floors .fl[aria-pressed="true"] { outline: 2px solid var(--accent); outline-offset: -2px; }
.lbl.chev { font: 600 11px var(--font-body); color: var(--bg); background: var(--branch); border-radius: 9px; padding: 1px 6px; transform: translate(8px, -50%); z-index: 2; }
.lbl.chev:hover { background: var(--accent); color: var(--bg); }
.lbl.layer.cur { color: var(--accent); }
.det .pctl { display: grid; grid-template-columns: auto 1fr; gap: 6px 8px; align-items: center; margin: 2px 0 8px; }
.det .segd { display: flex; flex-wrap: wrap; }
.det .segd .btn { border-radius: 0; margin-left: -1px; padding: 3px 8px; font-size: 12px; }
.det .segd .btn:first-child { border-radius: 5px 0 0 5px; margin-left: 0; }
.det .segd .btn:last-child { border-radius: 0 5px 5px 0; }
.det .segd .btn.on { background: var(--ink); color: var(--bg); border-color: var(--ink); }
.det button.lnk.rt { display: block; width: 100%; white-space: normal; overflow-wrap: anywhere; margin: 2px 0; border: 1px solid transparent; }
.det button.lnk.rt.on { border-color: var(--branch); color: var(--ink); }""")
rep("""@media (max-width: 820px) {""", """@media (max-width: 820px) {
  .floors { right: 6px; bottom: 30px; width: 104px; font-size: 11px; }
  .floors .fl { min-height: 26px; padding: 3px 6px; }""")
rep("""@media (max-width: 820px) {""", """.floors .short { display: none; }
@media (max-width: 520px) {
  .stage .floors { left: 6px; right: 6px; width: auto; flex-direction: row; flex-wrap: wrap; }
  .stage .floors .fl { flex: 1 1 0; min-width: 0; justify-content: center; gap: 3px; border-top-width: 1px; border-left-width: 0; padding: 2px 3px; min-height: 30px; }
  .stage .floors .fl:first-child { border-left-width: 1px; border-radius: 6px 0 0 6px; }
  .stage .floors .fl:last-of-type { border-radius: 0 6px 6px 0; }
  .stage .floors .fl .n, .stage .floors .full { display: none; }
  .stage .floors .short { display: inline; }
  .stage .floors label { margin: 4px 0 0 auto; }
}
@media (max-width: 820px) {""")

# Floor state, the picker, chevrons, keyboard.
rep("""  function setSel(sel, show) {""", """  // Floors: S.floor is 'all' or a slot. A floor shows its layer's classes at full strength and ghosts the rest, or
  // hides them with "Hide other floors". Positions never move: a floor change only re-highlights.
  const FLOORS = ['all', ...SLOT_ORDER.slice().reverse()];
  const floorOn = () => S.floor != null && S.floor !== 'all';
  const FLOOR_SHORT = ['Ext', 'Data', 'Pres', 'UI', 'Unpl'];
  const floorName = f =>(f === 'all' ? 'All' : LAYER_NAMES[f][0].toUpperCase() + LAYER_NAMES[f].slice(1));
  const floorGhost = n => floorOn() && n.slot !== S.floor;
  const floorHidden = n => floorGhost(n) && S.floorHide;
  function setFloor(f) { if (f !== 'all') f = +f; S.floor = f; store.set('floor', f); applyHighlight(); }
  function stepFloor(d) { const i = Math.max(0, FLOORS.indexOf(S.floor)); setFloor(FLOORS[Math.max(0, Math.min(FLOORS.length - 1, i + d))]); }
  function floorCounts() {
    const by = { all: 0 }; for (const s of SLOT_ORDER) by[s] = 0;
    for (const n of M.nodes) if (V.shown(n)) { by.all++; by[n.slot]++; }
    return by;
  }
  function renderFloors() {
    const el = $('floors'); if (!el) return;
    const by = floorCounts(), P = V.pick && V.pick.R.core.length ? V.pick : null;
    const touched = new Set(P ? P.strongNodes.map(x => M.nodes[x].slot) : []);
    el.innerHTML = FLOORS.map(f => `<button class="fl" data-floor="${f}" aria-pressed="${f === S.floor}" title="${f === 'all' ? 'Every floor' : floorName(f) + ' layer'}: ${by[f]} classes"><span><span class="full">${floorName(f)}</span><span class="short">${f === 'all' ? 'All' : FLOOR_SHORT[f]}</span></span><span class="c">${P && f !== 'all' ? `<span class="d${touched.has(f) ? '' : ' off'}" title="${touched.has(f) ? 'The strand touches this floor' : ''}"></span>` : ''}<span class="n">${by[f]}</span></span></button>`).join('')
      + `<label><input type="checkbox" id="floor-hide" ${S.floorHide ? 'checked' : ''}><span class="full">Hide other floors</span><span class="short">Hide others</span></label>`;
  }
  function setSel(sel, show) {""")
rep("""  $('pick-dir').value = S.pickDirDefault;""", """  $('floors').onclick = e => {
    const b = e.target.closest('[data-floor]'); if (b) { setFloor(b.dataset.floor); return; }
    if (e.target.id === 'floor-hide') { S.floorHide = e.target.checked; store.set('floorHide', S.floorHide); applyHighlight(); }
  };
  if (stage.setAttribute) stage.setAttribute('tabindex', '0');
  stage.addEventListener('keydown', e => {
    if (e.key !== 'ArrowUp' && e.key !== 'ArrowDown') return;
    if (e.target && e.target.closest && e.target.closest('input,select,textarea')) return;
    e.preventDefault(); stepFloor(e.key === 'ArrowUp' ? -1 : 1);
  });
  cv.addEventListener('pointerdown', () => { if (stage.focus) stage.focus({ preventScroll: true }); });
  $('pick-dir').value = S.pickDirDefault;""")
# Nodes, rings, planes and bands follow the floor.
rep("""      m.userData.cur = dim ? Math.min(m.userData.op, Math.max(m.userData.op * 0.3, floor)) : m.userData.op;
      m.material.opacity = m.userData.cur;
      for (const r of m.userData.rings) r.material.opacity = r.userData.op * (dim ? 0.35 : 1);""",
    """      m.userData.cur = dim ? Math.min(m.userData.op, Math.max(m.userData.op * 0.3, floor)) : m.userData.op;
      const ghost = floorGhost(m.userData.n), hid = ghost && S.floorHide;
      if (ghost) m.userData.cur *= hid ? 0 : 0.14;
      m.material.opacity = m.userData.cur; m.visible = !hid;
      m.userData.active = !dim && !ghost; if (!m.userData.active) inactiveNodes.add(m.userData.n.i);
      for (const r of m.userData.rings) { r.material.opacity = r.userData.op * (dim ? 0.35 : 1) * (ghost ? 0.14 : 1); r.visible = !hid; }""")
rep("""    renderLabels(true);
    for (const o of overlay) if (o.cont && o.el) o.el.classList.toggle('picked', !!selKey && o.cont !== 'pillar' && o.cont.key === selKey);
    hlVersion++; memKey = ''; wake();""", """    // Where the strong strands leave the floor: a chevron per class, pointing to the floor it goes to.
    overlay = overlay.filter(o => !o.chev);
    const perChev = new Map();
    for (const x of floorExits(V.pick)) {
      const n = M.nodes[x.n]; if (!V.shown(n)) continue;
      const p = npos(n); if (!p) continue; if (!side()) p.y += 2;
      const k = perChev.get(x.n) || 0; perChev.set(x.n, k + 1);
      const up = SLOT_ORDER.indexOf(x.to) > SLOT_ORDER.indexOf(S.floor);
      overlay.push({ cls: 'lbl chev', text: `${up ? '▲' : '▼'} ${LAYER_NAMES[x.to]}`, pos: p, chev: x, dy: k * 18 });
    }
    for (const o of sceneRoot()) if (o.userData.floorSlot != null) {
      const f = o.userData.floorSlot, k = !floorOn() ? 1 : f === S.floor ? (o.userData.band ? 2.2 : 2) : S.floorHide ? 0.25 : 0.45;
      o.material.opacity = o.userData.op0 * k;
    }
    renderLabels(true);
    for (const o of overlay) if (o.cont && o.el) o.el.classList.toggle('picked', !!selKey && o.cont !== 'pillar' && o.cont.key === selKey);
    for (const o of overlay) if (o.layerSlot != null && o.el) o.el.classList.toggle('cur', floorOn() && o.layerSlot === S.floor);
    retuneEdges(); renderFloors(); showHoverEdges(S.hover || S.selected);
    hlVersion++; memKey = ''; wake();""")
rep("""  function contextEdgeStats() {""", """  const sceneRoot = () => (root ? root.children : []);
  function contextEdgeStats() {""")
rep("""        if (o.stub) el.onclick = () => setSel({ kind: 'sibs', tree: V.T.i, at: o.stub.at }, true);""",
    """        if (o.stub) el.onclick = () => setSel({ kind: 'sibs', tree: V.T.i, at: o.stub.at }, true);
        if (o.chev) { el.title = `The strand continues on the ${LAYER_NAMES[o.chev.to]} floor`; el.onclick = e => { if (e.stopPropagation) e.stopPropagation(); setFloor(o.chev.to); }; }""")
rep("""    const cand = overlay.filter(o => o.px && !o.cls.includes('layer') && !o.stub);""",
    """    const cand = overlay.filter(o => o.px && !o.cls.includes('layer') && !o.stub && !o.chev);""")
rep("""      if (!V.shown(n) || !M.mem.of[n.i].length) continue;
      const p = npos(n); if (!p) continue;
      const R = V.rad(n);""", """      if (!V.shown(n) || !M.mem.of[n.i].length || floorHidden(n)) continue;
      const p = npos(n); if (!p) continue;
      const R = V.rad(n);""")
rep("""    const hit = ray.intersectObjects(nodeMeshes, false);""", """    const hit = ray.intersectObjects(nodeMeshes, false).filter(h => h.object.visible && h.object.userData.active !== false);""")
# Plane sheets and side bands carry their slot.
rep("""      m.rotation.x = -Math.PI / 2; m.position.set((b.minX + b.maxX) / 2, y - 0.5, (b.minZ + b.maxZ) / 2);
      root.add(m);""", """      m.rotation.x = -Math.PI / 2; m.position.set((b.minX + b.maxX) / 2, y - 0.5, (b.minZ + b.maxZ) / 2);
      root.add(m); if (!P.flat) { m.userData.floorSlot = s; m.userData.op0 = m.material.opacity; }""")
rep("""      line.rotation.x = -Math.PI / 2; line.position.copy(m.position); root.add(line);
      if (!P.flat) overlay.push({ cls: 'lbl layer', text: (s === 4 ? '' : s + ' ') + LAYER_NAMES[s], pos: new THREE.Vector3(b.maxX + pad + 6, y, b.maxZ + pad) });""",
    """      line.rotation.x = -Math.PI / 2; line.position.copy(m.position); root.add(line);
      if (!P.flat) { line.userData.floorSlot = s; line.userData.op0 = 1; }
      if (!P.flat) overlay.push({ cls: 'lbl layer', text: (s === 4 ? '' : s + ' ') + LAYER_NAMES[s], pos: new THREE.Vector3(b.maxX + pad + 6, y, b.maxZ + pad), layerSlot: s });""")
rep("""      m.position.set((minX + maxX) / 2, y, -2); root.add(m);
      overlay.push({ cls: 'lbl layer side-band', text: (s === 4 ? '' : s + ' ') + LAYER_NAMES[s], pos: new THREE.Vector3(minX, y, 0) });""",
    """      m.position.set((minX + maxX) / 2, y, -2); root.add(m); m.userData.floorSlot = s; m.userData.op0 = m.material.opacity; m.userData.band = true;
      overlay.push({ cls: 'lbl layer side-band', text: (s === 4 ? '' : s + ' ') + LAYER_NAMES[s], pos: new THREE.Vector3(minX, y, 0), layerSlot: s });""")
# 3D container rings on a plane follow the floor.
rep("""  function outlineMat(inner, tint, k = 1) {
    const m = new THREE.LineBasicMaterial({ color: tint || color('--ink'), transparent: true, opacity: k * Math.min(1, outlineEm(inner) + (tint ? 0.15 : 0)), depthWrite: false });
    outlineMats.push({ m, inner, tint, k }); return m;""", """  function outlineMat(inner, tint, k = 1, slot = null) {
    const m = new THREE.LineBasicMaterial({ color: tint || color('--ink'), transparent: true, opacity: k * Math.min(1, outlineEm(inner) + (tint ? 0.15 : 0)), depthWrite: false });
    outlineMats.push({ m, inner, tint, k, slot }); return m;""")
rep("""        const ring = new THREE.Line(ringGeo, iso ? new THREE.LineBasicMaterial({ color: color('--accent'), transparent: true, opacity: 0.9 * k }) : outlineMat(inner, S.color === 'container' && inner ? col : null, k));""",
    """        const ring = new THREE.Line(ringGeo, iso ? new THREE.LineBasicMaterial({ color: color('--accent'), transparent: true, opacity: 0.9 * k }) : outlineMat(inner, S.color === 'container' && inner ? col : null, k, P.flat ? null : s));""")

# ---------- side spans: box edges on band edges; a header only where it fits ----------
rep("""      const y0 = slots.length ? SL.bandY[slots[0]] - 2 : -2, spanTop = slots.length ? SL.bandY[slots[slots.length - 1]] + SL.bandH[slots[slots.length - 1]] + 12 : top;
      const y1 = spanTop + ROW_H * (deepest - depth + 1) - 2;""",
    """      // Box edges sit on band edges. Only a span that reaches the top band gets the header rows above it; a lower
      // span's box stops at its band's top, with its header on that edge. Unplaced-only spans keep the header inside.
      const topBand = visibleSlots.filter(x => SL.bandH[x] > 0).pop();
      const y0 = slots.length ? SL.bandY[slots[0]] : 0, spanTop = slots.length ? SL.bandY[slots[slots.length - 1]] + SL.bandH[slots[slots.length - 1]] + 12 : top;
      const reachesTop = !slots.length || slots[slots.length - 1] === topBand, onlyUnplaced = slots.length === 1 && slots[0] === 4;
      const y1 = reachesTop ? spanTop + ROW_H * (deepest - depth + 1) - 2 : spanTop;
      const headY = reachesTop ? spanTop + ROW_H * (deepest - depth + 0.5) : onlyUnplaced ? spanTop - ROW_H * (depth - 0.5) - 1 : spanTop + ROW_H * (deepest - depth) * 0.5;""")
rep("""        pos: new THREE.Vector3((r.x0 + r.x1) / 2, spanTop + ROW_H * (deepest - depth + 0.5), 0) });""",
    """        pos: new THREE.Vector3((r.x0 + r.x1) / 2, headY, 0), edge: !reachesTop && !onlyUnplaced });""")
rep("""        if (o.x0 != null) { const a = toPx(new THREE.Vector3(o.x0, o.pos.y, 0)), b = toPx(new THREE.Vector3(o.x1, o.pos.y, 0)); px = b[0] - a[0]; o.el.style.maxWidth = Math.max(0, px - 2) + 'px'; off = px < 22; }""",
    """        if (o.x0 != null) { const a = toPx(new THREE.Vector3(o.x0, o.pos.y, 0)), b = toPx(new THREE.Vector3(o.x1, o.pos.y, 0)); px = b[0] - a[0]; o.el.style.maxWidth = Math.max(0, px - 2) + 'px'; off = px < Math.min(o.text.length * 6.7 + 8, 160); }""")
rep(""".lbl.side { transform: translate(-50%, -50%); text-align: center; background: transparent; }""",
    """.lbl.side { transform: translate(-50%, -50%); text-align: center; background: transparent; }
.lbl.side.edge { background: color-mix(in srgb, var(--bg) 80%, transparent); }""")
rep("""      overlay.push({ cls: 'lbl side' + (inner ? '' : ' outer') + (iso ? ' iso' : ''), text: g === 'pillar' ? 'infrastructure' : g.label, cont: g, x0: r.x0, x1: r.x1,
        pos: new THREE.Vector3((r.x0 + r.x1) / 2, headY, 0)""", """      overlay.push({ cls: 'lbl side' + (inner ? '' : ' outer') + (iso ? ' iso' : '') + (!reachesTop && !onlyUnplaced ? ' edge' : ''), text: g === 'pillar' ? 'infrastructure' : g.label, cont: g, x0: r.x0, x1: r.x1,
        pos: new THREE.Vector3((r.x0 + r.x1) / 2, headY, 0)""")

# Focus on a selection's strands keeps exactly the highlighted classes: the context setting adds nothing to it.
rep("""  const ctx = S.ctx || 'none';
  const hopCells""", """  const ctx = focus === 'pick' ? 'none' : S.ctx || 'none';
  const hopCells""")
rep("""    if (S.ctx === 'none') { $('focus-stat').textContent = `No context: only ${core}, ${kept}.`;""",
    """    if (V.ctx === 'none') { $('focus-stat').textContent = `No context${V.focus === 'pick' && S.ctx !== 'none' ? ' (Focus keeps only the highlighted classes)' : ''}: only ${core}, ${kept}.`;""")

# ---------- legend, about, exports ----------
rep("""      + `<div>${line('var(--branch)')}Strands through the selection</div>`""",
    """      + `<div>${line('var(--branch)')}Every drawn route through the selection, with arrowheads and pulses</div>`
      + `<div>${line('color-mix(in srgb, var(--branch) 50%, var(--bg))')}With a second point: continuations beyond either end, arrowheads only</div>`
      + `<div style="display:flex;gap:6px;align-items:center"><span class="lbl chev" style="position:static;transform:none">▲ ui</span>The strand continues on another floor</div>`""")
rep("""A second click on those strands joins the two points. Faint pulses drift the way data flows.""",
    """Every drawn route through it is highlighted at one level, and other connections step back while it is shown. A second click on those strands highlights every route joining the two points. Hover any drawn line for what it is; click a strand segment to select it. The floor buttons at the map's edge show one layer at full strength and ghost the rest, without moving anything. Faint pulses drift the way data flows.""")
rep("""    focusPick, stepBackSelection,""", """    focusPick, stepBackSelection, setFloor, stepFloor, floorCounts, contextEdgeStats, floorExits: () => floorExits(V.pick), get edgeMats() { return edgeMats; },
    lineAt, lineTip, hoverRows, clickLine, targetOf, inactiveNodes, pickNode: pick, get hitLines() { return hitLines; }, get nodeMeshes() { return nodeMeshes; }, get overlay() { return overlay; },""")

# ---------- drawn lines: hit registry, hover, members hint ----------
rep("""hoverLines = null, dirty = true;
  let rafOn = false;""", """hoverLines = null, dirty = true;
  let rafOn = false, hitLines = [];
  // Classes dimmed by a highlight or ghosted by the floor picker: transparent to the pointer.
  const inactiveNodes = new Set();""")
rep("""    pulseLines = [];
    const per = { fn: [], init: [], prop: [], cell: [], hi: [] };""", """    pulseLines = []; hitLines = [];
    const per = { fn: [], init: [], prop: [], cell: [], hi: [] };""")
rep("""      const curve = tube(a.p, z.p, wpp * 1.4, acc, 10, bow);
      pulseLine('R' + i, curve.getPoints(10), wpp * 1.4, acc, 'solid', ['R' + (i - 1)]);""",
    """      const curve = tube(a.p, z.p, wpp * 1.4, acc, 10, bow);
      pulseLine('R' + i, curve.getPoints(10), wpp * 1.4, acc, 'solid', ['R' + (i - 1)]);
      hitLines.push({ pts: curve.getPoints(10), kind: 'trace', i, node: z.node, from: a.node >= 0 ? M.nodes[a.node].n : '?', to: z.node >= 0 ? M.nodes[z.node].n : '?' });""")
rep("""        if (a && z && a.distanceTo(z) > 1e-6) tube(a, z, wpp * 1.0, color('--conn'), 11, M.mem.n[E[4 * e]] === M.mem.n[E[4 * e + 1]] ? 0 : 6 * wpp);""",
    """        if (a && z && a.distanceTo(z) > 1e-6) {
          const curve = tube(a, z, wpp * 1.0, color('--conn'), 11, M.mem.n[E[4 * e]] === M.mem.n[E[4 * e + 1]] ? 0 : 6 * wpp);
          hitLines.push({ pts: curve.getPoints(8), kind: 'conn', a: E[4 * e], b: E[4 * e + 1], k: M.kinds[E[4 * e + 2]], c: E[4 * e + 3] });
        }""")
rep("""        Object.assign(edgeMats[edgeMats.length - 1], { mesh: m, nodes: B.nodes, sa: B.sa, sb: B.sb });""",
    """        Object.assign(edgeMats[edgeMats.length - 1], { mesh: m, nodes: B.nodes, sa: B.sa, sb: B.sb });""")
rep("""      const tier = edgeTier(V, a, b); byTier[tier].push(pa.x, pa.y + 1, pa.z, pb.x, pb.y + 1, pb.z); endsBy[tier].push(a, b);""",
    """      const tier = edgeTier(V, a, b); byTier[tier].push(pa.x, pa.y + 1, pa.z, pb.x, pb.y + 1, pb.z); endsBy[tier].push(a, b);""")
rep("""    const mm = memberAt(e);
    if (mm >= 0) { if (S.hover) { S.hover = null; showHoverEdges(S.selected); } showTip(null, e, describeMember(mm)); return; }""",
    """    const mm = memberAt(e);
    if (mm >= 0) { cv.style.cursor = 'pointer'; hoverRows(null); if (S.hover) { S.hover = null; showHoverEdges(S.selected); } showTip(null, e, describeMember(mm)); return; }
    const ln = lineAt(e);
    if (ln) { cv.style.cursor = 'pointer'; hoverRows(ln); if (S.hover) { S.hover = null; showHoverEdges(S.selected); } showTip(null, e, lineTip(ln)); return; }
    hoverRows(null);""")
rep("""    const cand = overlay.filter(o => o.px && !o.cls.includes('layer') && !o.stub && !o.chev);""",
    """    const cand = overlay.filter(o => o.px && !o.cls.includes('layer') && !o.stub && !o.chev);""")
rep(""".lbl.layer.cur { color: var(--accent); }""", """.lbl.layer.cur { color: var(--accent); }
.det .hov { background: color-mix(in srgb, var(--branch) 16%, transparent); outline: 1px solid var(--branch); border-radius: 3px; }
#steps li.hov { background: color-mix(in srgb, var(--accent) 14%, transparent); }
.hovpin { font-size: 12px; color: var(--ink); background: color-mix(in srgb, var(--branch) 16%, transparent); outline: 1px solid var(--branch); border-radius: 3px; padding: 3px 6px; margin: 4px 0; }
.memhint { position: absolute; left: 50%; top: 12px; transform: translateX(-50%); font-size: 12px; color: var(--ink); background: var(--surface); border: 1px solid var(--rule); border-radius: 6px; padding: 4px 10px; pointer-events: none; z-index: 4; max-width: calc(100% - 32px); }""")
rep("""      <div class="floors" id="floors" role="group" aria-label="Floors"></div>""", """      <div class="floors" id="floors" role="group" aria-label="Floors"></div>
      <div class="memhint" id="memhint" hidden>Click a member to see its data paths</div>""")
# The first time a class reveals its members, say they are clickable; it goes on the next click.
rep("""    if (key === memKey) return;
    memKey = key;""", """    if (key === memKey) return;
    memKey = key;
    if (revealed.length && !S.memHintSeen) { S.memHintSeen = true; store.set('memHint', true); $('memhint').hidden = false; }""")
rep("""sel2: null, selHist: [], pane: 'settings',""", """sel2: null, selHist: [], memHintSeen: store.get('memHint', false), pane: 'settings',""")
rep("""  cv.addEventListener('pointerdown', () => { if (stage.focus) stage.focus({ preventScroll: true }); });""",
    """  cv.addEventListener('pointerdown', () => { if (stage.focus) stage.focus({ preventScroll: true }); $('memhint').hidden = true; });""")


# ---------- round 8.2: edge strength default 0.05 ----------
rep("""  --edge-strength: 0.15; """, """  --edge-strength: 0.05; """)
rep("""  --edge-strength: 0.2;""", """  --edge-strength: 0.05;""", 2)
rep("""edgeStrength: store.get('edgeStrength', null),""", """edgeStrength: migrateEdgeStrength(store.get('edgeStrength', null)),""")
rep("""  const S = {""", """  // A stored strength equal to the old per-scheme default (0.15 light, 0.2 dark) was never chosen, so it follows the new default.
  function migrateEdgeStrength(v) {
    if (store.get('edgeStrength82', false)) return v;
    store.set('edgeStrength82', true);
    if (v == null) return v;
    let dark = false;
    try { const t = document.documentElement.dataset.theme; dark = t === 'dark' || (t !== 'light' && matchMedia('(prefers-color-scheme: dark)').matches); } catch (e) { }
    if (Math.abs(v - (dark ? 0.2 : 0.15)) > 1e-6) return v;
    store.set('edgeStrength', null); return null;
  }
  const S = {""")
rep("""parseFloat(css('--edge-strength')) || 0.15);""", """parseFloat(css('--edge-strength')) || 0.05);""")
rep("""const nodeFloor = () => Math.min(0.9, edgeEm(1) + 0.15);""", """const nodeFloor = () => Math.min(0.9, Math.max(edgeEm(1), emOf('divider')) + 0.15);""")

rep("""    const floor = nodeFloor();
    for (const m of nodeMeshes) {""", """    const floor = nodeFloor();
    inactiveNodes.clear();
    for (const m of nodeMeshes) {""")
rep("""      if (Math.hypot(x - R.x, y - R.y) > R.sr) continue;""", """      if (Math.hypot(x - R.x, y - R.y) > R.sr || inactiveNodes.has(R.n.i)) continue;""")
rep("""    if (mk) { showTip(null, e, markerTip(mk)); return; }""", """    if (mk) { cv.style.cursor = 'pointer'; showTip(null, e, markerTip(mk)); return; }""")
rep("""    showTip(n, e);
  });""", """    cv.style.cursor = n ? 'pointer' : '';
    showTip(n, e);
  });""")

open(p, 'w').write(s)
print('ok 8.1')
