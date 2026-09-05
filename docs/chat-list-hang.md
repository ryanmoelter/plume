# The chat list hang

`ChatMessageList` renders messages in a `LazyVStack`. It did once before, and that version froze the app. This records what happened, what was tried, and why the lazy stack is back, so the next freeze starts from evidence rather than from scratch.

## What happened

On Sep 1 2026 the chat list moved from `VStack` to `LazyVStack` (`28a40f2`, "Only build the chat rows on screen") so a long transcript would build only the rows on screen. On Sep 2 it went back (`88941bf`, "Stop the chat list oscillating between two heights"): scrolling a long transcript pinned a core and froze the window. The revert's diagnosis was a layout oscillation. A lazy stack picks which rows to realize from the content height, realizing rows of varied height changes that height, and the two never settle.

That diagnosis was a reading of the symptom, not a proven cause. Nothing in the scroll machinery changed in the revert. Only the container did.

## What changed in between

Between the revert and Sep 4 the chat rows lost most of their per-frame work, all found by sampling rather than by reasoning about the stack:

- `MarkdownView` keys its blocks by index instead of by an `enumerated()` tuple, which SwiftUI could never match across passes. A trace had caught it rebuilding markdown blocks about 31,000 times over 15 seconds of scrolling.
- `MarkdownCache` memoizes block parsing and attributed-string conversion.
- `WorkingIndicator` animates with `TimelineView` instead of `phaseAnimator`, which had been rebuilding the whole display list every tick.
- `ChatMessageList` passes live status only to the last row, so a status change no longer invalidates every row.
- The per-frame scroll geometry callback writes to a plain reference box, and the detach flag flips outside the view update.

Any of these could have been the load that turned a lazy stack's ordinary re-measurement into a loop. Which one was never isolated.

## What was tried on Sep 4

The lazy stack was swapped back in on top of all of the above and driven by a DEBUG harness, which is committed and reusable:

- `PLUME_SEED_TRANSCRIPT_PATH=<jsonl>` renders a full chat from an existing transcript with no `claude` process.
- `PLUME_SCROLL_EXERCISE=<seconds>` jumps between messages spread across the transcript with `scrollTo`.
- `PLUME_SCROLL_WHEEL=<points>` moves the backing `NSScrollView` that many points per frame and reverses at the ends, the shape of a trackpad scroll.
- `scripts/detect-chat-hang.sh [seconds]` watches Plume's CPU and, if it stays above 90% for five seconds, prints `HANG` with the hottest sampled frames.

Against an 11.5 MB transcript, none of these reproduced the freeze: not the jump mode, not the wheel mode at 8 or 40 points per frame, not with three transcripts mounted at once. Peak CPU stayed under 75%. Ryan then scrolled a very large conversation in the installed build by hand and saw no freeze.

Two honest gaps remain. The harness was never run against the pre-revert commit, so it is unproven that it can see this hang at all. And the fix was never bisected, so which change removed the load is unknown.

## If it comes back

1. Launch the Debug build with the harness and run `scripts/detect-chat-hang.sh 60` while it scrolls, or while you scroll by hand. The sampled frames are the evidence; the container comment in `ChatMessageList.swift` is not.
2. If the harness cannot reproduce it, `scripts/profile-chat-scroll.sh` records an Instruments trace while you scroll. The `swiftui-causes` and `hangs` tables name what is rebuilding.
3. Bisect the interaction, not the container. The candidates in order: the per-frame `onScrollGeometryChange` action and its `isDetached` write, the `onAppear` scroll into an unrealized bottom anchor, `ScrollViewReader` with an `.id()` on every row, and finally the rows themselves (a hugging user bubble, `TableLayout`, a code block's horizontal `ScrollView`). Swapping the container back to `VStack` hides the loop without finding it.
