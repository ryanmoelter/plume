import CoreGraphics
import Foundation
import Testing
@testable import Plume

/// The geometry of the minimap's non-prompt marks: an indirect prompt is as
/// thick as a prompt bar, and the end of the conversation outlines one.
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
}
