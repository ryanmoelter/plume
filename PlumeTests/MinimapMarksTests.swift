import CoreGraphics
import Foundation
import Testing
@testable import Plume

/// The geometry of the minimap's non-prompt marks: an indirect prompt is as
/// thick as a prompt bar, and the end of the conversation outlines one at
/// full opacity whether or not its row is on screen.
@MainActor
struct MinimapMarksTests {
    @Test func theEndOutlineSpansThePromptBarAndHollowsItsThickness() {
        let bar = CGRect(x: 0, y: 10, width: 16, height: 2)
        let outline = MinimapMarks.endOutline(barRect: bar)
        let stroke = MinimapMarks.endStrokeWidth

        let outer = outline.insetBy(dx: -stroke / 2, dy: -stroke / 2)
        let inner = outline.insetBy(dx: stroke / 2, dy: stroke / 2)
        #expect(outer.minX == bar.minX)
        #expect(outer.width == bar.width)
        #expect(inner.height == bar.height)
        #expect(inner.midY == bar.midY)
    }

    @Test func anIndirectMarkIsAsThickAsAPromptBar() {
        for shape in MinimapIndirectShape.allCases {
            #expect(MinimapMarks.indirectSize(shape: shape, promptLength: 16, thickness: 3).height == 3)
        }
    }

    @Test func aDotIsRoundAndALineIsAQuarterOfThePromptBar() {
        #expect(MinimapMarks.indirectSize(shape: .dot, promptLength: 16, thickness: 3) == CGSize(width: 3, height: 3))
        #expect(MinimapMarks.indirectSize(shape: .line, promptLength: 16, thickness: 3).width == 4)
    }

    @Test func theEndDrawsAtFullOpacityEvenOffScreen() {
        #expect(MinimapMarks.opacity(isHovered: false, isEnd: true, isVisible: false) == 1)
        #expect(MinimapMarks.opacity(isHovered: false, isEnd: true, isVisible: true) == 1)
    }

    @Test func aPromptDimsOffScreenAndBrightensUnderTheHover() {
        let offScreen = MinimapMarks.opacity(isHovered: false, isEnd: false, isVisible: false)
        let onScreen = MinimapMarks.opacity(isHovered: false, isEnd: false, isVisible: true)
        #expect(offScreen < onScreen)
        #expect(onScreen < 1)
        #expect(MinimapMarks.opacity(isHovered: true, isEnd: false, isVisible: false) == 1)
    }
}
