# Handoff: idle CPU and trackpad scroll lag in the release app

Branch `ryanm/idle-cpu`. Written 2026-09-14 for whoever picks this up next. The plan that started the work is at `~/.claude/plans/let-s-diagnose-why-plume-clever-goblet.md`; its H1 hypothesis is falsified below, so read this first.

## The symptom

The installed release app (`/Applications/Plume.app`) sits at 20–35% CPU while every agent is idle, with WindowServer at ~40%. Trackpad scrolling in the chat lags intermittently. The minimap and the jump-to-bottom button scroll smoothly.

## What we know

**One cause explains both symptoms.** A SwiftUI-internal redraw loop runs inside the window-root view graph at ~390 cycles per second, faster than the display link. Each cycle re-renders the RootDisplayList and redisplays a large RenderBox layer, and the main thread then blocks in `CA::Transaction::commit → RBLayer display → wait_for_allocations → CAContext waitForCommitId`. That stall eats 40–57% of main-thread samples and starves the chat list's wheel handling. When the loop is off, the user reports trackpad scrolling is "Smooth now".

**No Plume code runs per cycle.** The xctrace SwiftUI template shows the per-cycle work is all framework: `AnimatableFrameAttribute` ×12, `GeometryActionBinder<CGFloat>` ×1, `UpdateFilter<ElapsedSchedule,Text>` ×1, a `PlatformItemList` preference, "External: Bool" flips ~40/s, and `DynamicBody<Button>` ~16/s. No Plume closure appears in the per-cycle stacks. Symbolicating with the dSYM confirmed this.

**The loop is intermittent and toggles with interaction.** The passive monitor at `/tmp/plume-monitor.log` (shell clock is 3 h ahead of file mtimes) caught it flip HIGH → low → HIGH → low → HIGH → low within five minutes, then stay low for ten. The clearest observation: it stopped the moment the user moved the pointer off the window and clicked an answer in another app. CPU went from 34% to 0.1%. Resting the pointer on chat text, a sidebar row, the revealed minimap, or a code block did not restart it.

**Another agent finishing did not cause the stop.** The three other live `claude` children of the release app (sessions `727051c7`, `0ac4b977`, `3feb262f`) last wrote their transcripts at 19:48, 20:08, and 20:07. The loop stopped at 20:45. Nothing in those sessions changed at that time.

## Falsified

- **H1, `WorkingEllipsis`.** The `.symbolEffect(.variableColor…, .repeat(.continuous))` is render-server-only. A standalone reproducer showed zero SwiftUI graph updates. The loop also runs with no working rows and no working chat indicator. Do not replace the ellipsis.
- **Visible tab, sidebar visibility, terminals, live sessions.** The loop persisted with the sidebar hidden, with a terminal tab showing, with only the current conversation visible, and with agents idle.
- **The `AnimatedHeight` sidebar row modifier** (`TaskRowView.swift:151`). It was the leading candidate after H1 fell. A Debug build seeded with a copy of the real store, window frame, split frames, and the same open task never reproduced the loop under any of those conditions, so removing it was put on hold. Nothing in the evidence implicates it now.
- **Responsive-scrolling being disabled.** Wheel routing in `ChatListController` is an `NSEvent.addLocalMonitorForEvents(matching: .scrollWheel)` monitor, not a `scrollWheel(with:)` override, so AppKit's off-main-thread scrolling is intact. The lag came from the stalled main thread, not from the routing.

## Still open: what starts the loop

Candidates, with confidence:

1. **A stuck hover, tooltip, or transition state in a window-root view, cleared by pointer exit or a click** (medium). Fits the ~390 Hz runloop pacing, the `DynamicBody<Button>` and `External: Bool` churn, and the fact that leaving the window stopped it. Suspects: `ChatMinimap` `onContinuousHover`, the hover-revealed copy buttons in `ChatPieceView` and `MarkdownBlockView`, `MainWindow` `onGeometryChange` for `windowWidth`, and the `.frame(minWidth: WindowMetrics.minimumWidth(sidebarVisible:))` on the window root.
2. **A `TimelineView` schedule whose entries stop advancing** (low). `UpdateFilter<ElapsedSchedule,Text>` updates once per cycle, which is far faster than `ElapsedSchedule` should tick. Check whether `ElapsedTime.tickInterval` can return 0 or a negative interval for a `since` in the future, which would make `entries(from:mode:)` yield the same date forever.
3. **A dynamic `NSColor` on the window background** (low). `AppDelegate.tintTitlebar` sets `window.backgroundColor` from `ThemeChrome.titlebarBackground()`. Sampled at ~40 ticks per 10 s, which reads as noise, but it is the only window-level dynamic value found.

## How to catch it next time

1. Find the release PID by walking down from the app binary, not `pgrep -x`: `pgrep -f '^/Applications/Plume.app/Contents/MacOS/Plume'`. The PIDs in this doc (14026 release, 14241 the diagnosing agent) are stale.
2. Run `/tmp/monitor.sh` (edit the PID) in the background. It logs CPU and the render-server stall share every 20 s.
3. When it goes HIGH, attach immediately with `xcrun xctrace record --template SwiftUI --attach <pid> --time-limit 6s` and note what the pointer was over and what the user last did. `/tmp/probe.sh <pid> <label>` does the sample plus the update-group histogram in one shot. Use `--attach`, not `--launch`; several Plume processes make `--launch` ambiguous.
4. Compare the `swiftui-updates` and `swiftui-full-causes` tables with the loop off. The discriminating question is which attribute's invalidation starts each cycle.
5. Debug probes show zero updates while the window is occluded. Bring the window front with `open "$APP"` before sampling a Debug build.

Existing captures live in `/tmp`: `plume-swiftui.trace` and its `swiftui-*.xml` exports, `rel-timeprofile.xml`, and `plume-live-*.txt` samples for idle, working, no-sidebar, terminal, and four pointer positions.

## Changes on this branch

Built, `PlumeTests` passing for the touched suites (`ClaudeCodeSettingsResolverTests`, `GitStateDebounceTests`, `TaskRowDetailsTests`, `CheckoutFactsStoreTests`).

- **F2, git sweep.** `GitStateStore.pollInterval` 15 s → 60 s; `GitRunner` sets `GIT_OPTIONAL_LOCKS=0` so `git status` never rewrites the index and re-fires the `.git` watcher it was answering. Secondary cost, not the loop.
- **F3, settings reads off the render path.** `ClaudeCodeSettingsResolver` caches parsed settings keyed by file modification date and size behind an `NSLock`. `ComposerControlsRow` resolves settings once per body instead of four times. Secondary cost, not the loop.

Not done: F1 (falsified), F4 (scroll measurement budget; not needed while the loop is off), the `AnimatedHeight` removal (on hold), and responsive-scrolling changes (not needed).

## Debug data left on disk

The Debug app's data at `~/Library/Application Support/Plume.debug/` is a copy of the release store (27 tasks) with task `Z_PK 1` unarchived and retitled "Probe task". The previous Debug data was moved to `~/Library/Application Support/Plume.debug.bak-20260913-201602`. Debug `defaults` (`com.ryanmoelter.Plume.debug`) carry the release window frame, split frames, and `lastOpenTaskID`. Restore the `.bak` directory when the copy is no longer useful.
