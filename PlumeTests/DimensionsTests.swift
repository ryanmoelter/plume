import Foundation
import Testing
@testable import Plume

struct DimensionsTests {
    @Test func contentWidthScalesWithBodySize() {
        #expect(Dimensions(bodySize: 16).contentWidth == 640)
        #expect(Dimensions(bodySize: 13).contentWidth == 520)
    }

    @Test func bleedIsWiderThanContentAtEverySize() {
        for size in stride(from: 9.0, through: 32.0, by: 1.0) {
            let dimensions = Dimensions(bodySize: size)
            #expect(dimensions.bleedWidth > dimensions.contentWidth)
        }
    }

    @Test func bleedWidthScalesWithBodySize() {
        #expect(Dimensions(bodySize: 16).bleedWidth == 800)
        #expect(Dimensions(bodySize: 13).bleedWidth == 650)
    }

    @Test func listBottomPaddingScalesWithBodySize() {
        #expect(Dimensions(bodySize: 16).listBottomPadding == 72)
        #expect(Dimensions(bodySize: 13).listBottomPadding == 58.5)
    }

    @Test func everyScaledMeasureGrowsWithTheBodySize() {
        let small = Dimensions(bodySize: 11)
        let large = Dimensions(bodySize: 28)
        #expect(large.contentWidth > small.contentWidth)
        #expect(large.bleedWidth > small.bleedWidth)
        #expect(large.listBottomPadding > small.listBottomPadding)
        #expect(large.blockSpacing > small.blockSpacing)
    }

    /// A heading belongs to the text below it, so higher levels open more
    /// space above and the taper reaches zero before the ladder ends.
    @Test func headingSpacingTapersWithTheLevel() {
        let dimensions = Dimensions(bodySize: 16)
        let spacings = (1...6).map { dimensions.headingTopSpacing(level: $0) }
        for (above, below) in zip(spacings, spacings.dropFirst()) {
            #expect(above >= below)
        }
        #expect(spacings[0] > 0)
        #expect(dimensions.headingTopSpacing(level: 5) == 0)
        #expect(dimensions.headingTopSpacing(level: 6) == 0)
    }
}
