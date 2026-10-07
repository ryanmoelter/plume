import AppKit
import Testing
@testable import Plume

/// The styler hides and dims markers and indents list content by depth;
/// `ComposerDecorations` finds a decoration for each construct, inside the
/// composer's visible edge, without dropping the view to TextKit 1.
@MainActor
struct ComposerMarkdownPresentationTests {
    private let metrics = ComposerMarkdownMetrics(fontSize: 13)

    private func styledView(_ text: String) -> ComposerNSTextView {
        let textView = ComposerNSTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        textView.string = text
        MarkdownComposerStyler.style(textView.textStorage!, text: text, fontSize: metrics.fontSize)
        textView.markdownMetrics = metrics
        return textView
    }

    private func attribute<T>(_ key: NSAttributedString.Key, at location: Int, in view: NSTextView) -> T? {
        view.textStorage?.attribute(key, at: location, effectiveRange: nil) as? T
    }

    // MARK: - Styler

    @Test func hiddenMarkersAreClear() {
        let view = styledView("- a\n> b\n- [ ] c")
        let bullet: NSColor? = attribute(.foregroundColor, at: 0, in: view)
        let quote: NSColor? = attribute(.foregroundColor, at: 4, in: view)
        let box: NSColor? = attribute(.foregroundColor, at: 10, in: view)
        #expect(bullet == .clear)
        #expect(quote == .clear)
        #expect(box == .clear)
    }

    @Test func shownMarkersAreDimmed() {
        let view = styledView("# Title **b**")
        let hash: NSColor? = attribute(.foregroundColor, at: 0, in: view)
        let stars: NSColor? = attribute(.foregroundColor, at: 8, in: view)
        let content: NSColor? = attribute(.foregroundColor, at: 10, in: view)
        #expect(hash == .tertiaryLabelColor)
        #expect(stars == .secondaryLabelColor)
        #expect(content == .labelColor)
    }

    @Test func listIndentGrowsWithDepth() {
        let view = styledView("- a\n  - b\n    - c")
        let indents: [CGFloat] = [0, 4, 10].map {
            let style: NSParagraphStyle? = attribute(.paragraphStyle, at: $0, in: view)
            return style?.headIndent ?? 0
        }
        #expect(indents[0] > 0)
        #expect(indents[1] > indents[0])
        #expect(indents[2] > indents[1])
    }

    @Test func itemTextSharesOneColumnWhateverItsMarker() throws {
        let text = "- a\n- [ ] b\n- [x] c\n> - d"
        let view = styledView(text)
        let layoutManager = try #require(view.textLayoutManager)
        let contentStorage = try #require(layoutManager.textContentManager as? NSTextContentStorage)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        func minX(at location: Int) -> CGFloat? {
            guard let start = contentStorage.location(contentStorage.documentRange.location, offsetBy: location),
                  let end = contentStorage.location(start, offsetBy: 1),
                  let range = NSTextRange(location: start, end: end)
            else { return nil }
            var x: CGFloat?
            layoutManager.enumerateTextSegments(in: range, type: .standard, options: []) { _, segment, _, _ in
                x = segment.minX
                return false
            }
            return x
        }
        let ns = text as NSString
        let xs = ["a", "b", "c"].compactMap { minX(at: ns.range(of: $0).location) }
        #expect(xs.count == 3)
        #expect(xs.allSatisfy { abs($0 - xs[0]) < 0.5 }, "\(xs)")
        let quoted = try #require(minX(at: ns.range(of: "d").location))
        #expect(abs(quoted - xs[0] - metrics.quoteStep) < 0.5)
    }

    @Test(arguments: ["- top\n  - nested\n- [ ] task", "> a\n> b\n> c", "1. a\n2. b\n3. c"])
    func hiddenMarkersDoNotShrinkTheMeasuredHeight(_ text: String) {
        func height(of text: String, styled: Bool) -> CGFloat {
            let host = ScrollableComposerTextView()
            host.composerTextView.string = text
            host.composerTextView.bodyFont = metrics.body
            if styled {
                MarkdownComposerStyler.style(host.composerTextView.textStorage!, text: text, fontSize: metrics.fontSize)
            }
            return host.contentHeight(forWidth: 400)
        }
        let plain = height(of: "a\nb\nc", styled: false)
        let styled = height(of: text, styled: true)
        #expect(styled >= plain - 0.5, "\(styled) vs \(plain)")
    }

    @Test func listTouchingTextIsSpacedFromIt() {
        let text = "intro\n- a\n  more\n- b\noutro"
        let view = styledView(text)
        let ns = text as NSString
        func spacing(_ line: String) -> (before: CGFloat, after: CGFloat) {
            let style: NSParagraphStyle? = attribute(.paragraphStyle, at: ns.range(of: line).location, in: view)
            return (style?.paragraphSpacingBefore ?? 0, style?.paragraphSpacing ?? 0)
        }
        #expect(spacing("- a") == (metrics.listSpacing, 0))
        #expect(spacing("  more") == (0, 0))
        #expect(spacing("- b") == (0, metrics.listSpacing))
        #expect(spacing("intro") == (0, 0))
    }

    @Test func blankLinesAlreadySeparateAList() {
        let text = "intro\n\n- a\n\noutro"
        let view = styledView(text)
        let style: NSParagraphStyle? = attribute(.paragraphStyle, at: 7, in: view)
        #expect(style?.paragraphSpacingBefore == 0)
        #expect(style?.paragraphSpacing == 0)
    }

    // MARK: - Decorations

    @Test func staysOnTextKit2() {
        let view = styledView("- a\n`b`\n```\nc\n```")
        _ = ComposerDecorations.rects(in: view, metrics: metrics)
        view.display()
        #expect(view.textLayoutManager != nil)
    }

    @Test func bulletsStepRightByDepth() {
        let decorations = ComposerDecorations.rects(in: styledView("- a\n  - b"), metrics: metrics)
        #expect(decorations.bullets.count == 2)
        #expect(decorations.bullets[1].baselineOrigin.x > decorations.bullets[0].baselineOrigin.x)
        #expect(decorations.bullets.map(\.glyph) == ["•", "◦"])
    }

    @Test func oneBarPerQuoteLevel() {
        let decorations = ComposerDecorations.rects(in: styledView("> > deep"), metrics: metrics)
        #expect(decorations.quoteBars.count == 2)
        #expect(decorations.quoteBars.allSatisfy { $0.minX >= 5 })
    }

    @Test func codeBoxSitsInsideTheVisibleEdge() {
        let decorations = ComposerDecorations.rects(in: styledView("```\ncode\n```"), metrics: metrics)
        #expect(decorations.codeBoxes.count == 1)
        #expect(decorations.codeBoxes.allSatisfy { $0.minX >= 5 })
    }

    @Test func chipPaddingIsEvenOnBothSides() throws {
        let text = "a `code` b"
        let view = styledView(text)
        let layoutManager = try #require(view.textLayoutManager)
        let contentStorage = try #require(layoutManager.textContentManager as? NSTextContentStorage)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        func segment(_ location: Int) -> NSRect {
            let start = contentStorage.location(contentStorage.documentRange.location, offsetBy: location)!
            let range = NSTextRange(location: start, end: contentStorage.location(start, offsetBy: 1)!)!
            var rect = NSRect.zero
            layoutManager.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
                rect = frame
                return false
            }
            return rect.offsetBy(dx: view.textContainerOrigin.x, dy: 0)
        }
        let chip = try #require(ComposerDecorations.rects(in: view, metrics: metrics).chips.first)
        // Each code-font glyph inside the span has the same advance, so the
        // backticks' glyph edges follow from the first and last content letters.
        let advance = segment(3).width
        let openingGlyph = segment(3).minX - advance
        let closingGlyphEnd = segment(6).maxX + advance
        #expect(abs((openingGlyph - chip.minX) - (chip.maxX - closingGlyphEnd)) < 0.5)
        #expect(abs(openingGlyph - chip.minX - metrics.chipPadding) < 0.5)
    }

    @Test func inlineCodeGetsAChip() {
        let decorations = ComposerDecorations.rects(in: styledView("`x` then `y`"), metrics: metrics)
        #expect(decorations.chips.count == 2)
        #expect(decorations.chips.allSatisfy { $0.minX >= 5 })
    }

    @Test func taskAndRuleDecorations() {
        let decorations = ComposerDecorations.rects(in: styledView("- [x] done\n- [ ] open\n\n---"), metrics: metrics)
        #expect(decorations.checkboxes.map(\.isChecked) == [true, false])
        #expect(decorations.rules.count == 1)
        #expect(decorations.bullets.isEmpty)
    }
}
