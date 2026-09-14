import AppKit

/// Keeps the composer's `NSTextStorage` structurally consistent after an
/// edit: every paragraph tagged with exactly one `.plumeBlock` value across
/// its full range, and every run's font matching what `ComposerTextStyle`
/// says it should be.
///
/// Pure and `nonisolated` — no `NSTextView`. A caller runs `normalize(_:
/// editedRange:style:)` after every edit and `renumber(_:style:)` whenever a
/// numbered list may have changed shape.
nonisolated enum ComposerDocumentInvariants {
    /// Repairs every paragraph `editedRange` touches, expanded to full
    /// paragraph bounds plus the paragraph immediately after (re-normalizing
    /// an already-correct paragraph is harmless, and a split or a merge can
    /// leave the following paragraph needing a kind too).
    ///
    /// A paragraph that already carries a `.plumeBlock` at its start keeps
    /// it, reapplied across the paragraph's current full extent — which is
    /// what makes a merge keep the first paragraph's kind (the second
    /// paragraph's old tag, still sitting on its characters, is simply
    /// overwritten) and a split copy the original paragraph's kind to the
    /// half after the break (that half's characters never lost their tag).
    /// A paragraph with no tag at its start — a genuinely fresh line, one
    /// whose `.plumeBlock` a caller cleared on insertion — takes the
    /// previous paragraph's continuation kind instead.
    static func normalize(_ storage: NSMutableAttributedString, editedRange: NSRange, style: ComposerTextStyle) {
        guard storage.length > 0 else { return }
        let ns = storage.string as NSString
        let clampedEdit = NSRange(
            location: min(editedRange.location, ns.length),
            length: min(editedRange.length, ns.length - min(editedRange.location, ns.length))
        )
        var range = ns.paragraphRange(for: clampedEdit)
        if NSMaxRange(range) < ns.length {
            let following = ns.paragraphRange(for: NSRange(location: NSMaxRange(range), length: 0))
            range = NSUnionRange(range, following)
        }

        var location = range.location
        while location < NSMaxRange(range) {
            let enclosing = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let contentLength = enclosing.length - (ns.substring(with: enclosing).hasSuffix("\n") ? 1 : 0)
            let contentRange = NSRange(location: enclosing.location, length: contentLength)

            let kind: ComposerBlockKind
            if let existing = storage.attribute(.plumeBlock, at: enclosing.location, effectiveRange: nil) as? ComposerBlockKind {
                kind = existing
            } else {
                let previous = enclosing.location > 0
                    ? storage.attribute(.plumeBlock, at: enclosing.location - 1, effectiveRange: nil) as? ComposerBlockKind
                    : nil
                kind = continuationKind(after: previous)
            }
            storage.addAttribute(.plumeBlock, value: kind, range: enclosing)
            refont(contentRange, kind: kind, storage: storage, style: style)

            location = NSMaxRange(enclosing)
        }
    }

    /// Recomputes every `numbered` paragraph's number, per contiguous run at
    /// each depth — the source's own numbers (kept through edits on
    /// individual paragraphs) can otherwise drift from what a renumbered
    /// list should show.
    ///
    /// A run ends where anything interrupts it: a shallower paragraph, a
    /// bullet at the same depth, or any other kind. The first item after an
    /// interruption keeps its own number and counts up from there, which is
    /// also where `ComposerLists` starts the `NSTextList` it builds.
    static func renumber(_ storage: NSMutableAttributedString, style: ComposerTextStyle) {
        guard storage.length > 0 else { return }
        let ns = storage.string as NSString
        var countersByDepth: [Int: Int] = [:]
        var location = 0

        while location < ns.length {
            let enclosing = ns.paragraphRange(for: NSRange(location: location, length: 0))
            guard let kind = storage.attribute(.plumeBlock, at: enclosing.location, effectiveRange: nil) as? ComposerBlockKind else {
                countersByDepth.removeAll()
                location = NSMaxRange(enclosing)
                continue
            }

            switch kind.kind {
            case let .numbered(depth, number):
                countersByDepth = countersByDepth.filter { $0.key <= depth }
                let expected = countersByDepth[depth] ?? number
                if expected != number {
                    storage.addAttribute(.plumeBlock, value: ComposerBlockKind.numbered(depth: depth, number: expected), range: enclosing)
                }
                countersByDepth[depth] = expected + 1

            case .bullet:
                // A bullet interrupts any numbering at its own depth or
                // deeper: the next numbered item there starts a new list,
                // and a new list starts at that item's own number.
                countersByDepth = countersByDepth.filter { $0.key < kind.depth }

            default:
                countersByDepth.removeAll()
            }

            location = NSMaxRange(enclosing)
        }
    }

    /// Re-establishes the `kern` that opens visual space around an inline
    /// code chip: `style.chipPadding` on the character before a span and on
    /// the span's own last character, and no kern anywhere else.
    ///
    /// Padding is kern rather than a padding character because a padding
    /// character would become part of the text the user copies and sends.
    /// `ComposerDecorations.chipRects` reads both sides back when it sizes
    /// the chip, so the two have to agree about where the kern is.
    static func padChips(_ storage: NSMutableAttributedString, style: ComposerTextStyle) {
        guard storage.length > 0 else { return }
        let ns = storage.string as NSString
        var padded: Set<Int> = []
        for span in ComposerCodeRanges.inlineCodeSpans(in: storage) {
            padded.insert(NSMaxRange(span) - 1)
            let before = span.location - 1
            if before >= 0, ns.character(at: before) != 0x0A { padded.insert(before) }
        }

        let pad = Double(style.chipPadding)
        var wrong: [(location: Int, expected: Double?)] = []
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.kern, in: full, options: []) { value, range, _ in
            let current = (value as? NSNumber)?.doubleValue
            for location in range.location..<NSMaxRange(range) {
                let expected: Double? = padded.contains(location) ? pad : nil
                if current != expected { wrong.append((location, expected)) }
            }
        }

        for (location, expected) in wrong {
            let one = NSRange(location: location, length: 1)
            if let expected {
                storage.addAttribute(.kern, value: NSNumber(value: expected), range: one)
            } else {
                storage.removeAttribute(.kern, range: one)
            }
        }
    }

    /// The kind a paragraph with no tag of its own continues with, given the
    /// kind of the paragraph before it: a list item extends its list (a
    /// numbered one counting up), a code block extends its fence, and
    /// everything else — including the first paragraph of the document,
    /// which has no `previous` — starts a plain paragraph.
    ///
    /// `ComposerNSTextView.paragraphInfo(at:)` answers the character-less
    /// last line from here too, so the caret's kind on a fresh line and the
    /// kind the repair pass writes once a character lands there agree.
    static func continuationKind(after previous: ComposerBlockKind?) -> ComposerBlockKind {
        guard let previous else { return .paragraph }
        switch previous.kind {
        case let .bullet(depth):
            return .bullet(depth: depth)
        case let .numbered(depth, number):
            return .numbered(depth: depth, number: number + 1)
        case let .codeBlock(language):
            return .codeBlock(language: language, blockID: previous.blockID)
        default:
            return .paragraph
        }
    }

    /// Re-fonts any run whose font disagrees with what `style` says `kind`
    /// should produce — the state left behind by a paste or an undo that
    /// carried the wrong font in from somewhere else.
    private static func refont(
        _ contentRange: NSRange,
        kind: ComposerBlockKind,
        storage: NSMutableAttributedString,
        style: ComposerTextStyle
    ) {
        guard contentRange.length > 0 else { return }
        storage.enumerateAttribute(.plumeInline, in: contentRange, options: []) { value, range, _ in
            let inline = (value as? ComposerInlineStyle) ?? []
            let link = storage.attribute(.plumeLink, at: range.location, effectiveRange: nil) as? URL
            let expected = style.font(for: kind.kind, inline: inline)
            let current = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            if current == nil || !(current!.isEqual(expected)) {
                storage.addAttribute(.font, value: expected, range: range)
            }
            let expectedColor: NSColor = link != nil ? .linkColor : .labelColor
            let currentColor = storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
            if currentColor == nil || !(currentColor!.isEqual(expectedColor)) {
                storage.addAttribute(.foregroundColor, value: expectedColor, range: range)
            }
        }
    }
}
