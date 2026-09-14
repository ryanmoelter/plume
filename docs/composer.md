# The WYSIWYG composer

The chat composer is a true WYSIWYG markdown editor: `MarkdownComposerTextView` wraps an `NSTextView` subclass, `ComposerNSTextView`, because nothing in SwiftUI edits styled ranges of its own text. Typing `- ` turns into a bullet, `**bold**` turns bold, and the markers themselves never sit in the text the user sees — the same Typora/Notion-style editing model, built entirely on `NSAttributedString`.

Read this before touching anything under `Plume/UI/Chat/Composer/`, `Plume/UI/Chat/MarkdownComposerTextView.swift`, or `Plume/UI/Chat/CodeChipTextRenderer.swift`.

## The model

`NSTextStorage` **is** the document. There is no separate model object — every fact about the document's structure lives as an attribute on some range of the storage. Three keys, all defined in `ComposerAttributes.swift`, carry it:

- **`.plumeBlock`** — a `ComposerBlockKind`, covering the paragraph's full range including its trailing newline. Its `Kind` enum is `.paragraph`, `.heading(level:)`, `.bullet(depth:)`, `.numbered(depth:number:)`, `.quote`, `.codeBlock(language:)`, or `.verbatim` for a construct with no editing story (a table, a rule). `ComposerBlockKind` also carries a `blockID`, a `UUID` that distinguishes two adjacent, otherwise-identical `codeBlock` or `verbatim` paragraphs so they serialize as two blocks rather than merging into one (`hasOwnBlockID` is which kinds those are) — every other kind forces `blockID` to a shared sentinel, so equality never depends on a caller threading an id through.
- **`.plumeInline`** — a `ComposerInlineStyle` option set (`.bold`, `.italic`, `.code`) on a run. `ComposerTextStyle.font(for:inline:)` resolves the actual font: code wins outright (a bold code span still renders in mono), otherwise bold/italic add symbolic traits on top of the block kind's own base font.
- **`.plumeLink`** — the `URL` a run points to, independent of `.plumeInline`.

`ComposerTextStyle` (`ComposerTextStyle.swift`) is the single place that turns a block kind, an inline style, and a link into an actual attribute dictionary (fonts, colors, paragraph style, the three `plume*` keys). Every caller that builds composer text funnels through `attributes(for:inline:link:isFirstInBlock:isLastInBlock:lists:)` rather than hand-assembling attributes.

### The repair pass and its invariants

`ComposerDocumentInvariants.normalize(_:editedRange:style:)` runs after every edit (from `ComposerNSTextView.textStorage(_:didProcessEditing:range:changeInLength:)`, the `NSTextStorageDelegate` callback) and re-establishes two invariants:

1. **Every paragraph carries exactly one `.plumeBlock` value across its full extent.** A paragraph that already has a tag at its start keeps it, reapplied across the paragraph's *current* extent — which is what makes a merge (deleting the newline between two paragraphs) keep the first paragraph's kind, and a split (inserting a newline mid-paragraph) copy the original kind to both halves. A paragraph with no tag at its start — a genuinely fresh line — inherits the *continuation kind* of the paragraph before it: a list item extends its list (numbered counting up), a code block extends its fence, everything else starts a plain paragraph.
2. **Every run's font and color match what `ComposerTextStyle` says the kind should produce.** `refont` re-derives both from the block kind and inline style, correcting whatever a paste or an undo carried in from somewhere else.

`ComposerDocumentInvariants.renumber(_:style:)` is the second pass: it walks every numbered paragraph and recomputes its number per contiguous run at each depth, since a source number surviving individual paragraph edits can otherwise drift from what a renumbered list should show. A run ends where anything interrupts it — a shallower paragraph, a bullet at the same depth, any other kind — and the first item after an interruption keeps its own number.

`ComposerDocumentInvariants.padChips(_:style:)` is the third: it writes the `kern` that opens space around an inline code chip (see "Decorations" below) and clears it everywhere else. `ComposerParagraphStyles.apply(to:style:)` is the fourth: it rewrites every paragraph's `.paragraphStyle`, including the shared `NSTextList` stacks (`ComposerLists`) a list paragraph needs so decimal numbering keeps counting across paragraphs. All four are whole-document passes rather than edit-local ones — a composer draft is short enough that this costs nothing, and none of what they compute (list numbering, first/last-in-block padding) is actually local to the edited range.

### The character-less last line and `stickyKind`

A document ending in a newline — including an empty document, and the common case of the caret sitting after the last character typed — has a **character-less last line**: a caret position with no characters to carry an attribute. `ComposerNSTextView.ParagraphInfo` (`ComposerTextViewEditing.swift`) represents this as an `enclosing`/`content` range that are both empty.

`ComposerNSTextView.stickyKind` (`kind: ComposerBlockKind, paragraphStart: Int`) is where the answer for that line lives instead. Converting the character-less line to a new kind — say, Backspace outdenting an empty last list item — has nothing to write the kind onto, so `applying(_:thenStick:at:)` remembers it in `stickyKind` until the first character actually lands there. `paragraphInfo(at:)` consults it whenever the stored-attribute lookup at an empty enclosing range comes back empty and `stickyKind.paragraphStart` matches.

A selection that moves off that line abandons the sticky kind (`setSelectedRanges` override) — otherwise the marker of a list the user just selected and deleted would reappear on the next fresh line they start typing. Plume's own edits are exempt (guarded by `isApplyingEdit`), since they place the caret themselves as part of the edit rather than as the user leaving the line.

## Serialization policy

`ComposerDocument` (`ComposerDocument.swift`) is the only place that converts between markdown and the storage's `NSAttributedString`. The policy, stated in its own doc comment, is not negotiable: **the message goes to an LLM, not a renderer.** `ComposerDocument.markdown(from:)` and `ComposerInlineMarkdown.markdown(from:range:)` never escape a literal markdown character — a path, a shell command, or a stray `*` the user typed passes through exactly as typed. Markers appear in the output only for formatting that was actually applied through the model.

The round trip is deliberately **not a bijection**:

- One blank line separates blocks on the way out, regardless of how many separated them on the way in.
- List numbering and continuation are recomputed (`ComposerDocumentInvariants.renumber`, `ComposerLists`) rather than carried through verbatim.
- A plain paragraph or heading is never grouped with a neighbor even when adjacent in the storage, so a paragraph whose source text itself contained an embedded newline comes back out as several single-line paragraph blocks — one per physical `NSString` paragraph — rather than as the one multi-line block it started as. Only list items, quote lines, and same-`blockID` paragraphs merge back into one block.
- A trailing newline at the end of the whole document is not preserved (`MarkdownBlock.parseWithSources` drops a paragraph's own trailing blank line from its source).

**Verbatim blocks.** A table or a thematic break has no editing story in this model, so `ComposerDocument.attributedString(markdown:style:)` keeps it as `.verbatim` — one physical paragraph per source line, all sharing one `blockID` so they serialize back out as one block rather than being reparsed. What serializes is the paragraphs' own text, so an edit inside a table survives the round trip; two thematic breaks in a row stay two rules because their `blockID`s differ.

`ComposerDocument.plainTextIsSendable(_:)` is the sendability check: any non-whitespace character anywhere in the visible text. An empty heading or an empty list item has non-empty *markdown* (its scaffolding) but empty visible text, and still reads as not sendable.

### The attributed draft snapshot

`DraftStore` (`Plume/Models/DraftStore.swift`) keeps a draft twice: as markdown (`draft(forTab:)`, what a send and any future persistence use) and as the composer's own attributed document (`document(forTab:)`). The second copy exists because of the no-escaping policy above: a pasted **literal** `**x**` stays literal in the storage (see the pasteboard contract below), but re-parsing that same markdown string on a tab switch would read it back as *actual* bold. `MarkdownComposerTextView.restoredDocument` and `onDocumentChange` are what let `Coordinator.load(markdown:snapshot:fontSize:into:)` prefer the snapshot over reparsing whenever one exists — only the composer's own echo of its own change drops it (`DraftStore.setDraft` clears `documents` because every other caller is replacing the draft wholesale).

## Input rules

`ComposerInputRules` (`ComposerInputRules.swift`) is pure: paragraph text plus the character(s) just inserted in, an `Edit?` out. It never touches an `NSTextView`; `ComposerTextViewEditing.applyInputRule(inserted:)` is the integration layer that calls it from `insertText(_:replacementRange:)` and carries out whatever `Edit` comes back.

| Shortcut | Fires when | Converts to |
| --- | --- | --- |
| `# ` … `###### ` | Caret right after the space, paragraph starts with 1–6 `#` (a 7th never matches) | `.heading(level:)` |
| `- `, `* `, `+ ` | Caret at position 2, paragraph starts with the marker + space | `.bullet(depth:)`, depth inherited from a preceding list item |
| `N. ` | Caret right after the space, leading digits + `.` + space | `.numbered(depth:number:)`, depth inherited the same way |
| `> ` | Caret at position 2 | `.quote` |
| ` ``` ` + optional bare language word | The instant the closing backtick completes an exact `` ``` `` (+ language) paragraph | See "the fence-then-Return gesture" below |
| `**x**` | Second asterisk of a closing `**` just typed | `.convertInline(.bold)` on the enclosed text |
| `*x*` / `_x_` | A single, unpaired closing delimiter, content non-whitespace at both ends, `_` additionally requires a word boundary on both sides | `.convertInline(.italic)` |
| `` `x` `` | A single closing backtick not part of a `` `` `` run | `.convertInline(.code)` |
| `[text](url)` | Closing `)`, URL has no spaces and parses | `.convertLink(text:url:)` |

Every block marker is anchored at paragraph start (`blockEdit(for:)`), so leading whitespace — including inside an existing list item — never matches, and a marker typed inside an already-structured line (a heading, a quote, a list item) stays literal, matching Typora/Notion's behavior. Block rules are only even consulted when the paragraph's current kind is `.paragraph`; `.codeBlock` and `.verbatim` never convert at all (`ComposerInputRules.edit(for:)`).

Applying a conversion is a **second edit**, never part of the keystroke that triggered it — see "Undo" below for why.

### The fence-then-Return gesture

`ComposerInputRules.codeFenceEdit` does detect a completed fence line the instant the third backtick lands, and returns a `.convertBlock(kind: .codeBlock(language:))` edit for it — but `ComposerTextViewEditing.apply(_:in:caret:)` discards that edit outright (`if case .codeBlock = kind.kind { return }`). The fence characters stay literal so a language name can still be typed after them.

The actual conversion happens from `insertNewline(_:)`: on Return, it re-checks the current paragraph's text with `ComposerCodeFence.language(of:)`, and if it reads as a bare fence (with or without a language), calls `openCodeBlock(in:language:)`. That function replaces the fence line itself with an empty `.codeBlock` paragraph — no fence characters ever reach the document. If the fence was the very last line of the whole document, there's no existing trailing newline to reuse, so it clears the line's content and sticks the new kind via `stickyKind` instead of inserting an actual paragraph break, reusing the character-less-last-line mechanism above rather than creating a redundant one.

### Leaving a code block

Inside a code block, Return normally inserts a literal newline continuing the same kind and `blockID` (`ComposerListEditing.NewlineAction.insertNewlineInBlock`). Pressing Return again on what is now an **empty, last paragraph of that block** converts that paragraph to `.paragraph` instead (`isLastParagraphOfBlock(_:)`) — a double-Return exits the block, the same gesture Notion and Typora use.

### Quote exit

Return on a non-empty quote line continues it as a new `.paragraph` (`.splitToParagraph`) — quote lines don't auto-continue the way list items do. Return on an **empty** quote line exits to `.paragraph` in place (`.exitToParagraph`), same as an empty list item at depth 0.

## List editing

`ComposerListEditing` (`ComposerListEditing.swift`) is pure `ComposerBlockKind` in, action out, covering Return/Tab/Shift-Tab/Backspace for every block kind, not only lists:

- **`newline(in:at:)`** — a non-empty list item splits, continuing the same kind (a numbered item's carrying `number + 1`); an empty depth-0 item exits to `.paragraph`; an empty nested item outdents one level in place; a code block inserts a literal newline (see above); a heading or a non-empty quote splits to a new `.paragraph`; an empty quote exits.
- **`tab(in:previous:)`** — indents a list item one level deeper, but only up to the *previous* list item's depth + 1: a list item can never nest more than one level under the item above it. A no-op for a non-list paragraph or a first item with nothing above it to nest under.
- **`backtab(in:)`** — outdents one level; a no-op at depth 0, since Backspace is what removes the item entirely.
- **`backspaceAtStart(of:)`** — a depth-0 list item, a heading, or a quote becomes `.paragraph`; a nested list item just loses one depth; a no-op everywhere else, including inside a code block (leaving a code block is the explicit Return gesture above, not Backspace on its first line).

`ComposerTextViewEditing`'s overrides of `insertNewline(_:)`, `insertTab(_:)`, `insertBacktab(_:)`, and `deleteBackward(_:)` are what call these and apply the result via `convertParagraph(_:to:)` or `split(at:in:into:)`. **AppKit's own list handling never runs.** In a list paragraph, AppKit's stock `insertNewline:` inserts two newlines at the document's *end* rather than at the caret, and its stock `insertTab:` rewrites indents behind the model's back — both bypass `.plumeBlock` entirely. Every paragraph kind is handled by Plume's own overrides instead, with no `super` fallback for a list paragraph.

**`NSTextList` sharing.** `ComposerLists.lists(for:continuing:)` (`ComposerLists.swift`) builds the `[NSTextList]` stack a list paragraph's paragraph style carries; TextKit 2 synthesizes the visible marker from these, so no marker character ever lives in the storage. Decimal numbering continues across paragraphs only while they share the *same* `NSTextList` instance — a new depth, or a switch between bullets and numbers, starts a fresh instance and restarts numbering. This is why `ComposerParagraphStyles.apply(to:style:)` threads one `previousLists` value through its walk rather than building each paragraph's list stack in isolation.

A fresh decimal instance takes its `startingItemNumber` from the paragraph's own number, since TextKit counts from the list's start. Without that, a list opening at `3.` draws markers reading 1. and 2. while the same paragraphs serialize as 3. and 4.

## Typing attributes

`ComposerNSTextView.desiredTypingAttributes()` is the **one place** typing attributes are decided, for both an edit and a bare selection move — it's called from `applying(_:thenStick:at:)` after every rule conversion, and from the `NSTextViewDelegate` hook `textView(_:shouldChangeTypingAttributes:toAttributes:)` (`MarkdownComposerTextView.Coordinator`), which AppKit consults on both paths.

- **Bold and italic extend** at the caret's trailing edge: typing right after a bold word stays bold, derived from the inline style of the character just before the caret.
- **Inline code does not extend.** After a closing-backtick conversion, or at a chip's trailing edge, typing is plain — a code span only grows from *inside* it (both surrounding characters already code).
- **Links never extend.**
- `ComposerNSTextView.typingInlineOverride` is the one exception: ⌘B/⌘I on a collapsed selection sets it, so the next character honors the toggle rather than having `desiredTypingAttributes()` re-derive the style from what's already there and discard the toggle. It's cleared on the next insertion or caret move.

Nothing decorative — `kern`, spelling state, rendering attributes — is ever part of a typing-attribute dictionary; it's built from scratch each time rather than edited in place.

## The undo transaction design

Every change routes through `ComposerNSTextView.replace(_:with:selection:)` — `shouldChangeText(in:replacementString:)` → the replacement → `didChangeText()` — which is what puts every conversion and list edit on the text view's own undo stack alongside plain typing.

A markdown-shortcut conversion is deliberately a **second, separate undo step** from the literal insertion that triggered it. AppKit groups every edit made during one event into a single undo group, so applying a conversion from inside the same keystroke that triggered it would mean the same ⌘Z that removes the just-typed character also undoes the conversion — and the literal `- ` or `**x**` the user typed would never come back on its own.

`asStepAfterTheInsertion(_:)` (`ComposerTextViewEditing.swift`) is how the split happens. **`breakUndoCoalescing()` alone is not enough**: it only stops *adjacent similar registrations* from merging into one undo action (what keeps a fast typing run collapsing into a single "insert" step) — it does not split the current keystroke's undo *group*, which is what actually determines what one ⌘Z reverts. The fix is explicit: close the currently open group and reopen a fresh one (`endUndoGrouping()` / `beginUndoGrouping()`), so the literal insertion commits into the group that closes, and the conversion lands in the group that opens after it.

**This must never run on a general keystroke path** — only from a rule that has already inserted and registered a literal edit earlier in the same event. Calling it with nothing yet registered commits an empty group, which costs the user a dead ⌘Z that undoes nothing.

**`loadDocument(_:)` drops only its own composer's actions.** The undo manager belongs to the window, and every composer in it shares one, so a blanket `removeAllActions()` would throw away a sibling composer's history. AppKit registers a text edit against the **text storage**, not the text view, so the scoped removal takes both targets: the storage for the edits, and the view itself for the sticky-kind actions `applying(_:thenStick:at:)` registers.

`applying(_:thenStick:at:)` layers `stickyKind` bookkeeping on top of the same pattern: since the undo stack is LIFO, it registers the *previous* sticky value **before** running the edit, so on the way back the kind restoration happens after the text is restored, on the document it actually belongs to.

## The pasteboard contract

`ComposerPasteboard` (`ComposerPasteboard.swift`) defines a private type, `com.ryanmoelter.Plume.composer-document`, alongside plain `.string`. A copy writes both: the visible plain text (so any other app sees exactly the on-screen characters), and the private type carrying the three `plume*` attributes per run, re-buildable against whatever `ComposerTextStyle` the destination composer is using (only the attributes are archived — fonts, colors, and paragraph styles are rebuilt fresh on paste, so a slice copied at one font size pastes correctly at another).

**Reading is literal by default.** `ComposerNSTextView.readSelection(from:)` restores the private type's formatting when it's present (a slice from another composer), but anything else — a paste from Terminal, Slack, a browser — lands as **literal, unformatted text** under the current paragraph kind and typing attributes. This is deliberate: the message is read by an LLM, and a pasted `**` or `_` is far more often part of a shell command or an identifier than an emphasis marker the user meant to apply.

**⌥⇧⌘V** (`pasteAsMarkdown(_:)`) is the escape hatch: it reads the general pasteboard's plain string and parses it *as* markdown through `ComposerDocument.attributedString(markdown:style:)`, for the case where the clipboard genuinely holds markdown the user wants rendered.

## Decorations

`ComposerDecorations` (`ComposerDecorations.swift`) computes and draws the chip, code-box, and quote-bar rects behind the text, from a live TextKit 2 layout. Geometry (`rects(in:style:)`) and drawing (`draw(in:style:dirtyRect:)`) are kept separate so the rects can be asserted in tests without a graphics context.

**It draws from `drawBackground(in:)`, never `draw(_:)`.** Overriding `draw(_:)` on an `NSTextView` silently drops the view to TextKit 1 — `textLayoutManager` comes back `nil`, and every TextKit 2 API the decorations depend on goes with it, with no diagnostic beyond the geometry computing nothing. `drawBackground(in:)` keeps TextKit 2 and runs before the glyphs are drawn, which is where a background decoration belongs anyway. `ComposerNSTextView` also can't observe its own storage from `init(frame:)` for the same class of reason — AppKit's own designated initializer overflows the stack if overridden — so it wires up via `observeStorage()`, called from `layout()` on first use instead.

**Inline code chips.** One rounded rect per line a code span occupies; a span that wraps gets one rect per line rather than a spanning rect. **The kern trick**: the chat transcript (`MarkdownCache.styledInline`) and the composer both use `kern` rather than a padding character to open visual space around a chip — a padding character would become part of the copyable text. `ComposerDocumentInvariants.padChips` is what writes it in the composer: `style.chipPadding` on the character before a span and on the span's own last character, and no kern anywhere else. Typing attributes never carry it; it is re-derived by the repair pass instead. `chipRects(_:)` reclaims the leading kern as extra rect width, and checks whether the span's last character already carries a trailing kern before deciding whether to extend the trailing edge itself, so the two padding sources never double up. Without the leading kern the chip is drawn over the glyph before it.

**Code boxes and quote bars.** One full-width box per run of paragraphs sharing a code block's `blockID`, one bar per run of consecutive quote paragraphs (`blockRects(_:)`). Both use `layoutFragmentFrame` (not segment frames) so the box's vertical extent already includes the paragraph spacing `ComposerTextStyle.paragraphStyle` adds before/after a code block — the box's actual vertical padding — without an extra inset that would make two adjacent blocks overlap into one.

## Height measurement

`ComposerHeightMeasurer` (`ComposerHeightMeasurer.swift`) is a second, off-screen TextKit 2 stack (its own `NSTextContentStorage` / `NSTextLayoutManager` / `NSTextContainer`) that measures how tall the document would lay out at a given width, without touching the live view. SwiftUI's `sizeThatFits` is asked on *every* layout pass, not only when the text changes, so the stack is built once and re-measured in place.

The cache key (`Key`) is `(width, fontSize, inset, revision)`. **`revision` is the caller's own edit counter** (`ComposerNSTextView.documentRevision`), and it's what makes an attribute-only edit — a re-style, an undo that changes no characters — invalidate the cache correctly: the text content alone can't see those changes, but a repaired block kind changing a paragraph's font or spacing can still change its height. `documentRevision` is bumped from the storage delegate callback (`textStorage(_:didProcessEditing:range:changeInLength:)`), which fires for *any* edit AppKit processes, characters or attributes alike — that's why the revision is sourced there rather than derived from the string.

An empty document, and a document ending in a newline, have no layout fragment for their trailing empty line, yet the live view still reserves caret room there and counts it in `usageBoundsForTextContainer`. `measurable(_:)` reproduces this by appending a zero-width `\u{200B}` sentinel (carrying the last real run's attributes, or the caller-supplied `emptyAttributes`) before measuring, rather than approximating the gap from font metrics.

## Slash commands

`ChatComposer` tracks two different strings for the same composer: the draft (markdown, what gets sent and persisted) and `visibleText` (what the user actually sees, updated from `onTextChange`). Sendability and the slash-command autocomplete query both key off `visibleText` — an empty heading has non-empty markdown scaffolding but nothing visible to send, and the caret position the autocomplete needs is reported in the visible-text coordinate space.

**In-view acceptance.** Accepting a suggestion used to mean writing a new string straight through the `text` binding; it now runs as an ordinary edit inside the text view. `ChatComposer.acceptSlashCommand(_:)` just sets `pendingSlashCommand`, a `Binding<SlashCommand?>` (`MarkdownComposerTextView.pendingSlashCommand`); `updateNSView` hands it to `Coordinator.acceptSlashCommand(_:clearing:)`, which defers it one turn via `DispatchQueue.main.async` (accepting inside the current SwiftUI update pass would mutate state mid-update and trip AppKit's layout engine) and then calls `ComposerNSTextView.acceptSlashCommand(_:)`. That replaces just the leading `/token` through `replace(_:with:selection:)` — the range comes from `SlashCommandMatcher.accepting` — so the rest of the message keeps its formatting and ⌘Z steps back over only the insertion.

The command waits on the coordinator rather than in the binding, and the deferred block takes it before doing anything else. A second update pass before the block drains then finds nothing left to apply instead of inserting the command twice, and a block that drains after the composer has left its window applies nothing at all.

**Rendering-attribute tint.** `refreshCommandTint(names:)` tints a recognized leading `/name` by adding a **rendering attribute** on the `NSTextLayoutManager` (`layoutManager.addRenderingAttribute(.foregroundColor, ...)`), not a storage attribute. That keeps the tint out of the undo stack, the markdown, and the pasteboard entirely — it's purely a display-time hint over whatever the storage actually says.

## Spell check by attribute

`ComposerCodeRanges` (`ComposerCodeRanges.swift`) reads the document's own `.plumeInline`/`.plumeBlock` attributes to find every code range — inline spans plus whole code-block/verbatim paragraphs — rather than re-parsing text that may no longer even be markdown. `MarkdownComposerTextView.Coordinator` uses it from three `NSTextViewDelegate` text-checking hooks: `willCheckTextIn:` strips spelling/grammar from the checking types when a range is entirely code, `didCheckTextIn:` filters spelling/grammar results that land in code out of the results AppKit already computed, and `shouldSetSpellingState` suppresses the red-underline indicator itself for any range touching code. The code-range list is cached, keyed on `documentRevision` rather than the string, since applying inline code changes attributes without changing a single character.

Spelling marks themselves live as **layout-manager temporary attributes**, not storage attributes — set via `isContinuousSpellCheckingEnabled = true` in `ScrollableComposerTextView.setUp()` — so `ComposerDocumentInvariants`'s repair pass, which only ever touches `NSTextStorage` attributes, neither carries them across an edit nor has to explicitly strip them.

## Verifying by hand

- Type `# `, `- `, `1. `, `> `, and `` ``` `` at a paragraph's start — each converts immediately (the fence waits for Return) and the marker characters never remain on screen.
- Type `**bold**`, `*italic*`, `` `code` ``, and `[text](https://example.com)` inline — each converts on its closing delimiter.
- ⌘Z after any of the above restores the literal marker text; a second ⌘Z after typing more text still reaches that same undo step without skipping over it.
- Tab and Shift-Tab indent/outdent a list item, clamped to one level under the item above; Backspace at an item's start removes just its marker.
- Type a fence, a language, Return, some code, then Return twice on an empty line — the block opens and then closes back to a plain paragraph.
- Copy a formatted slice and paste it back into the same composer — formatting survives. Paste `**x**` from another app — it stays literal. ⌥⇧⌘V on the same clipboard text renders it as markdown instead.
- Switch chat tabs with an unsent, partially formatted draft, then switch back — the draft and its formatting are both restored, and a literal `**x**` in it is still literal.
- Resize the composer's width while it holds a code block, a chip, and a quote — the code box, chip, and quote bar all track the new layout without a visible lag or a stale rect.
- Misspell a word inside inline code and outside it — only the one outside gets a red underline.
- Type `/` to open the slash-command list, arrow to a different entry, and accept it — the rest of a message typed before it keeps its formatting, and ⌘Z undoes only the acceptance.
