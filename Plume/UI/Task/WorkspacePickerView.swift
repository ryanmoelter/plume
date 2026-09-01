import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The task's workspace, as two chips above the composer: the folder to run
/// in, and — when that folder is a git repository — which of its worktrees.
///
/// A running agent's working directory is fixed at launch, so `isEditable`
/// renders the same chips as plain labels rather than hiding them.
struct WorkspacePickerView: View {
    @Bindable var task: WorkTask
    var isEditable = true

    @State private var worktrees: [GitWorktree] = []
    @State private var repositoryBranch: String?
    @State private var recentFolders = RecentFolders.load()
    @State private var isTargetedForDrop = false
    @State private var worktreeSheetShown = false

    var body: some View {
        HStack(spacing: 14) {
            folderChip
            if task.repoPath != nil {
                worktreeChip
            }
            permissionModeChip
            if task.workingDirectoryPath != nil && !directoryExists {
                Label("Missing", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("This directory no longer exists.")
            }
        }
        .font(.callout)
        .padding(.horizontal, 4)
        .background(isTargetedForDrop ? Color.accentColor.opacity(0.15) : .clear)
        .onDrop(of: [.fileURL], isTargeted: isEditable ? $isTargetedForDrop : .constant(false)) { providers in
            handleDrop(providers)
        }
        .sheet(isPresented: $worktreeSheetShown) {
            NewWorktreeSheet(task: task)
        }
        // `git` runs off the main actor and lands in state: a subprocess per
        // render would be ruinous, and writing observable state from `body`
        // invalidates the view being rendered.
        .task(id: task.repoPath) {
            guard let repoPath = task.repoPath else {
                worktrees = []
                repositoryBranch = nil
                return
            }
            let loaded = await Task.detached {
                (GitRunner.worktrees(in: repoPath), GitRunner.currentBranch(in: repoPath))
            }.value
            worktrees = loaded.0
            repositoryBranch = loaded.1
        }
    }

    // MARK: - Folder

    private var folderChip: some View {
        chip(isEditable: isEditable) {
            Menu {
                ForEach(recentFolders, id: \.self) { path in
                    Button(abbreviate(path)) { setDirectory(path) }
                }
                if !recentFolders.isEmpty {
                    Divider()
                }
                Button("Choose Folder…", action: chooseFolder)
            } label: {
                folderLabel
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } readOnly: {
            folderLabel
        }
        .help(task.workingDirectoryPath.map(abbreviate) ?? "No folder chosen")
    }

    private var folderLabel: some View {
        Label(folderName, systemImage: "folder")
    }

    private var folderName: String {
        guard let path = task.workingDirectoryPath, !path.isEmpty else { return "Choose Folder" }
        return (path as NSString).lastPathComponent
    }

    // MARK: - Permission mode

    /// Only settable before launch: `--permission-mode` is a launch flag, and
    /// a running session changes mode from the statusline strip instead.
    private var permissionModeChip: some View {
        chip(isEditable: isEditable) {
            Menu {
                Button("Default") { task.permissionMode = nil }
                Divider()
                ForEach(PermissionMode.allCases) { mode in
                    Button(mode.label) { task.permissionMode = mode }
                }
            } label: {
                permissionModeLabel
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } readOnly: {
            permissionModeLabel
        }
        .help("Permission mode for new sessions")
    }

    private var permissionModeLabel: some View {
        Label(task.permissionMode?.label ?? "Default", systemImage: "lock.shield")
    }

    // MARK: - Worktree

    private var worktreeChip: some View {
        chip(isEditable: isEditable) {
            Menu {
                ForEach(worktrees, id: \.self) { worktree in
                    Button(label(for: worktree)) { select(worktree) }
                }
                Divider()
                Button("New Worktree…") { worktreeSheetShown = true }
            } label: {
                worktreeLabel
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } readOnly: {
            worktreeLabel
        }
    }

    private var worktreeLabel: some View {
        Label(worktreeName, systemImage: "tree")
    }

    private var worktreeName: String {
        task.branchName ?? repositoryBranch ?? "Worktree"
    }

    private func label(for worktree: GitWorktree) -> String {
        let branch = worktree.branch ?? (worktree.path as NSString).lastPathComponent
        return worktree.isMain ? "\(branch) (repository)" : branch
    }

    private func select(_ worktree: GitWorktree) {
        task.workingDirectoryPath = worktree.path
        task.branchName = worktree.branch
        task.workspaceKind = worktree.isMain ? .directory : .worktree
        RecentFolders.remember(worktree.path)
        recentFolders = RecentFolders.load()
    }

    // MARK: - Chrome

    /// Both chips share their frame across edit and read-only rendering, so
    /// launching an agent doesn't reflow the row.
    private func chip(
        isEditable: Bool,
        @ViewBuilder editable: () -> some View,
        @ViewBuilder readOnly: () -> some View
    ) -> some View {
        Group {
            if isEditable {
                editable()
            } else {
                readOnly().foregroundStyle(.secondary)
            }
        }
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
    }

    private func abbreviate(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var directoryExists: Bool {
        guard let path = task.workingDirectoryPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    // MARK: - Choosing

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setDirectory(url.path)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard isEditable, let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.hasDirectoryPath else { return }
            Task { @MainActor in setDirectory(url.path) }
        }
        return true
    }

    private func setDirectory(_ path: String) {
        task.workingDirectoryPath = path
        task.workspaceKind = .directory
        task.repoPath = GitRunner.repositoryRoot(containing: path)
        task.branchName = nil
        RecentFolders.remember(path)
        recentFolders = RecentFolders.load()
    }
}
