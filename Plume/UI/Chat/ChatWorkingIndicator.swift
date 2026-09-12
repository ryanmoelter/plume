import SwiftUI

/// The working ellipsis with a caption beside it, for inline use next to prose
/// rather than in a status list.
struct ChatWorkingIndicator: View, ThemedView {
    @Environment(\.theme) var theme
    @Environment(\.workStartedAt) private var workStartedAt

    var body: some View {
        HStack(spacing: 6) {
            WorkingEllipsis(color: colors.activity)
                .font(typography.caption.font)
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
