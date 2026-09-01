import SwiftUI

struct StatusBadge: View {
    let status: TaskStatus

    var body: some View {
        switch status {
        case .unset:
            EmptyView()
        case .idle:
            Circle().fill(.tertiary).frame(width: 7, height: 7)
        case .working:
            WorkingIndicator()
        case .needsInput:
            Image(systemName: "bell.fill").foregroundStyle(.orange)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}

private struct WorkingIndicator: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(.blue)
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
