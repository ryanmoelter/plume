import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shows the workspace picker while a task has none, collapsing to a path or
/// branch chip once set.
struct TaskSetupHeaderView: View {
    @Bindable var task: WorkTask

    @State private var isTargetedForDrop = false
    @State private var worktreeSheetShown = false
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 10) {
            if task.workspaceKind == .unset {
                unsetControls
            } else {
                workspaceChip
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isTargetedForDrop ? Color.accentColor.opacity(0.15) : .clear)
        .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
            handleDrop(providers)
        }
        .sheet(isPresented: $worktreeSheetShown) {
            NewWorktreeSheet(task: task)
        }
        .alert("Workspace Error", isPresented: errorBinding) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    @ViewBuilder
    private var unsetControls: some View {
        Button("Choose Folder…", action: chooseFolder)
        Button("New Worktree…") { worktreeSheetShown = true }
        Text("or drop a folder here")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var workspaceChip: some View {
        HStack(spacing: 6) {
            Image(systemName: task.workspaceKind == .worktree ? "arrow.triangle.branch" : "folder")
            if task.workspaceKind == .worktree, let branch = task.branchName {
                Text(branch).fontWeight(.medium)
            }
            Text(displayPath)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .font(.callout)
        .help(task.workingDirectoryPath ?? "")

        if !directoryExists {
            Label("Missing", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .help("This directory no longer exists.")
        }

        Button("Change…", action: chooseFolder)
            .buttonStyle(.link)
            .font(.callout)
    }

    private var displayPath: String {
        (task.workingDirectoryPath ?? "").replacingOccurrences(
            of: NSHomeDirectory(), with: "~"
        )
    }

    private var directoryExists: Bool {
        guard let path = task.workingDirectoryPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

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
        guard let provider = providers.first else { return false }
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
    }
}
