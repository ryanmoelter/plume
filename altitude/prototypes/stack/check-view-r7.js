// Round 7: branch trees as highlight, single click never restructures, click on nothing deselects, Details pane.
module.exports = ({ A, $, canvas, tick, keyHandler }) => {
  const THREE = A.npos(A.M.nodes[0]) ? A.npos(A.M.nodes[0]).constructor : null;
  let t = 1e6;
  const up = (x, y, ts) => canvas.fire('pointerup', { clientX: x, clientY: y, pointerId: 1, timeStamp: ts });
  const down = (x, y, ts) => canvas.fire('pointerdown', { clientX: x, clientY: y, pointerId: 1, button: 0, timeStamp: ts });
  const click = (x, y, drag) => { t += 1000; down(x, y, t); if (drag) canvas.fire('pointermove', { clientX: x + drag, clientY: y + drag, pointerId: 1 }); up(x + (drag || 0), y + (drag || 0), t + 40); tick(1); };
  const dbl = (x, y) => { click(x, y); down(x, y, t + 120); up(x, y, t + 160); canvas.fire('dblclick', { clientX: x, clientY: y }); tick(1); };
  const sig = () => A.M.nodes.map(n => (A.V.shown(n) ? (A.P.pos.get(n) || ['-']).map(v => (+v).toFixed(3)).join(',') + '/' + (A.SL.pos.get(n) || ['-']).map(v => (+v).toFixed(3)).join(',') : 'x')).join(';');
  const fail = m => { throw new Error('round 7: ' + m); };
  const onScreen = ([x, y]) => x > 20 && x < 880 && y > 20 && y < 580;

  $('trace').onchange({ target: { value: '-1' } }); $('cam-top').onclick(); tick(2);
  const base = sig();
  // every tree, clean on and off, levels 0..2: highlighting never moves or drops a node
  let combos = 0, marks = 0;
  for (const T of A.M.br.trees) for (const clean of [true, false]) {
    A.S.root = T.i; A.S.clean = clean; A.S.branch = combos % 3; A.S.endpoint = -1; A.applyHighlight(); tick(1);
    if (sig() !== base) fail('highlighting tree ' + T.i + ' moved the layout');
    marks += A.markers.length; combos++;
  }
  A.S.clean = true; A.S.branch = 1;
  console.log(`tree highlight sweep: ${combos} tree/toggle combinations, positions and kept set unchanged, ${marks} markers drawn`);

  // choose root #2 from the list
  $('root-list').onclick({ target: { closest: () => ({ dataset: { root: '2' } }) } }); tick(2);
  if (sig() !== base || !A.V.T || A.V.T.i !== 2) fail('choosing a root restructured or did not take');
  const rootDet = $('pane-details').innerHTML;
  const results = [`root: Details ${/Endpoints by kind/.test(rootDet)}, pane ${A.S.pane}`];

  // single click on a tree class
  const cam = () => A.camera();
  // a tree class whose centre carries no marker, so the click lands on the class itself
  tick(1);
  const marked = new Set(A.markers.map(m => A.toScreen(m.p).map(Math.round).join(',')));
  const nodeOn = [...A.V.treeNodes].map(i => A.M.nodes[i]).filter(n => A.V.shown(n) && A.V.rad(n) > 4).map(n => ({ n, s: A.toScreen(A.npos(n)) })).filter(x => onScreen(x.s));
  if (!nodeOn.length) fail('no tree class on screen');
  const near = s => A.markers.some(m => Math.hypot(A.toScreen(m.p)[0] - s[0], A.toScreen(m.p)[1] - s[1]) < m.px + 4);
  const nc = nodeOn.find(x => !near(x.s)) || nodeOn[0];
  click(nc.s[0] + 1, nc.s[1] + 1);
  if (sig() !== base) fail('class click restructured');
  results.push(`class click: sel ${A.S.sel && A.S.sel.kind}, endpoint ${A.S.endpoint}, layout unchanged`);
  // a drag is not a click
  const before = JSON.stringify(A.S.sel);
  click(450, 300, 40);
  if (JSON.stringify(A.S.sel) !== before) fail('a drag changed the selection');
  results.push('drag: selection kept');
  // single click on a terminal marker of the chosen root's tree (a class selection's strands replace the tree)
  $('root-list').onclick({ target: { closest: () => ({ dataset: { root: '2' } }) } }); tick(1);
  const mk = A.markers.find(m => m.kind === 'term' && onScreen(A.toScreen(m.p)));
  if (mk) {
    const [x, y] = A.toScreen(mk.p); click(x, y);
    if (sig() !== base) fail('terminal click restructured');
    // markers stacked on one class centre: the click takes the nearest, so check it took one under the pointer
    const hit = A.markers.find(m => m.point === A.S.endpoint && Math.hypot(A.toScreen(m.p)[0] - x, A.toScreen(m.p)[1] - y) <= m.px + 2);
    if (A.S.endpoint < 0 || !hit) fail('terminal click did not choose an endpoint under the pointer');
    results.push(`terminal click: sel ${A.S.sel.kind}, strand ${A.V.tv.strandSegs ? A.V.tv.strandSegs.size : 0} segments, Details ${/Cost:/.test($('pane-details').innerHTML) ? 'cost' : /A branch point/.test($('pane-details').innerHTML) ? 'branch point' : 'MISSING'}`);
  } else results.push('terminal click: no marker on screen');
  // single click on a container label, then double click isolates
  const lab = $('labels').children.find(e => e.ondblclick && !e.hidden);
  lab.onclick(); tick(1);
  if (sig() !== base || A.S.sel.kind !== 'container') fail('container click restructured or did not select');
  results.push(`container click: ${A.S.sel.key}, Details ${/Child containers/.test($('pane-details').innerHTML)}`);
  // click on nothing
  let cleared = false;
  for (const [x, y] of [[2, 2], [898, 2], [2, 598], [898, 598]]) { click(x, y); if (!A.S.sel) { cleared = true; break; } }
  if (!cleared) fail('click on nothing did not clear');
  results.push(`click on nothing: sel ${A.S.sel}, root ${A.S.root}, layout unchanged ${sig() === base}`);
  lab.ondblclick({ shiftKey: false }); tick(1);
  const isoSig = sig();
  if (isoSig === base) fail('double click on a container did not isolate');
  $('clear-iso').onclick(); tick(1);
  results.push(`container double click: isolated ${isoSig !== base}, cleared back ${sig() === base}`);

  // single click on a member: zoom in on a big tree class
  $('root-list').onclick({ target: { closest: () => ({ dataset: { root: '2' } }) } }); tick(1);
  const big = [...A.V.treeNodes].map(i => A.M.nodes[i]).filter(n => A.V.shown(n)).sort((a, b) => A.M.mem.of[b.i].length - A.M.mem.of[a.i].length)[0];
  const p = A.npos(big); A.view.top.x = p.x; A.view.top.z = p.z; A.zoomBy(0.05); tick(3);
  const mm = [...A.memPos.entries()].find(([m, q]) => onScreen(A.toScreen(q.p)) && q.r > 0);
  if (mm) {
    const [x, y] = A.toScreen(mm[1].p); click(x, y);
    if (sig() !== base) fail('member click restructured');
    results.push(`member click: sel ${A.S.sel && A.S.sel.kind}, conn ${A.S.conn ? A.S.conn.shown.size : 0}, Details ${/Member edges in|Writers/.test($('pane-details').innerHTML)}`);
  } else results.push('member click: no member revealed');
  A.view.zoom = 1; A.view.fitted = ''; tick(2);

  // double click on a tree class focuses; Esc steps back
  $('root-list').onclick({ target: { closest: () => ({ dataset: { root: '2' } }) } }); tick(1);
  const n2 = [...A.V.treeNodes].map(i => A.M.nodes[i]).filter(n => A.V.shown(n)).map(n => ({ n, s: A.toScreen(A.npos(n)) })).filter(x => onScreen(x.s))[0];
  dbl(n2.s[0], n2.s[1]);
  const focusSig = sig(), focusKind = A.V.focus, kept = A.M.nodes.filter(n => A.V.shown(n)).length;
  if (!A.S.focus || focusSig === base) fail('double click did not focus');
  keyHandler({ key: 'Escape' }); tick(1);
  const afterBack = sig() === base && !A.S.focus;
  if (A.S.endpoint < 0) { A.S.endpoint = A.M.br.trees[A.S.root].terms[0].point; A.applyHighlight(); }
  results.push(`before Esc: endpoint/root ${A.S.endpoint}/${A.S.root}`);
  keyHandler({ key: 'Escape' }); tick(1); const e2 = [A.S.endpoint, A.S.root];
  keyHandler({ key: 'Escape' }); tick(1); const e3 = [A.S.endpoint, A.S.root];
  results.push(`double click: focus ${focusKind}, kept ${kept}; Esc back ${afterBack}; Esc then endpoint/root ${e2.join('/')} then ${e3.join('/')}`);

  // Focus strand from the sidebar, level 2 stubs, Back
  A.S.root = 2; A.S.endpoint = A.M.br.trees[2].terms[A.V.tv ? 0 : 0].point; A.applyHighlight();
  $('focus-strand').onclick(); tick(1);
  const strandKept = A.M.nodes.filter(n => A.V.shown(n)).length;
  $('back').onclick(); tick(1);
  $('branch').onchange({ target: { value: '2' } }); tick(1);
  const stubs = $('labels').children.filter(e => /joining|branching/.test(e.textContent)).length;
  $('branch').onchange({ target: { value: '1' } }); tick(1);
  results.push(`focus strand: kept ${strandKept}; back restores ${sig() === base}; level 2 stubs ${stubs}`);

  // Details pane per kind, and a delegated click
  const det = () => $('pane-details').innerHTML;
  const cm = A.M.mem.kind.findIndex((k, i) => k === 'cell' && A.M.mem.cell[i] >= 0);
  const fm = A.M.mem.kind.findIndex(k => k === 'function');
  const checks = [
    ['class', { kind: 'node', n: big.i }, /Fan-in by edge kind[\s\S]*Strands through this · \d+ of \d+/],
    ['member', { kind: 'member', m: fm }, /Member edges in/],
    ['cell', { kind: 'cell', ci: A.M.mem.cell[cm], m: cm }, /Writers \(\d+\)/],
    ['container', { kind: 'container', ci: A.M.nodes[big.i].chain[1].ci }, /Child containers/],
    ['trace', { kind: 'trace', trace: 0 }, /Classes crossed/],
    ['chain', { kind: 'chain', tree: 2, point: A.M.br.trees[2].terms[0].point }, /best of \d+ path/],
    ['root', { kind: 'root', tree: 2 }, /Endpoints by kind/],
    ['sibs', { kind: 'sibs', tree: 2, at: A.M.br.trees[2].sibs[0].at }, /Values/],
  ];
  const ok = [];
  for (const [name, sel, re] of checks) { const s0 = sig(); A.setSel(sel); tick(1); if (!re.test(det())) fail('details ' + name); if (sig() !== s0) fail('details select restructured ' + name); ok.push(name); }
  const misBy = A.D.traces.map((x, i) => { A.setSel({ kind: 'trace', trace: i }); return `${x.name} ${(det().match(/field mismatch: reads/g) || []).length}`; });
  const mis = misBy.join(', ');
  $('pane-details').onclick({ target: { closest: () => ({ dataset: { n: String(big.i) } }) } }); tick(1);
  results.push(`details: ${ok.join(', ')} rendered and highlight only; read-expense mismatch notes ${mis}; delegated click selects ${A.S.sel.kind} ${A.S.sel.n === big.i}`);
  A.setSel(null); A.S.root = -1; A.applyHighlight(); tick(1);
  console.log(results.join('\n'));
};
