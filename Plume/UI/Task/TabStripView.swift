import SwiftUI
import SwiftData

struct TabStripView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var task: WorkTask

    var body: some View {
        HStack(spacing: 6) {
            ForEach(task.orderedTabs) { tab in
                TabChip(
                    task: task,
                    tab: tab,
                    isSelected: task.selectedTabID == tab.id,
                    themeForeground: ThemeChrome.foreground(for: colorScheme),
                    select: { TaskStore.selectTab(tab, in: task) },
                    close: { TaskStore.closeTab(tab, in: context) }
                )
                .draggable(tab.id.uuidString)
                .dropDestination(for: String.self) { draggedIDs, _ in
                    reorder(draggedIDs, before: tab)
                }
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
            .accessibilityLabel("New tab")
            .plumeID(AccessibilityID.newTabButton)

            Spacer()
                .dropDestination(for: String.self) { draggedIDs, _ in
                    reorder(draggedIDs, before: nil)
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .themeTint(colorScheme: colorScheme)
    }

    /// Moves the dragged tab immediately before `target`, or to the end when
    /// `target` is nil (dropped past the last chip). Reordering only rewrites
    /// `orderIndex` through `TaskStore.moveTabs` — surfaces are keyed by tab
    /// id and untouched by it.
    @discardableResult
    private func reorder(_ draggedIDStrings: [String], before target: TaskTab?) -> Bool {
        guard let idString = draggedIDStrings.first, let draggedID = UUID(uuidString: idString) else {
            return false
        }
        let ordered = task.orderedTabs
        guard let fromIndex = ordered.firstIndex(where: { $0.id == draggedID }) else { return false }

        let destination: Int
        if let target {
            guard target.id != draggedID, let targetIndex = ordered.firstIndex(where: { $0.id == target.id }) else {
                return false
            }
            destination = targetIndex
        } else {
            destination = ordered.count
        }

        TaskStore.moveTabs(ordered, from: IndexSet(integer: fromIndex), to: destination)
        return true
    }
}

private struct TabChip: View {
    let task: WorkTask
    @Environment(\.colorScheme) private var colorScheme

    let tab: TaskTab
    let isSelected: Bool
    /// The theme's resolved foreground, when a theme is tinting the strip.
    /// Nil means default chrome, so text/icons keep the system foreground.
    let themeForeground: Color?
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false
    @State private var isConfirmingStartFresh = false
    @State private var isConfirmingTransportSwitch = false

    /// The live title wins over the snapshot on the tab, which is only there
    /// to label the chip before anything reconnects.
    private var chipTitle: String {
        TitleStore.shared.title(forTab: tab.id) ?? tab.displayTitle
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: tab.kind == .agent ? "sparkles" : "terminal")
                .font(.caption)
            Text(chipTitle)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.callout)
                .frame(maxWidth: 120, alignment: .leading)

            if BellStore.shared.hasUnseenBell(tabID: tab.id) {
                Circle()
                    .fill(.tint)
                    .frame(width: 6, height: 6)
                    .help("This terminal rang a bell")
                    .transition(.opacity)
            }

            // Reserve the slot so the chip doesn't resize on hover.
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
            .help("Close tab")
            .accessibilityLabel("Close tab")
            .plumeID(AccessibilityID.tabChipClose)
        }
        .foregroundStyle(themeForeground ?? .primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(chipBackground, in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .plumeID(AccessibilityID.tabChip, label: chipTitle)
        .contextMenu {
            if tab.kind == .agent {
                Button(AgentTabMenu.transportSwitchLabel(for: tab.transport)) {
                    isConfirmingTransportSwitch = true
                }
                if let sessionID = tab.agentSessionID, !sessionID.isEmpty {
                    Button("Start Fresh Conversation") { isConfirmingStartFresh = true }
                }
            }
        }
        .confirmationDialog(
            "Start a fresh conversation?",
            isPresented: $isConfirmingStartFresh
        ) {
            Button("Start Fresh", role: .destructive) { tab.agentSessionID = nil }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This discards Plume's link to the previous conversation. The transcript stays on disk, but Plume won't be able to resume it.")
        }
        .confirmationDialog(
            "Switch how this agent runs?",
            isPresented: $isConfirmingTransportSwitch
        ) {
            Button("Switch", role: .destructive) { AgentLauncher.switchTransport(task: task, tab: tab) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This ends the running agent and starts it again on the other transport. Plume will resume the same conversation if it can.")
        }
    }

    /// `.selection` reads as a native system tint, which disappears against a
    /// custom theme background; a translucent wash of the theme's own
    /// foreground stays legible in both themes.
    private var chipBackground: AnyShapeStyle {
        guard let themeForeground else {
            return isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear)
        }
        let opacity = isSelected ? SidebarSelectionFill.opacity(for: colorScheme) : 0
        return AnyShapeStyle(themeForeground.opacity(opacity))
    }
}
