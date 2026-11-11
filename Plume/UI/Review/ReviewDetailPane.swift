#if DEBUG
import Observation
import SwiftData
import SwiftUI

/// Whether the task-level review pane is open. Window-wide and in memory: the
/// spike only needs to try the layout.
@MainActor
@Observable
final class ReviewPaneVisibility {
    static let shared = ReviewPaneVisibility()
    var isShown = false
}

enum ReviewNavigation {
    /// Selects the task's review tab, adding one if it has none, and shows
    /// `path` in it. The tab replaces the pane, which shows the same review.
    static func open(path: String, in task: WorkTask, context: ModelContext) {
        ReviewPaneVisibility.shared.isShown = false
        if let directory = task.workingDirectoryPath {
            ReviewStore.shared.model(for: directory).selectedPath = path
        }
        if let tab = task.orderedTabs.first(where: { $0.kind == .review }) {
            TaskStore.selectTab(tab, in: task)
        } else {
            TaskStore.addTab(to: task, kind: .review, in: context)
        }
    }
}

/// The task folder's file tree, beside the tabs and outside any one of them.
struct ReviewDetailPane: View {
    let task: WorkTask

    var body: some View {
        Group {
            if let directory = task.workingDirectoryPath {
                ReviewDetailPaneContent(task: task, model: ReviewStore.shared.model(for: directory))
                    .id(directory)
            } else {
                ContentUnavailableView("No Folder", systemImage: "folder")
            }
        }
        .plumeTheme(bodySize: CGFloat(AppSettings.defaultChatFontSize), setsAmbientFont: false)
        .plumeID(AccessibilityID.reviewDetailPane)
    }
}

private struct ReviewDetailPaneContent: View, ThemedView {
    @Environment(\.theme) var theme
    @Environment(\.modelContext) private var context
    let task: WorkTask
    let model: ReviewModel

    @State private var changedOnly = false
    /// Folders the reader flipped from their default, which is open when the
    /// folder holds a change and closed otherwise.
    @State private var flipped: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text((model.directory as NSString).lastPathComponent)
                    .font(typography.caption.font.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Toggle("Changed files only", isOn: $changedOnly)
                    .toggleStyle(.checkbox)
                    .font(typography.caption.font)
                    .plumeID(
                        AccessibilityID.reviewChangedOnlyToggle,
                        value: changedOnly ? "on" : "off",
                        invoke: { changedOnly.toggle() }
                    )
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            HStack {
                ReviewBasePicker(model: model)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let summaries = Dictionary(model.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
                    ForEach(rows) { row in
                        self.row(row, summary: summaries[row.node.path])
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear { model.retain() }
        .onDisappear { model.release() }
    }

    private var tree: ReviewFileTree { changedOnly ? model.changedTree : model.tree }

    private var rows: [ReviewFileTree.Row] {
        let tree = tree
        let changedOnly = changedOnly
        return tree.visibleRows { path in
            if changedOnly { return true }
            let hasChanges = tree.changedDescendants[path] != nil
            return hasChanges != flipped.contains(path)
        }
    }

    private func row(_ row: ReviewFileTree.Row, summary: DiffFileSummary?) -> some View {
        let node = row.node
        let change = tree.changes[node.path]
        let changedBelow = tree.changedDescendants[node.path]
        let isSelected = node.path == model.selectedPath
        return Button {
            if node.isDirectory {
                if flipped.contains(node.path) { flipped.remove(node.path) } else { flipped.insert(node.path) }
            } else if change != nil {
                ReviewNavigation.open(path: node.path, in: task, context: context)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: node.isDirectory ? (row.isExpanded ? "chevron.down" : "chevron.right") : "doc")
                    .font(.system(size: 9))
                    .frame(width: 12)
                    .emphasis(.subtle)
                Text(node.name)
                    .lineLimit(1)
                    .foregroundStyle(change.map { ReviewChangeBadge.color(for: $0, in: colors) } ?? (changedBelow != nil ? colors.foreground : colors.foreground.opacity(0.6)))
                Spacer(minLength: 4)
                if let change {
                    if let summary { ReviewChangeMagnitudeView(file: summary) }
                    ReviewChangeBadge(kind: change)
                } else if let changedBelow {
                    Text("\(changedBelow)")
                        .font(typography.caption.mono)
                        .foregroundStyle(colors.attention)
                }
            }
            .font(typography.caption.font)
            .padding(.leading, CGFloat(row.depth) * 12 + 6)
            .padding(.trailing, 8)
            .padding(.vertical, 2)
            .contentShape(.rect)
            .background(isSelected ? colors.selection : .clear, in: .rect(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .plumeID(
            AccessibilityID.reviewTreeRow,
            label: node.path,
            value: change?.rawValue ?? (changedBelow.map { "\($0) changed" })
        )
    }
}
#endif
