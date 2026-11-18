# The debug control server

A debug build of Plume opens a Unix-domain socket an agent can drive and inspect the app through: list the controls on screen, read and set the composer, click a word, dump the window as text, take a screenshot, and record a video. It needs no Accessibility (TCC) grant and never activates the app, so the user's focus stays where it was. `scripts/debug/plume-control.py` is the client; `Plume/Control/` is the implementation, all `#if DEBUG`.

## Inspect before you screenshot

Reach for commands in this order. Each is cheaper than the next for an agent to read.

1. `hierarchy` — the whole window as an indented outline: every text view with its text, every control with its enabled state, every `plumeID` with its frame. This answers "what is on screen" and "where is X" without pixels.
2. `readText` — one surface's text: the composer, the chat list row by row, or one control.
3. `screenshot` — only when the question is about layout or rendering that text cannot answer.
4. `recordStart` and `recordStop` — a video, for what only shows over time: a fade, a scroll hitch, a row that jumps.

## Finding the socket

Each instance binds `<Application Support>/control/<pid>.sock`, mode `0600` in a `0700` directory, and logs the path under the `control` category at launch. Sockets of instances that have exited are unlinked the next time an instance starts. `PLUME_CONTROL_SOCKET=<path>` overrides the location directly, and a preferred path longer than 103 bytes (a long `PLUME_APP_SUPPORT` override) falls back to `/tmp/plume-control-<pid>.sock`. `PLUME_CONTROL=0` disables the server. The test host has no bundle identifier and never starts one.

**`PLUME_APP_SUPPORT=<path>` redirects the whole Application Support directory** — `Plume.store`, `hooks`, `events`, and `control` all move with it. It is `#if DEBUG` only; a Release build ignores it. `URL.applicationSupportDirectory` resolves from the process's security context, not `$HOME`, so `open --env HOME=...` does **not** isolate a scratch instance from the user's real data — it still reads `~/Library/Application Support/Plume.debug*`. `PLUME_APP_SUPPORT` is the only way to get a genuinely isolated instance.

The client discovers the socket in this order: `--socket`, `$PLUME_CONTROL_SOCKET`, then the live `*.sock` files under every `Plume.debug*/control` directory, preferring the checkout's own (`Plume.debug` for the primary checkout, `Plume.debug-<worktree>` otherwise). With several instances running pass `--pid` or `--latest`. `--wait N` waits for a socket that accepts a connection, because a killed instance leaves its file behind.

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

**A split task shows two panes, each with its own tab strip, so every control inside a pane registers twice** — two `composer-send-button`s, two `composer-field`s. Pick one with `index` (the left pane ranks first when the rows line up) or with `label` where the control carries one. Each on-screen tab registers a `tab-pane` labelled with its tab's title, with `value: "focused"` on the focused one. The `composer` and `chatList` surfaces resolve to the focused pane's, and report not found when the focused pane is a terminal; to read the other pane, focus it first (a click inside it, or `⌥⌘\`) or target a control in it.

While split, a tab chip's label ends with its pane, counted from the left — `Chat (pane 2)` — and each strip's `tab-strip` and `new-tab-button` are labelled `pane 1` or `pane 2`. So `label: "(pane 2)"` picks out the right strip's chips. A chip reports `value: "selected"` for the focused tab and `"shown"` for the tab the other pane shows. Unsplit, labels are the bare title. Crop a screenshot to `tab-strip` to see one strip.

| Command | Params | Result |
|---|---|---|
| `list` | `plumeID?`, `label?`, `windowNumber?` | `[{id, index, label?, value?, isEnabled, frame, windowNumber, hasInvoke, hasSetValue}]` |
| `describe` | `target` | one such description |
| `invoke` | `target` | `{via: "closure" \| "click"}`; disabled controls are refused |
| `setValue` | `target`, `value` | `{}`; the composer, or a control that registered `setValue` |
| `readText` | `target` | `{text, rows?: [{index, text}]}`; rows for `chatList` and `window`. The composer adds `selection: {location, length}` in UTF-16 offsets, and `checkboxes: [{line, isChecked, rect}]` for the checkboxes in its visible area, `line` counted from 0 |
| `clickSpan` | `matching`, `target?`, `occurrence = 0` | `{rect, windowNumber, view}` of the text that was clicked. A text view is scrolled to the span first; a span still off screen is an error, not a click |
| `click` | `x`, `y`, `windowNumber?`, `clickCount = 1` | `{rect, windowNumber, view}`; `view` is the class the mouse-down hit-tested to |
| `pointerDrag` | `fromX`, `fromY`, `toX`, `toY`; `windowNumber?`, `clickCount = 1`, `steps = 10` | `{rect, windowNumber, view}` at the end point; mouse-down, `steps` `.leftMouseDragged` events along the line, mouse-up |
| `hover` | `target?` or `x`, `y`; `windowNumber?` | `{rect, windowNumber, regions}`; `regions` counts the `plumeHover` regions now under the pointer |
| `clear` | `windowNumber?` | `{}`; un-hovers everything and removes the overlay, in one window or all |
| `screenshot` | `path?`, `target?`, `windowNumber?` | `{path, width, height, scale}`; PNG, cropped to the target when given |
| `recordStart` | `path?`, `target?`, `windowNumber?`, `fps = 30` (1–60), `maxSeconds = 30` (at most 300) | `{path, width, height, scale, fps, maxSeconds}`; H.264, `.mov` for QuickTime and MPEG-4 otherwise, cropped to the target when given |
| `recordStop` | — | `{path, width, height, frames, dropped, duration, stoppedBy: "request" \| "limit" \| "windowClosed"}`; after a recording stopped itself, returns that one |
| `hierarchy` | `windowNumber?`, `target?`, `format = "text" \| "json"`, `textLimit = 200` | `{text}` or `{root}` |
| `drag` | `files?`, `text?`, `inApp?`; `target?` or `x`, `y`; `windowNumber?` | `{dropped, refusedAt?, view?, entered?, updated?, prepared?, performed?, feedbackAfterUpdate?, feedbackAfterDrop?}`, or `{destinations}` when no point is given |
| `key` | `key`, `modifiers? = ["command"\|"shift"\|"option"\|"control"]`, `windowNumber?` | `{chord, keyCode, windowNumber, handledBy?, handledByEnabled?, firstResponder?}`. `key` is one character or a name: `left`, `right`, `up`, `down`, `home`, `end`, `pageup`, `pagedown`, `delete`, `forwarddelete`, `return`, `tab`, `escape`, `space`. An uppercase letter, or a character only Shift types (`@`), adds Shift |
| `resize` | `width`, `height`, `windowNumber?`, `live = false`, `steps = 8` (at most 120), `stepDelay = 0.016` | `{windowNumber, width, height, sizes: [{width, height}], live}`; sets the content size in points. With `live`, steps there inside a live resize |
| `menu` | — | `{items: [{path, keyEquivalent?, modifiers, isEnabled}]}` for the whole main menu |
| `windowSize` | `width?`, `height?`, `windowNumber?` | `{windowNumber, width, height}`, the content size; with `width` and `height` it resizes the window's content to that size first |
| `selection` | — | `{markdown, plainText, anchor?, focus?}` for the focused chat's transcript selection; anchor and focus are `{pieceID, offset}`, absent when nothing is selected |
| `tab.move` | `tabID` or `label`, `toTask` | `{tabID, taskID}`; moves the tab to another task through `TaskStore.moveTab`. `label` matches a tab's title and `toTask` a task's ID or title, each as a case-insensitive substring that must match exactly one |
| `tab.split` | `tabID` or `label` | `{tabID, taskID}`; moves the tab into a new ungrouped task, as Move to New Task does |
| `sidebar.reveal` | `task` | `{taskID}`; scrolls the sidebar so the task's row is centered. `task` matches a task's ID or title, as a case-insensitive substring that must match exactly one. Refuses a task in a collapsed group |
| `tab.status` | `tabID` or `label`, `status`, optional `unread` | `{tabID, taskID, status, unread}`; sets the tab's status through `StatusEngine`, as an agent event does. `status` is a `TaskStatus` raw value (`working`, `awaitingReply`, `questionAsked`…). `unread`, when given, marks the tab unread or read after the status lands |
| `selectText` | `matching`, or `from` and `to?`; `occurrence = 0` | the same `{markdown, plainText, anchor, focus}` after selecting. `matching` selects that span; `from` and `to` select from the start of `from` to the end of the first `to` after it, across pieces. Searches the whole transcript, realized rows or not |
| `tasks` | — | `{tasks: [{id, title, isSelected, tabKind?, expectsRows}]}` for the frontmost window's unarchived tasks, in sidebar order |
| `selectTask` | `task`, `from?`, `repeat = 1` (at most 200), `timeout = 5`, `settle = 0.3` | `{samples, timedOut, visibleMs?, firstTurnMs?, rowsPlacedMs?, spans}`; see [Measuring a task switch](#measuring-a-task-switch) |
| `appendTurn` | `repeat = 1` (at most 200), `timeout = 15`, `settle = 1`, `reply = true` | `{samples, timedOut, visibleMs?, firstTurnMs?, rowsPlacedMs?, longestTurnMs?, busyMs?, spans}`; see [Measuring a transcript append](#measuring-a-transcript-append) |
| `scrollChat` | `to = "top" \| "bottom"` or `by` (signed points); `speed = 4000`, `settle = 0.3`, `maxSeconds = 30` (at most 300), `worst = 5`, `clock = "auto" \| "timer"` | `{clock, periodMs, frames, durationMs, startOffset, endOffset, distance, timedOut, realizations, intervalMs?, workMs?, overTwoPeriods, overFourPeriods, over50, over100, hitchMs, hitchMsPerSecond, spans, worstFrames}`; see [Measuring a scroll](#measuring-a-scroll) |

`list` filters by `plumeID`, not `id`, because `id` at the top level is the request's correlation id.

## Measuring a task switch

`selectTask` selects a task the way a sidebar click does and times it with `SwitchLatencyProbe` (`Plume/Support/SwitchLatencyProbe.swift`). The clock starts at the selection change. A run-loop observer ordered after Core Animation's commit marks the end of each main-thread turn, and the switch ends with the first turn in which the target tab's chat list placed rows. A tab with no transcript (`expectsRows: false`: an empty chat, a terminal) ends with its first turn. A task matches by id, then by exact title, then by a unique title substring, ignoring case.

```
c tasks
c selectTask task="Task 1" from="Task 3" repeat=15
```

`repeat` above 1 needs `from`: without it every round after the first would re-select the target. With `from`, each round first selects `from`, unmeasured, so every sample is the same switch. `settle` seconds pass after each selection, so work a switch defers doesn't land in the next sample. Each sample reports, in milliseconds from the selection change:

- `firstTurnMs`: the end of the first main-thread turn.
- `rowsPlacedMs`: when the chat list first placed rows.
- `visibleMs`: the end of the turn whose commit showed them. This is the number to compare.
- `turns`, and `spans`: time and call counts for the instrumented sections, `reveal` (the selection change itself), `rebuildPieces`, `listUpdate`, `layoutPass`, `realizeMeasure`, and counts for `pieceCacheHit` and `pieceCacheMiss`. Spans nest: `realizeMeasure` runs inside `layoutPass`.

The report summarizes `visibleMs`, `firstTurnMs`, `rowsPlacedMs` and each span as `{count, median, p90, min, max}` (p90 by nearest rank), leaving timed-out samples out. Every switch also logs a `switch-latency …` line under the `app` category, `SmokeHarness`'s `PLUME_CYCLE_SELECTION` cycling included.

## Measuring a transcript append

`appendTurn` appends a synthetic user prompt, and with `reply = true` an assistant reply, to the transcript of the selected task's tab. It then times how long the chat takes to show the new prompt's row. It needs a selected task whose tab watches a transcript. The command writes to that file, so seed the task with `PLUME_SEED_TRANSCRIPT_PATH` pointing at a scratch copy, never the original. It refuses to write:

- to any path inside Claude Code's projects directory (`~/.claude/projects`), even a seeded one, after resolving symlinks and `..`. A later `--resume` would feed the synthetic rows to the model, and a process this instance can't see, such as the installed app or a terminal `claude --resume`, may be writing the file;
- to a transcript that is not a `PLUME_SEED_TRANSCRIPT_PATH` path while a terminal or agent process of this instance backs the tab, since that process may be writing the same file;
- to a file whose last byte is not a newline, since its last row may be half-written;
- at all when opening, seeking or writing fails. That error returns at once, not after `timeout`.

```
c appendTurn repeat=2
c appendTurn repeat=10
```

The clock starts at the write. A sample ends with the main-thread turn whose commit first showed the new prompt's row. That includes the background parse. The store reads the first change of a burst at once, so the 250 ms debounce adds nothing unless the write lands inside a window an earlier change opened. `repeat` appends one turn per round, and `settle` seconds pass after each so trailing work stays out of the next sample. A sample that shows no row within `timeout` reports `timedOut: true` and is left out of the summaries.

The report has the same fields as a task switch, plus two:

- `longestTurnMs`: the longest single main-thread turn during the sample. This is the hitch a user sees.
- `busyMs`: the sum of every main-thread turn during the sample.

The `spans` add `storePublish`, the main-actor block of `TranscriptStore.read` that publishes a finished parse. Each transcript read also logs a `transcript-read …` line under the `app` category, with the time for the file load, the line decoding, the parse, each scanner, the subagents and the total. It also logs `bytes` (the file's size), `bytesRead` (what this read loaded), `tail` (whether it read only what was appended since the last read) and `reusedParent` (whether the file was unchanged).

## Measuring a scroll

`scrollChat` scrolls the focused chat list at a steady `speed` in points per second, to the top or bottom, or `by` a signed distance (negative is up). On every frame it moves the clip view by `speed × dt` with `clip.scroll(to:)` and `reflectScrolledClipView`, as a wheel would, so the list treats it as the reader's scroll. `to` re-reads the end every frame, because the document grows as rows measure. `by` counts the driver's own moves rather than comparing offsets: when rows above the viewport re-measure, the list shifts the offset to keep the reader's place, and the run still ends after `by` points. The report's `distance` is that count, so it can differ from `endOffset − startOffset` by those shifts. If the list leaves its window mid-run, a task switch say, the run fails with an error. The run measures for `settle` seconds after reaching its destination, and stops at `maxSeconds` regardless (`timedOut: true`). It holds the same activity assertion as `selectTask`.

```
c scrollChat to=top speed=4000
c scrollChat by=-2000 worst=10
```

The frame clock is the scroll view's display link. A hidden or occluded window, or a sleeping display, stops vsync, so a 120 Hz timer takes over when the link stays silent: 100 ms at the start, or a second since its last tick mid-run. A busy main thread delays a pending link callback as long as it delays the check, so a check that runs late gives the link another 100 ms before the timer takes over. The timer's first tick has no interval, like the run's first, so the silence never counts as a frame. `clock` reports `displayLink`, `timer`, or `mixed`. Each interval is judged against the period of the clock that ended it, and `periodMs` is the median of those periods. `clock=timer` never creates the display link and ticks from the 120 Hz timer throughout; compare runs taken with the same clock, and use `timer` for repeatable ones.

Each frame interval, from one tick's callback to the next, reports:

- `intervalMs`: how late the main thread reached the next frame. This is the hitch metric: any main-thread work, whoever did it, shows as a long interval.
- `workMs`: how long the main-thread turn the interval's first tick began ran, through Core Animation's commit. An interval much longer than its `workMs` waited on something other than that turn.
- `realizations`: rows the list built in the interval, and `spans`: the instrumented sections that ran in it. `layoutPass` holds `realizeWindow`, `placeHosts` and `publishVisible`; `realizeWindow` holds `makeRoot`, `realizeMeasure` and `freeHost`. `minimapBody` counts the minimap's SwiftUI body evaluations.

The first tick has no interval and is left out. `intervalMs` and `workMs` are summarized as `{count, median, p90, p99, max}`, by nearest rank. `overTwoPeriods` and `overFourPeriods` count intervals longer than two and four periods: at least one and three missed frames. `over50` and `over100` count intervals longer than that many milliseconds. `hitchMs` adds up, over intervals longer than 1.5 periods, the time past one period. `spans` are run totals, slowest first, and `worstFrames` itemizes the `worst` longest intervals with their offset.

Compare `hitchMsPerSecond` first, then `overTwoPeriods` and `overFourPeriods`, then `intervalMs.p99`. Every run also logs a `scroll-hitch …` line under the `app` category.

`scripts/debug/measure-chat-scroll.sh <transcript.jsonl> [passes=3] [speed=4000]` launches a scratch instance seeded with a copy of the transcript and runs top-and-back passes. It sets each pass's `maxSeconds` from the distance and the speed, and warns and exits non-zero if a pass still times out. Environment variables change its defaults:

- `CLOCK`: `timer` (the default) or `auto`.
- `DISTANCE`: scroll this many points each way instead of to the ends. Unset by default.
- `KEEP=1`: leave the app running afterwards. Off by default.
- `EXTRA_ENV="A=1 B=2"`: extra environment for the app.

The minimap re-renders whenever the set of visible rows changes, and that cost can hide the list's own. Launch with `PLUME_NO_VISIBLE_PUBLISH=1` (`EXTRA_ENV` in the script) to stop the list publishing that set, so the minimap stays still while the list scrolls. Debug builds only.

## How it works

**Registry, not accessibility tree.** SwiftUI puts `.accessibilityIdentifier` on no NSView, and it builds its accessibility tree only for a trusted external client. So views register themselves: `plumeID(_:)` in `Plume/Control/PlumeID.swift` sets the identifier and, in a debug build, records the control in `ControlRegistry` with its `.global` frame, its window, its enabled state, an optional `label` and `value`, and optional `invoke` and `setValue` closures. Geometry and window arrive before `onAppear` and in either order, so every callback rewrites the whole entry. A tab hidden by opacity marks its subtree with `plumeControlsHidden`, which unregisters everything inside; a hidden tab's controls are not on screen even though they are mounted.

**Invoke is a click unless told otherwise.** SwiftUI `Button` actions are not introspectable, so `invoke` on a bare `plumeID` posts a synthetic click at the control's center. A site that passes `invoke:` runs that closure instead and reports `via: "closure"`.

**Clicks go through `SyntheticClick`.** It builds `NSEvent`s for the window, calls `window.makeKey()` (never `NSApp.activate`, which would steal focus), posts the mouse-down, waits 150 ms, then posts the mouse-up. The events go through `NSApp.postEvent`, so they pass every local `NSEvent` monitor on the way, as a real click does, unless the view under the point refuses first mouse (below). The gap is load-bearing: queued together, AppKit's tracking loop exits before it pumps the run loop, and the click behaves differently from a human one. `docs/selectable-text-link-hang.md` found this.

**A click on a text view is handed to the view.** A driven instance is never active, so `makeKey()` never makes its window key, and `NSWindow` spends a mouse-down on a non-key window making it key unless the view under the point accepts first mouse. SwiftUI's controls do; `NSTextView` and the chat list's rows do not, so a posted click never reached the composer. When the hit-tested view refuses first mouse, `SyntheticClick` makes it first responder and calls its `mouseDown(with:)` directly, which is the same entry a real click reaches, so the composer's own checkbox hit-test runs. The view's tracking loop runs the run loop in event-tracking mode until the mouse-up, where a sleeping task never resumes, so the mouse-up and drag events ride timers in the common modes. `view` in the result names the class the click went to.

**`clickSpan` scrolls a text view to the span before it clicks.** It lays out the text up to the span first. TextKit 2 places lines it has not laid out at estimated heights, and corrects them once the viewport lays out after the scroll, so without that the span lands a line or more from the rect the click aimed at.

**A live resize runs through AppKit's own entry points.** A real one starts only from the window server's drag of a window edge, so `resize live=true` calls the private `NSWindow` methods `_startLiveResize` and `_endLiveResize` around its steps: `inLiveResize` reads true throughout, and every view hears `viewWillStartLiveResize` and `viewDidEndLiveResize`. It refuses rather than fakes when either is missing.

**Key presses go through `SyntheticKey`.** `key` also takes the navigation and editing keys by name, for keys no layout types a character for. Each carries the flags AppKit sets on its own (`.function`, and `.numericPad` on the arrows), so `key=left modifiers='["shift","option"]'` reaches a text view as `moveWordLeftAndModifySelection:`. `key` builds a real `NSEvent` and posts it the way `SyntheticClick` posts a mouse event, so it travels the whole dispatch path — local `.keyDown` monitors first (`TerminalShortcutMonitor`), then the key window's `performKeyEquivalent`, then the menu. The key code is found by translating every code on the active layout with `UCKeyTranslate`, so a chord resolves to whatever key is labelled that character. A character no key types on its own, like `@` on a US layout, resolves to the key that types it with Shift, and Shift is added to the press. `home` and `end` scroll a text view without moving the caret, as they do for a person on a Mac; `⌃A` and `⌃E` (`key=a modifiers='["control"]'`) move it to the line's ends, and `⌘up` and `⌘down` to the document's. `handledBy` names the menu item carrying the chord, which is how to tell "the chord reached the wrong command" from "the command did nothing".

**`menu` is the authority on what chord a command carries.** It reads `NSMenuItem.keyEquivalent` after `update()`, not what `PlumeCommands` asked for — the difference is exactly where a rebind goes wrong. `docs/keyboard-shortcuts.md` covers why the two can disagree.

**Hover goes through `plumeHover`, not through events.** SwiftUI's hover tracking answers only the real pointer: a `mouseMoved` posted to the window, sent straight to it, or delivered to the tracking area's owner does nothing, and faking `mouseLocationOutsideOfEventStream` does nothing either. So `.plumeHover { … }` stands in for `.onHover` everywhere. In a debug build it also registers the region's frame with `HoverRegistry`, and `hover` calls the closures itself: regions the pointer left hear `false`, regions it entered hear `true`, nested regions hover together. Every click hovers its point first, the way a real pointer arrives before it presses. A button style's own hover highlight is SwiftUI-internal and stays off.

**The overlay shows the driver's pointer.** The first hover or click over a window attaches a transparent child window (`ControlOverlay`) that draws `pointer.arrow.ipad` — chosen to look unlike the real arrow — at the synthetic pointer, and a ring that fades over half a second where a click landed. It ignores mouse events, never becomes key, and follows the window when it moves or resizes. `clear` removes it.

**Text is read from AppKit, and from the chat selection registry.** The composer is a real `NSTextView`. Markdown chat pieces draw through `ChatSelectionRenderer`, so they are no `NSTextField`; each `Text` records itself in `ChatTextLayoutRegistry`, and `readText` and `clickSpan` take those from the realized rows, merged top to bottom with the AppKit views (tool rows and the like). `clickSpan` finds a glyph rect in the `Text.Layout`. For AppKit views, `clickSpan` resolves a substring through the layout manager (`TextSpanLocator`): TextKit 2 first, because reading `layoutManager` on a TextKit 2 view silently downgrades it. An `NSTextField` without a live field editor is laid out again in a scratch container the size of its title rect, which matches to within a point.

**Screenshots come from the window server.** `WindowCapture` calls `CGWindowListCreateImage` for the app's own window, which needs no Screen Recording grant and returns real pixels even while the session reports itself locked, where drawing the view tree with `cacheDisplay(in:to:)` has come back blank. The SDK hides that function from Swift as "use ScreenCaptureKit", which does need a grant; it is bound by symbol name. The capture is cropped to the content view, the overlay's window is captured the same way and composited on top, and `scale` is pixels per point. A capture that is one flat color is refused with an error naming the display state (asleep, locked) instead of being written as a blank PNG.

**A recording is a screenshot on a timer.** `WindowRecorder` captures the window the same way, so it needs no Screen Recording grant either, and encodes the frames with `AVAssetWriter`. One recording runs at a time; `recordStart` refuses a second. A main-queue timer reads the window's geometry and the overlay each tick, and a serial queue captures and encodes, so the capture never stalls the animation being recorded. Each frame is stamped when it is captured, and the video ends at the moment it stopped, so its duration is real time. `fps` is a ceiling: a busy main thread skips ticks and the encoder skips frames it is still behind on (`dropped`). The recording holds a `ProcessInfo` activity, because App Nap would otherwise throttle a never-frontmost instance's timer to a few frames a second. Frames are drawn in the capture's own color space, since converting each one cost more than everything else in a frame. A recording stops itself at `maxSeconds`, so a forgotten one ends on its own; `recordStop` then returns it. Like `screenshot`, it cannot record a hidden (`open -j`) window. A target's crop is fixed when recording starts.

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
- `drag` proves the destination side only. A SwiftUI `.dropDestination(for:)` accepts the session and reports `performed: true` without the closure's payload decoding, because `Transferable` does not read a hand-built pasteboard item the way it reads a real drag's. `.onDrop` does run end to end, both with `fileURL` and with text read through `NSItemProvider.loadObject`, which is why the tab strip and sidebar drops use it: `drag text=plume-task:<uuid>` replays a real reorder. `drag` cannot drive a drag *source* — neither `.draggable` nor `.onDrag` installs anything at the AppKit layer. `pointerDrag` posts a real mouse-down, drag events and mouse-up inside the process, which drives selection and in-view tracking, but it does not start a window-server drag session. Drop feedback and the drop's fast path read `InAppDrag.shared`, which a real drag source fills from `onDrag`. A plain replay leaves it empty, so it draws nothing and the drop loads its payload. `inApp=true` with a Plume `text` payload records the item first, as the source would: the replay then takes the in-app path, and `feedbackAfterUpdate`/`feedbackAfterDrop` report what the drag would draw at each point. It proves the feedback state, not that the view renders it.
- **A command gated on a `focusedSceneValue` reads disabled in a scratch instance, and its chord does nothing.** SwiftUI populates those values only while the app's scene is active, which a hidden, never-activated instance never is. Every item in the Tab menu and most of the File menu is affected, including chords that work fine for a real user. `key` still proves which item owns a chord; it cannot prove the item's action ran. Check `handledByEnabled` before reading a no-op as a bug.
- The server runs on the main thread. A command that blocks the UI blocks the response.
- **A click handed straight to a view skips `NSApplication.sendEvent`**, so a local `NSEvent` monitor never sees its mouse-down. The mouse-up and drag events are still posted. This happens to every view that refuses first mouse: text views, and also the chat list's document view and its row hosting views. A click on any view that accepts first mouse, every SwiftUI control included, is posted whole. The result's `view` names the class the click went to.
- **With no key window, AppKit sends a posted key to the window last made key, not to the window the event names.** `key` calls `makeKey()` on its window first, which is enough with one window. Two test windows driven in parallel take each other's keys, so a test that types and clicks keeps both in one test.
- **`selectTask` times only the main thread.** Work a switch moves off the main actor and publishes later is outside `visibleMs` unless it delays the first rows. A chat whose transcript is still being read places no rows until the read lands, so the first switch into a tab after launch measures the read too; discard it, or warm the tab with one unmeasured round. A sample that places no rows within `timeout` reports `timedOut: true` and is left out of the summaries; it means the target showed something other than chat rows, so check `tasks`' `expectsRows` and which tab the task has focused.
- **`scrollChat` times the main thread only, and drives the clip view directly rather than through wheel events.** AppKit's responsive-scrolling path, momentum, and elasticity are never exercised, and render-server hitches that the main thread doesn't cause never show.
- **A driven instance is never frontmost, so macOS throttles it.** Without an activity assertion, samples from one run swing between about 0.6 s and 3 s for the same switch, and every span slows together. `selectTask` holds a `userInitiated` + `latencyCritical` activity while it runs; time a switch any other way and the numbers are noise.
- **A user-defaults write during a switch measures the defaults domain as much as Plume.** AppKit answers each write by rebuilding the merged domain on the main thread, at a cost that grows with its key count. Every debug build shares `com.ryanmoelter.Plume.debug`, which gathers thousands of keys over time, so one write there can cost hundreds of milliseconds that a user's machine never pays. `LastOpenTask` waits until selection has been still for two seconds for this reason. A span that jumps on one machine and not another is worth checking for a write.
- **A chat's minimap and info pane mount a turn after its rows.** `visibleMs` ends with the frame that first shows the rows, and those two mount once it has committed (`AfterCommit`), fading in over 0.15 s. Their controls register then too, so a read sent the instant `selectTask` returns can miss them. Read again before calling one missing. The composer is never deferred: it must take keystrokes, and serve its focused scene value, from the first frame.
- **The minimap is one registered control, driven through `setValue`.** The rail is a single `Canvas`, so it registers only `chat-minimap`, and it follows the pointer with `onContinuousHover`, which a synthetic `hover` never reaches. Its `value` is JSON: `scroll` (0–1, the map's own scroll), `railWidth` and `railInset` (in points, wider while hovered in a narrow pane) and `rows`, each `{index, label, kind, isVisible, isHovered}` with the end of the conversation as the last row (`kind: "end"`). `setValue` takes a command instead of a value:
  - `hover <n>` hovers row `n`, scrolling the map to it first if it is off the rail. It shows the magnification and the preview as a real pointer would.
  - `hover <fraction>` (it must contain a `.`, as in `hover 0.5`) puts the pointer that far down the rail. The map scrolls through `MinimapCatchUp`, so a sequence of fractions drives the catch-up exactly like a pointer moving. The first hover of a sequence sets where the pointer entered. The map holds still until a later one is the tuned dead zone (16 pt by default) away from it. The first and last twentieth of the rail are edge zones: a sweep toward an end reaches it (`scroll` 0 or 1) by the time the pointer enters that end's zone, at `hover 0.05` or `hover 0.95`, whatever the gap when it entered. A sweep that starts inside a zone reaches the end by `hover 0.0` or `hover 1.0`. Toward a zone the dead zone overlaps, the map does not hold. The hovered row is the one under the pointer at the catch-up's offset, but the drawn map scrolls only when that row changes: it then glides, over the `snap` duration, to where the catch-up would be with the pointer moved on to the new row's middle. The first row of a hover draws at the catch-up's own offset. `scroll` reports the drawn offset.
  - `leave` ends the hover. The map then returns to where the chat is.
  - `click <n>` scrolls the chat to row `n`; `click end` scrolls it to the bottom. This calls the selection directly and skips the click monitor.

  Either `hover` arms the minimap's click monitor, the way a real pointer over the rail does, until `leave`. A real click at a window point then goes through it: it selects the hovered row only if the point is on the rail, clear of the pane's edge, and over the chat's own content. Anywhere else, including a split divider, the click passes through. Use `describe` for the minimap's frame. The rail's edge is the frame's leading edge. In a scratch instance, a `click` over the chat never reaches the monitor, because the chat's views refuse first mouse and the click is handed to them directly (see the limits above). A minimap click that does nothing there is the harness, not the rail; `click <n>` tests the selection itself.

  ```
  c describe target='{"id":"chat-minimap"}'
  c setValue target='{"id":"chat-minimap"}' value="hover 3"
  c click x=12 y=300
  c setValue target='{"id":"chat-minimap"}' value="leave"
  c setValue target='{"id":"chat-minimap"}' value="click end"
  ```

  To make a short conversation overflow the rail, shrink the window with `windowSize`, as in `c windowSize width=900 height=420`.

  Settings ▸ Debug ▸ Minimap holds the tuning sliders, which start hidden; `invoke` `settings-minimap-tuning-toggle` (value `shown` or `hidden`) to show them. Each slider then registers as `settings-minimap-tuning-<key>` and takes a number through `setValue`, clamped to its range. The keys are `genie-radius`, `genie-width`, `genie-thickness`, `preview-width`, `preview-lines`, `fade-in`, `fade-out`, `slide`, `crossfade`, `snap`, `indirect-slide`, `catch-up-gain` and `dead-zone`. `settings-minimap-tuning-reset` restores the defaults.
- **A split is driven through `split-toggle` and `split-divider`.** The Split Right menu item reads disabled in a scratch instance, so `invoke` `split-toggle` instead. It splits the selected task to the right, or closes its split, and its label says which one it would do. While the task is split, `split-divider` registers the divider's grip with its frame. `invoke` on it resets the split to even, like a double-click. To test the gestures themselves, use `click` with `clickCount=2` on the grip's center, or `pointerDrag` from it.

  ```
  c invoke target='{"id":"split-toggle"}'
  c describe target='{"id":"split-divider"}'
  c pointerDrag fromX=640 fromY=300 toX=560 toY=300
  c click x=560 y=300 clickCount=2
  ```
- **A SwiftUI `Menu`'s items mount only while it is open, so a `plumeID` inside one never registers.** Put `plumeMenuItem(_:)` on the `Menu` instead. It registers an always-mounted entry that runs the item's action. The entry has the menu's frame, so it answers `invoke` and not `click`. The tab strip's `+` menu and the device tab's Shut Down Emulator use it. A menu built from a list of entries registers each one from a `ForEach` behind the menu, with the row's `label:`, as the info pane's Linear row menu does.
- **A `Menu` whose items repeat registers them with `plumeMenuItems(_:_:label:invoke:)`**, one entry per item under one id, told apart by `label`. The workspace picker's worktree list (`workspace-worktree-item`, labelled by worktree name) and subfolder list (`workspace-subfolder-item`, with the checkout's root as its root title) use it, beside `workspace-new-worktree-item`. The picker's menus and `statusline-branch` report the tab's saved workspace as `value`: `kind: worktree; folder: /path; branch: name`.
- **A `.contextMenu` mounts its items only while it is open, like a `Menu`.** Register an item with `plumeMenuItem` on the view the menu belongs to. A task row registers `task-archive-button` (only while the task has started) and `task-delete-button`, each labelled with the task's title.
- **A `confirmationDialog` is an AppKit sheet, where no `plumeID` registers.** Register its choices with `plumeMenuItem` on the presenting view while the dialog is pending. The worktree-removal dialog registers `worktree-removal-remove-button`, `worktree-removal-with-branch-button`, `worktree-removal-task-only-button` and `worktree-removal-cancel-button`, each labelled with the dialog's title and present only when the dialog offers it. `worktree-removal-message` carries the dialog's message as its `value`: each worktree, its uncommitted changes, any kept because another named task uses it, and any git no longer lists.
- **Moving a tab between tasks takes a drag the server cannot start**, so `tab.move` and `tab.split` call `TaskStore` directly. They prove the store's behavior, not the drop.
- **The sidebar is a `LazyVStack`, so a task row below the fold registers no controls.** `list plumeID=task-row` and `task-agent-group` simply leave it out, which reads like a missing row. A hidden instance takes no scroll gesture and no key, so run `sidebar.reveal task=<title>` first. It returns before the scroll lands, so if the first read comes back without the row, read again. Selecting a task scrolls to it as well, but only when the selection changes. It never expands a collapsed group, since that would change the user's own state.
- **`tab.status` goes through the real stores, so `UnreadStore` reacts as it would live.** An `awaitingReply` in a tab the user is not reading turns it unread with no `unread` flag at all, and any other status clears the mark. Pass `unread` to pin the mark the other way. It sends no system notification. A later real event from the tab's agent overwrites a driven status, so drive a tab whose agent is idle.
- **A task row names its folder lines `task-project-line`, `task-branch-line` and `task-pr-line`.** The label is the text the line shows. In a row with several agents, a line every agent shares sits above the headers and names no agent. A branch or PR line counts as shared only when every agent is in the same folder. A line that differs sits under each header, and its value starts with `agent: <header label>`, the label of the `task-agent-group` it sits under. The `same-directory` fixture shows the shared case, `multi-directory` the differing one and `mixed-directory` both. A branch line adds `worktree` and its PR's text, a PR line its directory.
- **`task-agent-group` is an agent's header in a row with several agents, labelled with the header label.** Its value is the agent's status, then `; focused` when the row is the selected task and the agent's tab is the focused one, then `; hovered` while its group is hovered, then `; pressed` while the left button is down on it. `pressed` comes from the mouse-down the window receives, so a `click` on a hovered group sets it for the click's hold and `invoke` never does. `invoke` selects the task and that tab, focusing its pane, as a click anywhere in the group does. `hover` on any line of a group hovers the group; a child's lines hover the child, not its parent. The hover widens the group's bar and brings its text to full strength. If Settings ▸ Debug ▸ Sidebar's `debug-agent-group-hover-wash-toggle` is on, the hover shows a wash behind the group instead.
