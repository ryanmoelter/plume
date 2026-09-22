---
name: drive-plume
description: Drive and inspect a running debug build of Plume from an agent — read what is on screen as text, click, type, hover, and screenshot — without stealing focus or needing an Accessibility grant. Use whenever verifying a UI change, reproducing a UI bug, or checking what the app shows, before reaching for a screenshot or a process tree.
---

# Drive the debug app

A debug build serves a Unix-socket control server; `scripts/debug/plume-control.py` is the client. **`docs/control-server.md` is the reference** for the wire format, every command and the limits. This skill is the working recipe.

## Launch a scratch instance

Never drive the instance the user is working in. Give the scratch one its own `HOME` so it has its own store, and its own socket path so the client finds it without guessing.

```
APP=$(xcodebuild -scheme Plume -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3}')/Plume.app
open -g -n --env HOME=/tmp/plume-scratch --env PLUME_SEED_TASKS=1 \
  --env PLUME_CONTROL_SOCKET=/tmp/plume-scratch.sock "$APP"
c() { scripts/debug/plume-control.py --socket /tmp/plume-scratch.sock --assert-frontmost "$@"; }
c --wait 30 hierarchy
```

`open -g` keeps it in the background. `--assert-frontmost` fails any call that changes the frontmost app; run every call with it, because never disturbing the user's focus is the point of this system. When done, kill the instance by walking down from its own PID, never with a global match on `Plume`:

```
pkill -f "$APP/Contents/MacOS/Plume"
```

## Inspect before you screenshot

Each step is cheaper than the next to read. Stop at the first one that answers the question.

1. `hierarchy` — the whole window as an indented outline: every text view with its text, every control with its enabled state and frame. Pass `target=` to scope it.
2. `readText target='{"kind":"composer"}'` or `'{"kind":"chatList"}'` — one surface's text, row by row.
3. `list plumeID=<id>` / `describe` — one control's frame, label, value and enabled state.
4. `screenshot` — only for a question about layout or rendering that text cannot answer. Pass `target=` to crop to one control. Read the PNG in a sub-agent, never in the main conversation.

## Act

```
c invoke target='{"id":"composer-send-button"}'
c setValue target='{"kind":"composer"}' value="hello"
c clickSpan matching=hello
c click x=120 y=80
c hover target='{"id":"group-header","index":0}'
c clear
```

`invoke` runs the control's registered closure or clicks its center. `hover` reveals hover-only controls such as a row's trailing buttons; `regions` in its result is how many hover regions the pointer is now inside, so `0` means the target has none. Every click and hover moves an overlay pointer in the window so a person watching can follow; `clear` un-hovers everything and removes it. Read the state back after every action rather than assuming it took.

## When a control is missing

The server sees only what registers with it. A SwiftUI control with no `plumeID(_:)` is invisible to `list` and `invoke`, and a bare `.onHover` never sees the synthetic pointer. Add `plumeID` (with `label:` on repeated rows) or `plumeHover` at the site and rebuild; never fall back to `.accessibilityIdentifier` or a coordinate click at a guessed position.

## What this cannot tell you

Terminal liveness. A tab's PTY is a real process, so whether it survived a switch is answered by the process tree, not by the window. The "Verifying terminal behavior" section of `CLAUDE.md` has that recipe; use both together when a change touches terminals.
