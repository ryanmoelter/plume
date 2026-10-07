import SwiftUI

/// One subagent: what it was asked to do, and how it is doing.
///
/// Reading one is a separate act from scanning the list, so the row opens the
/// full transcript in an overlay rather than expanding in place; a nested
/// disclosure made the list unreadable with several subagents running at once.
struct SubagentRow: View, ThemedView {
    @Environment(\.theme) var theme

    let subagent: SubagentTranscript
    let onOpen: () -> Void
    let onOverride: (SubagentStatusOverrides.Override?) -> Void
    let currentOverride: SubagentStatusOverrides.Override?
    let columns: Columns

    /// Where the badge and the text start, so a host with its own icon column
    /// can line the row up with it.
    struct Columns {
        var leadingIndent: CGFloat = 0
        var badgeWidth: CGFloat = 12
        var spacing: CGFloat = 8

        /// How far the hover wash reaches past the badge and the chevron.
        static let washInset: CGFloat = 8

        /// The badge in the info pane's icon column, under its section's icon.
        static let infoPane = Columns(
            badgeWidth: InfoPaneLayout.iconColumnWidth,
            spacing: InfoPaneLayout.columnSpacing
        )
    }

    /// Routes a status override to the store that owns this subagent.
    init(subagent: SubagentTranscript, tabID: UUID, columns: Columns = Columns(), onOpen: @escaping () -> Void) {
        self.subagent = subagent
        self.columns = columns
        self.onOpen = onOpen
        self.onOverride = { override in
            switch subagent.provider {
            case .claudeCode:
                TranscriptStore.shared.setOverride(override, tabID: tabID, subagentID: subagent.id)
            case .codex:
                CodexSubagentStore.shared.setOverride(override, tabID: tabID, subagentID: subagent.id)
            }
        }
        self.currentOverride = SubagentStatusOverrides.shared.override(tabID: tabID, subagentID: subagent.id)
    }

    @State private var isHovering = false

    /// What the row leads with — the ask, not the agent type, which the
    /// caption below states instead. Falls back to the id, matching the help
    /// text below it.
    private var title: String {
        subagent.descriptor?.description ?? subagent.id
    }

    var body: some View {
        let caption = SubagentCaption(subagent: subagent)
        Button(action: onOpen) {
            HStack(alignment: .firstTextBaseline, spacing: columns.spacing) {
                StatusBadge(status: subagent.status)
                    .frame(width: columns.badgeWidth, alignment: .center)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // Rendered even while empty, so a row keeps its height as
                    // the facts arrive on the next read.
                    Text(caption.text)
                        .font(typography.caption.font)
                        .emphasis(.subtle)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                // Rendered even while empty, for the same reason the caption
                // is: a row that gains its start time shouldn't reflow.
                Text(caption.elapsedText ?? "")
                    .font(typography.caption.font)
                    .monospacedDigit()
                    .emphasis(.subtle)
                Image(systemName: "chevron.right")
                    .font(typography.caption.font)
                    .emphasis(.subtle)
            }
            .padding(.leading, columns.leadingIndent)
            .padding(.horizontal, Columns.washInset)
            .padding(.vertical, 5)
            .contentShape(.rect(cornerRadius: 6))
            .background(
                isHovering ? colors.surfaceTint : Color.clear,
                in: .rect(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .plumeHover { isHovering = $0 }
        .help(subagent.descriptor?.description ?? subagent.id)
        .plumeID(AccessibilityID.subagentRow, label: subagent.title)
        .contextMenu { menu }
    }

    /// The escape hatch for a row nothing can settle on its own. Offered only
    /// where it applies: a subagent still reporting working, or one the user
    /// already marked and may want to put back.
    @ViewBuilder
    private var menu: some View {
        if currentOverride != nil {
            Button("Clear Status Override") { onOverride(nil) }
                .plumeID(AccessibilityID.subagentClearOverride)
        } else if subagent.status == .working {
            Button("Mark as Done") { onOverride(.done) }
                .plumeID(AccessibilityID.subagentMarkDone)
            Button("Mark as Interrupted") { onOverride(.interrupted) }
                .plumeID(AccessibilityID.subagentMarkInterrupted)
        }
    }
}
