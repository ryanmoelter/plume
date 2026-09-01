import AppKit
import SwiftUI

struct NewWorktreeSheet: View {
    @Bindable var task: WorkTask
    @Environment(\.dismiss) private var dismiss

    @State private var repositoryPath = ""
    @State private var branchName = ""
    @State private var errorMessage: String?
    @State private var isCreating = false
    @State private var recentRepositories = RecentRepositories.load()

    private var canCreate: Bool {
        !repositoryPath.isEmpty && !branchName.isEmpty && !isCreating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Worktree").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Repository").font(.callout).foregroundStyle(.secondary)
                HStack {
                    TextField("Path to repository", text: $repositoryPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…", action: chooseRepository)
                }
                if !recentRepositories.isEmpty {
                    Menu("Recent") {
                        ForEach(recentRepositories, id: \.self) { path in
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
                    Text(WorkspaceProvisioner.worktreePath(repository: repositoryPath, branch: branchName)
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
            branchName = WorkspaceProvisioner.suggestedBranchName(for: task.title)
        }
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        repositoryPath = GitRunner.repositoryRoot(containing: url.path) ?? url.path
    }

    private func create() {
        isCreating = true
        errorMessage = nil
        do {
            let path = try WorkspaceProvisioner.createWorktree(
                repository: repositoryPath,
                branch: branchName
            )
            task.workingDirectoryPath = path
            task.repoPath = repositoryPath
            task.branchName = branchName
            task.workspaceKind = .worktree
            RecentRepositories.remember(repositoryPath)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isCreating = false
        }
    }
}

enum RecentRepositories {
    private static let key = "recentRepositories"
    private static let limit = 8

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func remember(_ path: String) {
        var paths = load().filter { $0 != path }
        paths.insert(path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(limit)), forKey: key)
    }
}
