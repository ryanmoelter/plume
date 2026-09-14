# Text polish: chat code chips + true WYSIWYG composer

title: Text polish: chat code chips + true WYSIWYG composer
date: 2026-09-14
project: plume
branch: text-polish
slug: text-polish
status: Active

## Context / Goal

Typing and reading are Plume's two main actions. Inline `code` in the chat was a flat background rectangle, and the composer was WYSIWYM (raw markdown styled in place). Ryan decided: rounded, padded code chips in the chat; the composer becomes a **true WYSIWYG** markdown editor with markers hidden (Typora-style), bullets always shown, and **no escaping of literal markdown characters** on send (the message goes to an LLM). Undo/redo of plain typing is a first-class deliverable; it did not work before because `allowsUndo` was never set.

## Plan

Two parts. Part 1: a SwiftUI `TextRenderer` draws chips behind code runs of concatenated `Text` pieces, padding via `kern` on the neighboring characters, applied only to blocks that contain code. Part 2: the composer's TextKit 2 `NSTextStorage` is the model, carrying `.plumeBlock` / `.plumeInline` / `.plumeLink` attributes; a pure `nonisolated` layer converts markdown to and from it; input rules convert markdown shortcuts as typed; `NSTextList` renders list markers; decorations draw from `drawBackground(in:)`; a TextKit 2 measurer sizes the field. The full plan, with the architecture decisions, Astra's review and the spike results, is inlined at the end of this file.

## Done

- Worktree `.worktrees/text-polish`, branch `text-polish`. Everything below is committed on it as a WIP commit.
- W1 chat chips: `CodeChipTextRenderer.swift`, `MarkdownCache.styledInline` returns `StyledInline`, five `MarkdownBlockView` call sites; tests green.
- W2 model: `Plume/UI/Chat/Composer/` `ComposerAttributes`, `ComposerTextStyle`, `ComposerDocument`, `ComposerInlineMarkdown`, `ComposerDocumentInvariants`; long fences in `MarkdownBlock`; round-trip corpus tests.
- W3 rules: `ComposerInputRules`, `ComposerListEditing` (75 tests).
- W5 drawing and measurement: `ComposerDecorations`, `ComposerHeightMeasurer`, `ComposerLists`; `ComposerNSTextView.style`, `documentRevision`.
- W4 integration: `ComposerTextViewEditing`, `ComposerParagraphStyles`, `ComposerPasteboard`, rewritten `MarkdownComposerTextView`, `ChatComposer`, `ChatTabView` feedback field, `DraftStore` attributed snapshot, `ComposerCodeRanges` by attribute, `ComposerUndoTests` (17). Old `MarkdownHighlighter` / `MarkdownComposerStyler` deleted. Full unit suite was green here (1526 passed; the one failure is the documented environmental `SessionJSONLReaderTests` case).
- W6 docs: `docs/composer.md`, CLAUDE.md "Composer" section and chip gotcha.
- Independent code review found 8 issues; a fix agent applied all 8 plus two dedupes (see Remaining for the unverified state).

## Remaining

- [ ] **Verify the review-fix pass.** The fix agent was stopped right before its full-suite run, so its edits are unverified. Build, run the full `PlumeTests` suite, and check the new `ComposerSlashAcceptanceTests` plus the tests it added for: edited verbatim block serializes what is on screen; `---\n\n---` round-trips as two rules; `3. three` renders `3.` (`NSTextList.startingItemNumber`) and `renumber` resets across an interrupting bullet; composer chips carry `kern` on the neighboring characters; `loadDocument` clears only this view's undo (`removeAllActions(withTarget:)`); slash acceptance applied twice yields one trailing space; `**\`x\`**` gets a chip; `tint` dropped from the `StyledInline` cache key.
- [ ] Manual run of the Debug app: type `` `code` `` and confirm the chip no longer covers the preceding character; `3. three`, Return, `four` reads 3. and 4.; then the "verifying by hand" checklist in `docs/composer.md`.
- [ ] Not yet exercised by hand: ⌥⇧⌘V paste-as-markdown, IME composition, dictation, VoiceOver, a live send to an agent and reading the transcript rendering of every construct.
- [ ] Review-suggested follow-ups left alone on purpose: unify the four paragraph walks (`ComposerDocument.paragraphs`, `ComposerDocumentInvariants`, `ComposerParagraphStyles.apply`, `ComposerDecorations.blockRects`); reconcile `ComposerDocument.plainTextIsSendable` with `ChatComposer.sendableText`.
- [ ] Squash or tidy the WIP commit, write the MR description (`create-mr` skill; forge is GitLab), open the MR.

## Key files touched

- `Plume/UI/Chat/CodeChipTextRenderer.swift` — `CodeChipAttribute` + `CodeChipRenderer`; `.codeChips(_:fill:)` applies the renderer only when a block has code.
- `Plume/UI/Chat/MarkdownCache.swift` — `styledInline` returns `StyledInline` segments with chip ids and kern; `uppercased()` for headings.
- `Plume/UI/Chat/MarkdownBlockView.swift` — all five inline sites build `Text` from `StyledInline`.
- `Plume/UI/Chat/Composer/*` — the composer model, rules, drawing, measurement, editing layer, pasteboard.
- `Plume/UI/Chat/MarkdownComposerTextView.swift` — representable, coordinator, `ComposerNSTextView`, `ScrollableComposerTextView`; the bound `String` is now markdown.
- `Plume/UI/Chat/ChatComposer.swift`, `ChatTabView.swift` — autocomplete on visible text, in-view slash acceptance deferred a turn, `hasSendableText` from the document.
- `Plume/Models/DraftStore.swift` — in-memory attributed snapshot per tab beside the markdown draft.
- `Plume/UI/Chat/MarkdownBlock.swift`, `MarkdownSource.swift` — fences longer than three backticks; `nonisolated`.
- `Plume/UI/Chat/SlashCommandMatcher.swift` — `accepting` returns the replaced range too.
- `docs/composer.md`, `CLAUDE.md` — the reference and its pointer.

## Gotchas / Notes

- **Overriding `draw(_:)` on an `NSTextView` silently drops it to TextKit 1** (`textLayoutManager` becomes nil, no error). The composer had been TextKit 1 all along because of the placeholder's `draw(_:)`. Decorations and the placeholder draw from `drawBackground(in:)`. Reading `layoutManager` forces the same fallback. Do not subclass `NSTextView` with an `init(frame:)` override either (stack overflow).
- `breakUndoCoalescing()` alone does not split an undo event group; `asStepAfterTheInsertion` in `ComposerTextViewEditing` closes and reopens the group so ⌘Z after `- ` restores the literal text.
- A character-less last line cannot carry `.plumeBlock`; its kind lives in `stickyKind` on the view.
- Editing the document inside `updateNSView` crashed SwiftUI (`NSWindow._postWindowNeedsUpdateConstraints`); slash acceptance is deferred a turn and now guarded against a second update pass and a gone window.
- AppKit's own list handling (`insertNewline:` copies the list and inserts two newlines at document end, `insertTab:` demotes with a `.hyphen` list) is overridden in list paragraphs.
- `SessionJSONLReaderTests.encodingResolvesADirectoryClaudeCodeHasUsed` fails in any worktree; environmental, documented in CLAUDE.md.
- Another agent may be running debug builds from a sibling worktree; DerivedData is per path, but `Plume.debug/` app-support is shared, so never wipe the debug store.
- The Sonnet/Opus session limit interrupted two agents once; relaunching with the same prompt was enough.
- Astra (codex, medium effort) reviewed the plan; what it changed is recorded at the end of the plan below.

## How to resume

```
cd <repo>/.worktrees/text-polish   # or `wt co text-polish --no-tab` on a fresh machine, then `wt path text-polish`
xcodebuild -scheme Plume -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD" | tail
xcodebuild -scheme Plume -destination 'platform=macOS' test -only-testing:PlumeTests 2>&1 | grep -E "Test Suite '.*' (passed|failed)|Executed|failed" | tail -40
```

Then the manual checks in Remaining and `docs/composer.md`, then `create-mr`.

---

## Plan file (inlined verbatim from `~/.claude/plans/i-want-to-polish-splendid-wreath.md`)

# Text experience polish: chat code chips + true WYSIWYG composer

## Context

Typing and reading are the two main actions in Plume. Today inline `code` in the chat is a flat `backgroundColor` rectangle with no corners or padding, and the composer is WYSIWYM: raw markdown stays in the text with markers dimmed, so lists have no real bullets, code blocks have no bounds, and nothing reads like the rendered message will.

The user decided (asked, answered):
- Composer goes to **true WYSIWYG, markers hidden** (Typora-style). Not the live-preview hybrid.
- List bullets **always** show; no raw-marker reveal on the caret line.
- Serialization policy: the message goes to an LLM, not a renderer, so **never escape** literal markdown characters the user typed (`~/.claude/*.json`, `foo_bar` go verbatim). Emit markers only for formatting actually applied. Round-trip preserves intentional formatting, not bijection.
- All work in a new worktree (`wt`); delegate liberally; another agent runs debug builds concurrently from a sibling worktree.

## Verified facts

- Composer `NSTextView()` is **TextKit 2** at runtime (`textLayoutManager != nil`; nothing touches `.layoutManager`). The measuring stack in `ScrollableComposerTextView` is a separate TextKit 1 `NSLayoutManager`.
- The macOS 26 SDK documents `NSTextList.includesTextListMarkers` as **false by default**: TextKit 2 generates list markers without marker characters in storage (Astra, confident; S1 still verifies editing behavior).
- SwiftUI on the 26.2 SDK: `TextRenderer.draw(layout:in:)`, `Text.customAttribute(_: TextAttribute)`, `Text.Layout.Run[T.Type]`, `typographicBounds`, `characterIndices`. `Text + Text` concatenation carries per-piece custom attributes. SwiftUI `AttributedString` scope has `kern`.
- No markdown library. Block parser `MarkdownBlock.parse` / `parseWithSources` (`Plume/UI/Chat/MarkdownBlock.swift`), block serializer `MarkdownSource.markdown(of:)` (`Plume/UI/Chat/MarkdownSource.swift`), inline via Foundation `AttributedString(markdown:)`. `MarkdownBlock` has no verbatim case; `fenceMarker` recognizes only a three-character fence and treats extra backticks as the language, and closing detection accepts the shorter prefix.
- Two consumers of `MarkdownComposerTextView`: `ChatComposer` and `ChatTabView.feedbackField` (plan rejection, ⌥↩). Both get WYSIWYG.
- `SlashCommandMatcher.query` only matches the document's first token. `ComposerAutocompleteController.update(text:caretLocation:commands:)` is fed the draft string plus the text view's caret.
- `MarkdownBlockView` builds inline text at five sites: paragraph (:38), quote (:63), table cell (:154), heading (:211, which rebuilds the string run by run to uppercase h5/h6), list item (:275).

## Part 1: chat inline-code chips (independent workstream)

Rounded corners plus horizontal padding on inline code in the transcript, with no padding character in the text (`styledInlineCodeCopiesExactlyWithNoThinSpaces` in `PlumeTests/MarkdownCacheTests.swift` stays unchanged as the contract).

- New `Plume/UI/Chat/CodeChipTextRenderer.swift`: `CodeChipAttribute: TextAttribute { id: Int }` and a `TextRenderer`. For each line, coalesce the runs sharing a chip id into **one rect per line** (a chip may contain several font runs), extend the first run of the chip by `pad` on the leading edge, use layout rects rather than assumed baseline math for the vertical extent plus `vpad`, fill a `RoundedRectangle(cornerRadius: 4)`, then `ctx.draw(line)` for every line. A wrapped span becomes one chip per line; continuation lines get no reserved leading padding, and the leading gap from a preceding-character kern may land on the previous line. Both are accepted.
- `MarkdownCache.styledInline` returns `StyledInline { segments: [(AttributedString, chipID: Int?)], hasCode: Bool }`, cached on the same `(text, fontSize, tint)` key. Padding via `kern = pad` on the character before the span and on the span's last character.
- A `StyledInline.text()` helper builds `Text(prose) + Text(code).customAttribute(CodeChipAttribute(id:))`. All five `MarkdownBlockView` call sites use it and apply `.textRenderer` **only when `hasCode`**, so untouched paragraphs keep the plain `Text` scroll path. The heading site's uppercasing must operate per segment so the chip attribute survives. Do not change chat item structure (`docs/chat-list-hang.md`).
- Tests: rewrite the two `backgroundColor` assertions in `MarkdownCacheTests` against segments; add one asserting the concatenated characters equal the input; add one for an uppercased heading keeping its chip segment; keep the perf test. Manually test clipping and overlap at narrow widths and at the smallest and largest chat font sizes.

## Part 2: composer WYSIWYG

### Architecture decisions

1. **The text storage is the model.** Custom `NSAttributedString.Key`s: `.plumeBlock` (one value per paragraph: `paragraph | heading(Int) | bullet(depth:) | numbered(depth:number:) | quote | codeBlock(language:) | verbatim(source:)`) and `.plumeInline` (`OptionSet`: bold, italic, code) plus `.plumeLink: URL`. Values are immutable structs so they copy cleanly through undo snapshots. `verbatim` carries the original source lines of what the composer can't edit structurally (tables, rules), taken from `parseWithSources`, and serializes back unchanged, bypassing `MarkdownSource`'s table normalization.
   **Structural invariants** (write them in `docs/composer.md` and enforce in one `ComposerDocumentInvariants` helper): a paragraph owns its trailing newline; an empty document and the zero-length paragraph after a trailing newline take the kind of the previous paragraph's continuation rule (a list item continues, everything else becomes `paragraph`); splitting a paragraph copies its kind to both halves except where a list-editing rule says otherwise; merging keeps the first paragraph's kind; a replacement spanning paragraphs re-normalizes every touched paragraph; adjacent `codeBlock` paragraphs form one block only when they share a `blockID` (a UUID in the attribute value), so two blocks with the same language never merge by accident.
2. **Typing attributes are normalized in one place**: `textView(_:shouldChangeTypingAttributes:toAttributes:)` in the coordinator, covering selection changes as well as edits. Rules: bold/italic extend at their trailing edge; inline code does **not** (after a closing-backtick conversion and at a chip's trailing edge, typing is plain; extend a chip by typing inside it); links never extend; a new paragraph after a heading is `paragraph`; Enter inside `codeBlock` stays in the block; `kern` and other decorative attributes never enter typing attributes.
3. **Builder and serializer are pure and `nonisolated`.** Markdown → attributed uses `MarkdownBlock.parseWithSources` for blocks and Foundation inline parsing per paragraph, list item, heading and quote line. Attributed → markdown: **inline serialization runs first** per paragraph (run walk emitting `**`, `*`, `` ` `` with a delimiter longer than any backtick run inside the span, `[t](u)`, no escaping, adjacent runs coalesced, nested-style transitions closed in the right order), producing `MarkdownBlock` values whose text fields hold inline markdown, then `MarkdownSource.markdown(of:)` for the block layer. Code block content bypasses inline serialization. `MarkdownBlock.fenceMarker` and the closing-fence check gain support for fences longer than three backticks so `MarkdownSource`'s longer-fence choice round-trips. Block separator: one blank line between blocks; blank-line counts, list continuation paragraphs and original numbering are not preserved, and the doc says so.
4. **Attributed draft survives unmount.** Because literals are never escaped, a pasted literal `**hello**` would come back bold after a tab switch reparsed the markdown draft. `DraftStore` gains an in-memory attributed snapshot per tab (plus the typing-attribute state) next to the markdown it already keeps; the composer restores from the snapshot when one exists and parses markdown only when there is none (persisted draft, queued-message recall). Markdown remains what is sent and persisted.
5. **List markers: `NSTextList` is primary.** Each list paragraph's `NSParagraphStyle.textLists` holds the enclosing lists outermost-first, sharing one `NSTextList` object per logical list so numbering is continuous; marker formats `.disc`/`.circle`/`.square` by depth and `.decimal`. **Plume owns** continuation, renumbering, indent and outdent through the list-editing rules; S1 verifies AppKit's own list handling on Enter/Tab does not also act (and how to suppress it if it does), plus indentation, empty items, nesting, selection and deletion across items. Fallback if S1 fails: `.plumeBlock` list kinds set `firstLineHeadIndent`/`headIndent` and `draw(_:)` paints the glyph in a marker column measured from the widest number actually present, with an accessibility label for the marker.
6. **`isRichText = true`**, with the affordances disabled: `usesFontPanel`, `usesRuler`, `isRulerVisible`, `usesInspectorBar`, `importsGraphics`, `allowsImageEditing`, `isAutomaticTextCompletionEnabled` all false. `allowsUndo` stays true. Every formatting route AppKit opens is either handled or refused: ⌘B/⌘I go through Plume's toggles (override `changeFont`/`toggleBold` paths and menu validation) and update `.plumeInline`; drag-and-drop and Services insert plain text; contextual formatting menu items are removed. **Pasteboard contract**: copy/cut write the visible plain text as `.string` plus a private type carrying the attributed slice; paste prefers the private type, otherwise inserts the string **literally** inheriting the current paragraph kind and inline context, stripping decorative attributes. `pasteAsMarkdown` on ⌥⇧⌘V parses.
7. **Input rules in `ComposerNSTextView` overrides** (`insertText(_:replacementRange:)`, `doCommand(by:)` for `insertNewline:`, `insertTab:`, `insertBacktab:`, `deleteBackward:`), each asking a pure rule module for an `Edit`. Rules: `- `, `* `, `1. ` at line start; `#`..`######` + space; `> `; ``` alone on a line; closing `**`/`*`/`_`/`` ` ``; `[t](u)` on `)`. Nothing fires inside `codeBlock`.
   **Transaction design**: the typed text is inserted normally first (so the literal intermediate state exists), then the conversion runs as a **separate undoable edit** through `shouldChangeText(in:replacementString:)` → replacement → `didChangeText()` with undo coalescing broken around it and the selection restored; ⌘Z restores the literal characters including the closing delimiter, ⌘⇧Z redoes the conversion. `insertText` receives committed IME text, dictation and attributed input with replacement ranges: respect `NSNotFound`, and **skip every rule while `hasMarkedText()`**. `keyDown` gains a first guard, `if hasMarkedText() { super.keyDown; return }`, so Return and arrows reach the input method before send or autocomplete interception; the rest of `keyDown` keeps its shape.
8. **Decorations drawn in `draw(_:)` before `super`**: inline chips via `textLayoutManager.enumerateTextSegments(in:type:.standard, options:.rangeNotRequired)`, code boxes and quote bars via `enumerateTextLayoutFragments` + `layoutFragmentFrame`, offset by `textContainerOrigin`. A code box spans the **full container width** across the paragraphs sharing a `blockID`; inner padding from `firstLineHeadIndent`/`headIndent`, with `paragraphSpacingBefore` only on the block's first paragraph and `paragraphSpacing` only on its last. Chip padding via `.kern` like Part 1. Colors keep the dynamic `NSColor(name:)` pattern from `MarkdownComposerStyler.codeBackgroundColor`. Invalidate on `didChangeText`, selection change, and the clip view's bounds change. S1 fallback if TextKit 2 draws glyphs above the view's own drawing: a `ComposerDecorationView` subview at index 0 with `layer.zPosition = -1`.
9. **Measurement switches to TextKit 2** (`NSTextContentStorage` + `NSTextLayoutManager` + `NSTextContainer`) mirroring the live container's padding, insets and list configuration; height is max `layoutFragmentFrame.maxY` after `ensureLayout(for: documentRange)`, covering the empty document and the trailing insertion line. The container's width is set explicitly before measuring. Cache key: `(width, fontSize, insets, documentRevision)`. `documentRevision` is bumped from the storage's `NSTextStorageDelegate.textStorage(_:didProcessEditing:range:changeInLength:)` so attribute-only edits and undo/redo count. The same revision keys the coordinator's spell-check code-range cache, which is string-keyed today.
10. **Binding and autocomplete.** The bound `String` becomes **markdown**. `textDidChange` serializes and writes it to the binding. `updateNSView` rebuilds the document only when the incoming text differs from `lastEmittedMarkdown` **or** a `resetGeneration` counter (bumped by the caller for an explicit reload with equal markdown) changed; font-size and command-tint changes restyle in place without a rebuild; an external load places the caret at the end and clears the undo stack. **Autocomplete gets the visible text**: `onTextChange` and `onCaretChange` both pass `textView.string` (the plain text with no marker characters, which is the coordinate space of the caret) to `ComposerAutocompleteController.update`, never the markdown draft. Accepting a slash command is an **attributed-range edit inside the text view** (replace the leading `/token` with `/name `, keeping surrounding formatting and undo) instead of writing a new string through the binding and reparsing; `SlashCommandMatcher.accepting` supplies the replacement text and caret and the view applies it. Since the matcher only reads the first token, the composer's first paragraph is where commands live, same as today.
11. **Sendability from semantic content.** `hasSendableText` is derived from the document (non-whitespace characters in any paragraph), not from the markdown string, because an empty heading or an empty list item serializes to a non-empty string. It is initialized from the restored draft, which it is not today. `ChatTabView.feedbackField` gets the same rule for its rejection label and keeps ⌥↩.
12. **Spell check skips code by attribute.** `ComposerCodeRanges.codeRanges(in:)` reads `.plumeInline.code` and `.plumeBlock == .codeBlock` runs from the storage instead of parsing markdown; the range algebra and those tests stay. Applying code to a range clears its existing spelling marks; removing code re-requests checking for the range.
13. **Deletions.** `MarkdownHighlighter.swift`, `MarkdownComposerStyler.swift`, `MarkdownHighlighterTests.swift` go; the markdown-parsing cases in `ComposerCodeRangesTests` go. Rewrite the `MarkdownComposerTextView` doc comment (it promises WYSIWYM). Add `docs/composer.md`: attribute vocabulary and invariants, typing-attribute rules, input-rule table, transaction and undo design, pasteboard contract, serialization policy and what round-trip does not preserve, decoration contract, revision-keyed measurement. Link it from CLAUDE.md.

14. **Undo and redo of plain typing is a deliverable, not a side effect.** Today `allowsUndo` is never set on the composer's `NSTextView`, so ⌘Z does nothing after an accidental deletion. Set `allowsUndo = true` in `ScrollableComposerTextView.setUp()`; every programmatic change (input-rule conversions, list edits, ⌘B/⌘I, slash-command acceptance, paste) goes through `shouldChangeText`/`didChangeText` so it lands on the same stack; attribute normalization (`ComposerDocumentInvariants`, typing-attribute fixups) runs from the storage delegate's `didProcessEditing` and registers nothing of its own, and it re-normalizes whatever undo restores. Nothing on the keystroke path may call `textView.string =`, `setAttributedString`, or `breakUndoCoalescing()` except the explicit external reload in decision 10, which clears the stack on purpose. The app's Edit menu already carries the standard Undo/Redo items (SwiftUI's default command groups; `PlumeCommands` does not replace `.undoRedo`), so ⌘Z/⌘⇧Z reach the first responder. Tests: a `ComposerUndoTests` suite driving a real `ComposerNSTextView` off-screen: type, delete a word, ⌘Z restores it, ⌘⇧Z removes it again; type `- item`, undo restores `- item` literally, redo converts; undo across a list continuation. Manual: type a paragraph, select all, delete, ⌘Z.

### New files (`Plume/UI/Chat/Composer/`)

| File | Responsibility |
|---|---|
| `ComposerAttributes.swift` | The keys, `ComposerBlockKind` (with `blockID`, `verbatim(source:)`), `ComposerInlineStyle`. |
| `ComposerDocumentInvariants.swift` | Paragraph-kind normalization after any edit (decision 1). |
| `ComposerTextStyle.swift` | Pure font/metric resolution from a font size: body, heading ladder (mirror `MarkdownBlockView.headingStyle`), mono, list styles, code padding, chip radius, colors. |
| `ComposerDocument.swift` | `nonisolated` markdown ↔ `NSAttributedString`. |
| `ComposerInlineMarkdown.swift` | `nonisolated` inline parse into attributes and run-walk serialization. |
| `ComposerInputRules.swift` | `nonisolated` (paragraph text, kind, caret, inserted string) → `Edit?`. |
| `ComposerListEditing.swift` | `nonisolated` Enter / Tab / Shift-Tab / Backspace transforms. |
| `ComposerPasteboard.swift` | The private pasteboard type and copy/paste conversions. |
| `ComposerDecorations.swift` | Layout geometry → rects to paint. |
| `ComposerHeightMeasurer.swift` | TextKit 2 measuring stack, revision-keyed. |
| `Plume/UI/Chat/CodeChipTextRenderer.swift` | Part 1's attribute and renderer. |
| `docs/composer.md` | Reference doc. |

Also touched: `MarkdownBlock.swift` (long fences), `DraftStore.swift` (attributed snapshot), `ComposerCodeRanges.swift`, `ChatComposer.swift`, `ChatTabView.swift`, `MarkdownComposerTextView.swift`, `MarkdownCache.swift`, `MarkdownBlockView.swift`.

## Workstreams

Step 0: create the worktree with the `worktrees` skill (`wt`), and do everything inside it. `xcodebuild` keys DerivedData by path, so builds do not collide with the sibling agent's; the debug app-support dir `Plume.debug/` is shared, so never wipe the store.

| Stream | Scope | Depends on | Size | Model |
|---|---|---|---|---|
| S1 spike | Throwaway `swiftc` program under /tmp: TextKit 2 `NSTextView`, `isRichText = true`, nested paragraphs with shared `NSTextList`s and no marker chars. Verify: markers render; hanging indent; empty item; Enter/Tab default behavior (does AppKit continue lists on its own?); selection and deletion across items; a `draw(_:)`-before-super fill lands behind glyphs. | none | narrow, deep | opus |
| S2 spike | Scratch SwiftUI view: `Text(a) + Text(b).customAttribute(...)`, `.textRenderer`, `.textSelection(.enabled)`; selection works; `run[Attr.self]` resolves; wrapped spans; `kern` on the last glyph lands inside `typographicBounds.width`; behavior at narrow widths. | none | narrow, deep | opus |
| W1 chat chips | Part 1 in full, including tests. | S2 | medium | sonnet after S2 fixes the rect math |
| W2 model + serialization | `ComposerAttributes`, `ComposerDocumentInvariants`, `ComposerTextStyle`, `ComposerDocument`, `ComposerInlineMarkdown`, `MarkdownBlock` long fences, round-trip corpus tests. | none | wide, mechanical once keys are fixed | sonnet |
| W3 input rules + list editing | `ComposerInputRules`, `ComposerListEditing`, exhaustive tests. | W2 types | wide | sonnet |
| W4 text view integration | Decisions 2, 4, 6, 7, 10, 11, 12, 14: rich-text flip and disable list, typing-attribute delegate, `insertText`/`doCommand` wiring with the two-step undo transaction, IME guards, pasteboard, ⌘B/⌘I, spell check by attribute, binding and autocomplete rewiring, `DraftStore` snapshot, feedback field. Owns `keyDown`/`insertText`/the coordinator/`ChatComposer`. | W2, W3 | deep | opus |
| W5 drawing + measurement | `ComposerDecorations`, `ComposerHeightMeasurer`, `NSTextList` styling per S1. Owns `draw(_:)` and `ScrollableComposerTextView`. | W2, S1 | deep | opus, parallel with W4 |
| W6 cleanup | Deletions, doc comment, `docs/composer.md`, CLAUDE.md link. | W4, W5 | mechanical | sonnet |

## Tests

- `ComposerDocumentTests`: parameterized round-trip corpus (~30 cases): plain paragraph; `foo_bar`; `~/.claude/*.json`; `a * b`; a literal backslash; bold; italic; bold-in-italic; inline code containing a backtick (longer delimiter); link; h1–h6; bullets 3 deep; numbered list nested in bullets; quote with two lines; fenced block with a language; fenced block containing ``` (four-backtick fence); table (verbatim, byte-identical); `---`; trailing blank lines; empty. Formatting cases assert `markdown(attributed(x)) == x`; literal cases assert the exact substring appears unchanged.
- `ComposerInlineMarkdownTests`: existing literal backslashes survive; adjacent runs coalesce (`**ab**`, not `**a****b**`); nested transitions close in order.
- `ComposerDocumentInvariantsTests`: empty document, trailing newline, split and merge, cross-paragraph replacement, two same-language code blocks stay separate.
- `ComposerInputRulesTests`: each rule fires at line start only; `1. ` at depth; ``` alone on a line; closing `**` converts only against an unconsumed opener in the same paragraph; `[t](u)` on `)`; nothing fires inside `codeBlock`.
- `ComposerListEditingTests`: Enter continues and increments; Enter on an empty item exits to `paragraph` at depth 0; Tab clamps at parent depth + 1; Shift-Tab at depth 0 is a no-op; Backspace at item start demotes then removes.
- `ComposerHeightMeasurerTests`: a heading measures taller than the same string as a paragraph; an attribute-only edit changes the revision.
- `ComposerCodeRangesTests`: keep the algebra, re-point the source cases at an attributed fixture.
- `MarkdownCacheTests`: as in Part 1.

Run with `xcodebuild -scheme Plume -destination 'platform=macOS' test -only-testing:PlumeTests` and confirm the new suite names appear in the output (a name that matches nothing still prints `TEST SUCCEEDED`).

## Manual verification (delegate to a sub-agent; no screenshots in the main thread)

Type each shortcut and watch it convert; ⌘Z right after each conversion restores the literal text including the closing delimiter, ⌘⇧Z redoes it. Enter through a 3-deep list, Tab and Shift-Tab across it. Caret on a bullet line: the glyph stays. Type a fenced block: the box is full width and the composer grows without jitter. ⌘B mid-word, then ⌘Z. Paste a shell command with `*` and `_`: stays literal; paste literal `**x**`, switch tabs and back: still literal. Copy a bold range and paste it into the composer (stays bold) and into TextEdit (plain). Compose with a Japanese input method through a list item and press Return mid-composition. Dictate a sentence. ↑ recall a queued message containing a list. Type `/` at the start and drive autocomplete with arrows and Tab; accept a command inside a document that already has formatting below it. Misspell inside and outside a chip. Toggle appearance with a code block on screen. An empty heading must not enable Send. Reject a plan through the feedback field with a bulleted reason and ⌥↩. VoiceOver reads a list item. In the chat, drag-select across a chip and copy: no padding characters. Send a message with every construct and read the transcript's rendering of it.

## Risks

| Risk | Cheapest check |
|---|---|
| `TextRenderer` breaks `.textSelection(.enabled)` | S2. Fallback: keep `backgroundColor`, defer Part 1. |
| AppKit's own list editing acts alongside Plume's | S1. Suppress its `insertNewline`/`insertTab` list handling or take the custom-marker fallback. |
| TextKit 2 draws glyphs above `draw(_:)` output | S1. Fallback: `ComposerDecorationView` at `zPosition = -1`. |
| Decorations lag during scroll or typing | Observe clip-view bounds and `didChangeText`; if it tears, drive from `NSTextViewportLayoutController` delegate callbacks. |
| Height jitter from TextKit 2 wrapping or the revision key | The heading-vs-paragraph test plus typing a long wrapped list. `ensureLayout` is still a full pass per edit; watch typing latency. |
| Binding echo rebuilds the document per keystroke | Decision 10; type fast and check selection and ⌘Z. |
| Plain-typing undo silently broken by a restyle pass on the keystroke path | `ComposerUndoTests` plus decision 14's ban list; grep the final diff for `string =` and `setAttributedString` on the keystroke path. |
| Undo restores formatted rather than literal text | The two-step transaction in decision 7; ⌘Z and ⌘⇧Z after each of the ten conversions. |
| Rich-text routes bypass `.plumeInline` | Decision 6's handled-or-refused list; try the Format menu and the font panel shortcut. |


## Progress (Sep 13 2026)

- S1, S2, W1, W2, W3, W5 done in the worktree `.worktrees/text-polish` (branch `text-polish`), nothing committed yet.
- S2: `TextRenderer` keeps selection and copy intact, does not change measured size; leading kern lands before the chip run, trailing kern inside it.
- W5 finding (now a CLAUDE.md gotcha): a `draw(_:)` override on `NSTextView` silently drops it to TextKit 1; decorations and the placeholder draw from `drawBackground(in:)`. `NSTextView` subclasses must not override `init(frame:)`.
- W4 (integration) running; W6 (cleanup + `docs/composer.md`) after it.

## S1 results (Sep 13 2026, macOS 26.6.2)

- `NSTextList` markers render with zero marker characters in storage; nesting via `textLists = [outer, inner]`; decimal continuity keys off the shared `NSTextList` instance. Indent comes from the list: leave `headIndent`/`firstLineHeadIndent` at 0 for list paragraphs.
- AppKit's own `insertNewline:` copies the paragraph style (same list instance) into the new paragraph and, at document end, inserts **two** newlines; `insertTab:` demotes by appending a `.hyphen` list and rewriting `headIndent` to 72; `insertBacktab:` promotes and rewrites indents; `deleteBackward:` at item start just joins paragraphs. Plume overrides all four in list paragraphs and never calls `super` for them there.
- Filling before `super.draw(_:)` keeps glyphs on top, layer-backed and scrolled alike. `enumerateTextSegments` frames are in container space including `lineFragmentPadding`; add `textContainerOrigin`.
- Attribute writes inside `textStorage(_:didProcessEditing:...)` register no undo action and do not break typing coalescing.

## Astra review (medium effort, Sep 13 2026)

What it changed: `NSTextList` promoted to primary (SDK documents `includesTextListMarkers` false by default); attributed draft snapshot in `DraftStore` so unescaped literals survive a tab switch; explicit structural invariants and a single typing-attributes seam; inline-before-block serialization with `parseWithSources` for verbatim blocks and long-fence support in `MarkdownBlock`; two-step undoable conversion and IME guards; autocomplete fed visible text and slash-command acceptance as an in-view edit; pasteboard contract; per-line chip coalescing and the quote call site; revision from the storage delegate, keyed with insets; semantic sendability; spelling-mark refresh. Dropped: the "never emits a backslash" test (wrong contract) and the "slash command on a second bullet line" manual test (the matcher reads only the first token).
