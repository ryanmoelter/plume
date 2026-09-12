import SwiftUI

struct StatusBadge: View {
    let status: TaskStatus
    /// When the current stretch of work began. A working badge counts up from
    /// it; every other status ignores it.
    var workStartedAt: Date?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if status == .working, let workStartedAt {
                HStack(spacing: 4) {
                    ElapsedLabel(since: workStartedAt)
                    symbol
                }
            } else {
                symbol
            }
        }
        .animation(.default, value: status)
    }

    // Each case is its own branch, so a status change replaces the view
    // rather than mutating it — `.transition` is what animates that swap.
    @ViewBuilder
    private var symbol: some View {
        switch status {
        case .notStarted:
            EmptyView()
        case .working:
            WorkingEllipsis(color: ChatRole.activity(for: colorScheme))
        case .awaitingReply:
            Image(systemName: StatusSymbol.awaitingReply.filled)
                .foregroundStyle(Emphasis.secondary.textHierarchy)
                .transition(.symbolEffect)
        case .done:
            Image(systemName: StatusSymbol.done.filled)
                .foregroundStyle(ChatRole.success(for: colorScheme))
                .transition(.symbolEffect)
        case .planApproval:
            Image(systemName: StatusSymbol.plan.filled)
                .foregroundStyle(ChatRole.attention(for: colorScheme))
                .transition(.symbolEffect)
        case .questionAsked:
            Image(systemName: StatusSymbol.question.filled)
                .foregroundStyle(ChatRole.attention(for: colorScheme))
                .transition(.symbolEffect)
        case .permissionNeeded:
            Image(systemName: StatusSymbol.permission.filled)
                .foregroundStyle(ChatRole.warning(for: colorScheme))
                .transition(.symbolEffect)
        case .needsTerminalInput:
            Image(systemName: StatusSymbol.terminalInput.filled)
                .foregroundStyle(ChatRole.attention(for: colorScheme))
                .transition(.symbolEffect)
        case .interrupted:
            Image(systemName: StatusSymbol.interruption.filled)
                .foregroundStyle(Emphasis.subtle.textHierarchy)
                .transition(.symbolEffect)
        case .error:
            Image(systemName: StatusSymbol.error.filled)
                .foregroundStyle(ChatRole.danger(for: colorScheme))
                .transition(.symbolEffect)
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
                .foregroundStyle(Emphasis.secondary.textHierarchy)
        }
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
