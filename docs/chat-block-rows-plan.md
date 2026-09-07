# Chat list: one lazy item per block

An implementation plan for the fix to the hang diagnosed in `docs/chat-list-hang.md` ("Sep 6"). Read that section first, through "The mechanism" and "Fix direction". This document assumes it.

## The problem in one paragraph

`LazyVStack` estimates the rows it has not realized from the ones it has. When the realized region holds items whose heights differ by a large factor, about 50× in every reproduction and never at 21× or below, momentum scrolling on a tall viewport leaves the stack flipping between two realized sets forever, and the main thread pins at 100%. The chat list today has one lazy item per message, so a 2,140 pt assistant turn can sit beside a 23 pt compaction notice. Placeholder trials showed that splitting messages into paragraph-sized items of 24–180 pt never hangs (E4), that capping every item at 300 pt with the 23 pt rows left in place never hangs (E2), and that neither tiny items nor tall items reproduce it on their own. The fix is to make the lazy items the list hands to SwiftUI bounded in height, without changing what the reader sees.

## Design

### Pieces are the lazy items

Today: `messages: [ChatMessage]` → `ForEach` → `ChatMessageRow`, one lazy item per message, which lays out all of that message's blocks in a `VStack`.

After: `messages` → **pieces** → `ForEach` → `ChatPieceView`, one lazy item per piece.

A **piece** is the smallest unit the list can place on its own: one markdown block (paragraph, heading, list, code block, table, quote, rule), one thinking row, one tool call, one injected-content row, one notice, one image, the streaming overlay, the working indicator. A piece knows which message it belongs to, where it sits in that message's wash group, and the top inset it pays. Oversized blocks are split into segments so no piece exceeds a ceiling.

There is no packing of short pieces into larger items. Astra's review of the first draft showed that a packer cannot honour both a floor and a ceiling, and that state inside a re-packed item is lost when its parent changes. E2 is the evidence that a 300 pt ceiling with 23 pt rows left alone is safe (13×), so the ceiling does the work. If measurement later shows a contrast problem on the small side, the fallback is a small *actual* minimum height on the shortest rows (E1: 100 pt beside 2,140 pt was safe), not packing.

### Types

`Plume/UI/Chat/ChatPiece.swift`, `nonisolated` like `ChatMessage`.

```swift
struct ChatPiece: Identifiable, Equatable {
    let id: String              // "\(messageID)/\(blockIndex)" plus "/\(subIndex)" for markdown sub-blocks and "/\(subIndex)/\(segment)" for split segments; "stream/\(n)" and "working" for the trailing pieces
    let messageID: String
    let role: ChatMessage.Role
    let content: Content
    let segment: Segment        // this piece's place in its message's wash group
    let topInset: CGFloat

    enum Content: Equatable {
        case markdown(MarkdownBlock, index: Int, isAgentVoice: Bool)   // index within its block list, for heading spacing
        case codeSegment(CodeSegment)
        case listSegment(ListSegment)
        case thinking(String)
        case toolCall(ToolCall, isPending: Bool)
        case injected(InjectedContent, text: String)
        case notice(ChatNotice)
        case image(ChatImage)
        case streaming(ChatStreamHandoff.Overlay)
        case working
    }

    enum Segment { case single, first, middle, last }
}
```

`CodeSegment` carries the language, the segment's lines, the full text (for the copy button), the segment position and whether it is a mermaid fence. `ListSegment` carries the list kind, the items, the starting number for numbered lists, and the position.

### Splitting: `ChatPieceSplitter`

`static func pieces(for messages: [ChatMessage], lastMessageID: String?, status: TaskStatus, hiddenToolUseIDs: Set<String>, streaming: ChatStreamHandoff.Overlay, dimensions: Dimensions) -> [ChatPiece]`

Pure. Per message, per block, in order:

- `.markdown(text)` → `MarkdownBlock.parse(text)` gives `[MarkdownBlock]`, one piece per block. Use a cache (see "Where the model is built"); do not call `MarkdownCache.blocks(for:)` from inside `body`.
- `.thinking`, `.injected`, `.notice`, `.image` → one piece each.
- `.toolCall(call)` → one piece unless `hiddenToolUseIDs.contains(call.id)` (the dock draws it; `ChatMessageRow.swift:137`). A hidden call is omitted; other blocks keep their original `blockIndex`, so ids do not shift when the dock takes a call over or hands it back. `isPending` keeps today's rule from `ChatMessageRow.isPendingBlock(at:)` (`ChatMessageRow.swift:156`): `status == .needsInput` and the block is the last block of the last message (the last *original* block, not the last rendered one).
- After the last message, when it is an assistant message: a `.streaming` piece when the overlay is non-empty, then a `.working` piece when `status == .working`, mirroring `assistantBody` (`ChatMessageRow.swift:85–110`). When the last message is not an assistant message the streaming piece stands alone, as `ChatMessageList.swift:117–128` does today.
- `segment` is assigned per message once its rendered pieces are known: one → `.single`, otherwise `.first` / `.middle` / `.last`. The trailing streaming and working pieces belong to the last message's group. Appending a piece to a message turns its previous `.last` into `.middle` (or `.single` into `.first`); that is a value change on a stable id, which is what we want.

**Ceiling.** `maxPieceHeight = 300` pt, the value E2 tested. A block whose estimate exceeds it is split when its kind allows:

- Code block: into segments of `codeSegmentLines` (default 16) lines, only when the block has more than `2 × codeSegmentLines` lines, so ordinary blocks stay whole. Mermaid fences are never split; the diagram is one artifact.
- Bullet and numbered lists: into segments of `listSegmentItems` (default 12) items; numbered segments carry the continuing start number.
- Tables: never split. Segments would size their columns independently and the join would show. A table over the ceiling stays one piece; tables that long are rare in chat.
- Paragraphs, headings, quotes, images and the collapsed rows are never split.

**Estimates.** Only the ceiling uses them, and only to decide whether to split, so they must be cheap and need not be accurate. Suggested: paragraph or quote `lines × 20 + 8` with `lines = explicit newlines + 1 + characters / 90`; code `lines × 17 + 28`; list `items × 22`; everything else "never split". Keep the constants together.

**Insets.** `topInset` comes from `ChatBlockSpacing`, extended with a piece-level function. Rules to preserve exactly (they are test-locked in `ChatBlockSpacingTests`):

- The first piece of the list pays `dimensions.verticalPadding`.
- The first piece of a message pays the message-level inset: `toolCallSpacing` when both the previous message and this one are all tool calls, otherwise `messageSpacing` (`rowTopInset`, `ChatBlockSpacing.swift:40`). Compute it from `rowKind` of the previous *message* and this one, not from the previous piece, so a message ending in prose followed by a tool-call-only message spaces as it does today.
- Within an assistant message, between blocks: `blockTopInset` (`ChatBlockSpacing.swift:64`), `toolCallSpacing` between consecutive tool calls, otherwise `messageBlockSpacing`. Hidden tool calls do not advance the previous-kind cursor.
- Within a user message, between blocks: 8 (`userBody`'s `VStack(spacing: 8)`, `ChatMessageRow.swift:55,66`). Within a notice message: 6 (`noticeBody`, `ChatMessageRow.swift:79`).
- Between two markdown pieces from one `.markdown` block: whatever `MarkdownView.body` puts between its blocks today, including the extra `headingTopSpacing` a non-initial heading gets. Read `MarkdownView.swift:38–52` and reproduce the value from the piece's `index`; do not invent one.
- Between segments of one split code block: 0. Between segments of one split list: the 4 pt gap list items have today.
- The streaming piece pays `streamingTopInset(previous:)` (`ChatBlockSpacing.swift:84`); the working piece pays what `assistantBody` gives `WorkingIndicator` (`ChatMessageRow.swift:98`).

Keep `rowTopInsets` and `blockTopInsets` as the building blocks the new function calls, so the existing tests keep passing; add tests for the piece-level function that pin the same numbers.

### Where the model is built

`TranscriptStore` replaces the whole `[ChatMessage]` on every file change (`TranscriptStore.swift:184–206`, debounced 250 ms). `MarkdownCache` is MainActor-isolated, holds 512 entries and clears wholesale at capacity (`MarkdownCache.swift`), and today it is only consulted by realized rows. Splitting every message eagerly through it would churn the cache on long transcripts and would run parsing inside `body`.

So: `ChatMessageList` holds `@State private var pieces: [ChatPiece]` and a `@State` cache object `ChatPieceCache` (a final class, not observable) mapping `messageID → (ChatMessage, [ChatPiece])`. In `.onChange(of: messages, initial: true)`, and in `.onChange` of `status`, `pendingToolUseIDs` and `streaming`, rebuild: for each message, reuse the cached pieces when the cached `ChatMessage` is `==` the new one, otherwise split it (calling `MarkdownBlock.parse` directly and storing the result in the cache entry), then recompute segments, `isPending`, insets and the trailing pieces, which are cheap. The cache is per list instance, so it never outlives the tab, and is O(messages) per rebuild with O(changed blocks) parsing. `body` reads `pieces` only. This follows the rule in `CLAUDE.md`: never write `@Observable` state during `body`.

### Rendering: `ChatPieceView`

`ForEach(pieces) { piece in ChatPieceView(piece: piece).animatedHeight(enabled: settings.animateRowHeight && !piece.isStreaming).listItemPadding(bleed: true, column: .unpadded, vertical: false).padding(.top, piece.topInset) }`, replacing `ChatMessageList.swift:89–116`. The `rowInsets` array goes away.

`ChatPieceView` switches on `content`:

- `.markdown(block, index, isAgentVoice)` → a single-block markdown view. `MarkdownView(blocks: [block])` (`MarkdownView.swift:28`) renders index 0 and would lose the non-initial heading spacing; either pass the index through a new init parameter or extract `MarkdownView.render(_:at:)` (`MarkdownView.swift:60–150`) into a `MarkdownBlockView(block, index:)` the list can use directly. The view's `hoveredBlock` state (`MarkdownView.swift:21`) is index-keyed within the view and works unchanged.
- `.codeSegment` → the code block renderer from `MarkdownView.codeBlock` (`MarkdownView.swift:154–162`) with the background's corners squared on joined edges, the inner padding paid only on outer edges (`.first` pays top, `.last` pays bottom, all pay horizontal) so the join has no seam, and the copy button only on `.first` or `.single`, copying the full text. Each segment has its own horizontal scroll view, so wide code scrolls per segment rather than as one block; this is the accepted cost of splitting, and the 32-line threshold keeps it rare.
- `.listSegment` → the list renderer with the continuing start number.
- `.thinking`, `.toolCall`, `.injected`, `.notice`, `.image` → the existing rows, unchanged. Their `@State` (expanded / isExpanded) now lives in a view whose identity is the piece id, which is stable across re-parses, so expansion survives streaming.
- `.streaming(overlay)` → `StreamingBlocks` as today.
- `.working` → `WorkingIndicator` (move it out of `ChatMessageRow.swift:175`).

**Wash groups** replace `userBody` and `assistantBody`'s wrapping:

- User pieces get the wash bubble. Today `userBody` (`ChatMessageRow.swift:52–76`) wraps all blocks in `.padding(10)` + `.background(wash, in: .rect(cornerRadius: 10))`, trailing-aligned at `dimensions.contentWidth`, with `chatHugsContent` so a short message hugs its text. `.single` keeps exactly that. `.first` / `.middle` / `.last` draw the wash with `UnevenRoundedRectangle`, rounding only the outer corners, pay the horizontal 10 pt on every segment, the top 10 pt on `.first`, the bottom 10 pt on `.last`, and paint the inter-piece inset as wash by applying `topInset` *inside* the background for `.middle` and `.last` (so the `ForEach` applies no outer top padding to those pieces). Multi-piece user messages do not hug: they take the full `dimensions.contentWidth`, so every segment is the same width and the joined shape reads as one bubble. This is a deliberate visual change for long user messages, which are the ones that were tall enough to matter. An injected-only message keeps its no-bubble treatment (`isInjectedOnly`, `ChatMessageRow.swift:45`).
- Assistant pieces of the last message, while `status == .needsInput`, get the attention wash and 1 pt border that `assistantBody` draws around the whole message (`ChatMessageRow.swift:101–109`), including the streaming and working pieces. Same segment scheme for the fill. For the border, a small `Shape` strokes only the edges a segment owns: top and sides for `.first`, sides for `.middle`, bottom and sides for `.last`, all four for `.single`, with the corner arcs on the corners it owns. Put fill and border in one `SegmentedWash(role:segment:)` modifier used by both roles.
- Notice pieces keep `noticeBody`'s vertical 4 pt: on `.single` both, on `.first` top, on `.last` bottom.

Check the joins while a piece animates its height and while the window resizes, not only on settled screenshots; a seam that opens during animation is a real defect.

Delete `ChatMessageRow` once nothing uses it; its preview moves to `ChatPieceView`.

What does not change: `.scrollPosition($position)`, both `defaultScrollAnchor` calls, `onScrollGeometryChange`, `isDetached`, the jump-to-bottom button, `PendingPermissionDock` and `SubagentListView` after the `ForEach`, and the rule that nothing calls `scrollTo` into the stack. `ScrollExercise` (DEBUG, `ChatMessageList.swift:174`) scrolls by message id today; feed it the id of each message's first piece.

### Heights that the ceiling does not bound

Be explicit about what stays tall, so verification can look for it:

- A paragraph or quote over the ceiling (about 1,300 characters at reading width). Rare; stays one piece.
- A table over the ceiling. Stays one piece.
- An expanded `ThinkingRow` or `InjectedContentRow`: unbounded text. `ToolCallRow` already caps each expanded section at 240 pt (`ToolCallRow.swift:62,70,93`); give the other two the same `maxHeight` scroll treatment when expanded if the stats below show them mattering. Collapsed, all three are about 26 pt.
- `ChatImageView` up to 320 pt (`ChatImageView.swift:46`).
- The streaming overlay before phase 4, and the live thinking overlay even after it.

None of these were part of the reproduction, and E1 shows a 2,140 pt item beside 100 pt items is safe, but they are why the item-height stats matter more than the estimates.

### The streaming overlay (phase 4)

A long reply streams into one `StreamingBlocks` view before the transcript commits it, so mid-stream the list can hold one item over 1,000 pt beside 26 pt rows. The hang has only ever been seen on idle threads, so this phase is hardening, and it can land separately. Design: run `MarkdownBlock.parse` on `overlay.text`; every block but the last becomes a settled `.markdown` piece with id `"stream/\(index)"`, run through the same ceiling rule, and the last block is the live `.streaming` piece that `CharacterReveal` paces (`CharacterReveal.swift`), fed the raw source range of that tail block. Parsing is not prefix-stable (a table delimiter line re-reads the paragraph above it as a table), so settled pieces can be reinterpreted while streaming; accept the remount and test the transitions live tail → settled block → committed transcript block, including that the reveal does not restart on a settled block. `ChatStreamHandoff`'s prefix test (`ChatStreamHandoff.swift:45`) is string-based and needs no change. The live thinking text stays one piece.

## Phases

Each phase ends with a clean build, `PlumeTests` green, and a manual run. Commit per phase, single imperative subject, no body.

1. **Model.** `ChatPiece`, `ChatPieceSplitter` including the ceiling and segment splitting, the piece-level inset function in `ChatBlockSpacing`, `ChatPieceCache`. Unit tests, all pure, no UI:
   - A message with N markdown blocks yields the expected pieces and ids; a markdown block with M sub-blocks yields M pieces with sub-indices.
   - Hidden tool calls are omitted, do not advance spacing, and leave the other blocks' ids unchanged.
   - Segments: single-piece and multi-piece messages; trailing streaming and working pieces join the last message's group.
   - A 40-line code block splits into segments that concatenate back to the original; a 20-line one does not; a mermaid fence never does; a 30-item numbered list splits with continuing start numbers; a table never splits.
   - Appending a block to the last message, or a new message, leaves every earlier piece's id unchanged and changes at most the previous last piece's `segment`.
   - A tool result filling in changes that piece's content and nothing else.
   - The inset numbers for the scenarios in `ChatBlockSpacingTests` match what the old functions return; plus user-message 8, notice 6, code segments 0, list segments 4, non-initial heading spacing.
   - The cache reuses pieces for an unchanged message and re-splits a changed one.
2. **Rendering with parity.** `ChatPieceView`, `MarkdownBlockView` (or the index parameter), `SegmentedWash` with its border shape, the code and list segment renderers, `ChatMessageList` switched to pieces, `ChatMessageRow` deleted. Compare before and after on the same transcripts by screenshot (delegate the screenshots to a sub-agent): a short user message, a long user message with a code block, an assistant message with thinking + tool calls + prose, a run of tool-call messages, the needs-input state, a streaming reply, a split code block, a split numbered list. Spacing must match to the point; joined washes must show no seam settled, while animating, and while resizing.
3. **Measurement.** The `PLUME_CHAT_ITEM_STATS` probe below, run on the hang thread and the five largest transcripts on disk. Adjust the ceiling or add the expanded-row caps if the stats say so.
4. **Streaming overlay split.** As above. Defer if phases 1–3 pass verification, and say so in `docs/chat-list-hang.md`.
5. **Verification and docs.** Below. Then update `docs/chat-list-hang.md` ("Fix direction" becomes what landed), the "Chat spacing" and "Chat animation" notes in `docs/roadmap.md` that describe one row per message, and `CLAUDE.md`'s chat-list gotcha if its wording no longer fits.

## Verification

The bug only reproduces by hand, with trackpad momentum on a tall viewport. Ryan runs the momentum tests; the agent prepares the build and the measurements.

- **Positive control.** On `ryanm/chat-hang-diagnosis` the original list hangs within seconds on the hang thread (recorded in the hang doc). That branch is the control and the source of the capture script; it is not merged, and nothing in the fix needs it.
- **Item height stats.** A DEBUG-only probe behind `PLUME_CHAT_ITEM_STATS` measures every realized piece's outer height (the `ForEach` element after its modifiers, via `onGeometryChange`) and logs, per transcript load and once a second while scrolling: piece count, min, max and median measured height, the global max/min ratio over non-zero heights, and the largest ratio within any window of 20 consecutive realized pieces, along with viewport width and the count of expanded rows. It is observational: nothing reads it back into layout. Twenty is a convenience, not SwiftUI's realization span, which the diagnosis leaves unknown; the global ratio is the one to watch. Target: windowed ratio under 15× and global under 25× on the hang thread and the five largest transcripts with all rows collapsed. These are conservative empirical targets from the trials, not a proven threshold.
- **Momentum test.** On the 27" display with the window at full height, the hang thread, real content: two minutes of momentum passes up and down through the region that locked up, with `scripts/detect-chat-hang.sh <seconds> <pid>` watching the main thread. Repeat on the three largest transcripts, once with several tool and thinking rows expanded, and once at the 14" viewport. Pass is the detector never firing, not the absence of a visible freeze.
- **Streaming.** Stream a long reply (`HeadlessSession.debugStream(text:restart:)`, DEBUG) into a visible thread and into a thread whose tab is hidden, then scroll each with momentum. Settled content height must be stable once the stream ends.
- **Behaviour.** Initial open lands at the bottom; jump-to-bottom works; the list follows a streaming reply and stops once the reader scrolls up (`isDetached`); tool-call and thinking rows keep their expanded state while a thread streams; resizing re-wraps without a jump; switching tasks and back keeps the scroll position as today.
- **Cost.** With three or more chats mounted: time from selecting a task to its first presented frame (signpost from the selection change to the first `ChatPieceView` body plus a display-link tick, or a screen recording), task-switch latency between two long threads, scroll responsiveness, and resident memory, before and after. The lazy stack is kept precisely so this stays flat; a regression means the splitter or cache is doing per-load work that is not O(changed blocks).
- **Tests.** `xcodebuild -scheme Plume -destination 'platform=macOS' test -only-testing:PlumeTests`. `ChatBlockSpacingTests`, `ChatStreamHandoffTests`, `RevealPacingTests`, `MarkdownBlockTests`, `MarkdownCacheTests`, `TranscriptParserTests` must pass unchanged. Confirm the new suites' names appear in the output; a `-only-testing` filter that matches nothing prints success.

## Constraints and gotchas

- Never call `scrollTo` into the lazy stack and never write `@Observable` state during `body` (both in `CLAUDE.md`, both learned the hard way).
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: model types that tests and background code touch should be `nonisolated` like `ChatMessage`; test suites that touch views need `@MainActor`.
- Identity, not value equality, keeps view state alive across `TranscriptStore`'s wholesale replacement. Ids are deterministic from message id and original block index; never derive them from array positions after filtering.
- The height estimate only decides splitting. Do not measure text to improve it and never feed measured heights back into the splitter: a model that depends on layout results is the feedback loop this plan exists to remove.
- Keep comments to the why. The rationale for pieces belongs in this document and one paragraph at the `ChatPieceSplitter` definition, not at call sites.
- Commit messages: single imperative subject, under 50 characters, no body.

## Second opinion

Astra (the codex MCP's default model, medium effort) reviewed the first draft. Changes made in response:

- Dropped the packer. Its floor and ceiling rules could not both hold (a 26 pt piece before a 588 pt one has to violate one of them), and an item keyed by its first piece loses the `@State` of every piece that moves to a different parent when packing shifts. One lazy item per piece, the design E4 tested, has neither problem.
- Set the ceiling to 300 pt, the value E2 tested, and made the estimate's only job deciding whether to split.
- Tables are no longer split (independent column sizing), mermaid fences are never split, and code segments each own a horizontal scroll view, stated as an accepted cost with a threshold that keeps it rare.
- Added the missing parity rules: non-initial heading spacing when a markdown view renders a single block, 8 pt within user messages and 6 pt within notices, 4 pt between list segments; corrected the `isPendingBlock` claim to the last original block.
- Moved model building out of `body` into an `onChange`-driven cache, because eager splitting through `MarkdownCache` during body evaluation would churn its 512-entry cache and parse on the render path.
- Made real height measurement mandatory, with a global ratio alongside the windowed one, and listed the heights the ceiling does not bound.
- Folded oversized splitting into phase 1 and made phase 3 measurement; added the streaming, expanded-row and viewport cases to verification; noted that parsing is not prefix-stable for phase 4.
- Kept as future options rather than adopting: a small actual minimum height on the shortest rows (E1 evidence) if the stats show the small side matters.

## Changed while building

- **Code blocks are not split.** A block over the ceiling stays one piece and scrolls vertically inside itself, bounded at 300 pt by `CodeSegmentView`. Splitting cost the reader a continuous scroll through the block and gave each segment its own horizontal scroll view; bounding costs neither. `CodeSegment` therefore carries no position or full text — every one is whole.
- **A list splits as soon as it is over the ceiling**, with no "worth it" threshold, because its segments join at the gap its items already have. `listChunks` makes them equal length so a list just over the ceiling does not end on one item.
- **The measurement in phase 3 was a one-off.** It ran, the numbers are in `docs/chat-list-hang.md`, and it is not a recurring test — see the note above that table before spending 18 minutes on it again.
- **A block that draws nothing takes no item** — a tool call the pending dock has taken over, a thinking block with no text — which removed an 8 pt row from the short side.
