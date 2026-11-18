#if DEBUG
import SwiftUI

struct MinimapDebugSection: View {
    @State private var settings = AppSettings.shared
    @State private var tuning = MinimapTuning.shared

    var body: some View {
        Section {
            Picker("Side", selection: $settings.minimapSide) {
                Text("Leading").tag(MinimapSide.leading)
                Text("Trailing").tag(MinimapSide.trailing)
            }
            .plumeID(
                AccessibilityID.settingsMinimapSidePicker,
                value: settings.minimapSide.rawValue,
                setValue: { MinimapSide(rawValue: $0).map { settings.minimapSide = $0 } }
            )
            Picker("Spacing", selection: $settings.minimapSpacing) {
                Text("Even").tag(MinimapSpacing.even)
                Text("Proportional").tag(MinimapSpacing.proportional)
            }
            .plumeID(
                AccessibilityID.settingsMinimapSpacingPicker,
                value: settings.minimapSpacing.rawValue,
                setValue: { MinimapSpacing(rawValue: $0).map { settings.minimapSpacing = $0 } }
            )
            Picker("Indirect prompts", selection: $settings.minimapIndirectShape) {
                Text("Dot").tag(MinimapIndirectShape.dot)
                Text("Short line").tag(MinimapIndirectShape.line)
            }
            .plumeID(
                AccessibilityID.settingsMinimapIndirectShapePicker,
                value: settings.minimapIndirectShape.rawValue,
                setValue: { MinimapIndirectShape(rawValue: $0).map { settings.minimapIndirectShape = $0 } }
            )
            TuningSlider(title: "Magnify radius", value: $tuning.values.genieRadius,
                         range: MinimapTuning.genieRadiusRange, step: 1) { "\(Int($0)) pt" }
            TuningSlider(title: "Magnify width", value: $tuning.values.genieWidthScale,
                         range: MinimapTuning.genieWidthScaleRange, step: 0.1) { String(format: "%.1f×", $0) }
            TuningSlider(title: "Magnify thickness", value: $tuning.values.genieThicknessScale,
                         range: MinimapTuning.genieThicknessScaleRange, step: 0.05) { String(format: "%.2f×", $0) }
            TuningSlider(title: "Preview width", value: $tuning.values.previewMaxWidth,
                         range: MinimapTuning.previewMaxWidthRange, step: 10) { "\(Int($0)) pt" }
            TuningSlider(title: "Preview lines", value: $tuning.values.previewMaxLines,
                         range: MinimapTuning.previewMaxLinesRange, step: 1) { "\(Int($0))" }
            TuningSlider(title: "Fade in", value: $tuning.values.fadeInDuration,
                         range: MinimapTuning.durationRange, step: 0.01, format: Self.seconds)
            TuningSlider(title: "Fade out", value: $tuning.values.fadeOutDuration,
                         range: MinimapTuning.durationRange, step: 0.01, format: Self.seconds)
            TuningSlider(title: "Slide", value: $tuning.values.slideDistance,
                         range: MinimapTuning.slideDistanceRange, step: 1) { "\(Int($0)) pt" }
            TuningSlider(title: "Crossfade", value: $tuning.values.crossfadeDuration,
                         range: MinimapTuning.durationRange, step: 0.01, format: Self.seconds)
            TuningSlider(title: "Snap", value: $tuning.values.snapDuration,
                         range: MinimapTuning.durationRange, step: 0.01, format: Self.seconds)
            TuningSlider(title: "Indirect slide", value: $tuning.values.indirectSlideDuration,
                         range: MinimapTuning.durationRange, step: 0.01, format: Self.seconds)
            TuningSlider(title: "Catch-up gain", value: $tuning.values.catchUpGain,
                         range: MinimapTuning.catchUpGainRange, step: 0.5) { String(format: "%.1f", $0) }
            TuningSlider(title: "Scroll dead zone", value: $tuning.values.deadZoneRadius,
                         range: MinimapTuning.deadZoneRadiusRange, step: 1) { String(format: "%.0f pt", $0) }
            Button("Reset to defaults") { tuning.reset() }
                .plumeID(AccessibilityID.settingsMinimapTuningReset)
                .disabled(tuning.values == .defaults)
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

    private static func seconds(_ value: Double) -> String {
        value == 0 ? "Instant" : String(format: "%.2fs", value)
    }
}

private struct TuningSlider: View {
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
    }
}
#endif
