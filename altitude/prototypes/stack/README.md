# Stacked-layers viewer prototype

A throwaway web page that draws an Altitude export as layers stacked in 3D, with a top view, a side view and data-flow selection. It is a prototype for judging the idea, not product code. It grew by patch scripts, one per review round, so the build replays them in order.

## Build

Run in this folder. `<export>` is a directory written by `extractor export` (see `../../docs/export.md`): `altitude.json`, `altitude-nodes.json`, `altitude-members.json`, `altitude-variables.json`, `altitude-branches.json` and `altitude-branch-sinks.json`.

```
cp template-r7.html template.html
python3 -I p8.py template.html
python3 -I p81.py template.html
python3 -I p9.py template.html
python3 -I p9b.py template.html
python3 -I p9c.py template.html
python3 -I reduce9.py <export> template.html altitude-stack.html
```

`reduce9.py` refuses to build when `meta.exportId` differs between the export's files. It inlines a reduced copy of the data, so `altitude-stack.html` is self-contained and holds the analyzed project's class names. Never commit it for a private project; `.gitignore` covers it.

The page loads three.js r128 and d3 7.8.5 from cdnjs.

## Checks

- `node check.js altitude-stack.html` checks the inlined data and the layout rules.
- `CV_ROUNDS=check-view-r7.js node check-view.js altitude-stack.html <d3.min.js> <three.min.js>` renders every view headlessly in Node against local copies of the two libraries.
- The later rounds' checks (`check-view-r8.js` to `check-view-r9b.js`, `shots9b.js`, and `labels9c.js`, the real-input Playwright test for pan and zoom over labels) name classes of the private project they were written against, so they are not in this repository. Rewrite them against the new target.

## What each file is

| File | Role |
| --- | --- |
| `template-r7.html` | The page as of round 7: layouts, cameras, settings |
| `p8.py`, `pick-core.js`, `pick-view.js`, `pick-ui.js` | Round 8: selection by branch trees, Details pane, Lum palette |
| `p81.py` | Round 8.1–8.2: interaction rules, dimming, hover rules |
| `p9.py`, `core9.js`, `sl9.js` | Round 9a: stitch fit through cells, hop detail, strand labels |
| `p9b.py`, `v9b.js` | Round 9b: variables inside members, layer spans, Layer section |
| `p9c.py` | Round 9c: labels forward drag and wheel to the canvas |
| `reduce9.py` | Reduces the export and inlines it |

## Rules the page follows

- A single click never changes the layout. Only a double click does. A click on nothing deselects.
- Nothing dimmed answers hover or click; the pointer reaches what is in focus behind it.
- Container outlines stay darker than connectors. Connectors off the selected strands sit at 0.05 opacity.
- One selected node shows every route through it, all equal. A second node on a route gives direction, and then every route connecting the two is strong and continuations are fainter. The page never picks a "best" route.
- A join through a cell draws solid when the access paths match and dashed when the fit is unknown. A mismatch is never followed; Details lists it under Rejected candidates.
- The selected node always has a label. Nodes on highlighted strands get labels where they fit; close nodes of one class share a group label.
