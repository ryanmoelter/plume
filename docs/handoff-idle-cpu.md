# Idle CPU and trackpad scroll lag: what it was

Branch `ryanm/idle-cpu`. Investigation closed 2026-09-14. An earlier version of this file left the cause open; this one records the answer and the evidence, so the next performance question can start from what was measured rather than what was assumed.

## The symptom

The installed release app sat at 20–35% CPU with WindowServer at ~40%, and trackpad scrolling in the chat lagged. Ryan narrowed it to **while any agent is working, in any task**, ending when the turn ends. That gate was the discriminator the first pass lacked.

## The cause

`WorkingEllipsis` drew an SF Symbol with `.symbolEffect(.variableColor…, options: .repeat(.continuous))`. That is not a render-server animation. RenderBox re-rasterizes the glyph in-process on every frame (`RB::Symbol::Animation::apply` → `renderVectorGlyph`), then the main thread blocks in `CA::Transaction::commit → RBLayer display → waitForCommitId`. One instance costs about a tenth of a core in a bare window; the app shows one per working task in the sidebar plus one in the open chat, and each frame's commit stall is what starved wheel-event handling.

A second, smaller cost sat next to it: `ChatWorkingIndicator` wrapped its per-second caption in `.animation(.default, value: context.date)` with `.contentTransition(.numericText())`. The `.animation` alone measured ~7% of a core, because a `Text` interpolation was in flight for a third of every second.

## The evidence

- **Live trace of the release app** (`xctrace --template SwiftUI --attach`, 5 s, while an agent in this app was working): ~450 update transactions per second, each carrying one `ValueTransactionSeed<Date>`, five `InterpolatedDisplayList<ResolvedStyledText>` updates, 14 `AnimatableFrameAttribute` updates, and one layout invalidation of the chat list's `NSViewRepresentable`. No Plume closure per cycle.
- **`sample` of the release app**: 40–57% of main-thread samples inside the commit stall, with `_ShapeStyle_RenderedShape.renderVectorGlyph` and `RBSymbolAnimator` on the main thread.
- **Standalone reproducer, bisected by env var** (a bare `NSWindow` pinned to every Space so it was actually visible):

  | Contents | CPU |
  | --- | --- |
  | Symbol-effect ellipsis only, 1 instance | 8.6% |
  | Symbol-effect ellipsis only, 4 instances | 13.4% |
  | Caption with `.animation(value: date)` only | 7.4% |
  | Caption with `.contentTransition(.numericText())` only | 0.3% |
  | Caption `TimelineView` with neither, inside an `NSHostingView` | 0.2% |
  | New `WorkingEllipsis` (masked glyph, stepped fade), 4 instances | 1.1% steady state, against 5.4% for the symbol effect measured the same way |

  The ellipsis-only reproducer's `sample` had the same stack as the release app, which is what ties the two together.

## What was wrong in the first pass

- The earlier H1 test looked at SwiftUI **graph updates** for the ellipsis and saw none, then concluded it was free. The cost is in RenderBox and the CA commit, below the graph. The "loop also runs with no working rows" observation was made with other tabs still working (their sidebar badges carry the same ellipsis).
- `ElapsedSchedule` returning `startDate` as its first entry was suspected (H2). A reproducer showed `TimelineView` handles that correctly: one body evaluation per second, no spin. The schedule is unchanged.
- Debug-build reproductions never fired because the Debug window was on a different Space than the active one, where SwiftUI throttles updates. Check `CGWindowListCopyWindowInfo`'s `kCGWindowIsOnscreen` before trusting a negative from a Debug run, or pin the window with `.canJoinAllSpaces` as the reproducer did.

## The fix

- `Plume/UI/WorkingEllipsis.swift`: the same SF Symbol in two layers, a dimmed ellipsis under three masked full-colour copies, one per dot, each faded in for its 0.5 s turn followed by an empty frame, stepped by `TimelineView(.periodic(from: <fixed epoch>, by: 0.5))` so all instances stay in step. `litDot(at:)` is the pure phase function, covered by `WorkingEllipsisTests`.
- `Plume/UI/Chat/ChatWorkingIndicator.swift`: the caption ticks without an animation or content transition.

## Still on this branch from the first pass

- **F2, git sweep.** `GitStateStore.pollInterval` 15 s → 60 s; `GitRunner` sets `GIT_OPTIONAL_LOCKS=0`.
- **F3, settings reads off the render path.** `ClaudeCodeSettingsResolver` caches parsed settings by mtime and size; `ComposerControlsRow` resolves them once per body.

Both are secondary costs, kept.

## Follow-ups, not done here

Per-event main-thread work that runs while any agent works. None of it can produce the frame-rate loop above, but each is a real cost:

- `FileWatcher` delivers on `.main` for every write on every watched file; `AgentTitleMonitor` then does a whole-file read and reverse scan synchronously on main per debounce.
- `StatusEngine`'s dictionaries and `TranscriptStore.subagentTranscripts` are whole-property observables, so one tab's change invalidates every `TaskRowView` and `TaskActivityRow`, and `KeepAwakeCoordinator.refresh()` re-applies its IOKit assertion on every status transition anywhere.
- `HeadlessSession.handle` hops one main-actor `Task` per stream-json line, including per-token deltas.
- The `AnimatedHeight` removal that was on hold: nothing implicates it. Leave it.

## Verifying the installed build

Install per `docs/releasing.md`, start an agent turn, and while it is working:

```
PID=$(pgrep -f '^/Applications/Plume.app/Contents/MacOS/Plume')
top -l 3 -s 3 -pid $PID -stats pid,cpu | tail -1
sample $PID 4 -mayDie -file /dev/stdout | grep -c waitForCommitId
```

Expect single-digit CPU with a working badge on screen and the commit stall absent from the main-thread call graph. Trackpad scrolling in the chat should be smooth while agents work.
