import AppKit
import Testing
@testable import Plume

/// The geometry `ComposerDecorations` derives from a live TextKit 2 layout:
/// one chip per line a code span occupies, one full-width box per fenced
/// block, and one bar per run of quote paragraphs.
@MainActor
struct ComposerDecorationsTests {
    private static let style = ComposerTextStyle(bodySize: 14)

    private static func makeTextView(markdown: String, width: CGFloat) -> ComposerNSTextView {
        let view = ComposerNSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        view.textContainerInset = NSSize(width: 0, height: 9)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        view.observeStorage()
        view.style = style
        view.textStorage?.setAttributedString(
            ComposerDocument.attributedString(markdown: markdown, style: style)
        )
        view.layout()
        return view
    }

    @Test func wrappedCodeSpanGetsAChipPerLine() {
        let view = Self.makeTextView(
            markdown: "`alpha bravo charlie delta echo foxtrot golf hotel india`",
            width: 140
        )
        let decorations = ComposerDecorations.rects(in: view, style: Self.style)

        #expect(decorations.chips.count >= 2)
        let lines = Set(decorations.chips.map { $0.minY.rounded() })
        #expect(lines.count == decorations.chips.count)
        #expect(decorations.codeBoxes.isEmpty)
    }

    @Test func aCodeSpanOnOneLineIsOneChipWiderThanItsText() throws {
        let view = Self.makeTextView(markdown: "a `chip` b", width: 400)
        let decorations = ComposerDecorations.rects(in: view, style: Self.style)

        #expect(decorations.chips.count == 1)
        let chip = try #require(decorations.chips.first)
        let textWidth = ("chip" as NSString).size(withAttributes: [.font: Self.style.mono]).width
        #expect(chip.width > textWidth)
        #expect(chip.width < textWidth + Self.style.chipPadding * 3)
    }

    @Test func codeBlockParagraphsShareOneFullWidthBox() throws {
        let view = Self.makeTextView(markdown: "```\none\ntwo\nthree\n```", width: 300)
        let decorations = ComposerDecorations.rects(in: view, style: Self.style)

        #expect(decorations.codeBoxes.count == 1)
        let box = try #require(decorations.codeBoxes.first)
        let containerWidth = view.textContainer?.size.width ?? 0
        #expect(abs(box.width - containerWidth) < 0.5)
        #expect(box.height > Self.style.body.boundingRectForFont.height * 2)
        // Chips never open inside a code block.
        #expect(decorations.chips.isEmpty)
    }

    @Test func twoFencedBlocksMakeTwoBoxes() throws {
        let view = Self.makeTextView(markdown: "```\none\n```\n\n```\ntwo\n```", width: 300)
        let decorations = ComposerDecorations.rects(in: view, style: Self.style)

        try #require(decorations.codeBoxes.count == 2)
        let ordered = decorations.codeBoxes.sorted { $0.minY < $1.minY }
        #expect(ordered[0].maxY <= ordered[1].minY + 0.5)
    }

    @Test func consecutiveQuoteParagraphsShareOneBar() throws {
        let view = Self.makeTextView(markdown: "> first line\n> second line", width: 300)
        let decorations = ComposerDecorations.rects(in: view, style: Self.style)

        #expect(decorations.quoteBars.count == 1)
        let bar = try #require(decorations.quoteBars.first)
        #expect(bar.width == Self.style.quoteBarWidth)
        #expect(bar.height > Self.style.body.boundingRectForFont.height * 1.5)
    }

    /// The leading edge of the glyphs of `range`, in the view's coordinates —
    /// what the chip's own leading edge is measured against.
    private static func segmentMinX(of range: NSRange, in view: ComposerNSTextView) -> CGFloat? {
        guard let layoutManager = view.textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
              let start = contentStorage.location(contentStorage.documentRange.location, offsetBy: range.location),
              let end = contentStorage.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end)
        else { return nil }
        var minX: CGFloat?
        layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, frame, _, _ in
            if frame.width > 0 { minX = min(minX ?? frame.minX, frame.minX) }
            return true
        }
        return minX.map { $0 + view.textContainerOrigin.x }
    }

    /// Chip padding is `kern` rather than a padding character, which would
    /// become part of what the user copies and sends. The repair pass writes
    /// it on the character before the span and on the span's last character,
    /// and the chip's leading edge reclaims the first of those — without the
    /// kern the chip would be drawn over the preceding glyph.
    @Test func repairKernsTheCharactersAroundAChip() throws {
        let view = Self.makeTextView(markdown: "a `chip` b", width: 400)
        let storage = try #require(view.textStorage)
        let code = NSRange(location: 2, length: 4)
        let kern: (Int) -> Double? = { location in
            (storage.attribute(.kern, at: location, effectiveRange: nil) as? NSNumber)?.doubleValue
        }

        #expect(kern(code.location - 1) == Double(Self.style.chipPadding))
        #expect(kern(NSMaxRange(code) - 1) == Double(Self.style.chipPadding))
        #expect(kern(0) == nil)
        #expect(kern(storage.length - 1) == nil)

        let chip = try #require(ComposerDecorations.rects(in: view, style: Self.style).chips.first)
        let glyphs = try #require(Self.segmentMinX(of: code, in: view))
        #expect(abs(chip.minX - (glyphs - Self.style.chipPadding)) < 0.5)
    }

    @Test func plainProseDecoratesNothing() {
        let view = Self.makeTextView(markdown: "Just a plain paragraph.", width: 300)
        let decorations = ComposerDecorations.rects(in: view, style: Self.style)

        #expect(decorations == ComposerDecorations.Decorations())
    }
}
