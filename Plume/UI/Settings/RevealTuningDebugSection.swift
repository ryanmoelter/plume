#if DEBUG
import SwiftUI

struct RevealTuningDebugSection: View {
    @State private var revealTuning = RevealTuning.shared

    var body: some View {
        Section {
            RevealSlider(
                title: "Response",
                value: $revealTuning.values.response,
                range: RevealTuning.responseRange,
                step: 0.05,
                format: { String(format: "%.2fs", $0) }
            )
            RevealSlider(
                title: "Damping",
                value: $revealTuning.values.dampingRatio,
                range: RevealTuning.dampingRatioRange,
                step: 0.05,
                format: { String(format: "%.2f", $0) }
            )
            RevealSlider(
                title: "Minimum speed",
                value: $revealTuning.values.minimumSpeed,
                range: RevealTuning.minimumSpeedRange,
                step: 1,
                format: { "\(Int($0))/s" }
            )
            RevealSlider(
                title: "Maximum speed",
                value: $revealTuning.values.maximumSpeed,
                range: RevealTuning.maximumSpeedRange,
                step: 10,
                format: { $0 == 0 ? "Off" : "\(Int($0))/s" }
            )
            RevealSlider(
                title: "Word fade time",
                value: $revealTuning.values.fadeDuration,
                range: RevealTuning.fadeDurationRange,
                step: 0.05,
                format: { $0 == 0 ? "Instant" : String(format: "%.2fs", $0) }
            )
            RevealSlider(
                title: "Frame rate",
                value: $revealTuning.values.frameRate,
                range: RevealTuning.frameRateRange,
                step: 10,
                format: { "\(Int($0)) fps" }
            )
            Button("Reset to Defaults") { revealTuning.reset() }
                .disabled(revealTuning.values == .defaults)
        } header: {
            Text("Reveal Tuning")
        } footer: {
            Text(
                "The reveal is a character index on a spring pulled toward the newest " +
                "character. Response is the spring's period: lower chases the text harder. " +
                "Damping 1 settles without overshoot; lower surges. Speeds are characters " +
                "per second. Each word fades in over the fade time from the moment the " +
                "reveal reaches it, so a long word holds the next one back for longer."
            )
            .foregroundStyle(.secondary)
        }
    }
}

/// One reveal parameter: a label, a slider, and the value it is set to.
private struct RevealSlider: View {
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
