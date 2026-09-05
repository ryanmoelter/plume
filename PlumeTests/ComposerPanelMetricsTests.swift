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

    /// The tucked card's square bottom corners have to land on the panel's
    /// straight top edge, which starts one radius in from each side.
    @Test func tuckedCardStepsInPastThePanelsRounding() {
        for radius in stride(from: 0.0, through: 32.0, by: 2.0) {
            #expect(ComposerPanelMetrics.tuckedInset(panelCornerRadius: radius) >= radius)
        }
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
