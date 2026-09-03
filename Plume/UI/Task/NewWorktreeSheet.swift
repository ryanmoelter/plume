import AppKit
import SwiftUI

struct NewWorktreeSheet: View {
    @Bindable var task: WorkTask
    @Environment(\.dismiss) private var dismiss

    @State private var repositoryPath = ""
    @State private var branchName = ""
    @State private var errorMessage: String?
    @State private var isCreating = false
    @State private var recentFolders = RecentFolders.load()

    private var canCreate: Bool {
        !repositoryPath.isEmpty && !branchName.isEmpty && !isCreating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("New Worktree").font(.headline)
                BetaBadge()
                    .help("Worktree creation moved onto GitService and hasn't been driven since. Verify the result before relying on it.")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Repository").font(.callout).foregroundStyle(.secondary)
                HStack {
                    TextField("Path to repository", text: $repositoryPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…", action: chooseRepository)
                }
                if !recentFolders.isEmpty {
                    Menu("Recent") {
                        ForEach(recentFolders, id: \.self) { path in
                            Button(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                                repositoryPath = path
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Branch").font(.callout).foregroundStyle(.secondary)
                TextField("Branch name", text: $branchName)
                    .textFieldStyle(.roundedBorder)
                if !repositoryPath.isEmpty && !branchName.isEmpty {
                    Text(WorkspaceProvisioner.worktreePath(
                        repository: repositoryPath,
                        branch: branchName,
                        basePath: AppSettings.shared.worktreeBasePath
                    )
                        .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            repositoryPath = task.repoPath ?? ""
            branchName = WorkspaceProvisioner.suggestedBranchName(for: task.title)
        }
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        repositoryPath = url.path
        // Narrowed to the repository root once `git` answers, so the sheet
        // shows the chosen folder immediately rather than after a subprocess.
        Task {
            if let root = await GitService.shared.repositoryRoot(containing: url.path) {
                repositoryPath = root
            }
        }
    }

    private func create() {
        isCreating = true
        errorMessage = nil
        let basePath = AppSettings.shared.worktreeBasePath
        Task {
            do {
                // `git worktree add` checks out a whole tree, so this is the
                // slowest call the app makes. On the main thread it froze the
                // sheet before the spinner could draw.
                let path = try await GitService.shared.createWorktree(
                    repository: repositoryPath,
                    branch: branchName,
                    basePath: basePath
                )
                task.workingDirectoryPath = path
                task.repoPath = repositoryPath
                task.branchName = branchName
                task.workspaceKind = .worktree
                RecentFolders.remember(repositoryPath)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}

