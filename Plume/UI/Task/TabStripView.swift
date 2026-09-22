import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct TabStripView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var task: WorkTask

    @Query(sort: \WorkTask.orderIndex) private var allTasks: [WorkTask]

    /// Each chip's frame in the strip's coordinate space, which is where a
    /// drop reports its location.
    @State private var chipFrames: [UUID: CGRect] = [:]
    /// The gap a dragged tab would land in, while one is over the strip.
    @State private var insertionGap: Int?

    private static let chipSpacing: CGFloat = 6
    private static let coordinateSpace = "tabStrip"

    var body: some View {
        HStack(spacing: Self.chipSpacing) {
            ForEach(task.orderedTabs) { tab in
                TabChip(
                    task: task,
                    tab: tab,
                    isSelected: task.selectedTabID == tab.id,
                    themeForeground: ThemeChrome.foreground(for: colorScheme),
                    select: { TaskStore.selectTab(tab, in: task) },
                    close: { TaskStore.closeTab(tab, in: context) },
                    moveToNewTask: { moveToNewTask(tab) }
                )
                .onDrag { SidebarDragItem.tab(tab.id).itemProvider() }
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .named(Self.coordinateSpace))
                } action: { chipFrames[tab.id] = $0 }
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
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .coordinateSpace(.named(Self.coordinateSpace))
        // One destination for the whole strip, placing the drop by its
        // location, so there is no gap between chips where a drop misses.
        // The marker is an overlay so it never takes part in the strip's
        // layout.
        .overlay(alignment: .topLeading) { insertionMarker }
        .onDrop(of: [.utf8PlainText], delegate: TabStripDropDelegate(
            chips: { chipExtents },
            gap: $insertionGap,
            perform: reorder
        ))
        .themeTint(colorScheme: colorScheme)
    }

    /// The chips' horizontal extents, in strip order.
    private var chipExtents: [ClosedRange<CGFloat>] {
        task.orderedTabs.compactMap { chipFrames[$0.id].map { $0.minX...$0.maxX } }
    }

    @ViewBuilder
    private var insertionMarker: some View {
        if let insertionGap,
           let x = TabStripInsertion.markerX(gap: insertionGap, chips: chipExtents, spacing: Self.chipSpacing),
           let chip = chipFrames.values.first {
            Capsule()
                .fill(.tint)
                .frame(width: 2, height: chip.height)
                .offset(x: x - 1, y: chip.minY)
                .allowsHitTesting(false)
        }
    }

    /// Moves the dragged tab into `gap`. Reordering only rewrites
    /// `orderIndex` through `TaskStore.moveTabs` — surfaces are keyed by tab
    /// id and untouched by it.
    private func reorder(_ draggedID: UUID, into gap: Int) {
        let ordered = task.orderedTabs
        guard let fromIndex = ordered.firstIndex(where: { $0.id == draggedID }) else { return }
        TaskStore.moveTabs(ordered, from: IndexSet(integer: fromIndex), to: min(gap, ordered.count))
    }

    /// Splits `tab` into a new ungrouped task, as a sibling of every other
    /// top-level task.
    private func moveToNewTask(_ tab: TaskTab) {
        let siblings = allTasks.filter { $0.group == nil }
        TaskStore.splitTabIntoNewTask(tab, in: context, siblings: siblings)
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
    let moveToNewTask: () -> Void

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
        // Simultaneous, not exclusive: a plain `.onTapGesture` claims the
        // mouse-down, and the chip's drag never starts.
        .simultaneousGesture(TapGesture().onEnded(select))
        .plumeHover { isHovering = $0 }
        .plumeID(AccessibilityID.tabChip, label: chipTitle, value: isSelected ? "selected" : nil, invoke: select)
        .contextMenu {
            if tab.kind == .agent {
                Button(AgentTabMenu.transportSwitchLabel(for: tab.transport)) {
                    isConfirmingTransportSwitch = true
                }
                if let sessionID = tab.agentSessionID, !sessionID.isEmpty {
                    Button("Start Fresh Conversation") { isConfirmingStartFresh = true }
                }
                Divider()
            }
            Button("Move to New Task") { moveToNewTask() }
                .disabled(task.tabs.count < 2)
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

/// Tracks which gap a dragged tab is over, and hands the drop to the strip.
private struct TabStripDropDelegate: DropDelegate {
    let chips: () -> [ClosedRange<CGFloat>]
    @Binding var gap: Int?
    let perform: @MainActor (UUID, Int) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.utf8PlainText])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        switch InAppDrag.current {
        case .task, .group:
            gap = nil
            return DropProposal(operation: .forbidden)
        case .tab, nil:
            break
        }
        gap = TabStripInsertion.gap(forX: info.location.x, chips: chips())
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { gap = nil }

    func performDrop(info: DropInfo) -> Bool {
        let target = TabStripInsertion.gap(forX: info.location.x, chips: chips())
        gap = nil
        SidebarDragItem.load(from: info) { [perform] item in
            if case .tab(let id) = item { perform(id, target) }
        }
        return true
    }
}
