import SwiftUI

struct StatusBadge: View {
    let status: TaskStatus
    /// When the current stretch of work began. An active badge counts up from
    /// it; every other status ignores it.
    var workStartedAt: Date?
    /// Replaces the status glyph with a dot. The elapsed time stays, since a
    /// task can be reading unread in one tab while still working in another.
    var isUnread = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if status.isActive, let workStartedAt {
                HStack(spacing: 4) {
                    ElapsedLabel(since: workStartedAt)
                        .font(.caption)
                        .emphasis(.secondary)
                    glyph
                }
            } else {
                glyph
            }
        }
        .animation(.default, value: status)
        .animation(.default, value: isUnread)
    }

    @ViewBuilder
    private var glyph: some View {
        if isUnread {
            Circle()
                .fill(ChatRole.attention(for: colorScheme))
                .frame(width: 8, height: 8)
                .help("Finished a turn you haven't read")
                .transition(.opacity)
        } else {
            symbol
        }
    }

    // Each case is its own branch, so a status change replaces the view
    // rather than mutating it — `.transition` is what animates that swap.
    @ViewBuilder
    private var symbol: some View {
        switch status {
        // A finished turn the user has read is the resting state, so it
        // draws nothing; an unread one draws the dot instead.
        case .notStarted, .awaitingReply:
            EmptyView()
        case .working:
            WorkingEllipsis(color: ChatRole.activity(for: colorScheme))
        case .waitingOnSubagents:
            Image(systemName: StatusSymbol.subagents.filled)
                .foregroundStyle(ChatRole.activity(for: colorScheme))
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
struct ElapsedLabel: View {
    let since: Date

    var body: some View {
        TimelineView(ElapsedSchedule(since: since)) { context in
            Text(ElapsedTime.formatted(context.date.timeIntervalSince(since)))
                .monospacedDigit()
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
