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

Long transcripts to feed it live under `~/.claude/projects/`; the Notability one from Sep 4 is 13 MB and about a thousand rows.

## If it comes back

1. Get a sample first. If the window is frozen, `sample <pid> 5` while it spins, or let macOS write the hang report on force-quit. The frames decide; the container comment does not.
2. Look for `signalPrefetch → requestUpdate` and an animation in flight. That pairing is this bug. Anything that scrolls the list programmatically while rows are estimates, especially under animation, recreates it.
3. If placement itself is hot with no scroll driving it, suspect a row whose size depends on the proposal in a way estimates cannot converge on (a custom `Layout`, a code block's horizontal `ScrollView`, the hugging user bubble). Swap rows for fixed-height placeholders to confirm before touching the container.
4. Going back to `VStack` hides the loop without finding it.
