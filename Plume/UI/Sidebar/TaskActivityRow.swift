import SwiftUI

/// A task's live subagents, one status symbol each, and a count of its
/// running background tasks, for the bottom of a sidebar row.
///
/// This is the sidebar's view of what the info pane shows in the chat, so
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

    private var backgroundTaskCount: Int {
        tabIDs.reduce(0) { $0 + BackgroundTaskTracker.shared.inFlight(tabID: $1).count }
    }

    var body: some View {
        let rows = visible
        let backgroundTaskCount = backgroundTaskCount
        if !rows.isEmpty || backgroundTaskCount > 0 {
            // Centred, not baseline-aligned. Every SF Symbol reports the same
            // ascent whatever its ink, so a baseline puts `ellipsis` — 3pt of
            // ink centred in a 14pt box — visibly low against taller symbols.
            HStack(spacing: 8) {
                if !rows.isEmpty {
                    HStack(spacing: 4) {
                        // Also sets the row's height, which a row of only
                        // ellipses would otherwise leave shorter than its
                        // neighbours.
                        Image(systemName: StatusSymbol.subagents.filled)
                            .imageScale(.small)
                            .emphasis(.secondary)
                        ForEach(rows, id: \.subagent.id) { row in
                            StatusBadge(status: row.subagent.status)
                                .imageScale(.small)
                                .help(row.subagent.title)
                        }
                    }
                }
                if backgroundTaskCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: StatusSymbol.backgroundTasks.filled)
                            .imageScale(.small)
                        Text("\(backgroundTaskCount)")
                    }
                    .emphasis(.secondary)
                    .help(backgroundTaskCount == 1 ? "1 background task" : "\(backgroundTaskCount) background tasks")
                }
            }
            // These symbols carry little ink at this size — the working
            // ellipsis is three dots — so they take the extra weight to read.
            .font(.caption.weight(.bold))
        }
    }
}
