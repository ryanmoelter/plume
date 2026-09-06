import Foundation
import Testing
@testable import Plume

struct ComposerPanelMetricsTests {
    @Test func concentricRadiusLeavesAnEvenGapAroundTheCorner() {
        #expect(ComposerPanelMetrics.concentricRadius(outer: 18, inset: 8) == 10)
        #expect(ComposerPanelMetrics.concentricRadius(outer: 18, inset: 0) == 18)
    }

    /// A box inset further than the container's radius would want a negative
    /// one; square is the nearest thing that exists.
    @Test func concentricRadiusFloorsAtSquare() {
        #expect(ComposerPanelMetrics.concentricRadius(outer: 6, inset: 20) == 0)
    }

    @Test func composerFieldIsConcentricWithThePanel() {
        let dimensions = Dimensions(bodySize: 16)
        #expect(
            dimensions.composerFieldCornerRadius
                == ComposerPanelMetrics.concentricRadius(
                    outer: dimensions.panelCornerRadius,
                    inset: dimensions.composerFieldInset
                )
        )
        #expect(dimensions.composerFieldCornerRadius > 0)
    }
}
