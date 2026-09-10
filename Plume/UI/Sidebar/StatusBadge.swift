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
/// row — the reason `ChatWorkingIndicator` does the same. The cadence drops to
/// once a minute past the first minute, where the text stops changing faster
/// than that.
private struct ElapsedLabel: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: ElapsedTime.tickInterval(for: Date().timeIntervalSince(since)))) { context in
            Text(ElapsedTime.formatted(context.date.timeIntervalSince(since)))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Emphasis.subtle.textHierarchy)
        }
    }
}

private struct WorkingIndicator: View {
    @State private var pulsing = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Circle()
            .fill(ChatRole.activity(for: colorScheme))
            .frame(width: 7, height: 7)
            .opacity(pulsing ? 0.3 : 1)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
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
