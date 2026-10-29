import AppKit
import SwiftUI
import Testing
@testable import Plume

/// A reference chip's icons sit on the chip's vertical midpoint, in the chat
/// and the composer alike, and a Linear or GitHub chip leads with its logo
/// before the status icon.
@MainActor
struct ReferenceChipIconPlacementTests {
    @Test(arguments: [11.0, 13.0, 17.0])
    func theIconRectsShareTheChipsMidpoint(_ fontSize: CGFloat) throws {
        let metrics = ReferenceChipMetrics(fontSize: fontSize)
        let rects = metrics.iconRects(leadingX: 10, chipMidY: 20.25, brand: .github)
        let brand = try #require(rects.brand)
        #expect(abs(rects.status.midY - 20.25) < 0.01)
        #expect(abs(brand.midY - 20.25) < 0.01)
        #expect(abs(rects.status.minX - brand.maxX - metrics.brandGap) < 0.01)
    }

    @Test func onlyABrandedChipReservesALogoSlot() {
        let metrics = ReferenceChipMetrics(fontSize: 13)
        #expect(metrics.iconRects(leadingX: 0, chipMidY: 0, brand: nil).brand == nil)
        #expect(abs(metrics.triggerKern(brand: .linear) - metrics.triggerKern(brand: nil) - metrics.iconSize - metrics.brandGap) < 0.001)
        #expect(abs(metrics.placeholderKern(brand: .github) - metrics.placeholderKern(brand: nil) - metrics.iconSize - metrics.brandGap) < 0.001)
    }

    @Test func targetsNameTheirBrand() {
        #expect(ReferenceTarget.linear(identifier: "PLUME-1").brand == .linear)
        #expect(ReferenceTarget.pullRequest(owner: "o", repo: "r", number: 1).brand == .github)
        #expect(ReferenceTarget.file(path: "/a").brand == nil)
        #expect(MentionReference.Kind.pullRequest(number: 3).brand == .github)
        #expect(MentionReference.Kind.file(path: "a", isDirectory: false).brand == nil)
    }

    /// A font size and a status symbol the chips really draw.
    static let drawnIcons: [(CGFloat, String)] = [
        (13, "circle.fill"),
        (17, "circle.dashed"),
        (13, "arrow.trianglehead.pull"),
        (13, "checkmark.circle.fill"),
    ]

    // MARK: - Chat

    @Test(arguments: Self.drawnIcons)
    func aChatChipsIconDrawsOnItsMidpoint(_ fontSize: CGFloat, symbol: String) throws {
        let url = try #require(URL(string: "https://github.com/o/r/pull/7"))
        let styled = MarkdownCache.chippedInline("See [\u{202F}Fix it](\(url)) now", fontSize: fontSize)
        let chips = InlineChips(
            pad: styled.pad,
            fill: .clear,
            references: ReferenceChipDrawing(
                wash: .clear,
                brandColor: Color(red: 0, green: 0, blue: 1),
                icons: [url: .init(symbol: symbol, color: Color(red: 1, green: 0, blue: 0), brand: .github)],
                metrics: ReferenceChipMetrics(fontSize: fontSize)
            )
        )
        let recorder = PlacementRecorder(chips: chips)
        let renderer = ImageRenderer(content: styled.text().font(.system(size: fontSize)).textRenderer(recorder).fixedSize())
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let placement = try #require(recorder.box.placements.first { $0.icons != nil })
        let icons = try #require(placement.icons)
        let brand = try #require(icons.brand)

        #expect(abs(icons.status.midY - placement.rect.midY) < 0.5)
        #expect(brand.maxX < icons.status.minX)

        let bitmap = NSBitmapImageRep(cgImage: image)
        let red = try #require(inkBounds(in: bitmap, scale: 2, columns: icons.status, rows: placement.rect, matching: isRed))
        #expect(abs(red.midY - placement.rect.midY) < 1)
        let blue = try #require(inkBounds(in: bitmap, scale: 2, columns: brand, rows: placement.rect, matching: isBlue))
        #expect(abs(blue.midY - placement.rect.midY) < 1)
    }

    /// The prose face lacks the placeholder's narrow space, so its fallback
    /// run is shorter than the title's. The chip has to cover the title.
    @Test(arguments: [false, true])
    func aChatChipPadsItsTitleWithoutTouchingTheNextLines(_ isProse: Bool) throws {
        let fontSize: CGFloat = 13
        let url = "https://github.com/o/r/pull/7"
        let styled = MarkdownCache.chippedInline(Array(repeating: "[\u{202F}Fix it](\(url))", count: 12).joined(separator: " "), fontSize: fontSize)
        let chips = InlineChips(pad: styled.pad, fill: .clear)
        let recorder = PlacementRecorder(chips: chips)
        let font: Font = isProse ? .chatProse(size: fontSize, relativeTo: .body) : .system(size: fontSize)
        let renderer = ImageRenderer(content: styled.text().font(font).lineSpacing(fontSize * 0.22).textRenderer(recorder).frame(width: 160))
        _ = renderer.cgImage
        let placements = recorder.box.placements
        let glyphs = recorder.box.glyphBounds
        #expect(Set(placements.map(\.line)).count > 2)
        for placement in placements {
            let ink = try #require(glyphs[placement.line])
            #expect(placement.rect.minY <= ink.top - 1)
            #expect(placement.rect.maxY >= ink.bottom + 1)
        }
        for (upper, lower) in zip(placements, placements.dropFirst()) where lower.line == upper.line + 1 {
            #expect(upper.rect.maxY + chips.lineGap <= lower.rect.minY + 0.01)
        }
    }

    @Test func aChatFileChipHasNoLogo() throws {
        let url = URL(fileURLWithPath: "/tmp/notes.md")
        let styled = MarkdownCache.chippedInline("See [\u{202F}notes.md](\(url.absoluteString)) now", fontSize: 13)
        let chip = try #require(styled.segments.first { $0.chip != nil }?.text)
        #expect(chip.runs[chip.startIndex].kern == ReferenceChipMetrics(fontSize: 13).placeholderKern(brand: nil))
    }

    // MARK: - Composer

    @Test(arguments: Self.drawnIcons)
    func aComposerChipsIconsDrawOnItsMidpoint(_ fontSize: CGFloat, symbol: String) throws {
        let metrics = ComposerMarkdownMetrics(fontSize: fontSize)
        let text = "See #12 now"
        let chip = ComposerReferenceChip(
            range: NSRange(location: 4, length: 3),
            symbol: symbol,
            tint: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
            wash: .clear,
            brand: .github,
            textTint: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        )
        let view = ComposerNSTextView()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 120)
        view.string = text
        MarkdownComposerStyler.style(view.textStorage!, text: text, fontSize: fontSize, references: [chip])
        view.markdownMetrics = metrics
        view.referenceChips = [chip]
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)

        let decoration = try #require(ComposerDecorations.rects(in: view, metrics: metrics).referenceChips.first)
        let rect = try #require(decoration.rects.first)
        let brand = try #require(decoration.brandRect)
        #expect(abs(decoration.iconRect.midY - rect.midY) < 0.5)
        #expect(abs(brand.midY - rect.midY) < 0.5)
        #expect(brand.maxX < decoration.iconRect.minX)
        #expect(rect.minX < brand.minX)

        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
        let red = try #require(inkBounds(in: bitmap, scale: scale, columns: decoration.iconRect, rows: rect, matching: isRed))
        #expect(abs(red.midY - rect.midY) < 1)
        let blue = try #require(inkBounds(in: bitmap, scale: scale, columns: brand, rows: rect, matching: isBlue))
        #expect(abs(blue.midY - rect.midY) < 1)
    }

    @Test func aBrandedComposerChipIsWiderThanAFileChip() throws {
        let metrics = ComposerMarkdownMetrics(fontSize: 13)
        func iconWidth(_ brand: ReferenceChipBrand?) -> CGFloat {
            let text = "See @PLUME-1 now"
            let storage = NSTextStorage(string: text)
            let chip = ComposerReferenceChip(range: NSRange(location: 4, length: 8), symbol: "circle", tint: .red, wash: .clear, brand: brand)
            MarkdownComposerStyler.style(storage, text: text, fontSize: metrics.fontSize, references: [chip])
            return storage.attribute(.kern, at: 4, effectiveRange: nil) as? CGFloat ?? 0
        }
        #expect(iconWidth(.linear) > iconWidth(nil))
    }

    // MARK: - Pixels

    private func isRed(_ color: NSColor) -> Bool {
        color.alphaComponent > 0.5 && color.redComponent > 0.6 && color.greenComponent < 0.35 && color.blueComponent < 0.35
    }

    private func isBlue(_ color: NSColor) -> Bool {
        color.alphaComponent > 0.5 && color.blueComponent > 0.6 && color.redComponent < 0.35 && color.greenComponent < 0.35
    }

    /// The bounds, in points, of the matching pixels within `columns`'
    /// horizontal span and `rows`' vertical one. Row zero is the top.
    private func inkBounds(
        in bitmap: NSBitmapImageRep,
        scale: CGFloat,
        columns: CGRect,
        rows: CGRect,
        matching: (NSColor) -> Bool
    ) -> CGRect? {
        let minX = max(0, Int((columns.minX * scale).rounded(.down)))
        let maxX = min(bitmap.pixelsWide - 1, Int((columns.maxX * scale).rounded(.up)))
        let minY = max(0, Int((rows.minY * scale).rounded(.down)))
        let maxY = min(bitmap.pixelsHigh - 1, Int((rows.maxY * scale).rounded(.up)))
        guard minX <= maxX, minY <= maxY else { return nil }
        var top = Int.max, bottom = Int.min, left = Int.max, right = Int.min
        for y in minY...maxY {
            for x in minX...maxX {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), matching(color) else { continue }
                top = min(top, y)
                bottom = max(bottom, y)
                left = min(left, x)
                right = max(right, x)
            }
        }
        guard top <= bottom else { return nil }
        return CGRect(
            x: CGFloat(left) / scale,
            y: CGFloat(top) / scale,
            width: CGFloat(right - left + 1) / scale,
            height: CGFloat(bottom - top + 1) / scale
        )
    }
}

private final class PlacementBox {
    var placements: [InlineChips.Placement] = []
    /// Per line, the highest ascent and lowest descent of the chips' runs.
    var glyphBounds: [Int: (top: CGFloat, bottom: CGFloat)] = [:]
}

/// Keeps the last draw's placements: SwiftUI draws once to size the `Text`
/// before the pass that lays out every line.
private struct PlacementRecorder: TextRenderer {
    let chips: InlineChips
    let box = PlacementBox()

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        box.placements = chips.placements(in: layout)
        box.glyphBounds = [:]
        for (index, line) in layout.enumerated() {
            for run in line where run[ReferenceChipAttribute.self] != nil {
                let bounds = run.typographicBounds
                let current = box.glyphBounds[index] ?? (.infinity, -.infinity)
                box.glyphBounds[index] = (min(current.top, bounds.origin.y - bounds.ascent), max(current.bottom, bounds.origin.y + bounds.descent))
            }
        }
        InlineChipRenderer(chips: chips).draw(layout: layout, in: &ctx)
    }
}
