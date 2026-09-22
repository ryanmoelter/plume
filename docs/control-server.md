# The debug control server

A debug build of Plume opens a Unix-domain socket an agent can drive and inspect the app through: list the controls on screen, read and set the composer, click a word, dump the window as text, and take a screenshot. It needs no Accessibility (TCC) grant and never activates the app, so the user's focus stays where it was. `scripts/debug/plume-control.py` is the client; `Plume/Control/` is the implementation, all `#if DEBUG`.

## Inspect before you screenshot

Reach for commands in this order. Each is cheaper than the next for an agent to read.

1. `hierarchy` — the whole window as an indented outline: every text view with its text, every control with its enabled state, every `plumeID` with its frame. This answers "what is on screen" and "where is X" without pixels.
2. `readText` — one surface's text: the composer, the chat list row by row, or one control.
3. `screenshot` — only when the question is about layout or rendering that text cannot answer.

## Finding the socket

Each instance binds `<Application Support>/control/<pid>.sock`, mode `0600` in a `0700` directory, and logs the path under the `control` category at launch. Sockets of instances that have exited are unlinked the next time an instance starts. `PLUME_CONTROL_SOCKET=<path>` overrides the location directly, and a preferred path longer than 103 bytes (a long `PLUME_APP_SUPPORT` override) falls back to `/tmp/plume-control-<pid>.sock`. `PLUME_CONTROL=0` disables the server. The test host has no bundle identifier and never starts one.

**`PLUME_APP_SUPPORT=<path>` redirects the whole Application Support directory** — `Plume.store`, `hooks`, `events`, and `control` all move with it. It is `#if DEBUG` only; a Release build ignores it. `URL.applicationSupportDirectory` resolves from the process's security context, not `$HOME`, so `open --env HOME=...` does **not** isolate a scratch instance from the user's real data — it still reads `~/Library/Application Support/Plume.debug`. `PLUME_APP_SUPPORT` is the only way to get a genuinely isolated instance.

The client discovers the socket in this order: `--socket`, `$PLUME_CONTROL_SOCKET`, then the live `*.sock` files under the debug control directory. With several instances running pass `--pid` or `--latest`. `--wait N` waits for a socket that accepts a connection, because a killed instance leaves its file behind.

## Driving a scratch instance

```
open -g -j -n --env PLUME_APP_SUPPORT=/tmp/plume-scratch --env PLUME_SEED_TASKS=1 \
  --env PLUME_CONTROL_SOCKET=/tmp/plume-scratch.sock \
  <DerivedData>/Build/Products/Debug/Plume.app

c() { scripts/debug/plume-control.py --socket /tmp/plume-scratch.sock --assert-frontmost "$@"; }
c --wait 20 hierarchy
c list
c setValue target='{"kind":"composer"}' value="hello world"
c readText target='{"kind":"composer"}'
c invoke target='{"id":"composer-send-button"}'
c clickSpan matching=world
c screenshot
```

`-j` launches the app hidden, so the scratch window never appears on the user's Space; the window lookup falls back to the largest window when none is visible. The window server holds no image of a hidden window, and drawing it in-process gives a white page, so `screenshot` fails with an error naming the cause; relaunch without `-j` for one. `--assert-frontmost` reads `lsappinfo front` before and after the call and fails if it changed. Keep some other app frontmost while driving and run every call with it; that assertion is the load-bearing test of this whole feature.

To tear the instance down, capture its pid at launch — `open` reports none itself, so diff `pgrep -f "$APP/Contents/MacOS/Plume"` before and after — and `kill` that pid. Never `pkill -f` on the app's path: it matches every instance built from that DerivedData path, including a developer's own debug Plume. The `drive-plume` skill has the full launch-and-capture recipe.

## Wire format

One JSON object per line in each direction. A request is `{"id": "<any string>", "command": "<name>", ...params}`; the response repeats `id` and carries `"ok": true, "result": {...}` or `"ok": false, "error": "..."`. Requests on one connection are answered in order, so a driver can queue a click and a read and trust the read sees the click. A malformed line gets an error response with `"id": null`.

All rects and points are in the window's content view, origin top-left, in points. That is the space SwiftUI's `.global` frames use and the space a screenshot's pixels map to (divide by `scale`). `WindowGeometry` is the one place that converts to AppKit's bottom-left space.

A **target** is either a registered control — `{"id": "composer-send-button", "index"?: n, "label"?: "substring"}` — or a surface: `{"kind": "composer" | "chatList" | "window"}`. Controls sharing an id are ranked top-to-bottom then left-to-right; `index` is that rank, and `label` narrows to rows whose label contains the text (case-insensitive). A target that matches several controls without an index is an error.

| Command | Params | Result |
|---|---|---|
| `list` | `plumeID?`, `label?`, `windowNumber?` | `[{id, index, label?, value?, isEnabled, frame, windowNumber, hasInvoke, hasSetValue}]` |
| `describe` | `target` | one such description |
| `invoke` | `target` | `{via: "closure" \| "click"}`; disabled controls are refused |
| `setValue` | `target`, `value` | `{}`; the composer, or a control that registered `setValue` |
| `readText` | `target` | `{text, rows?: [{index, text}]}`; rows for `chatList` and `window` |
| `clickSpan` | `matching`, `target?`, `occurrence = 0` | `{rect, windowNumber}` of the text that was clicked |
| `click` | `x`, `y`, `windowNumber?`, `clickCount = 1` | `{rect, windowNumber}` |
| `hover` | `target?` or `x`, `y`; `windowNumber?` | `{rect, windowNumber, regions}`; `regions` counts the `plumeHover` regions now under the pointer |
| `clear` | `windowNumber?` | `{}`; un-hovers everything and removes the overlay, in one window or all |
| `screenshot` | `path?`, `target?`, `windowNumber?` | `{path, width, height, scale}`; PNG, cropped to the target when given |
| `hierarchy` | `windowNumber?`, `target?`, `format = "text" \| "json"`, `textLimit = 200` | `{text}` or `{root}` |
| `drag` | `files?`, `text?`, `inApp?`; `target?` or `x`, `y`; `windowNumber?` | `{dropped, refusedAt?, view?, entered?, updated?, prepared?, performed?, feedbackAfterUpdate?, feedbackAfterDrop?}`, or `{destinations}` when no point is given |
| `key` | `key`, `modifiers? = ["command"\|"shift"\|"option"\|"control"]`, `windowNumber?` | `{chord, keyCode, windowNumber, handledBy?, handledByEnabled?}` |
| `menu` | — | `{items: [{path, keyEquivalent?, modifiers, isEnabled}]}` for the whole main menu |

`list` filters by `plumeID`, not `id`, because `id` at the top level is the request's correlation id.

## How it works

**Registry, not accessibility tree.** SwiftUI puts `.accessibilityIdentifier` on no NSView, and it builds its accessibility tree only for a trusted external client. So views register themselves: `plumeID(_:)` in `Plume/Control/PlumeID.swift` sets the identifier and, in a debug build, records the control in `ControlRegistry` with its `.global` frame, its window, its enabled state, an optional `label` and `value`, and optional `invoke` and `setValue` closures. Geometry and window arrive before `onAppear` and in either order, so every callback rewrites the whole entry. A tab hidden by opacity marks its subtree with `plumeControlsHidden`, which unregisters everything inside; a hidden tab's controls are not on screen even though they are mounted.

**Invoke is a click unless told otherwise.** SwiftUI `Button` actions are not introspectable, so `invoke` on a bare `plumeID` posts a synthetic click at the control's center. A site that passes `invoke:` runs that closure instead and reports `via: "closure"`.

**Clicks go through `SyntheticClick`.** It builds `NSEvent`s for the window, calls `window.makeKey()` (never `NSApp.activate`, which would steal focus), posts the mouse-down, waits 150 ms, then posts the mouse-up. The gap is load-bearing: queued together, AppKit's tracking loop exits before it pumps the run loop, and the click behaves differently from a human one. `docs/selectable-text-link-hang.md` found this.

**Key presses go through `SyntheticKey`.** `key` builds a real `NSEvent` and posts it the way `SyntheticClick` posts a mouse event, so it travels the whole dispatch path — local `.keyDown` monitors first (`TerminalShortcutMonitor`), then the key window's `performKeyEquivalent`, then the menu. The key code is found by translating every code on the active layout with `UCKeyTranslate`, so a chord resolves to whatever key is labelled that character. `handledBy` names the menu item carrying the chord, which is how to tell "the chord reached the wrong command" from "the command did nothing".

**`menu` is the authority on what chord a command carries.** It reads `NSMenuItem.keyEquivalent` after `update()`, not what `PlumeCommands` asked for — the difference is exactly where a rebind goes wrong. `docs/keyboard-shortcuts.md` covers why the two can disagree.

**Hover goes through `plumeHover`, not through events.** SwiftUI's hover tracking answers only the real pointer: a `mouseMoved` posted to the window, sent straight to it, or delivered to the tracking area's owner does nothing, and faking `mouseLocationOutsideOfEventStream` does nothing either. So `.plumeHover { … }` stands in for `.onHover` everywhere. In a debug build it also registers the region's frame with `HoverRegistry`, and `hover` calls the closures itself: regions the pointer left hear `false`, regions it entered hear `true`, nested regions hover together. Every click hovers its point first, the way a real pointer arrives before it presses. A button style's own hover highlight is SwiftUI-internal and stays off.

**The overlay shows the driver's pointer.** The first hover or click over a window attaches a transparent child window (`ControlOverlay`) that draws `pointer.arrow.ipad` — chosen to look unlike the real arrow — at the synthetic pointer, and a ring that fades over half a second where a click landed. It ignores mouse events, never becomes key, and follows the window when it moves or resizes. `clear` removes it.

**Text is read from AppKit.** The composer is a real `NSTextView` and the chat list's selectable text is a real `NSTextField`, so `readText` reads their strings and `clickSpan` resolves a substring through the layout manager (`TextSpanLocator`): TextKit 2 first, because reading `layoutManager` on a TextKit 2 view silently downgrades it. An `NSTextField` without a live field editor is laid out again in a scratch container the size of its title rect, which matches to within a point.

**Screenshots come from the window server.** `WindowCapture` calls `CGWindowListCreateImage` for the app's own window, which needs no Screen Recording grant and returns real pixels even while the session reports itself locked, where drawing the view tree with `cacheDisplay(in:to:)` has come back blank. The SDK hides that function from Swift as "use ScreenCaptureKit", which does need a grant; it is bound by symbol name. The capture is cropped to the content view, the overlay's window is captured the same way and composited on top, and `scale` is pixels per point. A capture that is one flat color is refused with an error naming the display state (asleep, locked) instead of being written as a blank PNG.

**A drop is replayed, not dragged.** The window server owns the real drag session and answers only the physical pointer, so `drag` calls the destination protocol itself (`SyntheticDrag`): `draggingEntered`, `draggingUpdated`, `prepareForDragOperation`, `performDragOperation`, `concludeDragOperation`, reporting each step and the one that refused. This is what tells a drop that highlights and then does nothing apart from one that was never offered the drag. The payload goes on the real drag pasteboard, because `DropInfo` reads that by name rather than through `draggingPasteboard`.

Called with no point, `drag` instead surveys the window: every registered destination, its frame and its types. **Registration is not hit-testing** — SwiftUI puts its `_PlatformDraggingDestinationView` *behind* the content it belongs to, so walking up from `hitTest` finds none of them. Matching is by UTI conformance, since SwiftUI registers `public.data`/`public.item` rather than the type a drag actually carries.

**`hierarchy` walks the NSView tree** (`HierarchyDumper`), drops hidden views, collapses plain containers with nothing to say into their children, and attaches each registered control to the smallest visible view whose frame contains it, so a hosted SwiftUI button appears inside the hosting view that draws it.

## Limits

- A SwiftUI control without `plumeID` is invisible to `list` and `invoke`. Add the modifier; never a bare `.accessibilityIdentifier`.
- Views hidden by SwiftUI opacity outside a tab (not via `plumeControlsHidden`) still appear in `hierarchy`; their NSViews are not hidden.
- `invoke` of a bare `Button` is a click, so it needs the control to be on screen and unobscured. Pass `invoke:` at sites where that matters.
- A synthetic click never fires a `.onTapGesture` on a SwiftUI `List` row, visible or hidden; the row's `Button`s still work. Task rows pass `invoke:` for this reason, and report `value: "selected"` so a driver can confirm the selection.
- Synthetic clicks do not reorder windows and never activate the app. Launching is what puts a window on the user's Space; `open -j` avoids it.
- `hover` reaches only `plumeHover` regions. A bare `.onHover`, `.onContinuousHover`, or a button style's hover highlight never sees the synthetic pointer. The real pointer still wins: if it crosses a region, SwiftUI's own callback overrides the synthetic state.
- `drag` proves the destination side only. A SwiftUI `.dropDestination(for:)` accepts the session and reports `performed: true` without the closure's payload decoding, because `Transferable` does not read a hand-built pasteboard item the way it reads a real drag's. `.onDrop` does run end to end, both with `fileURL` and with text read through `NSItemProvider.loadObject`, which is why the tab strip and sidebar drops use it: `drag text=plume-task:<uuid>` replays a real reorder. There is no way to drive a drag *source* at all — neither `.draggable` nor `.onDrag` installs anything at the AppKit layer, and synthesizing pointer input is off limits. Drop feedback and the drop's fast path read `InAppDrag.shared`, which a real drag source fills from `onDrag`. A plain replay leaves it empty, so it draws nothing and the drop loads its payload. `inApp=true` with a Plume `text` payload records the item first, as the source would: the replay then takes the in-app path, and `feedbackAfterUpdate`/`feedbackAfterDrop` report what the drag would draw at each point. It proves the feedback state, not that the view renders it.
- **A command gated on a `focusedSceneValue` reads disabled in a scratch instance, and its chord does nothing.** SwiftUI populates those values only while the app's scene is active, which a hidden, never-activated instance never is. Every item in the Tab menu and most of the File menu is affected, including chords that work fine for a real user. `key` still proves which item owns a chord; it cannot prove the item's action ran. Check `handledByEnabled` before reading a no-op as a bug.
- The server runs on the main thread. A command that blocks the UI blocks the response.
