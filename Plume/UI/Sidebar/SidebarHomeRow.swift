import SwiftUI

/// The sidebar's first row, which opens the Home overview. Its badge counts
/// the conversations Home lists under "Needs you".
struct SidebarHomeRow: View {
    let tasks: [WorkTask]
    let isSelected: Bool
    let onSelect: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var needsYouCount: Int {
        tasks.lazy.flatMap(\.liveTabs).filter { tab in
            tab.kind == .agent && HomeFeed.needsYou(
                status: StatusEngine.shared.status(forTab: tab.id),
                isUnread: UnreadStore.shared.isUnread(tabID: tab.id)
            )
        }.count
    }

    var body: some View {
        let count = needsYouCount
        HStack(spacing: 6) {
            SidebarIconTitle(
                icon: Image(systemName: "house").imageScale(.large),
                iconMinWidth: SidebarMetrics.taskIconMinWidth,
                spacing: 5
            ) {
                Text("Home")
            }
            Spacer(minLength: 4)
            if count > 0 {
                Text(count, format: .number)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(ChatRole.attention(for: colorScheme)))
                    .help(Self.countDescription(count))
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(count > 0 ? "Home, \(Self.countDescription(count))" : "Home")
        .plumeID(AccessibilityID.sidebarHomeRow, value: isSelected ? "selected" : nil, invoke: onSelect)
    }

    private static func countDescription(_ count: Int) -> String {
        count == 1 ? "1 conversation needs you" : "\(count) conversations need you"
    }
}
