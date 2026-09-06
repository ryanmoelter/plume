import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The task's workspace, as two chips in the statusline: the folder to run
/// in, and — when that folder is a git repository — which of its worktrees,
/// with that worktree's ahead/behind and dirty markers beside it. Worktree
/// and branch answer one question, so they read as one group.
///
/// A running agent's working directory is fixed at launch, so `isEditable`
/// renders the same chips as plain labels rather than hiding them.
struct WorkspacePickerView: View {
    @Environment(\.colorScheme) private var colorScheme

    @Bindable var task: WorkTask
    var isEditable = true
    /// Ahead/behind and dirty for the directory the agent is actually in.
    /// The chip names its branch when there is one, so the name and the
    /// markers beside it always come from the same `git` run.
    var state: GitState?

    @State private var worktrees: [GitWorktree] = []
    @State private var repositoryBranch: String?
    @State private var recentFolders = RecentFolders.load()
    @State private var isTargetedForDrop = false
    @State private var worktreeSheetShown = false

    var body: some View {
        HStack(spacing: 10) {
            folderChip
            if task.repoPath != nil {
                HStack(spacing: 4) {
                    worktreeChip
                    branchMarkers
                }
                .accessibilityIdentifier(AccessibilityID.statuslineBranch)
            }
            if task.workingDirectoryPath != nil && !directoryExists {
                Label("Missing", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("This directory no longer exists.")
            }
        }
        .background(isTargetedForDrop ? ChatRole.selection.emphasized(.divider, colorScheme: colorScheme) : .clear)
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
            let loaded = await GitService.shared.worktreeListing(in: repoPath)
            worktrees = loaded.worktrees
            repositoryBranch = loaded.branch
        }
    }

    // MARK: - Folder

    private var folderChip: some View {
        chip(isEditable: isEditable, help: folderHelp) {
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
    }

    private var folderHelp: String {
        guard let path = task.workingDirectoryPath else { return "No folder chosen" }
        return "Working folder: \(abbreviate(path))"
    }

    private var folderLabel: some View {
        Label(folderName, systemImage: "folder")
    }

    private var folderName: String {
        guard let path = task.workingDirectoryPath, !path.isEmpty else { return "Choose Folder" }
        return (path as NSString).lastPathComponent
    }

    // MARK: - Worktree

    private var worktreeChip: some View {
        chip(isEditable: isEditable, help: worktreeHelp) {
            Menu {
                ForEach(worktrees, id: \.self) { worktree in
                    Button(label(for: worktree)) { select(worktree) }
                }
                Divider()
                Button(BetaBadge.menuTitle("New Worktree…")) { worktreeSheetShown = true }
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
        state?.branch ?? task.branchName ?? repositoryBranch ?? "Worktree"
    }

    /// The path, since two worktrees of one repository differ only there.
    private var worktreeHelp: String {
        guard let path = task.workingDirectoryPath else { return "Worktree: \(worktreeName)" }
        return "Worktree \(worktreeName): \(abbreviate(path))"
    }

    /// How this worktree stands against its upstream, and whether it holds
    /// uncommitted work.
    @ViewBuilder
    private var branchMarkers: some View {
        if let state {
            if let ahead = state.ahead, ahead > 0 {
                Text("\u{2191}\(ahead)")
                    .help("\(ahead) ahead of \(state.upstream ?? "upstream")")
            }
            if let behind = state.behind, behind > 0 {
                Text("\u{2193}\(behind)")
                    .help("\(behind) behind \(state.upstream ?? "upstream")")
            }
            // No upstream at all is worth saying: it is the common case on a
            // fresh worktree branch, and silence would read as "level with
            // upstream".
            if !state.hasUpstream {
                Text("no upstream")
                    .emphasis(.subtle)
                    .help("This branch tracks nothing")
            }
            if state.isDirty {
                Text("\u{2022}")
                    .help("Uncommitted changes")
            }
        }
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
        help: String,
        @ViewBuilder editable: () -> some View,
        @ViewBuilder readOnly: () -> some View
    ) -> some View {
        // The help lands on the menu itself rather than on this wrapper: the
        // tooltip has to reach the button the menu style draws.
        Group {
            if isEditable {
                editable().help(help)
            } else {
                readOnly().emphasis(.secondary).help(help)
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
        task.branchName = nil
        RecentFolders.remember(path)
        recentFolders = RecentFolders.load()
        // Resolved after the fact: finding the repository root is a
        // subprocess, and the picker should not wait on one to show the
        // folder the user just chose.
        Task { task.repoPath = await GitService.shared.repositoryRoot(containing: path) }
    }
}
