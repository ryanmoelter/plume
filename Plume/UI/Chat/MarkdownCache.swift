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
    private static var styledInlineCache: [StyledInlineKey: AttributedString] = [:]
    private static var chippedInlineCache: [ChippedInlineKey: StyledInline] = [:]

    /// The chip's fill is applied at draw time, so unlike `StyledInlineKey`
    /// a light/dark switch needs no miss.
    private struct ChippedInlineKey: Hashable {
        let text: String
        let fontSize: CGFloat
        let codeFontSizeMultiplier: Double
    }

    /// Styling depends on the body size, the resolved tint, and the code
    /// font's own size multiplier, as well as the text — all key the cache,
    /// so a font-size change, a code-size change, or a light/dark switch has
    /// to miss rather than return the previous appearance's chips.
    private struct StyledInlineKey: Hashable {
        let text: String
        let fontSize: CGFloat
        let tint: Color
        let codeFontSizeMultiplier: Double
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

    /// `inline(_:)` plus the inline-code treatment: the monospace face and a
    /// tinted background. Cached like the parse itself — the styling walks
    /// every run and rewrites ranges, which is far too costly to redo on
    /// each render.
    ///
    /// No padding is added around the code span: `AttributedString`'s flat
    /// `backgroundColor` can't express real layout padding, and a padding
    /// character would become part of the copied text.
    static func styledInline(
        _ text: String,
        fontSize: CGFloat,
        tint: Color
    ) -> AttributedString {
        let codeFontSizeMultiplier = AppSettings.shared.codeFontSizeMultiplier
        let key = StyledInlineKey(
            text: text,
            fontSize: fontSize,
            tint: tint,
            codeFontSizeMultiplier: codeFontSizeMultiplier
        )
        if let cached = styledInlineCache[key] { return cached }

        var attributed = inline(text)
        let codeFont = Font.chatCode(size: fontSize * codeFontSizeMultiplier)
        for run in attributed.runs where run.inlinePresentationIntent == .code {
            attributed[run.range].font = codeFont
            attributed[run.range].backgroundColor = tint
        }

        if styledInlineCache.count >= limit { styledInlineCache.removeAll(keepingCapacity: true) }
        styledInlineCache[key] = attributed
        return attributed
    }

    /// `inline(_:)` split at its code spans and reference chips, each one a
    /// segment with a `chip` that `InlineChips` paints a rounded chip behind.
    /// For text that draws through a `TextRenderer`; selectable text ignores
    /// its renderer, so it takes `styledInline`'s flat background instead.
    ///
    /// A reference chip is a link whose label opens with
    /// `ReferenceChipText.placeholder`, kerned wide enough to hold its icon.
    /// The chip's padding is `kern` on the character before the span and on
    /// the span's own last character, never a padding character, which would
    /// ride along into the copied text.
    static func chippedInline(_ text: String, fontSize: CGFloat) -> StyledInline {
        let codeFontSizeMultiplier = AppSettings.shared.codeFontSizeMultiplier
        let key = ChippedInlineKey(text: text, fontSize: fontSize, codeFontSizeMultiplier: codeFontSizeMultiplier)
        if let cached = chippedInlineCache[key] { return cached }

        let attributed = inline(text)
        let codeFont = Font.chatCode(size: fontSize * codeFontSizeMultiplier)
        let pad = fontSize * 0.25

        var segments: [StyledInline.Segment] = []
        var nextChipID = 0
        for run in attributed.runs {
            let piece = AttributedString(attributed[run.range])
            if run.inlinePresentationIntent?.contains(.code) == true {
                var code = piece
                code.font = codeFont
                segments.append(StyledInline.Segment(text: code, chip: .code(id: nextChipID)))
                nextChipID += 1
            } else if let link = run.link, piece.characters.first == ReferenceChipText.placeholder {
                var reference = piece
                reference[reference.startIndex..<reference.characters.index(after: reference.startIndex)].kern =
                    ReferenceChipMetrics(fontSize: fontSize).placeholderKern(brand: ReferenceTarget.classify(link, base: nil)?.brand)
                segments.append(StyledInline.Segment(text: reference, chip: .reference(id: nextChipID, url: link)))
                nextChipID += 1
            } else if let link = run.link, let last = segments.indices.last,
                      case .reference(_, link) = segments[last].chip {
                segments[last].text.append(piece)
            } else if let last = segments.indices.last, segments[last].chip == nil {
                segments[last].text.append(piece)
            } else {
                segments.append(StyledInline.Segment(text: piece, chip: nil))
            }
        }
        for index in segments.indices where segments[index].chip != nil {
            if index > 0, segments[index - 1].chip == nil {
                segments[index - 1].text.kernLastCharacter(pad)
            }
            segments[index].text.kernLastCharacter(pad)
        }

        let styled = StyledInline(segments: segments, pad: pad)
        if chippedInlineCache.count >= limit { chippedInlineCache.removeAll(keepingCapacity: true) }
        chippedInlineCache[key] = styled
        return styled
    }

    /// Drops everything. For tests.
    static func reset() {
        blockCache.removeAll()
        inlineCache.removeAll()
        styledInlineCache.removeAll()
        chippedInlineCache.removeAll()
    }
}

/// Inline-parsed text split at its code spans and reference chips, so each
/// one carries a chip attribute rather than a flat `backgroundColor`.
///
/// Consecutive runs outside a chip fold into one segment with no `chip`,
/// keeping their own runs, so bold and plain prose between two chips stay
/// intact.
struct StyledInline: Equatable {
    struct Segment: Equatable {
        enum Chip: Equatable {
            case code(id: Int)
            case reference(id: Int, url: URL)
        }

        var text: AttributedString
        var chip: Chip?

        var chipID: Int? {
            if case .code(let id) = chip { id } else { nil }
        }
    }

    var segments: [Segment]
    var pad: CGFloat

    var hasCode: Bool { segments.contains { $0.chipID != nil } }
    var hasChips: Bool { segments.contains { $0.chip != nil } }

    var referenceURLs: [URL] {
        segments.compactMap { if case .reference(_, let url) = $0.chip { url } else { nil } }
    }

    /// The characters `text()` draws, which the reveal and the selection
    /// count in.
    var plainText: String {
        segments.map { String($0.text.characters) }.joined()
    }

    func text() -> Text {
        segments.reduce(Text(verbatim: "")) { joined, segment in
            switch segment.chip {
            case nil:
                return joined + Text(segment.text)
            case .code(let id):
                return joined + Text(segment.text).customAttribute(CodeChipAttribute(id: id))
            case let .reference(id, url):
                // The placeholder is a run of its own, so the renderer can
                // find where the icon goes.
                let text = segment.text
                let split = text.characters.index(after: text.startIndex)
                let placeholder = Text(AttributedString(text[text.startIndex..<split]))
                    .customAttribute(ReferenceChipAttribute(id: id, url: url, isPlaceholder: true))
                let title = Text(AttributedString(text[split..<text.endIndex]))
                    .customAttribute(ReferenceChipAttribute(id: id, url: url, isPlaceholder: false))
                return joined + placeholder + title
            }
        }
    }

    /// Uppercased character by character, keeping each run's attributes and
    /// each segment's chip.
    func uppercased() -> StyledInline {
        StyledInline(
            segments: segments.map { Segment(text: $0.text.uppercasedPreservingRuns(), chip: $0.chip) },
            pad: pad
        )
    }

    /// Colors the first `length` characters, for a slash command's name.
    func coloringPrefix(_ length: Int, _ color: Color) -> StyledInline {
        var remaining = length
        var result = self
        for index in result.segments.indices where remaining > 0 {
            let count = result.segments[index].text.characters.count
            result.segments[index].text.colorPrefix(remaining, color)
            remaining -= count
        }
        return result
    }
}

extension AttributedString {
    mutating func colorPrefix(_ length: Int, _ color: Color) {
        guard length > 0, !characters.isEmpty else { return }
        let end = characters.index(startIndex, offsetBy: min(length, characters.count))
        self[startIndex..<end].foregroundColor = color
    }

    fileprivate mutating func kernLastCharacter(_ pad: CGFloat) {
        guard !characters.isEmpty else { return }
        self[characters.index(before: endIndex)..<endIndex].kern = pad
    }

    /// Uppercasing the plain string first would lose run boundaries, and
    /// carry a link's URL up with its visible text.
    func uppercasedPreservingRuns() -> AttributedString {
        runs.reduce(into: AttributedString()) { result, run in
            var raised = AttributedString(String(self[run.range].characters).uppercased())
            raised.mergeAttributes(run.attributes)
            result.append(raised)
        }
    }
}
