import CoreGraphics
import Testing
@testable import Plume

struct ChatContentBalanceTests {
    private let contentWidth: CGFloat = 640
    private let minimapWidth: CGFloat = 17

    @Test func narrowerThanContentWidthAddsNoLeftSpace() {
        let inset = ChatContentBalance.leftInset(
            viewportWidth: 500,
            contentWidth: contentWidth,
            minimapWidth: minimapWidth
        )
        #expect(inset == 0)
    }

    @Test func exactlyContentWidthAddsNoLeftSpace() {
        let inset = ChatContentBalance.leftInset(
            viewportWidth: contentWidth,
            contentWidth: contentWidth,
            minimapWidth: minimapWidth
        )
        #expect(inset == 0)
    }

    @Test func betweenContentWidthAndTheWideThresholdTracksHalfTheExtraSpace() {
        let viewportWidth = contentWidth + 20
        let inset = ChatContentBalance.leftInset(
            viewportWidth: viewportWidth,
            contentWidth: contentWidth,
            minimapWidth: minimapWidth
        )
        #expect(inset == 10)
    }

    @Test func atTheWideThresholdInsetEqualsTheMinimapWidth() {
        let viewportWidth = contentWidth + minimapWidth * 2
        let inset = ChatContentBalance.leftInset(
            viewportWidth: viewportWidth,
            contentWidth: contentWidth,
            minimapWidth: minimapWidth
        )
        #expect(inset == minimapWidth)
    }

    @Test func widerThanTheThresholdHoldsAtTheMinimapWidth() {
        let inset = ChatContentBalance.leftInset(
            viewportWidth: contentWidth + minimapWidth * 2 + 400,
            contentWidth: contentWidth,
            minimapWidth: minimapWidth
        )
        #expect(inset == minimapWidth)
    }

    @Test func aNarrowerViewportThanContentWidthStillFloorsAtZero() {
        let inset = ChatContentBalance.leftInset(
            viewportWidth: 0,
            contentWidth: contentWidth,
            minimapWidth: minimapWidth
        )
        #expect(inset == 0)
    }
}
