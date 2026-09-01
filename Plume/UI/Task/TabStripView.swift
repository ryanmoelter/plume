import SwiftUI
import SwiftData

struct TabStripView: View {
    @Environment(\.modelContext) private var context
    @Bindable var task: WorkTask

    var body: some View {
        HStack(spacing: 6) {
            ForEach(task.orderedTabs) { tab in
                TabChip(
                    tab: tab,
                    isSelected: task.selectedTabID == tab.id,
                    select: { task.selectedTabID = tab.id },
                    close: { TaskStore.closeTab(tab, in: context) }
                )
            }

            Menu {
                Button("Agent Tab") { TaskStore.addTab(to: task, kind: .agent, in: context) }
                Button("Terminal Tab") { TaskStore.addTab(to: task, kind: .terminal, in: context) }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New tab")

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

private struct TabChip: View {
    let tab: TaskTab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: tab.kind == .agent ? "sparkles" : "terminal")
                .font(.caption)
            Text(tab.displayTitle)
                .lineLimit(1)
                .font(.callout)

            // Reserve the slot so the chip doesn't resize on hover.
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
            .help("Close tab")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
    }
}
