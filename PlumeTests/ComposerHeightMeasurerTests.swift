import AppKit
import Testing
@testable import Plume

/// The composer's off-to-the-side height measurement, checked against the
/// height a live text view actually lays out.
@MainActor
struct ComposerHeightMeasurerTests {
    private static let style = ComposerTextStyle(bodySize: 14)
    private static let inset = NSSize(width: 0, height: 9)
    private static let width: CGFloat = 300

    private static func makeTextView(markdown: String) -> ComposerNSTextView {
        let view = ComposerNSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        view.textContainerInset = inset
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        view.observeStorage()
        // The view re-derives every font from its own style after each edit,
        // so it has to be the style the document was built with.
        view.style = style
        view.typingAttributes = style.attributes(for: .paragraph)
        view.textStorage?.setAttributedString(
            ComposerDocument.attributedString(markdown: markdown, style: style)
        )
        view.layout()
        return view
    }

    private static func makeMeasurer(for view: ComposerNSTextView) -> ComposerHeightMeasurer {
        let measurer = ComposerHeightMeasurer(
            lineFragmentPadding: view.textContainer?.lineFragmentPadding ?? 0
        )
        measurer.emptyAttributes = view.typingAttributes
        return measurer
    }

    /// What the live view itself lays out, so a measurement can be compared
    /// against the thing it stands in for.
    private static func liveHeight(of view: ComposerNSTextView) -> CGFloat {
        let layoutManager = view.textLayoutManager!
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        return layoutManager.usageBoundsForTextContainer.maxY + inset.height * 2
    }

    private static func measure(_ view: ComposerNSTextView) -> CGFloat {
        makeMeasurer(for: view).height(
            for: view.textStorage!,
            width: width,
            inset: inset,
            revision: view.documentRevision
        )
    }

    @Test(arguments: [
        "One line.",
        "A paragraph long enough to wrap at three hundred points of width, several times over, so the measurement has more than one line fragment to add up.",
        "- first item\n- second item\n- third item",
        "```\nlet x = 1\nlet y = 2\n```",
    ])
    func measuredHeightMatchesTheLiveView(markdown: String) {
        let view = Self.makeTextView(markdown: markdown)
        #expect(abs(Self.measure(view) - Self.liveHeight(of: view)) < 0.5)
    }

    @Test func anEmptyDocumentMeasuresOneLine() {
        let view = Self.makeTextView(markdown: "")
        let oneLine = Self.makeTextView(markdown: "x")
        #expect(abs(Self.measure(view) - Self.measure(oneLine)) < 0.5)
    }

    @Test func aTrailingNewlineCountsItsEmptyLine() {
        let one = Self.makeTextView(markdown: "one")
        let view = Self.makeTextView(markdown: "one")
        view.textStorage?.append(NSAttributedString(
            string: "\n",
            attributes: Self.style.attributes(for: .paragraph)
        ))
        let lineHeight = Self.measure(one) - Self.inset.height * 2
        #expect(abs(Self.measure(view) - Self.measure(one) - lineHeight) < 1)
    }

    @Test func aHeadingIsTallerThanTheSameStringAsAParagraph() {
        let heading = Self.makeTextView(markdown: "# Title")
        let paragraph = Self.makeTextView(markdown: "Title")
        #expect(Self.measure(heading) > Self.measure(paragraph))
    }

    @Test func anAttributeOnlyEditBumpsTheRevisionAndTheCachedHeight() {
        let view = Self.makeTextView(markdown: "One line.")
        let measurer = Self.makeMeasurer(for: view)
        let storage = view.textStorage!

        let before = view.documentRevision
        let firstHeight = measurer.height(for: storage, width: Self.width, inset: Self.inset, revision: before)

        // A block-kind change is the attribute-only edit that legitimately
        // changes the height; a bare font change is repaired straight back.
        storage.addAttribute(
            .plumeBlock,
            value: ComposerBlockKind.heading(1),
            range: NSRange(location: 0, length: storage.length)
        )
        let after = view.documentRevision
        #expect(after > before)

        let secondHeight = measurer.height(for: storage, width: Self.width, inset: Self.inset, revision: after)
        #expect(secondHeight > firstHeight)
    }
}

/// The `NSTextList` stacks a list paragraph's paragraph style carries.
/// Decimal numbering continues only across paragraphs sharing one instance.
struct ComposerListsTests {
    @Test func consecutiveNumberedItemsShareOneList() {
        let first = ComposerLists.lists(for: .numbered(depth: 0, number: 1), continuing: [])
        let second = ComposerLists.lists(for: .numbered(depth: 0, number: 2), continuing: first)

        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(first[0] === second[0])
        #expect(first[0].markerFormat == .decimal)
    }

    @Test func aDeeperItemAppendsRatherThanReplaces() {
        let outer = ComposerLists.lists(for: .numbered(depth: 0, number: 1), continuing: [])
        let inner = ComposerLists.lists(for: .numbered(depth: 1, number: 1), continuing: outer)

        #expect(inner.count == 2)
        #expect(inner[0] === outer[0])
        #expect(inner[1] !== outer[0])
    }

    @Test func switchingFromBulletsToNumbersStartsANewList() {
        let bullets = ComposerLists.lists(for: .bullet(depth: 0), continuing: [])
        let numbers = ComposerLists.lists(for: .numbered(depth: 0, number: 1), continuing: bullets)

        #expect(bullets[0].markerFormat == .disc)
        #expect(numbers[0].markerFormat == .decimal)
        #expect(bullets[0] !== numbers[0])
    }

    @Test func bulletMarkersCycleByDepth() {
        #expect(ComposerLists.bulletFormat(depth: 0) == .disc)
        #expect(ComposerLists.bulletFormat(depth: 1) == .circle)
        #expect(ComposerLists.bulletFormat(depth: 2) == .square)
        #expect(ComposerLists.bulletFormat(depth: 3) == .disc)
    }

    @Test func aNonListParagraphCarriesNoLists() {
        #expect(ComposerLists.lists(for: .paragraph, continuing: []).isEmpty)
    }
}
