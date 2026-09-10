import SwiftUI

struct StatusBadge: View {
    let status: TaskStatus
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
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
