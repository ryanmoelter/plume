import AppKit

/// The editing behavior of the WYSIWYG composer: markdown input rules, the
/// list keys, ⌘B/⌘I, the pasteboard, and the typing attributes that hold the
/// rest together.
///
/// Every change routes through `replace(_:with:selection:)`, which is
/// `shouldChangeText(in:replacementString:)` → replacement → `didChangeText()`.
/// That is what puts a rule conversion or a list edit on the same undo stack
/// as plain typing. Nothing here rebuilds the document or assigns `string`.
///
/// A conversion is deliberately a *second* edit rather than part of the
/// keystroke that triggered it: the literal characters are inserted first and
/// committed, then replaced in an undo group of their own (see
/// `asStepAfterTheInsertion`). ⌘Z therefore lands on the literal `- ` the user
/// typed rather than skipping past it.
extension ComposerNSTextView {
    /// One paragraph's extent and kind. `enclosing` includes the trailing
    /// newline the paragraph owns; `content` stops before it. Both are empty
    /// for the character-less line after a document's final newline, which is
    /// a caret position with nothing to carry attributes — see `stickyKind`.
    struct ParagraphInfo {
        let enclosing: NSRange
        let content: NSRange
        let kind: ComposerBlockKind
        let previousKind: ComposerBlockKind?
    }

    // MARK: - Paragraph geometry

    func paragraphInfo(at location: Int) -> ParagraphInfo {
        guard let storage = textStorage else {
            return ParagraphInfo(enclosing: NSRange(location: 0, length: 0), content: NSRange(location: 0, length: 0), kind: .paragraph, previousKind: nil)
        }
        let ns = storage.string as NSString
        let clamped = min(max(0, location), ns.length)
        let enclosing = ns.paragraphRange(for: NSRange(location: clamped, length: 0))
        let hasNewline = enclosing.length > 0 && ns.character(at: NSMaxRange(enclosing) - 1) == 0x0A
        let content = NSRange(location: enclosing.location, length: enclosing.length - (hasNewline ? 1 : 0))

        let previousKind: ComposerBlockKind? = enclosing.location > 0
            ? storage.attribute(.plumeBlock, at: enclosing.location - 1, effectiveRange: nil) as? ComposerBlockKind
            : nil

        let kind: ComposerBlockKind
        if enclosing.length > 0,
           let stored = storage.attribute(.plumeBlock, at: enclosing.location, effectiveRange: nil) as? ComposerBlockKind {
            kind = stored
        } else if let sticky = stickyKind, sticky.paragraphStart == enclosing.location {
            kind = sticky.kind
        } else {
            kind = ComposerDocumentInvariants.continuationKind(after: previousKind)
        }
        return ParagraphInfo(enclosing: enclosing, content: content, kind: kind, previousKind: previousKind)
    }

    private func previousParagraphInfo(before info: ParagraphInfo) -> ParagraphInfo? {
        guard info.enclosing.location > 0 else { return nil }
        return paragraphInfo(at: info.enclosing.location - 1)
    }

    private func isEmpty(_ info: ParagraphInfo) -> Bool {
        guard info.content.length > 0, let storage = textStorage else { return true }
        let text = (storage.string as NSString).substring(with: info.content)
        return !text.contains { !$0.isWhitespace }
    }

    private func listParagraph(_ info: ParagraphInfo) -> ComposerListEditing.Paragraph {
        ComposerListEditing.Paragraph(kind: info.kind, isEmpty: isEmpty(info))
    }

    private func isCode(_ kind: ComposerBlockKind) -> Bool {
        switch kind.kind {
        case .codeBlock, .verbatim: true
        default: false
        }
    }

    // MARK: - Undoable primitives

    /// Replaces `range`, landing on the text view's own undo stack.
    /// `selection` is clamped to the document that results.
    @discardableResult
    func replace(_ range: NSRange, with replacement: NSAttributedString, selection: NSRange?) -> Bool {
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: replacement.string) else {
            return false
        }
        isApplyingEdit = true
        defer { isApplyingEdit = false }
        storage.replaceCharacters(in: range, with: replacement)
        didChangeText()
        if let selection {
            let location = min(selection.location, storage.length)
            setSelectedRange(NSRange(location: location, length: min(selection.length, storage.length - location)))
        }
        return true
    }

    /// Runs `body` as an undo step separate from the insertion that triggered
    /// it, for the input rules and nothing else.
    ///
    /// AppKit puts every edit made during one event into a single undo group,
    /// so a conversion applied from the keystroke that triggered it would be
    /// undone by the same ⌘Z that removes the character — and the literal `- `
    /// or `**x**` the user typed would never come back. Closing the open group
    /// commits that insertion on its own; the group opened in its place is the
    /// one the conversion lands in, and whoever opened the first one closes
    /// that one instead. Only a rule may use this: anything else runs with
    /// nothing yet registered in the event, and would commit an empty group
    /// that costs the user a dead ⌘Z.
    private func asStepAfterTheInsertion(_ body: () -> Void) {
        breakUndoCoalescing()
        if let manager = undoManager, manager.groupingLevel > 0 {
            manager.endUndoGrouping()
            manager.beginUndoGrouping()
        }
        body()
        breakUndoCoalescing()
    }

    /// Runs `edit` and leaves the character-less line it ends on carrying
    /// `kind`, undoably.
    ///
    /// Nothing in the storage can carry that kind, so undo of the edit beside
    /// it would otherwise leave the line reading as a plain paragraph and the
    /// next character typed would lose its marker. The undo stack is LIFO, so
    /// the kind is registered *before* the edit: that puts it after the text
    /// on the way back, where it can see the document it belongs to. The
    /// closure registers the value it replaced, which is what makes this
    /// reverse in both directions.
    func applying(_ edit: () -> Void, thenStick kind: ComposerBlockKind?, at paragraphStart: Int) {
        let previous = stickyKind
        undoManager?.registerUndo(withTarget: self) { view in
            view.applying({}, thenStick: previous?.kind, at: previous?.paragraphStart ?? paragraphStart)
        }
        edit()
        stickyKind = kind.map { (kind: $0, paragraphStart: paragraphStart) }
        typingAttributes = desiredTypingAttributes()
    }

    /// Abandons a sticky kind once the selection leaves the line it belongs
    /// to. Plume's own edits place the caret themselves and are exempt.
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        if let sticky = stickyKind, !isApplyingEdit {
            let range = ranges.first?.rangeValue
            if range == nil || range!.length > 0 || range!.location != sticky.paragraphStart {
                stickyKind = nil
            }
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
    }

    /// `slice` re-attributed for `kind`, keeping each run's own inline style
    /// and link and adding `inline` on top.
    func restyled(_ slice: NSAttributedString, to kind: ComposerBlockKind, adding inline: ComposerInlineStyle = []) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let ns = slice.string as NSString
        slice.enumerateAttributes(in: NSRange(location: 0, length: slice.length), options: []) { attributes, range, _ in
            let existing = (attributes[.plumeInline] as? ComposerInlineStyle) ?? []
            result.append(NSAttributedString(
                string: ns.substring(with: range),
                attributes: style.attributes(
                    for: kind,
                    inline: existing.union(inline),
                    link: attributes[.plumeLink] as? URL
                )
            ))
        }
        return result
    }

    /// Re-kinds a paragraph in place, keeping its characters and selection.
    ///
    /// A character-less last line has nothing to write the kind onto, so the
    /// kind is remembered in `stickyKind` until the first character lands on
    /// it. That change is not undoable, which is the one gap in the
    /// keystroke-path undo contract: nothing visible was lost to restore.
    func convertParagraph(_ info: ParagraphInfo, to kind: ComposerBlockKind) {
        guard let storage = textStorage else { return }
        guard info.enclosing.length > 0 else {
            applying({}, thenStick: kind, at: info.enclosing.location)
            return
        }
        let selection = selectedRange()
        let leavesCode = isCode(info.kind) && !isCode(kind)
        replace(info.enclosing, with: restyled(storage.attributedSubstring(from: info.enclosing), to: kind), selection: selection)
        if leavesCode {
            checkText(in: info.enclosing, types: NSTextCheckingResult.CheckingType.spelling.rawValue, options: [:])
        }
    }

    // MARK: - Input rules

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let plain = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        super.insertText(plain, replacementRange: replacementRange)
        typingInlineOverride = nil
        guard !hasMarkedText() else { return }
        applyInputRule(inserted: plain)
    }

    private func applyInputRule(inserted: String) {
        guard !inserted.isEmpty, let storage = textStorage else { return }
        let caret = selectedRange().location
        let info = paragraphInfo(at: caret)
        guard info.content.length > 0, caret >= info.content.location, caret <= NSMaxRange(info.content) else { return }

        let context = ComposerInputRules.Context(
            paragraphText: (storage.string as NSString).substring(with: info.content),
            kind: info.kind,
            caret: caret - info.content.location,
            inserted: inserted,
            previousKind: info.previousKind,
            codeRanges: inlineCodeRanges(in: info.content)
        )
        guard let edit = ComposerInputRules.edit(for: context) else { return }
        apply(edit, in: info, caret: caret)
    }

    private func apply(_ edit: ComposerInputRules.Edit, in info: ParagraphInfo, caret: Int) {
        guard let storage = textStorage else { return }
        let origin = info.content.location

        switch edit {
        case let .convertBlock(markerRange, kind):
            // A completed fence waits for the following Return, so a language
            // can still be typed after it.
            if case .codeBlock = kind.kind { return }
            // The paragraph's own newline is re-kinded with it: that character
            // is what carries the kind once the marker text is gone.
            let rest = NSRange(
                location: origin + NSMaxRange(markerRange),
                length: NSMaxRange(info.enclosing) - origin - NSMaxRange(markerRange)
            )
            asStepAfterTheInsertion {
                applying({
                    replace(
                        info.enclosing,
                        with: restyled(storage.attributedSubstring(from: rest), to: kind),
                        selection: NSRange(location: max(origin, caret - markerRange.length), length: 0)
                    )
                }, thenStick: rest.length == 0 ? kind : nil, at: origin)
            }

        case let .convertInline(openRange, closeRange, inline):
            let inner = NSRange(
                location: origin + NSMaxRange(openRange),
                length: closeRange.location - NSMaxRange(openRange)
            )
            let full = NSRange(
                location: origin + openRange.location,
                length: NSMaxRange(closeRange) - openRange.location
            )
            let replacement = restyled(storage.attributedSubstring(from: inner), to: info.kind, adding: inline)
            var applied = false
            asStepAfterTheInsertion {
                applied = replace(
                    full,
                    with: replacement,
                    selection: NSRange(location: full.location + replacement.length, length: 0)
                )
            }
            if applied, inline.contains(.code) {
                setSpellingState(0, range: NSRange(location: full.location, length: replacement.length))
            }

        case let .convertLink(range, text, url):
            let full = NSRange(location: origin + range.location, length: range.length)
            let replacement = NSAttributedString(string: text, attributes: style.attributes(for: info.kind, link: url))
            asStepAfterTheInsertion {
                replace(full, with: replacement, selection: NSRange(location: full.location + replacement.length, length: 0))
            }
        }
    }

    /// The already-code ranges of a paragraph, relative to its own start,
    /// which is the coordinate space `ComposerInputRules.Context` expects.
    private func inlineCodeRanges(in contentRange: NSRange) -> [NSRange] {
        guard let storage = textStorage else { return [] }
        var ranges: [NSRange] = []
        storage.enumerateAttribute(.plumeInline, in: contentRange, options: []) { value, range, _ in
            guard let inline = value as? ComposerInlineStyle, inline.contains(.code) else { return }
            ranges.append(NSRange(location: range.location - contentRange.location, length: range.length))
        }
        return ranges
    }

    // MARK: - Return, Tab and Backspace

    /// AppKit's own list handling never runs: in a list paragraph its
    /// `insertNewline:` inserts two newlines at the document's end and its
    /// `insertTab:` rewrites the indents behind Plume's back. Every paragraph
    /// kind is handled here instead.
    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText(), let storage = textStorage else {
            super.insertNewline(sender)
            return
        }
        let selection = selectedRange()
        let info = paragraphInfo(at: selection.location)
        let text = info.content.length > 0 ? (storage.string as NSString).substring(with: info.content) : ""

        if case .paragraph = info.kind.kind, let language = ComposerCodeFence.language(of: text) {
            openCodeBlock(in: info, language: language)
            return
        }

        switch ComposerListEditing.newline(in: listParagraph(info), at: selection.location == NSMaxRange(info.content)) {
        case .insertNewlineInBlock:
            if isEmpty(info), isLastParagraphOfBlock(info) {
                convertParagraph(info, to: .paragraph)
            } else {
                split(at: selection, in: info, into: info.kind)
            }
        case let .splitContinuing(kind):
            split(at: selection, in: info, into: kind)
        case .splitToParagraph:
            split(at: selection, in: info, into: .paragraph)
        case .exitToParagraph:
            convertParagraph(info, to: .paragraph)
        case let .outdent(kind):
            convertParagraph(info, to: kind)
        }
    }

    override func insertTab(_ sender: Any?) {
        let info = paragraphInfo(at: selectedRange().location)
        guard info.kind.isList else {
            super.insertTab(sender)
            return
        }
        let previous = previousParagraphInfo(before: info).map(listParagraph)
        if case let .indent(kind) = ComposerListEditing.tab(in: listParagraph(info), previous: previous) {
            convertParagraph(info, to: kind)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        let info = paragraphInfo(at: selectedRange().location)
        guard info.kind.isList else {
            super.insertBacktab(sender)
            return
        }
        if case let .indent(kind) = ComposerListEditing.backtab(in: listParagraph(info)) {
            convertParagraph(info, to: kind)
        }
    }

    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length == 0 else {
            super.deleteBackward(sender)
            return
        }
        let info = paragraphInfo(at: selection.location)
        guard selection.location == info.content.location else {
            super.deleteBackward(sender)
            return
        }
        if case let .removeMarker(kind) = ComposerListEditing.backspaceAtStart(of: listParagraph(info)) {
            convertParagraph(info, to: kind)
            return
        }
        super.deleteBackward(sender)
    }

    /// Splits at `selection`, leaving the text before it under the paragraph's
    /// own kind and everything after it — including the newline the paragraph
    /// owned — under `kind`.
    private func split(at selection: NSRange, in info: ParagraphInfo, into kind: ComposerBlockKind) {
        guard let storage = textStorage else { return }
        let paragraphEnd = NSMaxRange(info.enclosing)
        let tailStart = min(max(NSMaxRange(selection), selection.location), paragraphEnd)
        let replaced = NSRange(location: selection.location, length: max(0, paragraphEnd - selection.location))

        let replacement = NSMutableAttributedString(
            string: "\n",
            attributes: style.attributes(for: info.kind)
        )
        let tail = NSRange(location: tailStart, length: paragraphEnd - tailStart)
        if tail.length > 0 {
            replacement.append(restyled(storage.attributedSubstring(from: tail), to: kind))
        }

        let caret = selection.location + 1
        applying({
            replace(replaced, with: replacement, selection: NSRange(location: caret, length: 0))
        }, thenStick: tail.length == 0 ? kind : nil, at: caret)
    }

    /// Replaces the fence line with an empty code-block line. Typing ``` (with
    /// an optional language after it) and pressing Return is the gesture; the
    /// fence characters themselves never stay in the document.
    private func openCodeBlock(in info: ParagraphInfo, language: String?) {
        let kind = ComposerBlockKind.codeBlock(language: language)
        if info.enclosing.length > info.content.length {
            let newline = NSAttributedString(string: "\n", attributes: style.attributes(for: kind))
            replace(info.enclosing, with: newline, selection: NSRange(location: info.enclosing.location, length: 0))
            typingAttributes = desiredTypingAttributes()
        } else {
            applying({
                replace(info.content, with: NSAttributedString(), selection: NSRange(location: info.content.location, length: 0))
            }, thenStick: kind, at: info.content.location)
        }
    }

    private func isLastParagraphOfBlock(_ info: ParagraphInfo) -> Bool {
        guard let storage = textStorage, NSMaxRange(info.enclosing) < storage.length else { return true }
        let next = storage.attribute(.plumeBlock, at: NSMaxRange(info.enclosing), effectiveRange: nil) as? ComposerBlockKind
        return next != info.kind
    }

    // MARK: - Typing attributes

    /// The one place typing attributes are decided, for edits and bare
    /// selection moves alike.
    ///
    /// Bold and italic extend at their trailing edge, so typing after a bold
    /// word stays bold. Inline code does not: after a closing-backtick
    /// conversion, and at a chip's trailing edge, typing is plain — a chip
    /// grows only from inside it. Links never extend. Nothing decorative
    /// (`kern`, spelling state, rendering attributes) is ever included,
    /// because the dictionary is built from scratch rather than edited.
    func desiredTypingAttributes() -> [NSAttributedString.Key: Any] {
        guard let storage = textStorage else { return style.attributes(for: .paragraph) }
        let selection = selectedRange()
        let caret = min(selection.location, storage.length)
        let info = paragraphInfo(at: caret)

        var inline: ComposerInlineStyle = []
        if let override = typingInlineOverride {
            inline = override
        } else if selection.length == 0, caret > info.content.location, caret <= NSMaxRange(info.content) {
            let before = (storage.attribute(.plumeInline, at: caret - 1, effectiveRange: nil) as? ComposerInlineStyle) ?? []
            inline = before.subtracting(.code)
            if before.contains(.code), caret < NSMaxRange(info.content),
               let after = storage.attribute(.plumeInline, at: caret, effectiveRange: nil) as? ComposerInlineStyle,
               after.contains(.code) {
                inline.insert(.code)
            }
        }

        var attributes = style.attributes(for: info.kind, inline: inline)
        attributes[.paragraphStyle] = paragraphStyle(for: info)
        return attributes
    }

    private func paragraphStyle(for info: ParagraphInfo) -> NSParagraphStyle {
        if info.enclosing.length > 0,
           let storage = textStorage,
           let stored = storage.attribute(.plumeBlock, at: info.enclosing.location, effectiveRange: nil) as? ComposerBlockKind,
           stored == info.kind,
           let existing = storage.attribute(.paragraphStyle, at: info.enclosing.location, effectiveRange: nil) as? NSParagraphStyle {
            return existing
        }
        let previousLists = previousParagraphInfo(before: info)
            .flatMap { previous -> [NSTextList]? in
                guard previous.enclosing.length > 0, let storage = textStorage else { return nil }
                return (storage.attribute(.paragraphStyle, at: previous.enclosing.location, effectiveRange: nil) as? NSParagraphStyle)?.textLists
            } ?? []
        return style.paragraphStyle(
            for: info.kind.kind,
            lists: ComposerLists.lists(for: info.kind, continuing: previousLists)
        )
    }

    // MARK: - Bold and italic

    /// ⌘B/⌘I, and the Format menu's routes into them. Toggling writes
    /// `.plumeInline`, which is what the font is then derived from — the font
    /// is never set on its own, so the attribute and the glyphs cannot
    /// disagree.
    func toggleInline(_ toggled: ComposerInlineStyle) {
        guard let storage = textStorage else { return }
        let selection = selectedRange()
        guard selection.length > 0 else {
            let current = (typingAttributes[.plumeInline] as? ComposerInlineStyle) ?? []
            typingInlineOverride = current.symmetricDifference(toggled)
            typingAttributes = desiredTypingAttributes()
            return
        }

        var everyRunHasIt = true
        storage.enumerateAttribute(.plumeInline, in: selection, options: []) { value, _, _ in
            let inline = (value as? ComposerInlineStyle) ?? []
            if !inline.isSuperset(of: toggled) { everyRunHasIt = false }
        }

        let slice = storage.attributedSubstring(from: selection)
        let result = NSMutableAttributedString()
        let ns = slice.string as NSString
        slice.enumerateAttributes(in: NSRange(location: 0, length: slice.length), options: []) { attributes, range, _ in
            let existing = (attributes[.plumeInline] as? ComposerInlineStyle) ?? []
            let updated = everyRunHasIt ? existing.subtracting(toggled) : existing.union(toggled)
            let kind = (attributes[.plumeBlock] as? ComposerBlockKind) ?? .paragraph
            result.append(NSAttributedString(
                string: ns.substring(with: range),
                attributes: style.attributes(for: kind, inline: updated, link: attributes[.plumeLink] as? URL)
            ))
        }

        replace(selection, with: result, selection: selection)
    }

    /// The Format menu and the font panel reach a text view through
    /// `NSFontManager`, which converts a font and sends this. Only the bold
    /// and italic traits mean anything to the composer; every other font
    /// change is refused so `.plumeInline` can never disagree with the glyphs.
    override func changeFont(_ sender: Any?) {
        guard let manager = sender as? NSFontManager else { return }
        let emphasis: NSFontTraitMask = [.boldFontMask, .italicFontMask]
        let changed: NSFontTraitMask
        switch manager.currentFontAction {
        case .addTraitFontAction: changed = manager.convertFontTraits([])
        case .removeTraitFontAction: changed = emphasis.subtracting(manager.convertFontTraits(emphasis))
        default: return
        }
        var toggled: ComposerInlineStyle = []
        if changed.contains(.boldFontMask) { toggled.insert(.bold) }
        if changed.contains(.italicFontMask) { toggled.insert(.italic) }
        guard !toggled.isEmpty else { return }
        toggleInline(toggled)
    }

    override func changeAttributes(_ sender: Any?) {}
    override func changeColor(_ sender: Any?) {}
    override func underline(_ sender: Any?) {}
    override func pasteFont(_ sender: Any?) {}
    override func pasteRuler(_ sender: Any?) {}

    // MARK: - Pasteboard

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [ComposerPasteboard.type, .string]
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [ComposerPasteboard.type, .string]
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let storage = textStorage else { return false }
        let selection = NSIntersectionRange(selectedRange(), NSRange(location: 0, length: storage.length))
        return ComposerPasteboard.write(storage.attributedSubstring(from: selection), to: pboard, type: type)
    }

    /// The read side of paste, drag-and-drop and Services alike. A slice from
    /// another composer keeps its formatting; anything else lands **literally**
    /// under the current paragraph kind and inline context, because the text
    /// goes to an LLM and a pasted `**` or `_` is far more often a shell
    /// command than an emphasis marker.
    override func readSelection(from pboard: NSPasteboard) -> Bool {
        let selection = selectedRange()
        if let restored = ComposerPasteboard.read(from: pboard, style: style) {
            return replace(selection, with: restored, selection: NSRange(location: selection.location + restored.length, length: 0))
        }
        guard let text = pboard.string(forType: .string) else { return false }
        let inserted = NSAttributedString(string: text, attributes: typingAttributes)
        return replace(selection, with: inserted, selection: NSRange(location: selection.location + inserted.length, length: 0))
    }

    /// ⌥⇧⌘V: the clipboard's text read as markdown rather than literally.
    @objc func pasteAsMarkdown(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let parsed = ComposerDocument.attributedString(markdown: text, style: style)
        let selection = selectedRange()
        replace(selection, with: parsed, selection: NSRange(location: selection.location + parsed.length, length: 0))
    }

    // MARK: - Document loading and restyling

    /// Replaces the whole document from outside the keystroke path — a tab
    /// switch, a queued-message recall, a send that clears the draft. The
    /// caret lands at the end and this composer's own undo actions are
    /// dropped on purpose: the text before the load is not something ⌘Z
    /// should bring back.
    ///
    /// Only this composer's actions go. The undo manager belongs to the
    /// window and every composer in it shares one, so a blanket
    /// `removeAllActions()` would throw away a sibling composer's history
    /// too. AppKit registers a text edit against the **text storage**, not
    /// the text view, so scoping the removal takes both targets: the storage
    /// for the edits, and the view itself for the sticky-kind actions
    /// `applying(_:thenStick:at:)` registers.
    func loadDocument(_ document: NSAttributedString) {
        guard let storage = textStorage else { return }
        let normalized = NSMutableAttributedString(attributedString: document)
        if normalized.length > 0 {
            ComposerDocumentInvariants.normalize(normalized, editedRange: NSRange(location: 0, length: normalized.length), style: style)
            ComposerDocumentInvariants.renumber(normalized, style: style)
            ComposerDocumentInvariants.padChips(normalized, style: style)
            ComposerParagraphStyles.apply(to: normalized, style: style)
        }
        storage.setAttributedString(normalized)
        stickyKind = nil
        typingInlineOverride = nil
        setSelectedRange(NSRange(location: storage.length, length: 0))
        typingAttributes = desiredTypingAttributes()
        undoManager?.removeAllActions(withTarget: storage)
        undoManager?.removeAllActions(withTarget: self)
    }

    /// Re-derives every font, color and paragraph metric from `style` without
    /// touching a single character — what a chat font-size change needs, and
    /// never a reason to rebuild the document.
    func restyle(bodySize: CGFloat) {
        style = ComposerTextStyle(bodySize: bodySize)
        font = style.body
        guard let storage = textStorage, storage.length > 0 else {
            typingAttributes = desiredTypingAttributes()
            return
        }
        let full = NSRange(location: 0, length: storage.length)
        ComposerDocumentInvariants.normalize(storage, editedRange: full, style: style)
        ComposerDocumentInvariants.padChips(storage, style: style)
        ComposerParagraphStyles.apply(to: storage, style: style)
        typingAttributes = desiredTypingAttributes()
    }

    var currentMarkdown: String {
        guard let storage = textStorage else { return "" }
        return ComposerDocument.markdown(from: storage)
    }

    var documentSnapshot: NSAttributedString {
        NSAttributedString(attributedString: textStorage ?? NSAttributedString())
    }

    // MARK: - Slash commands

    /// Accepting a command is an ordinary undoable edit inside the view, not a
    /// new string written through the binding: the rest of the message keeps
    /// its formatting and ⌘Z steps back over the insertion.
    func acceptSlashCommand(_ command: SlashCommand) {
        guard let storage = textStorage else { return }
        let accepted = SlashCommandMatcher.accepting(command, in: storage.string)
        let info = paragraphInfo(at: 0)
        let replacement = NSAttributedString(
            string: accepted.replacement,
            attributes: style.attributes(for: info.kind)
        )
        replace(
            accepted.replacedRange,
            with: replacement,
            selection: NSRange(location: accepted.caretLocation, length: 0)
        )
    }

    /// Tints a recognized leading `/name` through the layout manager's
    /// rendering attributes rather than the storage, so the tint never enters
    /// the undo stack, the markdown, or the pasteboard.
    func refreshCommandTint(names: Set<String>) {
        guard let layoutManager = textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage
        else { return }
        layoutManager.removeRenderingAttribute(.foregroundColor, for: layoutManager.documentRange)
        guard let range = SlashCommandMatcher.recognizedCommandRange(text: string, commandNames: names),
              let start = contentStorage.location(contentStorage.documentRange.location, offsetBy: range.location),
              let end = contentStorage.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end)
        else { return }
        layoutManager.addRenderingAttribute(.foregroundColor, value: NSColor.controlAccentColor, for: textRange)
    }
}

/// Recognizes the fence line the code-block gesture keys off: exactly three
/// backticks, optionally followed by a bare language word.
nonisolated enum ComposerCodeFence {
    /// The language when `text` is a fence line, `nil` when it is one without
    /// a language. `isFence` is what distinguishes "not a fence" from "a fence
    /// with no language".
    static func language(of text: String) -> String?? {
        let ns = text as NSString
        guard let match = pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.range.length == ns.length
        else { return nil }
        let languageRange = match.range(at: 1)
        return .some(languageRange.length > 0 ? ns.substring(with: languageRange) : nil)
    }

    private static let pattern = try! NSRegularExpression(pattern: "^```([A-Za-z0-9_+-]*)$")
}
