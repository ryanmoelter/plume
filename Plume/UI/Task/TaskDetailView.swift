import SwiftUI
import SwiftData

struct TaskDetailView: View {
    @Bindable var task: WorkTask

    /// Where the divider is while it is being dragged, written to the task
    /// once on release rather than on every pointer move. Held here so the
    /// strips follow the drag along with the content.
    @State private var draggedFraction: Double?

    var body: some View {
        GeometryReader { proxy in
            let panes = task.panes
            let shown = task.paneTabIDs(in: panes)
            let committed = layout(panes: panes.count, fraction: task.splitFraction, width: proxy.size.width)
            let live = draggedFraction.map { layout(panes: panes.count, fraction: $0, width: proxy.size.width) } ?? committed
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(live.panes.indices, id: \.self) { pane in
                        if pane > 0 {
                            Rectangle()
                                .fill(.separator)
                                .frame(width: SplitLayout.dividerWidth)
                        }
                        TabStripView(
                            task: task,
                            pane: pane,
                            paneCount: panes.count,
                            tabs: panes.indices.contains(pane) ? panes[pane] : [],
                            shown: Set(shown)
                        )
                        .frame(width: live.panes[pane].width)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Divider()
                TabContentView(
                    task: task,
                    panes: panes,
                    shown: shown,
                    layout: live,
                    committedLayout: committed,
                    draggedFraction: $draggedFraction
                )
            }
        }
        .navigationTitle(TitleStore.shared.displayTitle(for: task))
    }

    private func layout(panes: Int, fraction: Double, width: CGFloat) -> SplitLayout {
        SplitLayout(paneCount: panes, fraction: fraction, width: width, minimumPaneWidth: WindowMetrics.paneMinimumWidth)
    }
}
