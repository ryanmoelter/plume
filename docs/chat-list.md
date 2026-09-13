# The custom chat list

`docs/chat-list-hang.md` records why the `LazyVStack` engine has no estimator: a lazy stack estimates unrealized rows from realized ones, and a big enough spread between them never converges under momentum scrolling. This engine avoids the whole class of bug by never estimating past the first guess. It owns layout itself, in AppKit, and every visible row is measured for real before it is placed.

`ChatMessageList` still builds the pieces and picks the engine; this document is what happens once it hands them to the custom one. Read it before touching `Plume/UI/Chat/List/`.

## The shape

- **`ChatLayoutModel`** (`ChatLayoutModel.swift`) is the pure layout brain: item order, per-item heights (a target and an eased display value), prefix-sum offsets, which items fall in the realized window, the slack that pins a sent prompt to the top, and the arithmetic for keeping the reader's place. No AppKit, no SwiftUI, no `ChatPiece`. A measured height stops here and never flows back into `ChatPieceSplitter` or `ChatPieceEstimate`.
- **`ChatListController`** (`ChatListController.swift`) owns the `NSScrollView`, the document view, the model, the realized hosts, and the host pool. `layoutPass()` is the only place that reads scroll geometry, resolves an offset, and writes it back; see below.
- **Hosts** are `NSHostingView<AnyView>` instances, one per realized piece, holding a `ChatListItemRoot` that wraps the same `ChatPieceView` the lazy engine uses.
- **`ChatListAnimator`** (`ChatListAnimator.swift`) is one `CADisplayLink` behind every height ease, arrival grow-in, composer-room ease, and programmatic scroll. One clock rather than one animation per row, so the controller applies every in-flight value in a single layout pass per frame. A 60 Hz `Timer` stands in whenever the link goes quiet for 100 ms: a display that has gone to sleep stops vsync but not the stream, and an ease that never ends leaves rows clipped mid-growth. (The overnight harness runs found this: with the display off, no ease ever finished.)
- **`ChatListView`** (`ChatListView.swift`) is the `NSViewRepresentable` bridge. It diffs `ChatListInputs` and forwards callbacks (`onOpenSubagent`, `onVisiblePieceIDs`, `onDetachedChange`) unconditionally, since a value comparison can't see a changed closure capture.

`ChatListCommands` (`ChatListController.swift`) is the handle `ChatMessageList` calls into: `jump(to:)`, `scrollToBottom(animated:)`, and `pin(pieceID:)`, each forwarding to the matching controller method. `ChatMessageList` holds one in `@State` before the representable's `makeCoordinator()` has ever run, and `makeNSView` sets `commands.controller` to the real controller once it exists. That is what lets `jumpToBottom`, `jump(to:)`, and `pinSentPrompt` in `ChatMessageList.swift` call `commands.scrollToBottom`/`commands.jump`/`commands.pin` on the `.custom` branch of their `switch engine`, next to the `ScrollPosition`-based calls the `.lazyStack` branch makes.

`ChatListInputs` (top of `ChatListController.swift`) is the one value the SwiftUI side hands down each render: the pieces, the tab id, the subagent list, whether motion is on, the trailing inset the composer covers, the chat font size, when the current turn started, and the `arrivals`/`openings` sets that mark which pieces should grow in or type from zero. It is `Equatable`, and `ChatListView.updateNSView` only calls `controller.update(_:)` when it actually changed, so an unrelated SwiftUI re-render costs nothing on the AppKit side.

`update(_:)` diffs the old and new inputs field by field. A change to `pieces` or `tabID` rebuilds the item list (`rebuildItems`, which also frees hosts for anything removed); a change to `trailingInset` eases the composer room; turning `animate` off snaps every in-flight ease to its target instead of leaving it stranded mid-flight; a change to `chatFontSize` or `workStartedAt` marks every realized host stale so its root gets rebuilt with the new environment. `ChatListDocumentView.layout()`, AppKit's own layout hook, is what actually calls `layoutPass()`. `update(_:)` and everything else only ever request one, through `documentView.needsLayout = true`.

## The layout pass and the single-offset-writer rule

`ChatListController.layoutPass()` is the only place the scroll offset is written. Everything else, inputs changing, a measurement arriving, an animation ticking, the clip view resizing, sets `documentView.needsLayout = true` and waits for the next pass.

Each pass resolves one **offset policy**, in this order (`resolvedOffset()`):

1. **A programmatic scroll in flight** (`easedOffset` non-nil): the animator is driving toward a target (`.bottom` or `.item(id)`), re-resolved every tick so a jump can retarget as rows below it measure.
2. **Following the bottom** (`isFollowing`): the offset is `model.followOffset` minus `followDistance`, the gap the reader last settled at inside `ChatScrollAnchor.bottomTolerance`, so growth keeps that gap rather than snapping it shut. A landed scroll to the bottom resets the gap to zero. `followOffset` is `maxOffset` less the fold (below), so following rests with the fold behind the composer while a deliberate scroll can still reach `maxOffset` and bring it out.
3. **Preserving the reader's anchor** (`readerAnchor`): the id and distance captured the last time the reader scrolled, so a height change above them moves nothing they can see.
4. Otherwise, the scroll view's own current offset. Nothing wants to move it.

The pass writes the offset **only when the policy's answer changed** (`desired != lastResolvedOffset`, or a scroll is actively easing). This is deliberate. The scroll view's own rubber-banding past either end is real, user-driven motion that a policy which hasn't changed its answer should never fight. Re-asserting the same offset on every pass would fight that elastic bounce and make it feel dead.

## How scroll events are attributed

`clipBoundsChanged` fires on every bounds change, both the ones the controller causes and the ones a trackpad or scrollbar cause. Two guards separate them:

- `isOwnScroll` is true only for the duration of a `clip.scroll(to:)` call the controller itself makes, so its own writes never look like reader input.
- `isLayingOut` guards against reentrancy from inside `layoutPass()` itself.

Past those, a bounds change whose size still matches the model's `viewportHeight`/`measurementWidth` is a scroll; one whose size doesn't is a resize, which is geometry, not intent, and just triggers a fresh pass to re-resolve the existing policy. Anything left, a wheel, a momentum tail, a keyboard page, is the reader's: it cancels any in-flight programmatic scroll and pin, recomputes `isFollowing` and `readerAnchor` from the new offset, and updates `isDetached`. It also stamps `lastResolvedOffset` immediately, so the very next layout pass doesn't see a changed policy answer and yank the view back.

## The realized window

`realizeWindow(around:)` asks the model for `realizedRange(offset:)`: everything whose slot falls within the viewport plus **overscan** of half a viewport on each side, capped at `maxRealized` (120) hosts by trimming alternately from whichever end is farther from the offset. It realizes anything in that window without a host, but frees only what has left a window three times as wide. The hysteresis matters: a sustained fast scroll otherwise builds and tears down every host at the window's edge once per frame, which was the difference between 63% and 39% main-thread CPU under the synthetic wheel harness.

Both numbers come from measuring the real cost. Creating and measuring one host for a real piece is about 1.3 ms, and laying out 150 of them costs about 50 ms more on top of that. Half a viewport of overscan each side is enough headroom that a normal scroll never outruns realization; the 120-host cap exists so a pathological case, a huge viewport, or many tiny pieces, can't make a single pass do unbounded work.

## Measurement

A piece is measured twice, on purpose.

- **Synchronously at realization.** `realize(id:item:)` sets the host's `rootView` and reads `view.fittingSize.height` in the same call. This is correct because `sizingOptions = .intrinsicContentSize` makes `fittingSize` synchronous and accurate right after a `rootView` replacement, and after a width change too, which is what `remeasure(id:item:host:)` relies on. `sizingOptions = []` would return zero instead.
- **Asynchronously afterward, on any natural-height change.** `ContainerHeight` (`ChatListItemState.swift`) wraps the row in `.fixedSize(vertical: true)` plus `.onGeometryChange`, reporting back through `onNaturalHeight` to `ChatListController.report(id:height:width:generation:)`. `onGeometryChange` fires synchronously inside AppKit's `layoutSubtreeIfNeeded`, even for a host that starts at zero size, because the hosting view's root fixes its own width from the frame it's given.

Every report is stamped with the **generation** the row was realized at and the **width** it was measured against (`setTargetHeight` rejects a report whose generation or width no longer matches). A row freed and later re-realized bumps its generation, so a measurement that arrives late for the old incarnation is silently dropped instead of corrupting a different piece's height. Reports queue in `pendingMeasurements` and are applied at the top of the next `layoutPass()`, never inline. Measurement never re-enters layout.

Intrinsic sizing never fights an explicit frame the controller sets afterward. A host given, say, a 20 pt frame keeps it through layout rather than snapping back to its natural size, which is what lets `layoutPass()` assign every host's `NSRect` from the model's resolved geometry without a second pass fighting it back.

**Why the height lives inside SwiftUI, not on the host's AppKit frame.** A SwiftUI root taller than the frame it's drawn into is *centered* inside that frame, not top-pinned, no matter what alignment the root itself asks for. So easing a row's height by resizing the `NSHostingView`'s own frame during the ease would center the content inside a frame that doesn't yet match its natural size: a visible jump once the ease catches up. `ChatListItemState.containerHeight` avoids that. It's read *inside* the SwiftUI tree, at the same point in `ChatPieceView`'s modifier chain where `AnimatedHeight` sits for the lazy engine, through `HeightSource` in `ChatPieceView.swift`. The wash sizes to the animated `containerHeight`, and the host's own AppKit frame only ever gets set to the model's already-resolved `displayHeight` once a pass has computed it. It never drives the animation itself.

## Pooling and state reset

Hosts are pooled. `dequeueHost()` pops a spare `NSHostingView` before creating one, and `free(_:force:)` returns a freed host to the pool (capped at 40) rather than destroying it. A pooled host's `rootView` is reset to `AnyView(EmptyView())` before it goes back, dropped rather than kept, because a pooled root that came back for the same id would keep its `@State`, and it holds its own view graph. A host whose subtree holds first-responder focus is kept in place instead of freed unless `force` is set (item deleted outright), so an editing text field isn't yanked out from under the reader when it scrolls out of the realized window.

`ChatListItemRoot` carries `.id(id)` on the SwiftUI root, so replacing `rootView` for the *same* id keeps `@State` (a height ease, say); a different id resets it.

## The environment a fresh root needs

A fresh `NSHostingView` root starts with none of the ambient SwiftUI environment a view mounted inside `ChatMessageList` would normally inherit. `ChatListItemRoot` (bottom of `ChatListController.swift`) puts back everything a row reads: `plumeTheme(bodySize:)`, `\.chatFontSize`, `\.revealClock`, and `\.workStartedAt`. **Any new environment key a chat row starts reading has to be added here too**, or the row silently renders with SwiftUI's default for that key instead of failing loudly.

## Send-to-top and slack

`pin(pieceID:)` is how a just-sent prompt gets pushed to the top of the viewport with room below it for the reply. `ChatListCommands.pin(pieceID:)` is called from `ChatMessageList.pinSentPrompt`. It sets the model's anchor to that piece and scrolls to `.bottom` animated.

The room below the anchor is **slack**, computed in `ChatLayoutModel.recomputeSlack()`:

```
slack = max(0, V - (C - A) - B)
```

where `C` is the content height, `A` is the anchor's own top offset, `V` is the viewport height, and `B` is the trailing inset (the room the floating composer covers). `C - A` is everything at or below the anchor. Subtracting that and `B` from the viewport height leaves however much of the viewport isn't yet filled below the pinned prompt: the blank space the reply grows into instead of the pinned prompt itself moving.

Slack follows the formula until it first reaches zero, then **latches at zero** until the next `setAnchor`. Below the fill line the formula rules in both directions, so a streaming block that re-wraps a line taller for one frame and then back takes nothing away from the pinned prompt; an earlier one-way cap bled slack on every such transient, which read as the list jittering and as the message above the prompt creeping into view. Once the reply has filled the viewport the reader is following the bottom, and a disclosure collapsing or the window growing keeps them there rather than snapping the prompt back to the top.

While the prompt and the pieces below it are still measuring for the first time, `notePinMeasurement` keeps calling `setAnchor(pendingPin)` again on every measurement at or past the anchor. This is the **calibration** window, and it clears the latch each time, so an estimate that overstated the reply cannot lock it in. `land(_:)`, called when the scroll to bottom finishes, sets `pendingPin = nil` and ends calibration for good.

Sending always jumps: `pin(pieceID:)` unconditionally scrolls, regardless of where the reader currently is.

## The fold

The trailing items are, in order, the permission dock, the subagent header and the subagent rows. The rows are marked `folds` on their `ChatLayoutItem`, and `ChatLayoutModel.foldHeight` is the height of the trailing run of folding items. Following rests at `followOffset = maxOffset - foldHeight`: the header sits just above the composer and the rows behind it, where they can be read through the glass or scrolled out. The slack formula uses `heldHeight = contentHeight - foldHeight`, so while a reply is still shorter than the viewport the rows show in full below it and slide behind the composer as it grows, before the list starts scrolling. The dock comes first because it needs a click. `SubagentListView.Part` is what lets one view draw as two items.

## Wheel events over a row's own scroll view

A code block's horizontal scroller is an `NSScrollView` of its own, and AppKit gives it every wheel event over it, vertical ones included, so scrolling the list from over a code block stalled. `ChatListController.routeWheel` is a local `NSEvent` monitor: for a wheel event over one of this list's rows whose nearest scroll view has no vertical room, a vertical gesture is sent to the list's scroll view and swallowed before the row sees it. The axis is decided once, when the gesture begins, and held through its momentum. A row scroller that can scroll vertically, such as a disclosed tool result, is left alone. The lazy engine never needed this because SwiftUI arbitrates between its own nested scroll views.

## Lifted ceilings

`ChatPieceLimits` (`ChatPieceMetrics.swift`) carries the height ceilings a list asks its rows to keep, through the `\.chatPieceLimits` environment value. The default is the lazy stack's, and `CodeSegmentView` bounds a tall code block at it. `ChatListItemRoot` sets `.unbounded`, so under this engine a long code block draws whole and the outer scroll is the only scroll. The pieces themselves are the same for both engines: `ChatPieceSplitter` never split code blocks, and it still gives a list one piece per item, so a row stays a block, only taller. `ChatPieceEstimate` guesses a code block at its full line count for the same reason. The disclosed-body ceiling (`ChatPieceMetrics.maxDisclosedHeight`) still applies under both engines; it is as much a reading choice as a layout one.

## The engine switch

`AppSettings.chatListEngine` (`Plume/Support/AppSettings.swift`) is `.lazyStack` or `.custom`, persisted under `chatListEngineRaw`, defaulting to `.custom` so the custom list gets daily use before the lazy stack is removed. The Settings toggle is "Use the new chat layout" under the Chat Layout section in `SettingsView.swift`. `PLUME_CHAT_LIST_ENGINE=custom|lazy` (`ChatListEngine.environmentOverride` in `ChatListEngine.swift`) wins over the stored setting, for a harness run.

The choice **applies to the next chat opened, not the current one**: `ChatMessageList` reads `AppSettings.shared.effectiveChatListEngine` once into `@State` at init, because switching containers under a mounted list would rebuild every row.

## The `chat-list` log category

`Log.chatList` (`Plume/Support/Log.swift`, category `"chat-list"`) is custom-engine only. `logPass` writes at most one `pass` line per second, plus the state a burst settled on a second after it ends, so a run with the screen off still leaves evidence of what the list did. `land` logs where a programmatic scroll finished. Read them with `log show --predicate 'subsystem == "com.ryanmoelter.Plume" AND category == "chat-list"' --info --last 5m`:

```
pass items=<count> realized=<count> pool=<count> offset=<Int> max=<Int> total=<Int> viewport=<Int> slack=<Int> following=<Bool> detached=<Bool> animating=<Bool>
```

`items` is everything in the model; `realized` and `pool` are host counts; `offset`/`max`/`total`/`viewport` are the pass's resolved geometry; `slack` is the send-to-top room described above; `following`/`detached`/`animating` are the controller's own state flags.

## What is still lazy-engine-only

- `PLUME_CHAT_ITEM_STATS` and its probes (`ChatItemStats.swift`), attached only inside `lazyList`'s `ForEach`.
- The **"Chat Item Boxes"** debug toggle (`ChatItemOutlines.swift`, `chatItemOutline`), also only in `lazyList`.
- The 300 pt piece ceiling (`ChatPieceMetrics.maxPieceHeight`) still applies to **both** engines, because `ChatPieceSplitter` and `ChatPieceEstimate` are shared: `ChatMessageList.rebuildPieces()` builds one `pieces` array that both `lazyList` and `customList` draw from. The custom engine has no estimator of its own to protect, but the splitter doesn't know which engine is reading it.

## Verifying

Harness command line (DEBUG build), matching the runs that showed no hang over 60 s with the same main-thread CPU as the lazy engine:

```
PLUME_CHAT_LIST_ENGINE=custom PLUME_SEED_TRANSCRIPT_PATH=a.jsonl,b.jsonl \
PLUME_FAKE_STREAM=0.2 PLUME_CYCLE_SELECTION=5 PLUME_SCROLL_WHEEL=30 \
  <DerivedData>/Plume.app/Contents/MacOS/Plume &
```

Watch the main thread with `scripts/detect-chat-hang.sh [seconds] [pid]` alongside it; it prints `HANG` and the hottest frames if the main thread stays above 90% CPU for five seconds.

Manual checklist, on both engines where it applies:

- Opens at the bottom of a transcript.
- Follows a live stream without detaching.
- Jump-to-bottom button appears once scrolled away, and returns to the bottom.
- Minimap select jumps to a piece; select-end jumps to the bottom.
- Composer growth (gaining a line) slides the list rather than jumping it.
- Resizing the window re-measures rather than leaving stale heights.
- Send-to-top with a short reply leaves visible slack below the pinned prompt.
- Sending a message while scrolled up still jumps to the pinned prompt.
- Trackpad momentum scrolling through a long thread never hangs.
