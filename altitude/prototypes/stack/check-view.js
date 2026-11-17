// node check-view.js <built.html> <d3.min.js> <three.min.js>
// Runs the page's view code against real three.js with a stub DOM and a stub renderer.
const fs = require('fs'), vm = require('vm');
const [html, d3path, threePath] = process.argv.slice(2);
const script = [...fs.readFileSync(html, 'utf8').matchAll(/<script>([\s\S]*?)<\/script>/g)][0][1];

const els = new Map();
function el(id) {
  const listeners = {};
  const e = {
    id, innerHTML: '', textContent: '', hidden: false, classList: { add() { }, remove() { }, toggle() { }, contains: () => false }, value: '', disabled: false, style: {}, dataset: {}, className: '', children: [],
    clientWidth: 900, clientHeight: 600,
    setAttribute() { }, appendChild(c) { this.children.push(c); }, prepend(c) { this.children.unshift(c); },
    addEventListener(t, f) { (listeners[t] = listeners[t] || []).push(f); }, setPointerCapture() { },
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 900, height: 600 }),
    fire(t, ev) { (listeners[t] || []).forEach(f => f(ev)); },
  };
  return e;
}
const document = {
  getElementById(id) { if (!els.has(id)) els.set(id, el(id)); return els.get(id); },
  createElement() { return el('anon'); },
  documentElement: el('root'),
};
const ctx = {
  console, document, window: {}, devicePixelRatio: 2,
  getComputedStyle: () => ({ getPropertyValue: () => '#4b6a8a' }),
  matchMedia: () => ({ addEventListener() { } }),
  MutationObserver: class { observe() { } }, ResizeObserver: class { constructor(f) { this.f = f; } observe() { this.f(); } },
  requestAnimationFrame: f => { (ctx.__rafq = ctx.__rafq || []).push(f); },
  get localStorage() { throw new Error('blocked'); },
};
ctx.window = ctx; ctx.self = ctx; ctx.__win = {}; ctx.addEventListener = (t, f) => { ctx.__win[t] = f; };
vm.createContext(ctx);
vm.runInContext(fs.readFileSync(threePath, 'utf8'), ctx);
vm.runInContext(fs.readFileSync(d3path, 'utf8'), ctx);
let renders = 0, lastScene = null;
ctx.THREE.WebGLRenderer = class { constructor() { this.domElement = document.getElementById('canvas'); } setPixelRatio() { } setSize() { } render(s, c) { renders++; lastScene = s; s.updateMatrixWorld(); c.updateMatrixWorld(); } };
vm.runInContext(script, ctx);
const tick = n => { for (let i = 0; i < n; i++) { const q = ctx.__rafq || []; ctx.__rafq = []; q.forEach(f => f()); } };
{ const lab = document.getElementById('labels'); let h = ''; Object.defineProperty(lab, 'innerHTML', { get: () => h, set(v) { h = v; if (v === '') lab.children.length = 0; } }); }
const $ = id => document.getElementById(id);
const count = () => { let m = 0; lastScene.traverse(o => { if (o.isMesh || o.isLine) m++; }); return m; };
tick(2);
console.log('initial render', renders, 'objects', count(), 'labels', $('labels').children.length, 'steps html', $('steps').innerHTML.length);
const canvas = $('canvas');
let picked = 0; $('tip').hidden = true;
for (let x = 50; x < 900; x += 40) for (let y = 50; y < 600; y += 40) {
  canvas.fire('pointermove', { clientX: x, clientY: y, pointerId: 1 });
  if (!$('tip').hidden) { picked++; ctx.__hit = { x, y }; }
}
console.log('hover hits on a 22x14 grid', picked);
const h = ctx.__hit;
canvas.fire('pointerdown', { clientX: h.x, clientY: h.y, pointerId: 1, button: 0 });
canvas.fire('pointerup', { clientX: h.x, clientY: h.y, pointerId: 1 });
console.log('select', ctx.__altstack.S.selected && ctx.__altstack.S.selected.n, $('pane-details').innerHTML.length);
canvas.fire('pointerdown', { clientX: 450, clientY: 300, pointerId: 1, button: 0 });
canvas.fire('pointermove', { clientX: 520, clientY: 340, pointerId: 1 });
canvas.fire('pointerup', { clientX: 520, clientY: 340, pointerId: 1 });
canvas.fire('wheel', { deltaY: 120, preventDefault() { } });
console.log('focus stat:', $('focus-stat').textContent);
for (const cam of ['orbit', 'top', 'side']) {
  $('cam-' + cam).onclick(); tick(1);
  const ck = (k, on) => { $('ckinds').onchange({ target: { dataset: { ckind: k }, checked: on } }); tick(1); return [...ctx.__altstack.S.ckinds].join('+') + ':' + ctx.__altstack.V.tree.all.length; };
  const seen = [ck('file', true), ck('sourceSet', true), ck('module', false), ck('package', false), ck('file', false), ck('sourceSet', false), ck('module', true), ck('package', true)];
  if (cam === 'orbit') console.log('  kinds sweep (checked:containers):', seen.join(' '));
  for (const v of ['pillar', 'hide', 'inline']) { $('infra').onchange({ target: { value: v } }); tick(1); }
  for (const v of ['role', 'infra', 'container']) { $('color').onchange({ target: { value: v } }); tick(1); }
  for (const v of ['0', '2', '3', '1']) { $('hops').onchange({ target: { value: v } }); tick(1); }
  for (const v of ['down', 'up', 'both']) { $('dir').onchange({ target: { value: v } }); tick(1); }
  for (const v of ['hide', 'show', 'shrink']) { $('synth').onchange({ target: { value: v } }); tick(1); }
  $('skip-hubs').onchange({ target: { checked: false } }); tick(1); const hubOff = $('hub-stat').textContent;
  $('skip-hubs').onchange({ target: { checked: true } }); tick(1);
  $('hub-min').onchange({ target: { value: '20' } }); tick(1); const hub20 = $('hub-stat').textContent;
  $('hub-min').onchange({ target: { value: '' } }); tick(1);
  $('edge-strength').oninput({ target: { value: '0.4' } }); tick(1); const ev = $('edge-val').textContent;
  $('edge-reset').onclick(); tick(1);
  if (cam === 'side') console.log(`  hub off: ${hubOff}\n  hub 20: ${hub20}\n  hub auto: ${$('hub-stat').textContent}\n  focus: ${$('focus-stat').textContent}\n  slider: ${ev} -> ${$('edge-val').textContent}`);
  $('compact').onchange({ target: { checked: true } }); tick(1);
  $('compact').onchange({ target: { checked: true } }); tick(1); $('compact').onchange({ target: { checked: false } }); tick(1);
  $('focus-on').onchange({ target: { checked: false } }); tick(1); $('focus-on').onchange({ target: { checked: true } }); tick(1);
  $('hop-kinds').onchange({ target: { dataset: { kind: 'di' }, checked: false } }); tick(1); $('hop-kinds').onchange({ target: { dataset: { kind: 'di' }, checked: true } });
  for (let t = -1; t < 5; t++) { $('trace').onchange({ target: { value: String(t) } }); tick(1); }
  $('trace').onchange({ target: { value: '4' } });
  $('layers').onchange({ target: { dataset: { slot: '1' }, checked: false } }); tick(1);
  const struck = ($('steps').innerHTML.match(/class="hidden"/g) || []).length;
  $('layers').onchange({ target: { dataset: { slot: '1' }, checked: true } });
  $('kinds').onchange({ target: { dataset: { kind: 'value' }, checked: true } }); tick(1);
  $('kinds').onchange({ target: { dataset: { kind: 'value' }, checked: false } });
  const key = ctx.__altstack.V.tree.all.find(c => c.depth === 3).key, key2 = ctx.__altstack.V.tree.all.filter(c => c.depth === 3)[1].key;
  $('tree').onclick({ target: { closest: () => ({ dataset: { g: key } }) }, shiftKey: false }); tick(1);
  $('tree').onclick({ target: { closest: () => ({ dataset: { g: key2 } }) }, shiftKey: true }); tick(1);
  const iso = [...ctx.__altstack.S.iso];
  const labelsShown = $('labels').children.filter(e => !e.hidden).length;
  $('trace').onchange({ target: { value: '-1' } }); tick(1);
  const objsIsoNoTrace = count();
  $('clear-iso').onclick(); tick(1);
  console.log(`${cam}: objects ${count()}, data-off struck ${struck}, iso ${iso.length} (${objsIsoNoTrace} objects without trace), labels shown ${labelsShown}/${$('labels').children.length}`);
  $('trace').onchange({ target: { value: '4' } }); tick(1);
}
// Round 5: context rules, member reveal by zoom, possible connections
const A = ctx.__altstack;
const keyHandler = ctx.__win.keydown;
for (const v of ['hops', 'state', 'budget']) { $('ctx').onchange({ target: { value: v } }); tick(1); console.log(`ctx ${v}: ${$('focus-stat').textContent}`); }
$('budget').oninput({ target: { value: '10' } }); $('budget').onchange({ target: { value: '10' } }); tick(1);
console.log(`budget 10: ${$('focus-stat').textContent}`);
$('budget').onchange({ target: { value: '30' } }); tick(1);
const instCount = () => { let n = 0, marks = {}; if (A.memGroup) A.memGroup.traverse(o => { if (o.isInstancedMesh) { n += o.count; marks[o.geometry.type + o.count] = 1; } }); return n; };
for (const cam of ['orbit', 'top', 'side']) {
  $('cam-' + cam).onclick(); tick(2);
  // centre on the path node with the most members, the way a reader would zoom toward it
  const target = [...A.V.onPath].map(i => A.M.nodes[i]).sort((a, b) => A.M.mem.of[b.i].length - A.M.mem.of[a.i].length)[0];
  const p = A.npos(target);
  if (cam === 'orbit') A.view.target.copy(p); else if (cam === 'top') { A.view.top.x = p.x; A.view.top.z = p.z; } else { A.view.side.x = p.x; A.view.side.y = p.y; }
  tick(1);
  const rows = [`centred on ${target.n} (${A.M.mem.of[target.i].length} members)`];
  for (const [label, f] of [['fit', 1], ['x2', 0.5], ['x4', 0.5], ['x12', 1 / 3], ['x36', 1 / 3]]) {
    if (f !== 1) A.zoomBy(f); tick(2);
    const rv = A.revealed, onPath = rv.filter(r => A.V.onPath.has(r.n.i)).length;
    rows.push(`${label}: ${rv.length} nodes (${onPath} on path), ${instCount()} member marks`);
  }
  console.log(`${cam} reveal: ${rows.join(' | ')}`);
  if (cam === 'side') {
    const shown = [...A.memPos.keys()];
    const m = shown.find(m => A.M.mem.adj[m].length > 25) ?? shown[0];
    A.clickMember(m); tick(1);
    const s1 = A.S.conn.shown.size, hd1 = ($('conn').innerHTML.match(/showing \d+ of \d+/g) || []).join(', ');
    const cellRow = $('conn').innerHTML.match(/cell: \d+ of \d+ writers and readers, stops here/g);
    const nxt = [...A.S.conn.shown].find(x => x !== m);
    A.clickMember(nxt); tick(1);
    const s2 = A.S.conn.shown.size;
    A.clickMember(m, true); tick(1);
    const s3 = A.S.conn.shown.size;
    $('conn-dir').onchange({ target: { value: 'out' } }); tick(1); const sOut = A.S.conn.shown.size;
    $('conn-kinds').onchange({ target: { dataset: { kind: 'call' }, checked: false } }); tick(1); const sNoCall = A.S.conn.shown.size;
    $('conn-kinds').onchange({ target: { dataset: { kind: 'call' }, checked: true } }); $('conn-dir').onchange({ target: { value: 'both' } }); tick(1);
    const tubes = (() => { let n = 0; A.memGroup.traverse(o => { if (o.geometry && o.geometry.type === 'TubeGeometry') n++; }); return n; })();
    console.log(`member click (${A.M.mem.name[m]}, ${A.M.mem.adj[m].length} edges): shown ${s1} [${hd1}]${cellRow ? ' ' + cellRow[0] : ''}; second step ${s2}; show more ${s3}; outputs only ${sOut}; without call ${sNoCall}; tubes ${tubes}`);
    console.log(`  title present: ${/Possible connections — call contexts merged/.test(fs.readFileSync(html, 'utf8'))}; tip: ${$('pane-details').innerHTML.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').slice(0, 160)}`);
    // a cell member: its writers and readers, and nothing further
    const cm = A.M.mem.kind.findIndex((k, i) => k === 'cell' && A.M.mem.adj[i].length > 3);
    A.clickMember(cm); tick(1);
    console.log(`cell click (${A.M.mem.name[cm]}): ${($('conn').innerHTML.match(/Writers and readers of cell[^:]*: showing \d+ of \d+/g) || ['?'])[0].replace(/<[^>]+>/g, '')}, shown ${A.S.conn.shown.size}`);
    if (keyHandler) keyHandler({ key: 'Escape' }); tick(1);
    console.log(`after Esc: conn ${A.S.conn ? 'still set' : 'cleared'}; panel "${$('conn').innerHTML.replace(/<[^>]+>/g, '')}"`);
    A.clickMember(m); tick(1);
    canvas.fire('pointerdown', { clientX: 2, clientY: 2, pointerId: 1, button: 0 }); canvas.fire('pointerup', { clientX: 2, clientY: 2, pointerId: 1 }); tick(1);
    console.log(`after empty click: conn ${A.S.conn ? 'still set' : 'cleared'}`);
  }
}
// Round 6: the top camera draws the flat layout; no two shown circles overlap, path nodes kept, repeatable
{
  $('cam-top').onclick(); tick(1);
  const overlaps = () => {
    const V = A.V, P = A.P, ns = A.M.nodes.filter(n => V.shown(n)).map(n => ({ n, p: P.pos.get(n), r: V.rad(n) }));
    if (ns.some(x => !x.p)) return 'unplaced';
    ns.sort((a, b) => a.p[0] - b.p[0]);
    let bad = 0;
    for (let i = 0; i < ns.length; i++) for (let j = i + 1; j < ns.length && ns[j].p[0] - ns[i].p[0] < ns[i].r + ns[j].r; j++)
      if (Math.hypot(ns[i].p[0] - ns[j].p[0], ns[i].p[1] - ns[j].p[1]) < ns[i].r + ns[j].r - 1e-6) bad++;
    return bad;
  };
  const posSig = () => A.M.nodes.map(n => (A.P.pos.get(n) || ['-']).join(',')).join(';');
  let combos = 0;
  const kindSets = [['module', 'package'], ['package'], ['module', 'sourceSet', 'package', 'file'], []];
  const setKinds = ks => { for (const k of A.M.ckinds) $('ckinds').onchange({ target: { dataset: { ckind: k }, checked: ks.includes(k) } }); tick(1); };
  for (const ks of kindSets) for (const trace of ['-1', '0', '4']) for (const c of ['budget', 'state', 'hops']) for (const compact of [false, true]) {
    setKinds(ks);
    $('trace').onchange({ target: { value: trace } }); $('ctx').onchange({ target: { value: c } }); $('compact').onchange({ target: { checked: compact } }); tick(1);
    if (!A.P.flat) throw new Error('top camera is not on the flat layout');
    const b = overlaps(); if (b) throw new Error(`top overlap ${b} ${ks} ${trace} ${c} ${compact}`);
    if (A.V.path) for (const ix of A.V.path) if (!A.V.shown(A.M.nodes[ix]) || !A.P.pos.get(A.M.nodes[ix])) throw new Error('top path node lost');
    const s1 = posSig(); $('compact').onchange({ target: { checked: !compact } }); $('compact').onchange({ target: { checked: compact } }); tick(1);
    if (posSig() !== s1) throw new Error('top layout not repeatable');
    combos++;
  }
  setKinds(['module', 'package']); $('compact').onchange({ target: { checked: false } }); $('cam-orbit').onclick(); tick(1);
  console.log(`top view: ${combos} combinations drawn on the flat layout with zero overlap, path nodes kept, repeatable; orbit back on 3D: ${!A.P.flat}`);
}
for (const f of (process.env.CV_ROUNDS || 'check-view-r7.js,check-view-r8.js,check-view-r81.js,check-view-r82.js').split(',')) require('./' + f)({ A, $, canvas, tick, ctx, keyHandler, count });
console.log('renders', renders, 'done without exceptions');
