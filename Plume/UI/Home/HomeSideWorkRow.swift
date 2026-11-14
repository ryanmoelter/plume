import SwiftUI

/// A Running item's third row: one chip per subagent or background task the
/// tab runs beside its main turn, capped so a busy tab keeps to one line.
struct HomeSideWorkRow: View, ThemedView {
    let items: [HomeSideWork]
    @Environment(\.theme) var theme

    private static let limit = 6

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items.prefix(Self.limit)) { item in
                HomeSideWorkChip(item: item)
                    .transition(.opacity)
            }
            if items.count > Self.limit {
                Text("+\(items.count - Self.limit)")
                    .emphasis(.subtle)
            }
        }
        .font(typography.caption.font)
        .lineLimit(1)
    }
}

private struct HomeSideWorkChip: View, ThemedView {
    let item: HomeSideWork
    @Environment(\.theme) var theme

    var body: some View {
        HStack(spacing: 4) {
            icon
            Text(item.typeName)
                .emphasis(.secondary)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(colors.divider)
        }
        .help(description)
        .plumeID(AccessibilityID.homeSideWorkChip, label: description, value: item.status.rawValue)
    }

    @ViewBuilder private var icon: some View {
        switch item.kind {
        case .subagent:
            StatusBadge(status: item.status, showsElapsed: false)
                .imageScale(.small)
        case .backgroundTask:
            Image(systemName: StatusSymbol.backgroundTasks.name)
                .imageScale(.small)
                .emphasis(.secondary)
        }
    }

    private var description: String {
        item.detail.map { "\(item.typeName): \($0)" } ?? item.typeName
    }
}
