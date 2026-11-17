  // Variables inside a revealed member: lambda groups packed in order (the member's own body first), each holding its
  // variables by rank, so the stateRead ones sit nearest the middle. Drawn once the member is VAR_REVEAL_PX across.
  const VAR_REVEAL_PX = 16, MAX_VARS = 6000, VAR_MAX_R = 0.26;
  let varPos = new Map(), spanMeshes = [];
  function varLayout(m) {
    if (!M.vlay) M.vlay = new Map();
    if (M.vlay.has(m)) return M.vlay.get(m);
    const VV = M.vars, list = (VV.byMem.get(m) || []).filter(v => VV.home(v) === m);
    let out = { vars: [], lams: [] };
    if (list.length) {
      const byLam = new Map();
      for (const v of list) { const k = VV.lam[v]; if (!byLam.has(k)) byLam.set(k, []); byLam.get(k).push(v); }
      const rk = v => VAR_RANK_ORDER[VV.rank[v]];
      for (const g of byLam.values()) g.sort((a, b) => rk(a) - rk(b) || VV.line[a] - VV.line[b] || a - b);
      const groups = [...byLam.entries()].sort((a, b) => (a[0] >= 0) - (b[0] >= 0) || rk(a[1][0]) - rk(b[1][0]) || a[0] - b[0]);
      const h = d3.hierarchy({ children: groups.map(([lam, vs]) => ({ lam, children: vs.map(v => ({ v })) })) }).sum(d => (d.v != null ? 1 : 0));
      d3.pack().size([2, 2]).padding(0.05)(h);
      const leaves = h.leaves(), k = Math.min(1, VAR_MAX_R / Math.max(...leaves.map(l => l.r)));
      out = {
        vars: leaves.map(l => ({ v: l.data.v, x: (l.x - 1) * k, y: (l.y - 1) * k, r: l.r * k * 0.85 })),
        lams: (h.children || []).filter(c => c.data.lam >= 0 && groups.length > 1).map(c => ({ lam: c.data.lam, x: (c.x - 1) * k, y: (c.y - 1) * k, r: c.r * k })),
      };
    }
    M.vlay.set(m, out);
    return out;
  }
  // Called per drawn member: q is its centre, rr its radius in world units, pr its radius on screen.
  function placeVars(per, it, q, rr, pr, f, n, s) {
    if (pr < VAR_REVEAL_PX || per.var.length >= MAX_VARS) return;
    const L = varLayout(it.m); if (!L.vars.length) return;
    const sel = S.sel && S.sel.kind === 'var' ? S.sel.v : -1, inner = rr * 0.86;
    const at = (x, y) => (side() ? new THREE.Vector3(q.x + x * inner, q.y + y * inner, q.z + 0.3) : new THREE.Vector3(q.x + x * inner, q.y + 0.25, q.z + y * inner));
    for (const c of L.lams) per.lam.push([at(c.x, c.y), c.r * inner, it.m, f]);
    for (const x of L.vars) {
      const p = at(x.x, x.y), r = x.r * inner;
      varPos.set(x.v, { p, r, n: n.i, s });
      per.var.push([p, r, x.v, f]);
      if (x.v === sel) per.vhi.push([p, r, x.v, 1]);
    }
  }
  function varAt(ev) {
    if (!varPos.size) return -1;
    const r = renderer.domElement.getBoundingClientRect(), x = ev.clientX - r.left, y = ev.clientY - r.top;
    const cam = camera(), v = new THREE.Vector3(), w = stage.clientWidth || 1, h = stage.clientHeight || 1;
    let best = -1, bd = Infinity;
    for (const [i, vp] of varPos) {
      if (inactiveNodes.has(vp.n)) continue;
      v.copy(vp.p).project(cam);
      const pr = vp.r * vp.s, d = Math.hypot(x - (v.x + 1) / 2 * w, y - (1 - v.y) / 2 * h);
      if (d <= Math.max(pr, 3) && d < bd) { best = i; bd = d; }
    }
    return best;
  }
  function describeVar(v) {
    const VV = M.vars, m = VV.home(v), segs = varSegs(M, v).length;
    const lam = VV.lam[v] >= 0 ? VV.lambdas[VV.lam[v]] : null;
    return `<b>${esc(VV.name[v])}</b><div class="k">variable · ${esc(VV.kind[v])} in ${esc(M.nodes[M.mem.n[m]].n)}.${esc(M.mem.name[m])}</div>`
      + `<div>Line ${VV.line[v]}${VV.rank[v] !== 'other' ? ' · ' + esc(VV.rank[v]) : ''}${lam ? ` · in a lambda at line ${lam[2]}` : ''}</div>`
      + `<div>${segs ? `Named by ${segs} route segment${segs === 1 ? '' : 's'}` : 'No exported route names it'}</div>`;
  }
  // A class that spans layers is drawn again on each other layer it has code on: a hollow copy sized by that layer's
  // share of its lines, tied to the class by a thin line. The top view is one plane, so there the other layer is an
  // outer ring in that layer's tone.
  function spanCopies(n, mesh, p, r, ringFor) {
    const sz = n.lsz || {}, tot = Object.values(sz).reduce((a, b) => a + b, 0) || 1, own = (sz[n.slot] || tot) / tot;
    const col = nodeColor(n), up = s => SLOT_ORDER.indexOf(s) > SLOT_ORDER.indexOf(n.slot);
    let k = 0;
    for (const s of n.lys) {
      if (s === n.slot) continue;
      if (P.flat) { const w = Math.max(0.7, r * 0.08), r0 = r + 0.5 + k * (w + 0.4); ringFor(r0, r0 + w, layerTone(s), 0.95, 4); k++; continue; }
      const rr = Math.max(1.5, Math.min(r, r * Math.sqrt((sz[s] || 0) / tot / Math.max(own, 1e-6))));
      let c;
      if (side()) {
        if (!(SL.bandH[s] > 0)) continue;
        c = new THREE.Vector3(p.x, up(s) ? SL.bandY[s] + rr + 3 : SL.bandY[s] + SL.bandH[s] - rr - 3, 0.5);
      } else c = new THREE.Vector3(p.x, P.slotY(s) + 1, p.z);
      const disc = new THREE.Mesh(new THREE.CircleGeometry(rr, 40), new THREE.MeshBasicMaterial({ color: col, transparent: true, opacity: 0.12, depthWrite: false, side: THREE.DoubleSide }));
      const ring = new THREE.Mesh(new THREE.RingGeometry(Math.max(0, rr - Math.max(0.5, rr * 0.12)), rr, 40), new THREE.MeshBasicMaterial({ color: col, transparent: true, opacity: 0.9, depthWrite: false, side: THREE.DoubleSide }));
      for (const o of [disc, ring]) { if (!side()) o.rotation.x = -Math.PI / 2; o.position.copy(c); o.renderOrder = 4; root.add(o); mesh.userData.rings.push(o); }
      disc.userData.op = 0.12; ring.userData.op = 0.9;
      disc.userData.n = n; disc.userData.copyOf = mesh; disc.userData.spanSlot = s; spanMeshes.push(disc);
      const a = mesh.position.clone(), z = c.clone(); if (!side()) { a.y += 0.5; } else { a.z = z.z = 0.4; }
      const tie = new THREE.Line(new THREE.BufferGeometry().setFromPoints([a, z]), new THREE.LineBasicMaterial({ color: col, transparent: true, opacity: 0.3, depthWrite: false }));
      tie.userData.op = 0.3; tie.renderOrder = 4; root.add(tie); mesh.userData.rings.push(tie);
    }
  }
  const layerShort = s => (s >= 0 && s < 4 ? LAYER_NAMES[s] : 'unplaced');
  function layerSection(i) {
    const n = M.nodes[i], rows = [];
    rows.push(`<div>Layer ${n.L >= 0 ? n.L + ' ' + LAYER_NAMES[n.L] : 'unplaced'} <span class="sub">(${esc(whyText(n.w))})</span></div>`);
    if (n.li) {
      const nb = n.lnb || {};
      rows.push(`<div>Placed by its neighbours, so drawn hollow: ${nb.share != null ? Math.round(nb.share * 100) + '% of ' : ''}${nb.count != null ? nb.count + ' placed neighbour' + (nb.count === 1 ? '' : 's') : 'its neighbours'} in the same ${esc(nb.level || 'container')}${nb.container ? ` <span class="mono">${esc(String(nb.container).split('/').pop())}</span>` : ''} sit on this layer.</div>`);
    }
    if (n.lys && n.lys.length > 1) {
      const sz = n.lsz || {};
      rows.push(`<div>Spans ${n.lys.length} layers: ${n.lys.map(s => `${esc(layerShort(s))} ${sz[s] || 0} lines`).join(' · ')}</div>`);
    }
    const ml = D.memberLayers || [], by = new Map();
    for (const m of M.mem.of[i]) { const l = ml[m]; if (l == null) continue; by.set(l, (by.get(l) || 0) + 1); }
    if (by.size > 1) rows.push(`<div>Members by layer: ${[...by].sort((a, b) => a[0] - b[0]).map(([l, c]) => `${esc(layerShort(l))} ${c}`).join(' · ')}</div>`);
    if (n.lsc) rows.push(`<div>Scores: ${Object.entries(n.lsc).sort((a, b) => b[1] - a[1] || a[0] - b[0]).map(([l, v]) => `${esc(layerShort(+l))} ${v}`).join(' · ')}</div>`);
    if (n.lfv != null) rows.push(`<div>Flow vote: ${esc(layerShort(n.lfv))}${n.L >= 0 && n.lfv !== n.L ? ' <span class="sub">(differs from its layer)</span>' : ''}</div>`);
    if (n.lh && n.lh.length) rows.push(`<div>Hints: <span class="mono">${n.lh.map(esc).join(', ')}</span></div>`);
    if (n.lc) rows.push(`<div class="conflict">Layer conflict: ${n.lfv != null && n.lfv !== n.L ? `its layer (${esc(layerShort(n.L))}) disagrees with the flow vote (${esc(layerShort(n.lfv))})${n.lh && n.lh.length ? ', so a hint decided it' : ''}` : 'its evidence disagrees on the layer'}.</div>`);
    return sec('Layer', rows.join(''));
  }
  // World units per pixel at the fitted zoom, so a mark built once still shows at fit.
  const fitWpp = () => (side() ? Math.max(view.baseSide, view.sideW * (stage.clientHeight || 1) / (stage.clientWidth || 1)) : view.baseTop) * 2 / (stage.clientHeight || 1);
