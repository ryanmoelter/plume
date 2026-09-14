import Foundation
import Testing
@testable import Plume

struct ComposerListEditingTests {
    private func paragraph(_ kind: ComposerBlockKind, isEmpty: Bool = false) -> ComposerListEditing.Paragraph {
        ComposerListEditing.Paragraph(kind: kind, isEmpty: isEmpty)
    }

    // MARK: - newline

    @Test func enterMidNonEmptyBulletContinuesAtSameDepth() {
        let action = ComposerListEditing.newline(in: paragraph(.bullet(depth: 1)), at: false)
        #expect(action == .splitContinuing(kind: .bullet(depth: 1)))
    }

    @Test func enterAtEndOfNonEmptyBulletContinuesTheSameWayAsMidItem() {
        let mid = ComposerListEditing.newline(in: paragraph(.bullet(depth: 1)), at: false)
        let end = ComposerListEditing.newline(in: paragraph(.bullet(depth: 1)), at: true)
        #expect(mid == end)
    }

    @Test func enterOnNonEmptyNumberedItemIncrementsTheNumber() {
        let action = ComposerListEditing.newline(in: paragraph(.numbered(depth: 0, number: 3)), at: true)
        #expect(action == .splitContinuing(kind: .numbered(depth: 0, number: 4)))
    }

    @Test func enterOnEmptyDepthZeroBulletExitsToParagraph() {
        let action = ComposerListEditing.newline(in: paragraph(.bullet(depth: 0), isEmpty: true), at: true)
        #expect(action == .exitToParagraph)
    }

    @Test func enterOnEmptyDepthZeroNumberedItemExitsToParagraph() {
        let action = ComposerListEditing.newline(in: paragraph(.numbered(depth: 0, number: 5), isEmpty: true), at: true)
        #expect(action == .exitToParagraph)
    }

    @Test func enterOnEmptyNestedBulletOutdentsOneLevel() {
        let action = ComposerListEditing.newline(in: paragraph(.bullet(depth: 2), isEmpty: true), at: true)
        #expect(action == .outdent(kind: .bullet(depth: 1)))
    }

    @Test func enterOnEmptyNestedNumberedItemOutdentsOneLevelKeepingItsNumber() {
        let action = ComposerListEditing.newline(in: paragraph(.numbered(depth: 1, number: 2), isEmpty: true), at: true)
        #expect(action == .outdent(kind: .numbered(depth: 0, number: 2)))
    }

    @Test func enterInsideACodeBlockInsertsALiteralNewline() {
        let action = ComposerListEditing.newline(in: paragraph(.codeBlock(language: "swift")), at: false)
        #expect(action == .insertNewlineInBlock)
    }

    @Test func enterOnAHeadingSplitsToAPlainParagraph() {
        let action = ComposerListEditing.newline(in: paragraph(.heading(2)), at: true)
        #expect(action == .splitToParagraph)
    }

    @Test func enterOnANonEmptyQuoteLineContinuesTheQuote() {
        let action = ComposerListEditing.newline(in: paragraph(.quote), at: true)
        #expect(action == .splitToParagraph)
    }

    @Test func enterOnAnEmptyQuoteLineExitsToParagraph() {
        let action = ComposerListEditing.newline(in: paragraph(.quote, isEmpty: true), at: true)
        #expect(action == .exitToParagraph)
    }

    @Test func enterOnAPlainParagraphSplitsContinuingAsParagraph() {
        let action = ComposerListEditing.newline(in: paragraph(.paragraph), at: false)
        #expect(action == .splitContinuing(kind: .paragraph))
    }

    // MARK: - tab

    @Test func tabIndentsABulletUnderAPreviousBulletAtTheSameDepth() {
        let action = ComposerListEditing.tab(in: paragraph(.bullet(depth: 0)), previous: paragraph(.bullet(depth: 0)))
        #expect(action == .indent(kind: .bullet(depth: 1)))
    }

    @Test func tabIndentsANumberedItemKeepingItsNumber() {
        let action = ComposerListEditing.tab(
            in: paragraph(.numbered(depth: 0, number: 2)),
            previous: paragraph(.numbered(depth: 0, number: 1))
        )
        #expect(action == .indent(kind: .numbered(depth: 1, number: 2)))
    }

    @Test func tabClampsAtPreviousItemDepthPlusOne() {
        let action = ComposerListEditing.tab(in: paragraph(.bullet(depth: 1)), previous: paragraph(.bullet(depth: 0)))
        #expect(action == .none)
    }

    @Test func tabAllowsGoingExactlyOneDeeperThanThePreviousItem() {
        let action = ComposerListEditing.tab(in: paragraph(.bullet(depth: 0)), previous: paragraph(.bullet(depth: 1)))
        #expect(action == .indent(kind: .bullet(depth: 1)))
    }

    @Test func tabOnANonListParagraphIsANoOp() {
        let action = ComposerListEditing.tab(in: paragraph(.paragraph), previous: paragraph(.bullet(depth: 0)))
        #expect(action == .none)
    }

    @Test func tabOnAFirstItemWithNoPreviousListItemIsANoOp() {
        let action = ComposerListEditing.tab(in: paragraph(.bullet(depth: 0)), previous: paragraph(.paragraph))
        #expect(action == .none)
    }

    @Test func tabWithNoPreviousParagraphAtAllIsANoOp() {
        let action = ComposerListEditing.tab(in: paragraph(.bullet(depth: 0)), previous: nil)
        #expect(action == .none)
    }

    // MARK: - backtab

    @Test func backtabOutdentsABullet() {
        let action = ComposerListEditing.backtab(in: paragraph(.bullet(depth: 2)))
        #expect(action == .indent(kind: .bullet(depth: 1)))
    }

    @Test func backtabOutdentsANumberedItemKeepingItsNumber() {
        let action = ComposerListEditing.backtab(in: paragraph(.numbered(depth: 1, number: 4)))
        #expect(action == .indent(kind: .numbered(depth: 0, number: 4)))
    }

    @Test func backtabAtDepthZeroIsANoOp() {
        let action = ComposerListEditing.backtab(in: paragraph(.bullet(depth: 0)))
        #expect(action == .none)
    }

    @Test func backtabOnANonListParagraphIsANoOp() {
        let action = ComposerListEditing.backtab(in: paragraph(.paragraph))
        #expect(action == .none)
    }

    // MARK: - backspaceAtStart

    @Test func backspaceOnADepthZeroBulletConvertsToParagraph() {
        let action = ComposerListEditing.backspaceAtStart(of: paragraph(.bullet(depth: 0)))
        #expect(action == .removeMarker(kind: .paragraph))
    }

    @Test func backspaceOnANestedBulletOutdentsOneLevel() {
        let action = ComposerListEditing.backspaceAtStart(of: paragraph(.bullet(depth: 2)))
        #expect(action == .removeMarker(kind: .bullet(depth: 1)))
    }

    @Test func backspaceOnADepthZeroNumberedItemConvertsToParagraph() {
        let action = ComposerListEditing.backspaceAtStart(of: paragraph(.numbered(depth: 0, number: 3)))
        #expect(action == .removeMarker(kind: .paragraph))
    }

    @Test func backspaceOnANestedNumberedItemOutdentsKeepingItsNumber() {
        let action = ComposerListEditing.backspaceAtStart(of: paragraph(.numbered(depth: 1, number: 3)))
        #expect(action == .removeMarker(kind: .numbered(depth: 0, number: 3)))
    }

    @Test func backspaceOnAHeadingConvertsToParagraph() {
        let action = ComposerListEditing.backspaceAtStart(of: paragraph(.heading(3)))
        #expect(action == .removeMarker(kind: .paragraph))
    }

    @Test func backspaceOnAQuoteConvertsToParagraph() {
        let action = ComposerListEditing.backspaceAtStart(of: paragraph(.quote))
        #expect(action == .removeMarker(kind: .paragraph))
    }

    @Test func backspaceOnAPlainParagraphIsANoOp() {
        let action = ComposerListEditing.backspaceAtStart(of: paragraph(.paragraph))
        #expect(action == .none)
    }

    @Test func backspaceInsideACodeBlockIsANoOp() {
        let action = ComposerListEditing.backspaceAtStart(of: paragraph(.codeBlock(language: nil)))
        #expect(action == .none)
    }
}
