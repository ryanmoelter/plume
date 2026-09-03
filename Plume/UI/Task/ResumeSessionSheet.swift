import SwiftData
import SwiftUI

/// Picks a past `claude` conversation for a tab to resume.
struct ResumeSessionSheet: View {
    let workingDirectory: String
    let repoPath: String?
    let onSelect: (StoredSession) -> Void

    @Environment(\.dismiss) private var dismiss
    /// Every tab, to hide conversations another one already holds. Reading
    /// the persisted IDs rather than the live sessions also covers a tab that
    /// has not spawned its process yet.
    @Query private var tabs: [TaskTab]
    @State private var sessions: [StoredSession]?
    @State private var query = ""

    private var openSessionIDs: Set<String> {
        Set(tabs.compactMap { $0.agentSessionID }.filter { !$0.isEmpty })
    }

    private var available: [StoredSession] {
        ResumableSessions.excludingOpen(sessions ?? [], openSessionIDs: openSessionIDs)
    }

    private var matches: [StoredSession] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return available }
        return available.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(trimmed)
                || $0.workingDirectory.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Resume a Conversation").font(.headline)

            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)

            content
                .frame(height: 320)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            sessions = await ResumableSessions.load(
                workingDirectory: workingDirectory,
                repoPath: repoPath
            )
        }
    }

    /// Distinguishes "there are none" from "they are all already open", so a
    /// filtered-out conversation never just goes missing.
    private var emptyMessage: String {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No conversations match “\(query)”."
        }
        if sessions?.isEmpty == false {
            return "Every past conversation here is already open in a tab."
        }
        return "No past conversations in this folder."
    }

    @ViewBuilder
    private var content: some View {
        if sessions == nil {
            centered { ProgressView() }
        } else if matches.isEmpty {
            centered {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        } else {
            List(matches) { session in
                Button {
                    onSelect(session)
                    dismiss()
                } label: {
                    row(for: session)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
        }
    }

    private func row(for session: StoredSession) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.displayTitle)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(session.lastModified.formatted(.relative(presentation: .named)))
                if isElsewhere(session) {
                    // Resuming runs in this tab's directory, not the one the
                    // conversation was recorded in. The tree matches the
                    // worktree chip in `WorkspacePickerView`.
                    Label(
                        (session.workingDirectory as NSString).lastPathComponent,
                        systemImage: "tree"
                    )
                    .help("Recorded in \(session.workingDirectory). Resuming runs it here instead.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    private func isElsewhere(_ session: StoredSession) -> Bool {
        URL(fileURLWithPath: session.workingDirectory).standardizedFileURL
            != URL(fileURLWithPath: workingDirectory).standardizedFileURL
    }

    private func centered(@ViewBuilder _ content: () -> some View) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity)
    }
}
