import SwiftUI

struct StatusBadge: View {
    let status: TaskStatus
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch status {
        case .unset:
            EmptyView()
        case .idle:
            Circle().fill(Emphasis.subtle.textHierarchy).frame(width: 7, height: 7)
        case .working:
            WorkingIndicator()
        case .needsInput:
            Image(systemName: "bell.fill").foregroundStyle(ChatRole.attention(for: colorScheme))
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(ChatRole.success(for: colorScheme))
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
