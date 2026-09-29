import Foundation

/// One physical paragraph of the composer's storage.
nonisolated struct ComposerParagraph: Equatable {
    /// The full paragraph, line terminator included — the extent `.plumeBlock`
    /// covers.
    let range: NSRange
    let contentRange: NSRange
    /// The `.plumeBlock` at the paragraph's start. Nil for an untagged
    /// paragraph, which some walks treat differently from a tagged `.paragraph`.
    let storedKind: ComposerBlockKind?

    var kind: ComposerBlockKind { storedKind ?? .paragraph }
}

/// The paragraph walk every whole-document composer pass shares.
nonisolated enum ComposerParagraphs {
    /// Every paragraph that `range` touches, in order; the whole document when
    /// `range` is nil.
    ///
    /// A document ending in a newline gets no entry for its character-less last
    /// line: nothing there can carry a `.plumeBlock`, so its kind lives in
    /// `ComposerNSTextView.stickyKind` instead.
    static func all(in storage: NSAttributedString, within range: NSRange? = nil) -> [ComposerParagraph] {
        let ns = storage.string as NSString
        let bounds = range ?? NSRange(location: 0, length: ns.length)
        var result: [ComposerParagraph] = []
        var location = bounds.location
        while location < NSMaxRange(bounds) {
            var start = 0
            var end = 0
            var contentsEnd = 0
            ns.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            result.append(ComposerParagraph(
                range: NSRange(location: start, length: end - start),
                contentRange: NSRange(location: start, length: contentsEnd - start),
                storedKind: storage.attribute(.plumeBlock, at: start, effectiveRange: nil) as? ComposerBlockKind
            ))
            location = end
        }
        return result
    }

    /// `paragraphs` split into maximal runs of neighbors for which
    /// `continues(previous, next)` holds.
    static func runs(
        of paragraphs: [ComposerParagraph],
        where continues: (ComposerParagraph, ComposerParagraph) -> Bool
    ) -> [ArraySlice<ComposerParagraph>] {
        var runs: [ArraySlice<ComposerParagraph>] = []
        var start = paragraphs.startIndex
        while start < paragraphs.endIndex {
            var end = start + 1
            while end < paragraphs.endIndex, continues(paragraphs[end - 1], paragraphs[end]) { end += 1 }
            runs.append(paragraphs[start..<end])
            start = end
        }
        return runs
    }
}
