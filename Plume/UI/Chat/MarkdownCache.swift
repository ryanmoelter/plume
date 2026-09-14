import Foundation
import SwiftUI

/// Memoizes the two markdown conversions that sit on the scroll path.
///
/// `MarkdownView` re-runs on every `body` pass, and SwiftUI evaluates `body`
/// constantly while scrolling. Both `MarkdownBlock.parse` and
/// `AttributedString(markdown:)` are pure functions of their input string, so
/// the result can be reused instead of recomputed — inline parsing alone
/// measured 0.083ms per block, which a screenful of blocks turns into more
/// than a frame's budget.
///
/// Bounded because a long-running session would otherwise hold every string
/// it has ever rendered. Eviction is crude on purpose: this is a render
/// cache, and a miss only costs what the work cost before.
@MainActor
enum MarkdownCache {
    /// Comfortably more than one screenful of either kind, small enough that
    /// the memory never matters.
    private static let limit = 512

    private static var blockCache: [String: [MarkdownBlock]] = [:]
    private static var inlineCache: [String: AttributedString] = [:]
    private static var styledInlineCache: [StyledInlineKey: StyledInline] = [:]

    /// Styling depends on the body size as well as the text, so both key the
    /// cache — a font-size change has to miss rather than return chips built
    /// at the previous size.
    private struct StyledInlineKey: Hashable {
        let text: String
        let fontSize: CGFloat
    }

    static func blocks(for markdown: String) -> [MarkdownBlock] {
        if let cached = blockCache[markdown] { return cached }
        let parsed = MarkdownBlock.parse(markdown)
        if blockCache.count >= limit { blockCache.removeAll(keepingCapacity: true) }
        blockCache[markdown] = parsed
        return parsed
    }

    /// Inline-only parsing (bold, italic, inline code, links) that keeps
    /// single newlines inside the block rather than collapsing them.
    static func inline(_ text: String) -> AttributedString {
        if let cached = inlineCache[text] { return cached }
        let parsed = (try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        ))) ?? AttributedString(text)
        if inlineCache.count >= limit { inlineCache.removeAll(keepingCapacity: true) }
        inlineCache[text] = parsed
        return parsed
    }

    /// `inline(_:)` split at its code spans, each one earning a `chipID` a
    /// `CodeChipRenderer` can paint a rounded chip behind. Cached like the
    /// parse itself — the split walks every run and rewrites ranges, which is
    /// far too costly to redo on each render.
    ///
    /// No padding character is added around a code span: that would become
    /// part of the copied text. Padding comes from `kern` instead, on the
    /// character before the span and the span's own last character — a real
    /// layout change the renderer's chip rect then follows.
    static func styledInline(_ text: String, fontSize: CGFloat) -> StyledInline {
        let key = StyledInlineKey(text: text, fontSize: fontSize)
        if let cached = styledInlineCache[key] { return cached }

        let attributed = inline(text)
        let codeFont = Font.system(size: fontSize * 0.92, design: .monospaced)
        let pad = fontSize * 0.25

        var segments: [StyledInline.Segment] = []
        var nextChipID = 0
        for run in attributed.runs {
            let piece = AttributedString(attributed[run.range])
            if run.inlinePresentationIntent?.contains(.code) == true {
                var code = piece
                code.font = codeFont
                segments.append(StyledInline.Segment(text: code, chipID: nextChipID))
                nextChipID += 1
            } else if let lastIndex = segments.indices.last, segments[lastIndex].chipID == nil {
                segments[lastIndex].text.append(piece)
            } else {
                segments.append(StyledInline.Segment(text: piece, chipID: nil))
            }
        }

        for index in segments.indices where segments[index].chipID != nil {
            if index > 0, segments[index - 1].chipID == nil {
                segments[index - 1].text.kernLastCharacter(pad)
            }
            segments[index].text.kernLastCharacter(pad)
        }

        let styled = StyledInline(
            segments: segments,
            hasCode: segments.contains { $0.chipID != nil },
            pad: pad
        )
        if styledInlineCache.count >= limit { styledInlineCache.removeAll(keepingCapacity: true) }
        styledInlineCache[key] = styled
        return styled
    }

    /// Drops everything. For tests.
    static func reset() {
        blockCache.removeAll()
        inlineCache.removeAll()
        styledInlineCache.removeAll()
    }
}

/// Inline-parsed text, split at its code spans so each one can carry a
/// `CodeChipAttribute` instead of a flat `backgroundColor`.
///
/// A `Segment` with a `chipID` is one code span; consecutive non-code runs
/// fold into a single `nil`-chip segment, so a mix of bold and plain prose
/// between two code spans stays one segment with its runs intact.
struct StyledInline: Equatable {
    struct Segment: Equatable {
        var text: AttributedString
        var chipID: Int?
    }

    var segments: [Segment]
    var hasCode: Bool
    var pad: CGFloat

    /// Concatenates the segments into one `Text`, tagging each chip segment
    /// with the attribute `CodeChipRenderer` groups runs by.
    func text() -> Text {
        segments.reduce(Text(verbatim: "")) { concatenated, segment in
            let piece = Text(segment.text)
            guard let chipID = segment.chipID else { return concatenated + piece }
            return concatenated + piece.customAttribute(CodeChipAttribute(id: chipID))
        }
    }

    /// Uppercases every segment's characters while preserving each segment's
    /// runs (and its chip id), for heading levels that rank by case rather
    /// than by size.
    func uppercased() -> StyledInline {
        StyledInline(
            segments: segments.map { Segment(text: $0.text.uppercasedPreservingRuns(), chipID: $0.chipID) },
            hasCode: hasCode,
            pad: pad
        )
    }
}

private extension AttributedString {
    /// Sets `kern` on this string's own last character, for the padding
    /// `CodeChipRenderer` reads on either side of a chip.
    mutating func kernLastCharacter(_ pad: CGFloat) {
        guard !characters.isEmpty else { return }
        let lastCharacterStart = characters.index(before: endIndex)
        self[lastCharacterStart..<endIndex].kern = pad
    }

    /// Uppercases character by character while keeping each run's attributes,
    /// since uppercasing the plain string first would lose run boundaries
    /// (and, for a link, carry its URL along with the visible text).
    func uppercasedPreservingRuns() -> AttributedString {
        runs.reduce(into: AttributedString()) { result, run in
            var raised = AttributedString(String(self[run.range].characters).uppercased())
            raised.mergeAttributes(run.attributes)
            result.append(raised)
        }
    }
}
