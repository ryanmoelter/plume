import Testing
import Foundation
@testable import Plume

/// The collapse decision for the composer's controls row, which is pure
/// arithmetic over the labels it would draw.
struct ComposerControlsMetricsTests {
    private let labels = ["Default (Opus)", "Medium", "Accept Edits"]
    private let spacing: CGFloat = 8

    @Test func aRowWideEnoughForEveryLabelKeepsThem() {
        let form = ComposerControlsMetrics.form(availableWidth: 600, labels: labels, spacing: spacing)
        #expect(form == .labels)
    }

    @Test func aNarrowRowCollapsesToIcons() {
        let form = ComposerControlsMetrics.form(availableWidth: 120, labels: labels, spacing: spacing)
        #expect(form == .iconsOnly)
    }

    /// The first render has no geometry yet, and starting collapsed would
    /// flash icons on every window wide enough for labels.
    @Test func anUnmeasuredRowShowsLabels() {
        #expect(ComposerControlsMetrics.form(availableWidth: 0, labels: labels, spacing: spacing) == .labels)
    }

    @Test func theDecisionFlipsExactlyAtTheRequiredWidth() {
        let required = ComposerControlsMetrics.requiredWidth(labels: labels, spacing: spacing)
        #expect(ComposerControlsMetrics.form(availableWidth: required, labels: labels, spacing: spacing) == .labels)
        #expect(
            ComposerControlsMetrics.form(availableWidth: required - 1, labels: labels, spacing: spacing)
                == .iconsOnly
        )
    }

    @Test func aLongerLabelNeedsMoreRoom() {
        let short = ComposerControlsMetrics.requiredWidth(labels: ["Opus"], spacing: spacing)
        let long = ComposerControlsMetrics.requiredWidth(labels: ["Default (Haiku 4.5 200K)"], spacing: spacing)
        #expect(long > short)
    }

    /// Collapsing has to be a way out of a tight row, never a way into one.
    @Test func collapsingIsAlwaysNarrowerThanLabelling() {
        for label in labels {
            #expect(ComposerControlsMetrics.collapsedSegmentWidth < ComposerControlsMetrics.segmentWidth(label: label))
        }
    }

    @Test func spacingCountsOnlyTheGapsBetweenSegments() {
        let one = ComposerControlsMetrics.requiredWidth(labels: ["Opus"], spacing: spacing)
        let three = ComposerControlsMetrics.requiredWidth(labels: ["Opus", "Opus", "Opus"], spacing: spacing)
        #expect(three == one * 3 + spacing * 2)
    }

    @Test func anEmptyRowNeedsNoWidth() {
        #expect(ComposerControlsMetrics.requiredWidth(labels: [], spacing: spacing) == 0)
    }
}

/// Every mode and effort level draws its own icon, which is the only thing
/// naming the control once the row collapses.
struct ComposerControlSymbolsTests {
    @Test func everyPermissionModeHasItsOwnSymbol() {
        let symbols = PermissionMode.allCases.map(\.symbol)
        let named = symbols.filter { !$0.isEmpty }
        #expect(Set(symbols).count == PermissionMode.allCases.count)
        #expect(named.count == symbols.count)
    }

    @Test func everyEffortLevelHasItsOwnSymbol() {
        let symbols = AgentEffort.allCases.map(\.symbol)
        let gauges = symbols.filter { $0.hasPrefix("gauge.with.dots.needle.") }
        #expect(Set(symbols).count == AgentEffort.allCases.count)
        #expect(gauges.count == AgentProviderKind.claudeCode.efforts.count)
    }
}
