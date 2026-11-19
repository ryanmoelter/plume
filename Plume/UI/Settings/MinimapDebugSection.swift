#if DEBUG
import SwiftUI

struct MinimapDebugSection: View {
    @State private var tuning = MinimapTuning.shared
    @State private var showsTuning = false

    var body: some View {
        Section {
            Button(showsTuning ? "Hide Tuning" : "Show Tuning") { showsTuning.toggle() }
                .plumeID(
                    AccessibilityID.settingsMinimapTuningToggle,
                    value: showsTuning ? "shown" : "hidden",
                    invoke: { showsTuning.toggle() }
                )
            if showsTuning {
                tuningSliders
                Button("Reset to defaults") { tuning.reset() }
                    .plumeID(AccessibilityID.settingsMinimapTuningReset)
                    .disabled(tuning.values == .defaults)
            }
        } header: {
            Text("Minimap")
        } footer: {
            Text(
                "Hovering magnifies the bars within the radius of the hovered one and shows its " +
                "prompt in a preview. Catch-up gain sets how much faster than the pointer the map " +
                "scrolls toward where the pointer points, per unit of distance between them."
            )
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var tuningSliders: some View {
        TuningSlider(key: "genie-radius", title: "Magnify radius", value: $tuning.values.genieRadius,
                     range: MinimapTuning.genieRadiusRange, step: 1) { "\(Int($0)) pt" }
        TuningSlider(key: "genie-width", title: "Magnify width", value: $tuning.values.genieWidthScale,
                     range: MinimapTuning.genieWidthScaleRange, step: 0.1) { String(format: "%.1f×", $0) }
        TuningSlider(key: "genie-thickness", title: "Magnify thickness", value: $tuning.values.genieThicknessScale,
                     range: MinimapTuning.genieThicknessScaleRange, step: 0.05) { String(format: "%.2f×", $0) }
        TuningSlider(key: "preview-width", title: "Preview width", value: $tuning.values.previewMaxWidth,
                     range: MinimapTuning.previewMaxWidthRange, step: 10) { "\(Int($0)) pt" }
        TuningSlider(key: "preview-lines", title: "Preview lines", value: $tuning.values.previewMaxLines,
                     range: MinimapTuning.previewMaxLinesRange, step: 1) { "\(Int($0))" }
        TuningSlider(key: "fade-in", title: "Fade in", value: $tuning.values.fadeInDuration,
                     range: MinimapTuning.durationRange, step: 0.01, format: Self.seconds)
        TuningSlider(key: "fade-out", title: "Fade out", value: $tuning.values.fadeOutDuration,
                     range: MinimapTuning.durationRange, step: 0.01, format: Self.seconds)
        TuningSlider(key: "slide", title: "Slide", value: $tuning.values.slideDistance,
                     range: MinimapTuning.slideDistanceRange, step: 1) { "\(Int($0)) pt" }
        TuningSlider(key: "crossfade", title: "Crossfade", value: $tuning.values.crossfadeDuration,
                     range: MinimapTuning.durationRange, step: 0.01, format: Self.seconds)
        TuningSlider(key: "snap", title: "Snap", value: $tuning.values.snapDuration,
                     range: MinimapTuning.durationRange, step: 0.01, format: Self.seconds)
        TuningSlider(key: "indirect-slide", title: "Indirect slide", value: $tuning.values.indirectSlideDuration,
                     range: MinimapTuning.durationRange, step: 0.01, format: Self.seconds)
        TuningSlider(key: "catch-up-gain", title: "Catch-up gain", value: $tuning.values.catchUpGain,
                     range: MinimapTuning.catchUpGainRange, step: 0.5) { String(format: "%.1f", $0) }
        TuningSlider(key: "dead-zone", title: "Scroll dead zone", value: $tuning.values.deadZoneRadius,
                     range: MinimapTuning.deadZoneRadiusRange, step: 1) { String(format: "%.0f pt", $0) }
    }

    private static func seconds(_ value: Double) -> String {
        value == 0 ? "Instant" : String(format: "%.2fs", value)
    }
}

private struct TuningSlider: View {
    let key: String
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        HStack {
            Text(title)
            Slider(value: $value, in: range, step: step)
            Text(format(value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
        .plumeID(
            AccessibilityID.settingsMinimapTuningSliderPrefix + key,
            value: String(value),
            setValue: { text in
                guard let number = Double(text) else { return }
                value = min(max(number, range.lowerBound), range.upperBound)
            }
        )
    }
}
#endif
