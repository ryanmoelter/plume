import SwiftUI

struct StatusBadge: View {
    let status: TaskStatus
    /// When the current stretch of work began. A working badge counts up from
    /// it; every other status ignores it.
    var workStartedAt: Date?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if status == .working, let workStartedAt {
            HStack(spacing: 4) {
                ElapsedLabel(since: workStartedAt)
                symbol
            }
        } else {
            symbol
        }
    }

    @ViewBuilder
    private var symbol: some View {
        switch status {
        case .notStarted:
            EmptyView()
        case .working:
            WorkingIndicator()
        case .awaitingReply:
            Circle().fill(Emphasis.subtle.textHierarchy).frame(width: 7, height: 7)
        case .planApproval:
            Image(systemName: "list.bullet.clipboard.fill").foregroundStyle(ChatRole.attention(for: colorScheme))
        case .questionAsked:
            Image(systemName: "questionmark.circle.fill").foregroundStyle(ChatRole.attention(for: colorScheme))
        case .permissionNeeded:
            Image(systemName: "hand.raised.fill").foregroundStyle(ChatRole.warning(for: colorScheme))
        case .needsTerminalInput:
            Image(systemName: "bell.fill").foregroundStyle(ChatRole.attention(for: colorScheme))
        case .interrupted:
            Image(systemName: "hand.raised.slash.fill").foregroundStyle(Emphasis.subtle.textHierarchy)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ChatRole.danger(for: colorScheme))
        }
    }
}

/// How long the current stretch of work has been going, counting up.
///
/// Driven by `TimelineView` off the clock rather than by a timer writing
/// state, so the redraw stays inside this label instead of invalidating the
/// row — the reason `ChatWorkingIndicator` does the same. The schedule slows
/// itself once the text stops changing by the second.
private struct ElapsedLabel: View {
    let since: Date

    var body: some View {
        TimelineView(ElapsedSchedule(since: since)) { context in
            Text(ElapsedTime.formatted(context.date.timeIntervalSince(since)))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Emphasis.subtle.textHierarchy)
        }
    }
}

/// An ellipsis whose dots light in turn, the way a chat app shows someone
/// typing.
///
/// `.variableColor` animates in the render server rather than through the
/// view graph, so unlike a `repeatForever` opacity animation it costs no
/// per-frame SwiftUI update — the reason this is a symbol effect and not an
/// animated `Circle`.
private struct WorkingIndicator: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(systemName: "ellipsis")
            .foregroundStyle(ChatRole.activity(for: colorScheme))
            .symbolEffect(
                .variableColor.iterative.hideInactiveLayers.nonReversing,
                options: .repeat(.periodic)
            )
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(TaskStatus.allCases, id: \.self) { status in
            HStack { StatusBadge(status: status); Text(status.rawValue) }
        }
    }
    .padding()
}
