# The chat list hang

`ChatMessageList` renders messages in a `LazyVStack` and lets the scroll view's own anchors follow the newest content. An earlier lazy version drove the scroll itself and froze the app. This records what happened, what was measured, why the current shape is what it is, and how to investigate if it comes back.

## History

- **Sep 1 2026** (`28a40f2`): the list moved from `VStack` to `LazyVStack` so a long transcript builds only the rows on screen.
- **Sep 2** (`88941bf`): reverted to `VStack` after scrolling a long transcript pinned a core. The commit blamed a height oscillation between the stack's estimates and its realized rows. That was a reading of the symptom; nothing was sampled.
- **Sep 4**: `LazyVStack` came back on top of the row-identity and markdown-cache work that had landed in between. A scroll harness could not make it hang, and neither could scrolling by hand. It shipped as 0.2.2 build 5 and froze that evening on *opening* a live chat, a few tasks into switching between them, coming to rest part way down the transcript rather than at the bottom. macOS wrote a hang report (spindump) on the force-quit, and the harness then reproduced the same hang once it imitated the live chat.

## What the hang is

Both the spindump and the harness sample agree, and no Plume code appears in the loop.

The main thread sits entirely inside SwiftUI's lazy-stack placement pass: `LazySubviewPlacements.placeSubviews` → `LazyStack.place` → walking the whole `ForEach` view list, each row through the `ModifiedViewList` chain of its modifiers, ending in `ViewTraitCollection.setTagIfUnset`, which is the per-row `.id()` tag. Each pass ends in `LazyLayoutViewCache.signalPrefetch` → `NSHostingView.requestUpdate`, which schedules the next pass. An animation is in flight throughout (`AnimatableFrameAttribute`, `KickModifier`), and `ViewTransform.nearestScrollGeometry` is consulted inside placement.

Put together: a programmatic, animated `scrollTo` targets an anchor inside a lazy stack whose rows are still estimates. Every placement pass moves the anchor, the animation retargets, the prefetch asks for another pass, and the content keeps growing under it because a stream is appending text. There is no fixed point, and the window freezes wherever the animation happened to be, which is the "part way down" Ryan saw.

The conditions that made it reachable:

- A `ScrollViewReader` with `.id()` on every row and a bottom anchor, and `proxy.scrollTo(bottomAnchorID, anchor: .bottom)` inside `withAnimation` on every `streaming` change (many times per second while a reply streams) and on every new message.
- A hidden tab. Every tab stays mounted, so a background chat's list has a zero-height viewport, estimates only, and a queue of follow scrolls. Switching to it is what asks the stack to realize rows, place them, and honour the animation all at once. Ryan triggered it by clicking between tasks and landing on the live one; it took several switches.
- A long transcript (about a thousand rows), so each placement pass is expensive enough that the loop never catches up.

Removing the animation alone stopped the hang but the list then lost the stream: an un-animated `scrollTo` lands on an estimated offset and stays there while the content grows.

## What the list does now

- `LazyVStack` with `.scrollTargetLayout()`, no `ScrollViewReader`, no per-row `.id()`, no bottom anchor, no `scrollTo` of its own.
- `.defaultScrollAnchor(.bottom)` opens at the bottom, and `.defaultScrollAnchor(.bottom, for: .sizeChanges)` keeps a list that is already at the bottom there as content grows. Following the stream is the scroll view's job.
- `.scrollPosition($position)` with a SwiftUI `ScrollPosition` serves the jump-to-bottom button (`position.scrollTo(edge: .bottom)`) and the DEBUG scroll exerciser.
- `ChatScrollAnchor` still decides `isDetached` from the scroll geometry so the button appears once the user has scrolled away. Its `shouldAutoScroll` is no longer consulted by the list.

Under the harness this ran six minutes of task cycling, fake streaming and live appends without a hang, where the previous shape hung inside five. Ryan then could not reproduce the hang by hand against either build in the same session, so the fix is proven against the harness, not against the original trigger.

## The harness

All DEBUG-only, in `SmokeHarness` and `ScrollExercise`. The optimized variant is what reproduced the hang; Debug builds ran hot but never locked.

```
# Optimized build with the harness compiled in, using the Plume.debug store
xcodebuild -scheme Plume -configuration Release -destination 'platform=macOS' build \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) DEBUG' \
  PRODUCT_BUNDLE_IDENTIFIER=com.ryanmoelter.Plume.debug \
  CONFIGURATION_BUILD_DIR=/tmp/plume-harness
```

- `PLUME_SEED_TRANSCRIPT_PATH=a.jsonl,b.jsonl` gives each seeded task its own transcript, rendered from disk with no `claude` process. Tasks are titled after the file.
- `PLUME_FAKE_STREAM=<seconds>` appends markdown chunks to the first task's live text on that interval, restarting the message every 400 chunks, so the streaming overlay and its follow behaviour run without a process.
- `PLUME_CYCLE_SELECTION=<seconds>` switches tasks, which is what makes hidden lists visible.
- `PLUME_SCROLL_EXERCISE=<seconds>` jumps between messages; `PLUME_SCROLL_WHEEL=<points>` moves the backing `NSScrollView` per frame like a trackpad.
- To imitate a live session's transcript, copy a long one, truncate it, and append the rest a line at a time while the app watches it.
- `scripts/detect-chat-hang.sh [seconds] [pid]` watches the **main thread's** CPU (the transcript parser legitimately runs hot on a background thread) and prints `HANG` with the hottest sampled frames once it stays above 90% for five seconds. Run it in the background and click around; it exits 1 on a hang.
- `scripts/capture-chat-hang.sh [--launch <Plume.app>] [--watch <seconds>] [outdir]` wraps `detect-chat-hang.sh` with a full capture: a config snapshot, a live log stream, and, on a hang, two main-thread samples ten seconds apart. See "Diagnosing the next reproduction" below.

Long transcripts to feed it live under `~/.claude/projects/`; the Notability one from Sep 4 is 13 MB and about a thousand rows.

## Sep 6: it came back, while scrolling up

Diagnosed below, and fixed by the split in **What landed**. Ryan hit it on a plain Debug build of `ryanm/release-0.3.5` while scrolling up through an idle thread — nothing streaming. Two `sample`s nine minutes apart (the first at `~/plume-hang-live-2026-09-06.txt`) have the same shape, and the process was still at 100% with 54 minutes of CPU an hour later, so it is a loop, not expensive layout that would finish.

What each pass does, by share of main-thread samples:

- 19% `LazySubviewPlacements.placeSubviews` — the placement pass.
- 19% `RootGeometry.value.getter` → `NavigationStackLayout` → the scroll view's content → `LazyStack.measureEstimates`, walking the whole `ForEach`. The window re-measures from the root every pass.
- 12% `LazyLayoutViewCache.updateItemPhases` → `propagate_dirty`. `value_set` only propagates when a value changes, so items are changing phase every pass: the visible set is oscillating.
- 5–7% `DynamicBody.updateValue` with `Binding.Box` / `LocationBox` updates — a body re-running off a binding write. The Plume frames present are copies of `ChatMessageRow`, `ChatMessage` and `ListItemPadding`, consistent with the list's body re-running but not proof of it — the full parse below found no `ChatMessageList.body` frame at all.
- 2% `ScrollStateRequestTransform.findClosestSubview` — the `scrollPosition` binding being resolved against the visible subviews.
- Present in small counts every pass: `ScrollViewAdjustedState.alignIfNeeded` / `adjustOffsetIfNeeded` with `ScrollAnchorStorage.anchor(role:)` (the `.sizeChanges` anchor), `LazySubviewPlacements.makeAnchorTranslationIfNeeded`, and `signalPrefetch` → `asyncTransaction` → `requestUpdate` scheduling the next pass.
- Near-absent: animation attributes (19 of 6653), `onGeometryChange`, `Markdown`. Nothing animated is driving it.

A full parse of the raw sample (`~/plume-hang-live-2026-09-06.txt`, 6653 main-thread samples) sharpened this:

- No `ChatMessageList.body`, `AnimatedHeight`, `onGeometryChange`, or `ScrollPositionBox` frame appears anywhere in the sample. Plume code is 0.7% of samples total, and every bit of it is a compiler value-witness copy of `ChatMessageRow`, `ListItemPadding`, `ThinkingRow`, `ToolCallRow` or `Theme`, under `DynamicBody.updateValue → _DynamicPropertyBuffer.update → EnvironmentBox/LocationBox/Binding.Box update`. That is rows having their dynamic properties updated — consistent with the list body re-running or rows being recreated, but it proves neither.
- 18.9%: `RootGeometry.value.getter` sizes the whole window tree from the root every pass, through `NavigationStackLayout` and the hidden terminal tabs (`PlatformViewLayoutEngine` / `TerminalViewRepresentable`) down to `LazyStack.measureEstimates`.
- 11.6%: a separate transaction, `LazyLayoutCacheItem.AllItemsPhaseMutation → LazyLayoutViewCache.updateItemPhases → AG::Graph::propagate_dirty`, 95% of it inside `propagate_dirty` walking ancestors. That fan-out is what dirties the root and turns every pass into a full-window layout.
- Present every pass but small: `ScrollStateRequestTransform.findClosestSubview` 2.3% (the `scrollPosition` binding), `LazySubviewPlacements.makeAnchorTranslationIfNeeded` 0.8%, `ScrollViewAdjustedState.adjustOffsetIfNeeded → alignIfNeeded → ScrollAnchorStorage.anchor(role:)` 0.3%.

The very deep alternating `_PaddingLayout` / `_FlexFrameLayout` / `_FrameLayout` recursion is the row's real modifier stack measured once, not a cycle: `padding(.top, inset)` → `ListItemPadding` (two flex frames, two paddings, a flex frame) → `_FrameLayout` (`AnimatedHeight`'s `frame(height:)`) → `_FixedSizeLayout` → the assistant body's paddings → its `VStack` → each block's padding → `ListItemPadding` again → the block's own stacks. `animateRowHeight` was on.

Hypotheses, ranked:

1. A SwiftUI-internal cycle with no Plume state write. Placement realizes and evicts rows at the lazy window's boundary; a realized row's height differs from its estimate (or its measurement is invalidated), so the content height changes; the bottom `.sizeChanges` anchor, or the lazy stack's own anchor translation, shifts the offset by the delta to hold the bottom distance; the shifted viewport changes the visible set; repeat. This fits an idle thread, only some transcripts, scrolling up specifically (a height change below the viewport is where a bottom anchor moves the visible content), and the harness never hitting the boundary. The open question: a finite transcript with stable measurements would settle, so this needs evidence that measurements are lost or alternate, or that two offset corrections keep disagreeing.
2. The scroll-position hypothesis this doc used to lead with: `.scrollPosition($position)` with `.scrollTargetLayout()` writes `position` on a user scroll, re-running the list body, re-estimating, and re-anchoring. Less supported now — no body frames were sampled, and a `Binding<ScrollPosition>` is not documented to report the nearest row continuously during a user scroll — but it is cheap to test.
3. `AnimatedHeight`'s nil→measured first pass on a re-realized row, or a width change re-wrapping text.
4. The `isDetached` writes: one threshold, no hysteresis.

Reproduction so far: none. `PLUME_SCROLL_EVENTS=<points>` sends legacy scroll-wheel events through the scroll view's own `scrollWheel(with:)`, which is what updates the binding; `PLUME_SCROLL_SWIPES=<points>` shapes them as swipe, momentum tail, pause. A synthetic event carrying gesture phases is dropped by the scroll view outright. One run scrolled the 3.1 MB transcript end to end with the content height changing all the way and peaked at 39%; later runs of the same code did not move the list at all, which is still unexplained. Next: reproduce by hand with `PLUME_CHAT_DIAG` and `scripts/capture-chat-hang.sh` running, per the next section, rather than forcing it through the synthetic-scroll harness.

Run the harness against a private store: `PLUME_APP_SUPPORT_DIR=<dir>` (DEBUG only), and build it with its own bundle ID so its defaults are separate too. `SmokeHarness` used to repoint whatever tasks the store already had at the seeded transcript, which against a store in daily use retitled all sixteen tasks and rewired every agent tab (six of them had transcript paths); it now creates its own. The window also has to be on screen and unoccluded: a SwiftUI hosting view stops updating behind a locked screen, so a synthetic scroll then moves nothing and the run reads as idle at 1% CPU.

### Diagnosing the next reproduction

The probes, bisect switches and capture script in this section live on the `ryanm/chat-hang-diagnosis` branch, not on the release line. Check that branch out to use them.

- `PLUME_CHAT_DIAG` (env, or `defaults write com.ryanmoelter.Plume.debug PLUME_CHAT_DIAG -bool YES`) turns on `ChatHangDiagnostics`. Every probe carries a sequence number and logs at `.info`, which `log stream` picks up live; a background timer that keeps running even while the main thread is pinned also emits a `.notice` aggregate once a second, so a force-quit still leaves counts on disk. The probes: `ChatMessageList.body` logs `_logChanges()`'s output plus a run counter; every write to the `scrollPosition` binding logs `isPositionedByUser`, the view ID, the edge, the point, and whether the new value equals the old one; scroll geometry logs a signed offset and the viewport width alongside content height; scroll-phase transitions are logged as they happen; `isDetached` logs both when a change is scheduled and when it is applied; each row logs its message ID on appear and disappear; `AnimatedHeight` logs its first measurement and every later change, tagged with a token identifying the row's `@State` lifetime. The body probe never reads `position` — doing that inside `body` would create the dependency the probe exists to catch. Row appear/disappear is supporting evidence for lifecycle churn, not proof that the lazy stack evicted anything.
- The bisect switches (`ChatListBisect`) are all runtime, DEBUG-only, and read the same env-or-defaults pair. `PLUME_CHAT_NO_SIZE_ANCHOR` now genuinely drops the `.sizeChanges` anchor — the first version only overrode `.initialOffset` on top of the broad `.defaultScrollAnchor(.bottom)`, which already supplies every role including `.sizeChanges`, so it changed nothing. `PLUME_CHAT_NO_TARGET_LAYOUT` drops `.scrollTargetLayout()`. `PLUME_CHAT_NO_POSITION` drops `.scrollPosition(...)` entirely. `PLUME_CHAT_PLAIN_FIXED_SIZE` gives rows a bare `.fixedSize(horizontal: false, vertical: true)` instead of `.animatedHeight(...)`. The Settings toggle `animateChatMotion` off remains the "all of it removed" variant. `PLUME_CHAT_PLACEHOLDER_HEIGHTS=<file>` replaces every row's content with `Color.clear` at the height recorded for that message ID (`<id> <height>` per line, where `<height>` may be a comma-separated list to render one placeholder piece per paragraph; rows not in the file get 40), keeping the row's outer modifiers, so the list can be scrolled with the real height sequence and none of the real content. `~/plume-hang-captures/row-heights.txt` holds the 491 heights the first capture measured, all at the 800 pt content width.
- `scripts/capture-chat-hang.sh [--launch <Plume.app>] [--watch <seconds>] [outdir]` records a reproduction attempt: `config.txt` (git rev and branch, the active `PLUME_CHAT_*` environment and defaults), a live `log.txt` of the `chat-hang` category plus SwiftUI's "Changed Body Properties" category, and `detector.txt` from `detect-chat-hang.sh`. On a hang it also saves `sample-1.txt` and `sample-2.txt` ten seconds apart — proving the spin is sustained, not a finishing burst — plus a `log-show.txt` dump of the aggregates, then leaves the app running for a force-quit. Exit codes: 0 OK, 1 HANG (see `outdir`), 2 no Plume process found, 3 the process exited during the watch, otherwise the detector's own exit code.
- Read a capture by the **sustained** spin, not the onset:

  | Observation during the sustained spin | Reading |
  |---|---|
  | Body count climbing and `_logChanges` names `_position` | hypothesis 2's engine is live |
  | Position setter quiet and body count flat while the sample still shows phase churn | hypothesis 2 is not the engine |
  | The same row IDs alternating appear/disappear, or repeated first measurements for one ID under new tokens | lifecycle or state recreation at the boundary |
  | Content height alternating between two values with the offset moving by the same delta each time | bottom-distance preservation is applying the correction |
  | `height change` lines with a changed width | re-wrapping |
  | Every probe quiet while the sample loops | the cycle is below the callback boundary — go straight to the switches |

- Trial order: an instrumented baseline first, no bisect switch. Then one switch per attempt, default order `NO_SIZE_ANCHOR`, `NO_POSITION`, `NO_TARGET_LAYOUT`, `PLAIN_FIXED_SIZE`, `animateChatMotion` off. A hang that persists with a switch on falsifies that participant's necessity. A single non-reproduction does not prove causation, so a switch that seems to fix it gets a second attempt on the same thread.

Trials, all on Sep 6 against a copy of the release store (`~/plume-hang-store`, taken with `sqlite3 .backup` so the running release app was never touched), on the transcript `552fca5e-ef53-4d86-bb44-93538851af98.jsonl` under the plume project, with a 1322×1017 viewport:

- **Trial 0, instrumented baseline** (`~/plume-hang-captures/20260906-112823`): hung after 105 s of scrolling. In the last 400 ms before the probes went silent, the content height alternated on every geometry callback between two families about 1,136 pt apart (22,379 ↔ 23,502, both drifting up ~8 pt per cycle) while the offset stayed at exactly 19,090.5. Scroll phase `decelerating`. The list body had not run for 3.4 s (its earlier re-runs were all `_isDetached`), the position binding never wrote during the oscillation (all 56 writes in the run were `isPositionedByUser=true, viewID=nil`, about two per gesture), the same 117 rows were torn down and rebuilt three times in five seconds in batches of about six per millisecond, and every rebuilt row measured the same height as before (zero `height change` lines). Then every probe went quiet while the thread stayed at 100%. Both raw samples, ten seconds apart, have this morning's shape: placement 29%, row dynamic-property updates 24%, root re-measure 14–16%, phase mutation 7%, prefetch scheduling present, anchor and position machinery 2–3%, animation 0.3%. A 22-level `_HStackLayout` / `_FlexFrameLayout` `explicitAlignment` recursion is 8–10% of each pass and is cost, not the loop. Reading: hypothesis 2 falsified as the engine; hypothesis 1's mechanism (realized set flipping around a fixed offset) supported.
- **Trial 1, `PLUME_CHAT_PLAIN_FIXED_SIZE`** (`20260906-113547`): hung in 20 s with the same signature and no height events at all. `AnimatedHeight` is not necessary.
- **Trial 2, `PLUME_CHAT_PLACEHOLDER_HEIGHTS`** (`20260906-121821`): every row an empty rectangle at its recorded height, and it hung in 9 s. Content 23,895 ↔ 24,509, offset frozen at 21,234, phase `decelerating`. The sample has the same machinery with zero row body work. Row content is not necessary; the container is the bug.
- Where it freezes: content offset about 19,100–21,200 of a 23,000–24,500 pt list, which is the assistant turn `b6eaf7fd` (the one headed "State: Codex in Plume", recorded at 2,140.8 pt, the tallest row in the transcript) followed by the compaction boundary and eight rows of 23–39 pt (`201f01a2`, `ac3eeb8f`, `28d70c8d`, `ba649cab`, `8cc5ab48`, `f2273afc`, `7a96c824`, `18d57972`), which are the rows that churn. A row fifty times taller than its neighbours sits at the realization boundary.
- Every freeze happened in the `decelerating` phase, and the synthetic harness never reaches that phase: its events only ever produce `interacting → idle`. Four harness runs against the placeholder configuration (`PLUME_SCROLL_SWIPES=60`, `PLUME_SCROLL_EVENTS=40`, `PLUME_SCROLL_SWIPES=25`, `PLUME_SCROLL_WHEEL=30`) swept the offset through the freezing region repeatedly and peaked at 10% CPU. Momentum scrolling is a necessary ingredient, and a trackpad is the only known way to supply it.
- **Trial 3, `PLUME_CHAT_NO_SIZE_ANCHOR`** (`~/plume-hang-captures/20260906-171931`), placeholder heights: hung within 2 s of launch. The flags line confirmed `noSizeAnchor=true`. Content height alternated 24,105 ↔ 24,662 pt with the offset frozen at 21,089.5, viewport 1322×1016, last phase `decelerating`. The sample still shows `ScrollViewAdjustedState.adjustOffsetIfNeeded → alignIfNeeded` (18 / 3 frames) with the public size-change anchor gone, so the offset alignment is the scroll view's own, not the modifier's. `.sizeChanges` is not necessary.
- **Trial 4, `PLUME_CHAT_NO_TARGET_LAYOUT`** (`20260906-172244`), placeholder heights: hung after about 30 s of back-and-forth scrolling. Content height alternated 52,636 ↔ 53,205 pt with the offset frozen at 49,550.5. 61 row IDs in this capture were absent from the recorded heights file and fell back to the 40 pt default, so this run scrolled rows the other two trials did not, but the signature is unchanged. `.scrollTargetLayout()` is not necessary.
- **Trial 5, `PLUME_CHAT_NO_POSITION`** (`20260906-172423`), placeholder heights: hung within 2 s. Content height alternated 23,999 ↔ 24,578 pt with the offset frozen at 21,284.5. `ScrollStateRequestTransform.findClosestSubview`, present in every other capture, is absent from these samples, confirming the switch removed the binding's path — the loop did not need it. `.scrollPosition` is not necessary.
- None of the three modifiers is a necessary participant. The loop is inside `LazyVStack` itself.
- The recorded heights file spans five threads, every row that appeared during the recording session, so its 46,620 pt total is not one thread's height. Trial D's eager `VStack` reports the hang thread's true height as 22,548 pt. Against that, the lazy estimate at lock-in was 24,000–24,700 pt in Trials 3 and 5 (7–9% high) and 53,100–53,700 pt in Trial 4 and Trial A (2.4× the truth), so `contentSize.height` is the lazy stack's estimate and can drift far from the truth. The same cluster of rows churns in all of them: `680636e3` (420 pt), `18d57972`, `1327b1d6`, `7a96c824` (31 pt each), `f2273afc` (39 pt), `8cc5ab48` (23 pt), and the tallest row, `b6eaf7fd` (2,140.8 pt), appears and disappears with them at the lock-in point. The upper content value creeps about 1 pt per pass.
- Every hang so far had a 1322 pt tall viewport on the 27" external display. On the 14" MacBook display, viewport under about 900 pt, the same build, store and thread scroll through the same region without hanging. This is the current lead, but it is not yet tested as necessary.
- Trials A, C, C′, B and D followed, all on the 27" display with a 1322 × 1016 viewport, placeholder rows throughout, real trackpad momentum gestures, and the same thread.
- **Trial A, original heights** (`~/plume-hang-captures/20260906-191956`): hung on the first gesture. Content 53,118 ↔ 53,698 pt, offset frozen at 50,088. The planned window-height sweep never ran; the viewport stayed at 1322 pt for the whole gesture.
- **Trial C, tallest row capped** (`b6eaf7fd` capped from 2,140.8 to 200 pt, everything else unchanged; `row-heights-captall.txt`, capture `20260906-192106`): hung after about 21 gestures. Content 25,178 ↔ 25,565 pt, offset frozen at 22,444.5. The eight small rows were realized 7–9 times each at their original 23–39 pt heights. The tall row is not necessary.
- **Trial C′, cap plus redistribution** (the same cap, with the removed 1,941 pt spread over the eight small rows in the cluster — `201f01a2`, `ac3eeb8f`, `28d70c8d`, `ba649cab`, `8cc5ab48`, `f2273afc`, `7a96c824`, `18d57972`, now 265–281 pt each, block total unchanged; `row-heights-redistributed.txt`, capture `20260906-192216`): no hang across 56 momentum gestures over 85 s, 11 of which decelerated through the offset band where the other runs lock up.
- **Trial B, uniform heights** (every row 95 pt; `row-heights-uniform.txt`, capture `20260906-192343`): no hang across 61 gestures, 15 through the band.
- **Trial D, `PLUME_CHAT_EAGER_STACK`** (original heights, plain `VStack` in place of `LazyVStack`; capture `20260906-192754`): no hang across 55 gestures, 14 through the band. Content height held steady at 22,548.5 pt for this thread.
- **Trial E1, small rows floored at 100** (every row under 100 pt raised to 100 pt, tall rows untouched; `row-heights-floor100.txt`, captures `20260906-201755` and `20260906-202147`): no hang across 73 and 17 momentum gestures, 521 and 223 geometry samples inside the band where the original locks up. The floor removes every tiny row and cuts the contrast against the 2,140 pt row from about 90× to about 20×.
- **Trial E2, tall rows capped at 300** (every row capped at 300 pt, the 405 rows under 100 pt untouched; `row-heights-cap300.txt`, captures `20260906-201858` and `20260906-202205`): no hang across 57 and 14 gestures. The tiny rows stay in place, and the contrast tops out at about 13×.
- **Trial E3, uniform 25 pt rows** (every row 25 pt; `row-heights-all25.txt`, captures `20260906-202017` and `20260906-202222`): no hang across 25 and 9 gestures. A wall of tiny rows on its own is harmless.
- **Trial E4, split into blocks** (every message split into paragraph-sized pieces of 24 to 180 pt using the multi-piece placeholder format, 848 rows in place of 491, 306 of them under 30 pt, tallest 180 pt; `row-heights-split.txt`, capture `20260906-202250`): no hang across 57 gestures, 868 samples in the band. This simulates one lazy row per markdown block instead of one per message.
- Trials E1 through E4 isolate the cause: neither very short rows nor very tall rows trigger the loop on their own. The trigger needs both within the same realized or prefetch region, the 23–39 pt cluster alongside rows of 1,300–2,140 pt; the trials cannot tell whether the contrast has to sit between immediate neighbors or only somewhere within that region. Raising the small side to 100 pt (E1), lowering the tall side to 300 pt (E2), or spreading the tall row over its small neighbors (C′) each remove it. Capping only the tallest row (C) still leaves a 1,298 pt neighbor next to the cluster and still hangs. About 50× height contrast reproduced it, and about 20× and below never did, but that is where reproduction happened, not an established threshold.

### The mechanism

`LazyVStack` estimates unrealized rows from the ones it has realized. After momentum scrolling stops near a realized or prefetch region holding items whose heights differ by a large factor (observed from about 50×; the trials cannot tell whether the contrast has to sit between immediate neighbors or only somewhere within that region), with a tall viewport (1322 pt; a viewport under about 900 pt has never reproduced it), the realized set at the prefetch edge flips between two states. The tiny rows and the tall rows are each necessary, and neither is sufficient on its own. Each flip changes the estimate and so the reported content height. The scroll view's own offset alignment (`ScrollViewAdjustedState.alignIfNeeded`, running with or without the public size anchor) and the stack's anchor translation (`makeAnchorTranslationIfNeeded`) re-map the frozen offset onto a different row range, and prefetch schedules the next pass. No Plume state is written, and none of `.scrollPosition`, `.scrollTargetLayout()`, or `.defaultScrollAnchor(for: .sizeChanges)` takes part.

The second-opinion review rates local height contrast as sufficient to trigger the loop and removing that contrast as sufficient to avoid it, without proving the estimator safe for every height distribution.

### What landed

The chat list places **one lazy item per block**, not per message. `ChatPieceSplitter` turns the transcript into `ChatPiece`s — one markdown block, one thinking row, one tool call, one notice, the streaming overlay, the working indicator — and `ChatPieceView` draws each one. A message's wash is drawn per piece, with only the corners and edges that piece owns, so several pieces still read as one bubble.

- **The ceiling is 300 pt**, the value Trial E2 tested. A list over it splits into segments; a code block over it stays one piece and scrolls inside itself, bounded at the same 300 pt by `CodeSegmentView` — splitting a code block would cost the reader a continuous scroll through it. A table, a paragraph, a heading, a quote and a mermaid fence are neither split nor bounded. Both decisions come from a crude estimate in `ChatPieceMetrics` — nothing measures text, and no measured height ever reaches the splitter, which is the feedback loop this document exists to remove.
- **The streaming overlay splits too.** Everything above the block still arriving is settled markdown; only the tail block stays live and revealing. Parsing is not prefix-stable, so a settled piece can be reinterpreted mid-stream; the remount is accepted.
- **The model is built in `onChange`, never in `body`.** `ChatPieceCache` memoizes `MarkdownBlock.parse` by source across rebuilds, pruned to what the current messages hold.
- Piece ids are deterministic from the message id and the block's original index, so a re-parse or a tool result landing keeps a row's expanded state alive.
- **Short pieces are not packed back into larger items**, and should not be. A packer cannot honour both a floor and a ceiling — a 26 pt piece before a 588 pt one has to violate one of them — and an item keyed by its first piece loses the `@State` of every piece that moves to a different parent when the packing shifts. The 300 pt ceiling does the work on its own; if the small side ever turns out to matter, the answer is a real minimum height on the shortest rows (Trial E1), not packing.

### What the list animates

The list was built animating almost nothing, on the reading that animation caused the hang. The trials above falsified that: Trial 1 hung with `AnimatedHeight` replaced by a plain `fixedSize`, and Trial 2 hung with every row a blank rectangle. Height contrast in the container is the trigger. So the list now moves:

- **Every piece eases its own height**, including the turn in flight and a piece whose wash joins its neighbours. `ChatPieceView` applies the frame inside the wash and outside the vertical padding, so the wash sizes to it and a joined segment cannot open a seam.
- **A piece that has just arrived grows from zero into place**, which is what pushes the conversation up. `ChatListMotion` names those pieces, and `AnimatedHeight` runs the growth.
- **The room the composer covers eases**, so a composer that gains a line slides the messages.

**The `ForEach` diff is still never wrapped in an animated transaction**, and there is still no `.transition` on a row. Every animation here belongs to one row's own frame. That matters for two reasons: an animated diff inside a lazy stack is the "animation in flight during the placement pass" pairing this document warns about, and a transition would also play an entrance for any row the stack happens to realize during a scroll. A removed piece therefore cuts rather than shrinking — nothing is left in the hierarchy to animate — which is accepted.

The `animateChatMotion` setting (stored under its older key, `animateRowHeight`) turns all of it off in one place.

**Measured once**, with `PLUME_CHAT_ITEM_STATS=1` and `PLUME_SCROLL_WHEEL=150` driving the scroll, one transcript per run at a 1016 pt viewport, on the hang thread and the five largest transcripts on disk. This was a one-off check that the ceiling holds on real content — it is not a regular test. A full sweep costs about 18 minutes of wall clock, and a returning hang announces itself in seconds of scrolling, so do not re-run it on a schedule or before a release. Run it again only to answer a specific question about item heights.

| transcript | pieces | min | max | median | global | window | tallest |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `552fca5e` (the hang thread, 2.0 MB) | 318 | 27 | 358 | 63 | 13.3× | 13.3× | code |
| `8031d34c` (7.9 MB) | 1188 | 24 | 651 | 63 | **27.1×** | **24.1×** | table |
| `3d68cfeb` (3.0 MB) | 378 | 27 | 251 | 63 | 9.3× | 8.1× | list |
| `31a71dff` (3.0 MB) | 198 | 27 | 226 | 63 | 8.4× | 8.4× | paragraph |
| `36a80209` (3.9 MB) | 461 | 27 | 252 | 63 | 9.3× | 9.3× | list |
| `b7a80004` (3.0 MB) | 385 | 27 | 407 | 67 | 15.1× | 14.3× | code |

The two `code` rows predate the code-block bound: a block over the ceiling now stops at 300 pt rather than splitting, so both would measure lower today. Nothing else in the table changes.

The hang thread's tallest row before the split was 2,140 pt against a 23 pt cluster, about 93×. The short side is now a collapsed tool call at 27 pt throughout; blocks that draw nothing — a call the dock has taken over, a thinking block with no text — take no item at all, which removed an 8 pt row that was dragging the ratio out.

**One transcript misses the target, and one table is why.** `8031d34c` holds a 651 pt table, and a table is never split — segments would size their columns independently and the join would show. Everything else on that thread is under 350 pt. The two remedies, neither taken here because both change what the reader sees: bound an oversized table the way `ToolCallRow` bounds an oversized result, or put an actual minimum height on the shortest items (Trial E1: 100 pt beside 2,140 pt was safe). Neither is worth doing until a hang actually comes back on that thread.

**Heights the ceiling does not bound**, so verification knows where to look: a table; a paragraph or quote over the ceiling; an expanded `ThinkingRow` or `InjectedContentRow`, which have no `maxHeight` the way `ToolCallRow`'s sections do; `ChatImageView` up to 320 pt; and the live tail of the streaming overlay, which is one item until the next block starts.

**Rebuilding the whole piece list costs about 6 ms** for 385 pieces, logged as `rebuildMs`. `ChatPieceCache` memoizes the parse, so a rebuild after a status or streaming change reparses nothing.

Acceptance beyond "no hang after momentum through the boundary":

- A positive control: the original layout still hangs under the same test, proving the test itself catches the bug.
- Synthetic transcripts that vary contrast, cluster length, oversized-block count, and item count independently, rather than only the one transcript these trials used.
- A viewport sweep from about 900 to 1322 pt and beyond.
- Streaming into both a visible message and an off-screen one.
- The main-thread watchdog (`detect-chat-hang.sh`) as the failure detector, not a visible freeze.
- Stable total height once content settles.
- Correct initial bottom position, working jump-to-bottom, and the bottom following during streaming.
- No movement while reading older messages.
- The momentum test from this section, run on this thread with real content and repeated on the largest transcripts.
- Bidirectional momentum, several window sizes including the tall external display, resizing, and hidden-tab switching.
- Compare cold open, task-switch latency, scroll responsiveness and memory against the current shape, with several chats mounted at once.

If the split does not hold up, the fallback is unchanged: an eager `VStack` with an owned height cache. Trial D proves plain eager layout removes the loop outright; the open question is its cost on long transcripts. After that, `List`, then manual windowing last.

## If it comes back

1. Turn on `PLUME_CHAT_DIAG` and run `scripts/capture-chat-hang.sh` before trying to reproduce — reading an instrumented capture is cheaper than reading a cold sample from scratch.
2. Get a sample first. If the window is frozen, `sample <pid> 5` while it spins, or let macOS write the hang report on force-quit. The frames decide; the container comment does not.
3. Look for `signalPrefetch → requestUpdate` and an animation in flight. That pairing is this bug. Anything that scrolls the list programmatically while rows are estimates, especially under animation, recreates it.
4. If placement itself is hot with no scroll driving it, suspect a row whose size depends on the proposal in a way estimates cannot converge on (a custom `Layout`, a code block's horizontal `ScrollView`, the hugging user bubble). Swap rows for fixed-height placeholders to confirm before touching the container.
5. Going back to `VStack` hides the loop without finding it.
