import Foundation
import Testing
@testable import Plume

struct TypographyTests {
    @Test func rolesStepByTheRatio() {
        let typography = Typography(bodySize: 16)
        #expect(typography.body.size == 16)
        #expect(typography.caption.size == 16 / Typography.ratio)
        #expect(typography.bodyLarge.size == 16 * Typography.ratio)
    }

    @Test func theScaleAscendsFromCaptionToDisplay() {
        let typography = Typography(bodySize: 16)
        let sizes = [
            typography.caption.size,
            typography.body.size,
            typography.bodyLarge.size,
            typography.title.size,
            typography.headline.size,
            typography.display.size,
        ]
        for (below, above) in zip(sizes, sizes.dropFirst()) {
            #expect(above > below)
        }
    }

    @Test func lineSpacingFollowsTheRolesOwnSize() {
        let typography = Typography(bodySize: 16)
        #expect(typography.body.lineSpacing < typography.display.lineSpacing)
        #expect(typography.caption.lineSpacing < typography.body.lineSpacing)
    }

    @Test func changingTheFaceKeepsTheScale() {
        let system = Typography(bodySize: 16)
        let serif = system.inFace(.serif)
        #expect(serif.bodySize == system.bodySize)
        #expect(serif.display.size == system.display.size)
        #expect(serif.proseFace == .serif)
    }
}
