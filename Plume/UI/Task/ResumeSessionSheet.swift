import SwiftUI

/// Picks a past `claude` conversation for a tab to resume.
struct ResumeSessionSheet: View {
    let workingDirectory: String
    let repoPath: String?
    let onSelect: (StoredSession) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [StoredSession]?
    @State private var query = ""

    private var matches: [StoredSession] {
        guard let sessions else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sessions }
        return sessions.filter {
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
        // Loaded once here rather than from `body`: the scan runs a `git`
        // subprocess and reads every transcript in range, and writing
        // observable state during a render invalidates it.
        .task {
            sessions = ResumableSessions.load(workingDirectory: workingDirectory, repoPath: repoPath)
        }
    }

    @ViewBuilder
    private var content: some View {
        if sessions == nil {
            centered { ProgressView() }
        } else if matches.isEmpty {
            centered {
                Text(sessions?.isEmpty == true
                    ? "No past conversations in this folder."
                    : "No conversations match “\(query)”.")
                    .foregroundStyle(.secondary)
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
                    // conversation was recorded in.
                    Label(
                        (session.workingDirectory as NSString).lastPathComponent,
                        systemImage: "arrow.turn.down.right"
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
