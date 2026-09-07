import SwiftUI

/// Local re-export of the sidebar's pulsing dot, sized for inline use next to
/// prose rather than a status list.
struct ChatWorkingIndicator: View, ThemedView {
    @Environment(\.theme) var theme

    var body: some View {
        HStack(spacing: 6) {
            // `TimelineView` rather than an animation modifier. Both
            // `phaseAnimator` and a `repeatForever` opacity animation drive a
            // display-list rebuild for every tick, and this dot lives in the
            // same stack as the message list — a trace showed those ticks
            // rebuilding the whole chat tree ~37,000 times over 15 seconds.
            // Deriving opacity from the clock keeps the redraw to this view.
            TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { context in
                Circle()
                    .fill(colors.activity)
                    .opacity(Self.opacity(at: context.date))
            }
            .frame(width: 7, height: 7)
            Text("Working…")
                .font(typography.caption.font)
                .emphasis(.secondary)
        }
        .listItemPadding(vertical: false)
    }

    private static let pulsePeriod: TimeInterval = 1.4

    /// A smooth 1.0 → 0.3 → 1.0 pulse from wall-clock time, so the phase does
    /// not restart when a recycled row remounts.
    private static func opacity(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: pulsePeriod) / pulsePeriod
        return 0.65 + 0.35 * cos(phase * 2 * .pi)
    }
}
