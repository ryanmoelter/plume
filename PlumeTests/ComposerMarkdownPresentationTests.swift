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
        #expect(stars == .tertiaryLabelColor)
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
        #expect(decorations.bullets[1].origin.x > decorations.bullets[0].origin.x)
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
