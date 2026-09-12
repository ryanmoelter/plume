import SwiftUI

/// A task's live activity, for the bottom of a sidebar row: one status symbol
/// per live subagent, and an antenna when a tab can be driven remotely.
///
/// This is the sidebar's view of what `SubagentListView` shows in the chat, so
/// it follows the same rule for which subagents count: live ones, plus the
/// finished ones still inside their linger. Both read
/// `SubagentCompletionTracker`, so a subagent folds away here and there at the
/// same moment.
///
/// A sidebar row covers a whole task, which can hold several agent tabs, so
/// this gathers across all of them — where the chat's list is one tab's.
///
/// Both views only read the tracker. `TranscriptStore` is what observes, so a
/// subagent's linger runs whether or not anything is mounted to show it — a
/// row here disappears on its own rather than waiting for the user to open the
/// task it belongs to.
struct TaskActivityRow: View, ThemedView {
    @Environment(\.theme) var theme

    let tabIDs: [UUID]

    private var tracker: SubagentCompletionTracker { .shared }

    private var visible: [(tabID: UUID, subagent: SubagentTranscript)] {
        tabIDs.flatMap { tabID in
            TranscriptStore.shared.subagents(forTab: tabID)
                .filter { !tracker.hasSettled($0, tabID: tabID) }
                .map { (tabID, $0) }
        }
    }

    /// Tabs someone can drive from elsewhere. Only the headless transport
    /// carries the bridge; a terminal tab's own TUI serves `/rc` itself.
    private var remoteControlledTabs: Int {
        tabIDs.count { HeadlessSessionManager.shared.existingSession(for: $0)?.remoteControl.link != nil }
    }

    var body: some View {
        let rows = visible
        let remote = remoteControlledTabs
        if !rows.isEmpty || remote > 0 {
            // Centred, not baseline-aligned. Every SF Symbol reports the same
            // ascent whatever its ink, so a baseline puts `ellipsis` — 3pt of
            // ink centred in a 14pt box — visibly low against taller symbols.
            HStack(spacing: 4) {
                if !rows.isEmpty {
                    // `sparkles` is already the app's mark for an agent tab.
                    // Also sets the row's height, which a row of only ellipses
                    // would otherwise leave shorter than its neighbours.
                    Image(systemName: "sparkles")
                        .imageScale(.small)
                        .emphasis(.secondary)
                    ForEach(rows, id: \.subagent.id) { row in
                        StatusBadge(status: row.subagent.status)
                            .imageScale(.small)
                            .help(row.subagent.title)
                    }
                }
                if remote > 0 {
                    Image(systemName: StatusSymbol.remoteControl.name)
                        .imageScale(.small)
                        .foregroundStyle(colors.attention)
                        .help(remote == 1 ? "Remote control is on" : "Remote control is on for \(remote) tabs")
                }
            }
            .font(.caption)
        }
    }
}
