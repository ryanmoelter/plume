import sys
p = sys.argv[1]
s = open(p).read()
def rep(old, new, n=1):
    global s
    c = s.count(old)
    if c != n: sys.exit('expected %d of %r, found %d' % (n, old[:90], c))
    s = s.replace(old, new)

# Nothing on the visualization is selectable text.
rep(".stage { position: relative; min-width: 0; min-height: 0; overflow: hidden; touch-action: none; }",
    ".stage { position: relative; min-width: 0; min-height: 0; overflow: hidden; touch-action: none; -webkit-user-select: none; user-select: none; }\n"
    ".lbl, .slbl { -webkit-user-select: none; user-select: none; touch-action: none; }")

# Labels forward presses and wheels to the canvas's own handlers: a press on a label captures the pointer to the
# canvas, so a drag pans or orbits, and only a release within the canvas's click threshold acts on the label.
rep("""  cv.addEventListener('pointerdown', e => {
    cv.setPointerCapture(e.pointerId); pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (pointers.size === 2) { const [p, q] = [...pointers.values()]; pinch = { d: Math.hypot(p.x - q.x, p.y - q.y) }; drag = null; }
    else drag = { x: e.clientX, y: e.clientY, sx: e.clientX, sy: e.clientY, pan: e.shiftKey || e.button === 2 || S.cam !== 'orbit' };
  });""",
"""  function startPointer(e, lab) {
    cv.setPointerCapture(e.pointerId); pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (pointers.size === 2) { const [p, q] = [...pointers.values()]; pinch = { d: Math.hypot(p.x - q.x, p.y - q.y) }; drag = null; }
    else drag = { x: e.clientX, y: e.clientY, sx: e.clientX, sy: e.clientY, pan: e.shiftKey || e.button === 2 || S.cam !== 'orbit', lab };
  }
  cv.addEventListener('pointerdown', e => startPointer(e, null));
  const labelOf = e => (e.target && e.target.closest ? e.target.closest('.lbl, .slbl') : null);
  stage.addEventListener('pointerdown', e => {
    const lab = labelOf(e); if (!lab) return;
    e.preventDefault(); startPointer(e, lab);
    if (stage.focus) stage.focus({ preventScroll: true }); $('memhint').hidden = true;
  });
  stage.addEventListener('wheel', e => { if (labelOf(e)) onWheel(e); }, { passive: false });
  // The label's action runs from endPointer, so a native click on a label is dropped.
  for (const t of ['click', 'dblclick']) stage.addEventListener(t, e => { if (e.isTrusted && labelOf(e)) e.stopPropagation(); }, true);
  function labelClick(lab, e) {
    if (lab.dataset && lab.dataset.sl != null) { const p = slPlacedList[+lab.dataset.sl]; if (p) slClick(p); return; }
    if (lab.onclick) lab.onclick({ stopPropagation() { }, shiftKey: e.shiftKey });
    else handleClick(e);
  }""")
rep("""        lastClick.t = now; lastClick.x = e.clientX; lastClick.y = e.clientY;
        if (!again) handleClick(e);""",
"""        lastClick.t = now; lastClick.x = e.clientX; lastClick.y = e.clientY; lastClick.lab = !!drag.lab;
        if (drag.lab) { if (!again) labelClick(drag.lab, e); else if (drag.lab.ondblclick) drag.lab.ondblclick({ shiftKey: e.shiftKey }); }
        else if (!again) handleClick(e);""")
rep("cv.addEventListener('dblclick', e => { if (lastClick.wasClick) handleDouble(e); });",
    "cv.addEventListener('dblclick', e => { if (lastClick.wasClick && !lastClick.lab) handleDouble(e); });")
rep("cv.addEventListener('wheel', e => { e.preventDefault(); zoomBy(Math.exp(e.deltaY * 0.0012)); }, { passive: false });",
    "function onWheel(e) { e.preventDefault(); zoomBy(Math.exp(e.deltaY * 0.0012)); }\n  cv.addEventListener('wheel', onWheel, { passive: false });")
open(p, 'w').write(s)
print('ok 9c')
