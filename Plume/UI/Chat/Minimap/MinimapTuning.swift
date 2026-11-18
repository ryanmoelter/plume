import SwiftUI

/// The knobs of the minimap's hover. A debug build persists them and exposes
/// them in Settings so the feel can be tuned by eye; a release build always
/// uses `Values.defaults`.
@MainActor
@Observable
final class MinimapTuning {
    static let shared = MinimapTuning()

    struct Values: Equatable {
        /// Points from the hovered row at which magnification reaches zero.
        var genieRadius: Double
        /// How many times wider the hovered bar draws.
        var genieWidthScale: Double
        /// How many times thicker the hovered bar draws.
        var genieThicknessScale: Double
        var previewMaxWidth: Double
        var previewMaxLines: Double
        var fadeInDuration: Double
        var fadeOutDuration: Double
        /// How far the preview travels as it fades in, toward the chat.
        var slideDistance: Double
        /// How long the preview's text takes to swap between rows.
        var crossfadeDuration: Double
        /// How long the magnification takes to move to a newly hovered row.
        var snapDuration: Double
        /// `MinimapCatchUp`'s gain: how much faster than the pointer the map
        /// scrolls per unit of gap.
        var catchUpGain: Double
        /// Points the pointer can move from where it entered the rail before
        /// the map starts to scroll. Rows still hover and preview inside it.
        var deadZoneRadius: Double
        /// How long a hovered indirect prompt's mark takes to slide out to a
        /// prompt bar's end, and back.
        var indirectSlideDuration: Double
        /// Whether a hover scrolls the map only when the hovered row changes,
        /// rather than with every pointer move. `MinimapSnappedScroll`.
        var snappedScroll: Bool

        static let defaults = Values(
            genieRadius: 18,
            genieWidthScale: 2.4,
            genieThicknessScale: 1.75,
            previewMaxWidth: 280,
            previewMaxLines: 3,
            fadeInDuration: 0.16,
            fadeOutDuration: 0.12,
            slideDistance: 6,
            crossfadeDuration: 0.12,
            snapDuration: 0.14,
            catchUpGain: 10,
            deadZoneRadius: 16,
            indirectSlideDuration: 0.18,
            snappedScroll: false
        )
    }

    static let genieRadiusRange: ClosedRange<Double> = 4...60
    static let genieWidthScaleRange: ClosedRange<Double> = 1...5
    static let genieThicknessScaleRange: ClosedRange<Double> = 1...4
    static let previewMaxWidthRange: ClosedRange<Double> = 120...480
    static let previewMaxLinesRange: ClosedRange<Double> = 1...8
    static let durationRange: ClosedRange<Double> = 0...1
    static let slideDistanceRange: ClosedRange<Double> = 0...40
    static let catchUpGainRange: ClosedRange<Double> = 0...40
    static let deadZoneRadiusRange: ClosedRange<Double> = 0...40

    var values: Values {
        didSet { scheduleSave() }
    }

    private let defaults: UserDefaults
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    private static let key = "minimapTuning"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if DEBUG
        let stored = defaults.dictionary(forKey: Self.key) as? [String: Double] ?? [:]
        #else
        let stored: [String: Double] = [:]
        #endif
        let fallback = Values.defaults
        values = Values(
            genieRadius: stored["genieRadius"] ?? fallback.genieRadius,
            genieWidthScale: stored["genieWidthScale"] ?? fallback.genieWidthScale,
            genieThicknessScale: stored["genieThicknessScale"] ?? fallback.genieThicknessScale,
            previewMaxWidth: stored["previewMaxWidth"] ?? fallback.previewMaxWidth,
            previewMaxLines: stored["previewMaxLines"] ?? fallback.previewMaxLines,
            fadeInDuration: stored["fadeInDuration"] ?? fallback.fadeInDuration,
            fadeOutDuration: stored["fadeOutDuration"] ?? fallback.fadeOutDuration,
            slideDistance: stored["slideDistance"] ?? fallback.slideDistance,
            crossfadeDuration: stored["crossfadeDuration"] ?? fallback.crossfadeDuration,
            snapDuration: stored["snapDuration"] ?? fallback.snapDuration,
            catchUpGain: stored["catchUpGain"] ?? fallback.catchUpGain,
            deadZoneRadius: stored["deadZoneRadius"] ?? fallback.deadZoneRadius,
            indirectSlideDuration: stored["indirectSlideDuration"] ?? fallback.indirectSlideDuration,
            snappedScroll: stored["snappedScroll"].map { $0 != 0 } ?? fallback.snappedScroll
        )
    }

    func reset() {
        values = .defaults
    }

    /// A slider drag sets the values on every tick, and a defaults write
    /// costs main-thread time, so only the value it settles on is written.
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        #if DEBUG
        let values = values
        defaults.set([
            "genieRadius": values.genieRadius,
            "genieWidthScale": values.genieWidthScale,
            "genieThicknessScale": values.genieThicknessScale,
            "previewMaxWidth": values.previewMaxWidth,
            "previewMaxLines": values.previewMaxLines,
            "fadeInDuration": values.fadeInDuration,
            "fadeOutDuration": values.fadeOutDuration,
            "slideDistance": values.slideDistance,
            "crossfadeDuration": values.crossfadeDuration,
            "snapDuration": values.snapDuration,
            "catchUpGain": values.catchUpGain,
            "deadZoneRadius": values.deadZoneRadius,
            "indirectSlideDuration": values.indirectSlideDuration,
            "snappedScroll": values.snappedScroll ? 1.0 : 0.0
        ], forKey: Self.key)
        #endif
    }
}
