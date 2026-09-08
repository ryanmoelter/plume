import AppKit
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

    /// The icon-only segments pin their glyph run to a box this tall, so a
    /// line height that collapsed below the type at either end of the chat
    /// font range would clip the segment rather than steady it.
    @Test func lineHeightClearsThePointSizeAcrossTheChatFontRange() {
        for bodySize in stride(from: AppSettings.chatFontSizeRange.lowerBound,
                               through: AppSettings.chatFontSizeRange.upperBound,
                               by: 1) {
            let typography = Typography(bodySize: bodySize)
            #expect(typography.caption.lineHeight > typography.caption.size)
            #expect(typography.body.lineHeight > typography.body.size)
        }
    }

    @Test func lineHeightGrowsWithTheRole() {
        let typography = Typography(bodySize: 16)
        #expect(typography.caption.lineHeight < typography.body.lineHeight)
        #expect(typography.body.lineHeight < typography.display.lineHeight)
    }

    /// The premise `ComposerSegmentLabel` pins its run for: a `.slash` variant
    /// draws a taller glyph box than its plain form, and the extra is all
    /// above the baseline — the alignment rects match. Bottom-aligning is only
    /// steady while that holds.
    @Test func aSlashVariantOverflowsItsPlainFormAboveTheBaseline() throws {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let plain = try #require(NSImage(systemSymbolName: "antenna.radiowaves.left.and.right",
                                        accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration))
        let slashed = try #require(NSImage(systemSymbolName: "antenna.radiowaves.left.and.right.slash",
                                           accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration))

        #expect(slashed.size.height > plain.size.height)
        #expect(slashed.alignmentRect.minY == plain.alignmentRect.minY)
        #expect(slashed.alignmentRect.height == plain.alignmentRect.height)
    }

    @Test func changingTheFaceKeepsTheScale() {
        let system = Typography(bodySize: 16)
        let serif = system.inFace(.serif)
        #expect(serif.bodySize == system.bodySize)
        #expect(serif.display.size == system.display.size)
        #expect(serif.proseFace == .serif)
    }
}
