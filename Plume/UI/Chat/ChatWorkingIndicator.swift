import SwiftUI

/// Local re-export of the sidebar's pulsing dot, sized for inline use next to
/// prose rather than a status list.
struct ChatWorkingIndicator: View, ThemedView {
    @Environment(\.theme) var theme
    @Environment(\.workStartedAt) private var workStartedAt

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
            if let workStartedAt {
                // Its own timeline, an order of magnitude slower than the
                // dot's: the text changes once a second at most, so driving
                // it off the pulse would rebuild it twenty times for nothing.
                TimelineView(.periodic(from: workStartedAt, by: 1)) { context in
                    Text(caption(at: context.date, startedAt: workStartedAt))
                        .font(typography.caption.font)
                        .emphasis(.secondary)
                        .monospacedDigit()
                }
            } else {
                Text("Working…")
                    .font(typography.caption.font)
                    .emphasis(.secondary)
            }
        }
        .listItemPadding(vertical: false)
    }

    private func caption(at now: Date, startedAt: Date) -> String {
        let verb = WorkingVerb.forTurn(startedAt: startedAt)
        return "\(verb)… \(ElapsedTime.formatted(now.timeIntervalSince(startedAt)))"
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

extension EnvironmentValues {
    /// When the turn in flight started, so the working caption can name a
    /// verb and count up. Nil outside a live chat — a preview, say — where
    /// the caption falls back to plain prose.
    @Entry var workStartedAt: Date?
}
