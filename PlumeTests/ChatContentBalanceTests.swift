import CoreGraphics
import Testing
@testable import Plume

/// The property that matters is alignment: a chat row's left edge sits where
/// the composer's does, at every width that can seat both the text column and
/// the minimap.
struct ChatContentBalanceTests {
    private let contentWidth: CGFloat = 640
    private let minimapWidth: CGFloat = 17

    /// Where a chat row's text starts, given the inset the balance chose. The
    /// row centers itself in whatever span is left once the inset and the
    /// minimap have taken theirs.
    private func rowLeftEdge(viewportWidth: CGFloat) -> CGFloat {
        let inset = ChatContentBalance.leftInset(
            viewportWidth: viewportWidth,
            contentWidth: contentWidth,
            minimapWidth: minimapWidth
        )
        let span = viewportWidth - minimapWidth - inset
        return inset + max(span - contentWidth, 0) / 2
    }

    /// The composer reserves nothing for the minimap, so it centers in the
    /// whole viewport.
    private func composerLeftEdge(viewportWidth: CGFloat) -> CGFloat {
        max((viewportWidth - contentWidth) / 2, 0)
    }

    @Test(arguments: [700.0, 900.0, 1200.0, 1600.0, 2400.0])
    func theChatLinesUpWithTheComposer(viewportWidth: CGFloat) {
        #expect(abs(rowLeftEdge(viewportWidth: viewportWidth)
            - composerLeftEdge(viewportWidth: viewportWidth)) < 0.001)
    }

    /// Below the width that seats both, the minimap keeps its column and the
    /// text gives up the alignment rather than the other way round.
    @Test func aViewportTooNarrowForBothGivesTheSpaceToTheText() {
        #expect(ChatContentBalance.leftInset(
            viewportWidth: contentWidth,
            contentWidth: contentWidth,
            minimapWidth: minimapWidth
        ) == 0)
    }

    @Test func theInsetNeverExceedsTheMinimapsOwnColumn() {
        for viewportWidth in stride(from: 0.0, through: 3000.0, by: 7.0) {
            let inset = ChatContentBalance.leftInset(
                viewportWidth: viewportWidth,
                contentWidth: contentWidth,
                minimapWidth: minimapWidth
            )
            #expect(inset >= 0 && inset <= minimapWidth)
        }
    }

    /// A jump here would shift the whole transcript sideways mid-resize.
    @Test func theInsetMovesContinuously() {
        var previous = ChatContentBalance.leftInset(
            viewportWidth: 0,
            contentWidth: contentWidth,
            minimapWidth: minimapWidth
        )
        for viewportWidth in stride(from: 0.5, through: 3000.0, by: 0.5) {
            let inset = ChatContentBalance.leftInset(
                viewportWidth: viewportWidth,
                contentWidth: contentWidth,
                minimapWidth: minimapWidth
            )
            #expect(abs(inset - previous) <= 0.5)
            previous = inset
        }
    }

    @Test func aDegenerateViewportFloorsAtZero() {
        #expect(ChatContentBalance.leftInset(
            viewportWidth: 0,
            contentWidth: contentWidth,
            minimapWidth: minimapWidth
        ) == 0)
    }
}
