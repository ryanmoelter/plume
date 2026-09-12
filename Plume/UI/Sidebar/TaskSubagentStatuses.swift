import SwiftUI

/// A task's live subagents, one status symbol each, for the bottom of a
/// sidebar row.
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
struct TaskSubagentStatuses: View {
    let tabIDs: [UUID]

    private var tracker: SubagentCompletionTracker { .shared }

    private var visible: [(tabID: UUID, subagent: SubagentTranscript)] {
        tabIDs.flatMap { tabID in
            TranscriptStore.shared.subagents(forTab: tabID)
                .filter { !tracker.hasSettled($0, tabID: tabID) }
                .map { (tabID, $0) }
        }
    }

    var body: some View {
        let rows = visible
        if !rows.isEmpty {
            // Centred, not baseline-aligned. Every SF Symbol reports the same
            // ascent whatever its ink, so a baseline puts `ellipsis` — 3pt of
            // ink centred in a 14pt box — visibly low against taller symbols.
            HStack(spacing: 4) {
                // Also sets the row's height, which a row of only ellipses
                // would otherwise leave shorter than its neighbours.
                Image(systemName: "person.2")
                    .imageScale(.small)
                    .emphasis(.subtle)
                ForEach(rows, id: \.subagent.id) { row in
                    StatusBadge(status: row.subagent.status)
                        .imageScale(.small)
                        .help(row.subagent.title)
                }
            }
            .font(.caption)
        }
    }
}
