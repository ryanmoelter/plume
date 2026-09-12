import SwiftUI

/// Local re-export of the sidebar's pulsing dot, sized for inline use next to
/// prose rather than a status list.
struct ChatWorkingIndicator: View, ThemedView {
    @Environment(\.theme) var theme
    @Environment(\.workStartedAt) private var workStartedAt

    var body: some View {
        HStack(spacing: 6) {
            // A symbol effect rather than an animation modifier. Both
            // `phaseAnimator` and a `repeatForever` opacity animation drive a
            // display-list rebuild for every tick, and this sits in the same
            // stack as the message list — a trace showed those ticks
            // rebuilding the whole chat tree ~37,000 times over 15 seconds.
            // `.variableColor` animates in the render server, so the view
            // graph sees nothing at all.
            Image(systemName: "ellipsis")
                .foregroundStyle(colors.activity)
                .symbolEffect(
                    .variableColor.iterative.hideInactiveLayers.nonReversing,
                    options: .repeat(.periodic)
                )
            if let workStartedAt {
                // Its own timeline, an order of magnitude slower than the
                // dot's: the text changes once a second at most, so driving
                // it off the pulse would rebuild it twenty times for nothing.
                TimelineView(ElapsedSchedule(since: workStartedAt)) { context in
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
}

extension EnvironmentValues {
    /// When the turn in flight started, so the working caption can name a
    /// verb and count up. Nil outside a live chat — a preview, say — where
    /// the caption falls back to plain prose.
    @Entry var workStartedAt: Date?
}
