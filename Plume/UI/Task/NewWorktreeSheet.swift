import AppKit
import SwiftUI

/// Names a branch and creates its worktree for the task.
///
/// The repository is not asked for here: it is already chosen on the screen
/// behind this sheet, and `task.repoPath` is what that choice writes.
struct NewWorktreeSheet: View {
    @Bindable var task: WorkTask
    @Environment(\.dismiss) private var dismiss

    @State private var branchName = ""
    @State private var stripsBranchPrefix = false
    @State private var isEditingLocation = false
    @State private var locationOverride = ""
    @State private var errorMessage: String?
    @State private var isCreating = false

    private var repositoryPath: String { task.repoPath ?? "" }

    private var canCreate: Bool {
        !repositoryPath.isEmpty && !branchName.isEmpty && !isCreating
    }

    /// Where the worktree will land, given every choice on the sheet. Also
    /// what seeds the location field the moment the user opens it, so editing
    /// starts from the derived answer rather than from nothing.
    private var derivedPath: String {
        WorkspaceProvisioner.worktreePath(
            repository: repositoryPath,
            branch: branchName,
            basePath: AppSettings.shared.worktreeBasePath,
            strippingPrefix: stripsBranchPrefix
        )
    }

    private var resolvedPath: String {
        isEditingLocation && !locationOverride.isEmpty
            ? (locationOverride as NSString).expandingTildeInPath
            : derivedPath
    }

    private var branchHasPrefix: Bool {
        branchName.contains("/")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Worktree").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Branch").font(.callout).foregroundStyle(.secondary)
                TextField("Branch name", text: $branchName)
                    .textFieldStyle(.roundedBorder)
                    .plumeID(AccessibilityID.worktreeBranchField)
                    .background(InitialFocus())
                if branchHasPrefix {
                    Toggle("Drop the branch prefix from the folder name", isOn: $stripsBranchPrefix)
                        .plumeID(AccessibilityID.worktreeStripPrefixToggle)
                }
            }

            location

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
                    .plumeID(AccessibilityID.worktreeCancelButton)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
                    .plumeID(AccessibilityID.worktreeCreateButton)
            }
        }
        .padding(20)
        .frame(width: 480)
        // Chrome, not chat: the sheet is presented from the statusline, which
        // sits under the conversation's ambient font, and inherits it without
        // this. A path is the thing this sheet most needs to show whole.
        .plumeTheme(
            bodySize: CGFloat(AppSettings.defaultChatFontSize),
            setsAmbientFont: false
        )
        .onAppear {
            branchName = WorkspaceProvisioner.suggestedBranchName(
                for: task.title,
                prefix: WorkspaceProvisioner.configuredBranchPrefix(in: task.repoPath)
                    ?? WorkspaceProvisioner.defaultBranchPrefix
            )
        }
    }

    /// The derived path reads as a caption until the user asks to change it,
    /// which keeps the common case to one field.
    @ViewBuilder
    private var location: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Location").font(.callout).foregroundStyle(.secondary)
                Spacer()
                if !isEditingLocation {
                    Button("Edit") {
                        locationOverride = derivedPath
                        isEditingLocation = true
                    }
                    .buttonStyle(.link)
                    .plumeID(AccessibilityID.worktreeEditLocationButton)
                }
            }
            if isEditingLocation {
                HStack {
                    TextField("Worktree path", text: $locationOverride)
                        .textFieldStyle(.roundedBorder)
                        .plumeID(AccessibilityID.worktreeLocationField)
                    Button("Choose…", action: chooseLocation)
                        .plumeID(AccessibilityID.worktreeChooseLocationButton)
                }
            } else if !repositoryPath.isEmpty && !branchName.isEmpty {
                Text(abbreviated(resolvedPath))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }
        }
    }

    private func abbreviated(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// The panel picks the *parent* directory; `git worktree add` wants a path
    /// that does not exist yet, so the branch's folder name is appended to it.
    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = WorkspaceProvisioner.worktreeDirectoryName(
            for: branchName,
            strippingPrefix: stripsBranchPrefix
        )
        locationOverride = url.appending(path: name).path
    }

    private func create() {
        isCreating = true
        errorMessage = nil
        let repository = repositoryPath
        let basePath = AppSettings.shared.worktreeBasePath
        let override = isEditingLocation && !locationOverride.isEmpty ? locationOverride : nil
        let strippingPrefix = stripsBranchPrefix
        let branch = branchName
        Task {
            do {
                // `git worktree add` checks out a whole tree, so this is the
                // slowest call the app makes. On the main thread it froze the
                // sheet before the spinner could draw.
                let path = try await GitService.shared.createWorktree(
                    repository: repository,
                    branch: branch,
                    basePath: basePath,
                    strippingPrefix: strippingPrefix,
                    explicitPath: override
                )
                task.workingDirectoryPath = path
                task.repoPath = repository
                task.branchName = branch
                task.workspaceKind = .worktree
                RecentFolders.remember(repository)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}
