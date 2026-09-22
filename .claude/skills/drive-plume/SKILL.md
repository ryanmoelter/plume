---
name: drive-plume
description: Drive and inspect a running debug build of Plume from an agent — read what is on screen as text, click, type, hover, and screenshot — without stealing focus or needing an Accessibility grant. Use whenever verifying a UI change, reproducing a UI bug, or checking what the app shows, before reaching for a screenshot or a process tree.
---

# Drive the debug app

A debug build serves a Unix-socket control server; `scripts/debug/plume-control.py` is the client. **`docs/control-server.md` is the reference** for the wire format, every command and the limits. This skill is the working recipe.

## Launch a scratch instance

Never drive the instance the user is working in. Give the scratch instance its own `PLUME_APP_SUPPORT` so it has its own store, and its own socket path so the client finds it without guessing.

**`--env HOME=...` does not isolate a scratch instance.** `URL.applicationSupportDirectory` resolves from the process's security context, not `$HOME`, so an instance launched with a fake `HOME` still opens `~/Library/Application Support/Plume.debug` — the user's real tasks and terminals. `PLUME_APP_SUPPORT` is a `#if DEBUG`-only override built for exactly this; it redirects the whole Application Support directory (store, hooks, events, control socket) in one shot. `docs/control-server.md` has the reference.

```
APP=$(xcodebuild -scheme Plume -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3}')/Plume.app
BEFORE=$(pgrep -f "$APP/Contents/MacOS/Plume")
open -g -j -n --env PLUME_APP_SUPPORT=/tmp/plume-scratch --env PLUME_SEED_TASKS=1 \
  --env PLUME_CONTROL_SOCKET=/tmp/plume-scratch.sock "$APP"
sleep 1
PID=$(comm -13 <(echo "$BEFORE" | sort) <(pgrep -f "$APP/Contents/MacOS/Plume" | sort))
c() { scripts/debug/plume-control.py --socket /tmp/plume-scratch.sock --assert-frontmost "$@"; }
c --wait 30 hierarchy
```

`open -j` launches the app **hidden**, so its window never appears on the user's screen at all; that is the default, because a new window lands on the user's current Space and in front of every other inactive app. Everything works hidden except `screenshot`, which needs the window server to hold an image of the window. Drop `-j` when a screenshot is the only way to answer the question, or when the user wants to watch the overlay pointer, and say so. `-g` keeps the app from activating either way. `--assert-frontmost` fails any call that changes the frontmost app; run every call with it, because never disturbing the user's focus is the point of this system. Synthetic clicks never reorder windows; the frontmost check plus a hidden launch is the whole focus story.

When done, kill the instance by the `$PID` captured above — never `pkill -f` on the app's path, which also matches a developer's own debug Plume launched from the same DerivedData build:

```
kill "$PID"
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

`invoke` runs the control's registered closure (`via: "closure"`) or clicks its center (`via: "click"`). A task row and a tab chip report `value: "selected"` when selected, so `list plumeID=task-row` tells you which conversation is open; check it after selecting rather than assuming the click took. A click on a `List` row never fires its tap gesture, which is why task rows carry an `invoke` closure. `hover` reveals hover-only controls such as a row's trailing buttons; `regions` in its result is how many hover regions the pointer is now inside, so `0` means the target has none. Every click and hover moves an overlay pointer in the window so a person watching can follow; `clear` un-hovers everything and removes it. Read the state back after every action rather than assuming it took.

## When a control is missing

The server sees only what registers with it. A SwiftUI control with no `plumeID(_:)` is invisible to `list` and `invoke`, and a bare `.onHover` never sees the synthetic pointer. Add `plumeID` (with `label:` on repeated rows) or `plumeHover` at the site and rebuild; never fall back to `.accessibilityIdentifier` or a coordinate click at a guessed position.

## What this cannot tell you

Terminal liveness. A tab's PTY is a real process, so whether it survived a switch is answered by the process tree, not by the window. The "Verifying terminal behavior" section of `CLAUDE.md` has that recipe; use both together when a change touches terminals.
