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
struct WorkspacePickerView: View, ThemedView {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.theme) var theme

    @Bindable var task: WorkTask
    var isEditable = true
    /// How much room the branch name may take. The statusline row decides
    /// this, since it is the row's one compressible segment.
    var branchWidth: BranchWidth = .natural
    var prominence: WorkspacePickerProminence = .statusline
    /// Ahead/behind and dirty for the directory the agent is actually in.
    /// The chip names its branch when there is one, so the name and the
    /// markers beside it always come from the same `git` run.
    var state: GitState?

    /// The line the resume affordance sits on, supplied by the empty state.
    /// Nil everywhere else, and the picker draws nothing for it.
    var resumeAction: (() -> Void)?

    @State private var worktrees: [GitWorktree] = []
    @State private var repositoryBranch: String?
    @State private var recentFolders = RecentFolders.load()
    @State private var isTargetedForDrop = false
    @State private var worktreeSheetShown = false

    var body: some View {
        Group {
            if prominence == .inline {
                inlineSentence
            } else {
                chipRow
            }
        }
        .background(isTargetedForDrop ? ChatRole.selection.emphasized(.divider, colorScheme: colorScheme) : .clear)
        .onDrop(of: [.fileURL], isTargeted: isEditable ? $isTargetedForDrop : .constant(false)) { providers in
            handleDrop(providers)
        }
        .sheet(isPresented: $worktreeSheetShown) {
            NewWorktreeSheet(task: task)
        }
        // `folderName` reads this cache, which only a lifecycle event may
        // fill — see `CheckoutFactsStore.load`.
        .onChange(of: task.workingDirectoryPath, initial: true) { _, path in
            if let path, !path.isEmpty { CheckoutFactsStore.shared.load(path) }
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

    // MARK: - Chips

    /// The folder chip and the ahead/behind/dirty markers hold their own
    /// intrinsic size (`.fixedSize()`); the branch name is the one segment
    /// that gives way when the row runs out of room, since it's the only
    /// thing here with room to lose without going illegible.
    private var chipRow: some View {
        HStack(spacing: 10) {
            folderChip
                .fixedSize()
            if task.repoPath != nil {
                branchGroup
                    .accessibilityIdentifier(AccessibilityID.statuslineBranch)
            }
            if task.workingDirectoryPath != nil && !directoryExists {
                Label("Missing", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize()
                    .help("This directory no longer exists.")
            }
        }
    }

    // MARK: - Inline sentence

    /// The sentence broken across lines, each clause on its own, sharing one
    /// leading edge. Stacking rather than wrapping keeps the two dropdowns at
    /// a fixed place on the screen instead of moving with the text around
    /// them.
    ///
    /// The worktree clause is unconditional. A plain directory still names the
    /// checkout it is in, so the sentence keeps one shape and the folder
    /// dropdown never shifts as a repository is chosen.
    private var inlineSentence: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Start a conversation")
            HStack(spacing: 6) {
                Text("in")
                inlineFolderMenu
            }
            HStack(spacing: 6) {
                Text("in the")
                inlineWorktreeMenu
                Text("worktree")
            }
            if let resumeAction {
                Button("or resume a conversation \u{2192}", action: resumeAction)
                    .buttonStyle(.link)
                    .font(.body)
                    .padding(.top, 6)
                    .help("Continue a past Claude conversation in this folder")
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var inlineFolderMenu: some View {
        if isEditable {
            Menu {
                folderMenuItems
            } label: {
                inlineLabel(folderName, systemImage: "folder")
            }
            .modifier(InlineMenuChrome(help: folderHelp))
        } else {
            inlineLabel(folderName, systemImage: "folder", isControl: false)
                .help(folderHelp)
        }
    }

    @ViewBuilder
    private var inlineWorktreeMenu: some View {
        if isEditable {
            Menu {
                worktreeMenuItems
            } label: {
                inlineLabel(worktreeName, systemImage: "tree")
            }
            .modifier(InlineMenuChrome(help: worktreeHelp))
        } else {
            inlineLabel(worktreeName, systemImage: "tree", isControl: false)
                .help(worktreeHelp)
        }
    }

    /// An underline and a trailing chevron are the only marks that this word
    /// is a control — no well, no border, no size change.
    ///
    /// The rule is drawn rather than applied with `.underline()`, which reaches
    /// only the `Text` and takes the text's own color. This one runs the width
    /// of the icon, label and chevron together, and sits at the palette's
    /// divider weight so it stays quieter than the words above it. Icons drop a
    /// step below the text so they sit inside the line rather than driving its
    /// height.
    ///
    /// A launched agent's workspace is fixed, so its label keeps the words and
    /// drops both marks rather than advertising a menu that will not open.
    private func inlineLabel(_ title: String, systemImage: String, isControl: Bool = true) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .imageScale(.small)
                .font(.footnote)
            Text(title)
            if isControl {
                Image(systemName: "chevron.down")
                    .imageScale(.small)
                    .font(.footnote)
            }
        }
        .lineLimit(1)
        .overlay(alignment: .bottom) {
            if isControl {
                Rectangle()
                    .fill(colors.divider)
                    .frame(height: 1)
                    .offset(y: 2)
            }
        }
    }

    // MARK: - Folder

    @ViewBuilder
    private var folderMenuItems: some View {
        ForEach(recentFolders, id: \.self) { path in
            Button(abbreviate(path)) { setDirectory(path) }
        }
        if !recentFolders.isEmpty {
            Divider()
        }
        Button("Choose Folder…", action: chooseFolder)
    }

    private var folderChip: some View {
        chip(isEditable: isEditable, help: folderHelp) {
            Menu {
                folderMenuItems
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

    /// The project the checkout belongs to, not the checkout's own directory.
    /// Switching to a linked worktree changes the working directory, and
    /// naming that directory here would make the project appear to change with
    /// it.
    private var folderName: String {
        guard let path = task.workingDirectoryPath, !path.isEmpty else { return "Choose Folder" }
        if let projectName = CheckoutFactsStore.shared.facts(for: path)?.projectName {
            return projectName
        }
        return (path as NSString).lastPathComponent
    }

    // MARK: - Worktree

    /// The branch name and its markers under whatever ceiling the row asked
    /// for. The width belongs to the pair rather than the name alone: a frame
    /// wide enough to truncate against is wider than a short branch name, and
    /// putting it on the name would strand the markers at its far edge.
    /// Truncation comes from `chip`'s own `lineLimit(1)`.
    @ViewBuilder
    private var branchGroup: some View {
        let group = HStack(spacing: 4) {
            worktreeChip
            branchMarkers
            Spacer(minLength: 0)
        }
        switch branchWidth {
        case .natural:
            // Fixed at its natural width so the row's spacer, not this group,
            // absorbs the slack — the two are otherwise both flexible and
            // split it evenly.
            group
                .frame(maxWidth: dimensions.statuslineBranchMaxWidth, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        case .flexible:
            group
                .frame(
                    minWidth: dimensions.statuslineBranchMinWidth,
                    maxWidth: dimensions.statuslineBranchMaxWidth,
                    alignment: .leading
                )
        }
    }

    @ViewBuilder
    private var worktreeMenuItems: some View {
        ForEach(worktrees, id: \.self) { worktree in
            Button(label(for: worktree)) { select(worktree) }
        }
        Divider()
        Button(BetaBadge.menuTitle("New Worktree…")) { worktreeSheetShown = true }
    }

    private var worktreeChip: some View {
        chip(isEditable: isEditable, help: worktreeHelp) {
            Menu {
                worktreeMenuItems
            } label: {
                worktreeLabel
            }
            .menuStyle(.borderlessButton)
        } readOnly: {
            worktreeLabel
        }
    }

    private var worktreeLabel: some View {
        Label(worktreeName, systemImage: "tree")
    }

    /// Which worktree, not which branch. The repository's own checkout is
    /// "main" whatever it happens to have checked out; a linked worktree goes
    /// by its directory name, which is what distinguishes two worktrees of one
    /// repository. Only a directory that is in no listing falls back to the
    /// branch.
    private var worktreeName: String {
        if let path = task.workingDirectoryPath.map(standardized),
           let worktree = worktrees.first(where: { standardized($0.path) == path }) {
            return worktree.isMain ? "main" : (worktree.path as NSString).lastPathComponent
        }
        return state?.branch ?? task.branchName ?? repositoryBranch ?? "Worktree"
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
                    .emphasis(.secondary)
                    .fixedSize()
                    .help("\(ahead) ahead of \(state.upstream ?? "upstream")")
            }
            if let behind = state.behind, behind > 0 {
                Text("\u{2193}\(behind)")
                    .emphasis(.secondary)
                    .fixedSize()
                    .help("\(behind) behind \(state.upstream ?? "upstream")")
            }
            // No upstream at all is worth marking: it is the common case on a
            // fresh worktree branch, and silence would read as "level with
            // upstream". An icon rather than words, so it sits beside the
            // ahead/behind markers as one more glyph instead of crowding the
            // branch name off the row.
            if !state.hasUpstream {
                Image(systemName: "network.slash")
                    .emphasis(.subtle)
                    .fixedSize()
                    .help("This branch tracks nothing")
            }
            if state.isDirty {
                Text("\u{2022}")
                    .emphasis(.secondary)
                    .fixedSize()
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
    /// launching an agent doesn't reflow the row. Secondary either way: the
    /// statusline is metadata, not the thing the eye should land on.
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
                readOnly().help(help)
            }
        }
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .emphasis(.secondary)
    }

    /// `git` and the stored path can spell one directory differently — a
    /// trailing slash, or `..` left in.
    private func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
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

/// How loudly the picker should present itself.
enum WorkspacePickerProminence {
    /// Metadata beside the meters: small, secondary, no chrome of its own.
    case statusline
    /// Words in a sentence. The dropdowns take the surrounding text's size and
    /// are marked only by an underline and a chevron, so the sentence reads as
    /// prose the user can edit rather than as a row of controls.
    case inline
}

/// Strips a `Menu` back to its label so it can sit in a run of text: no bezel,
/// no system disclosure arrow (the label draws its own chevron), and no claim
/// on the row's slack — an unfixed menu stretches and pushes the words after
/// it to the far edge.
private struct InlineMenuChrome: ViewModifier {
    let help: String

    func body(content: Content) -> some View {
        content
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(help)
    }
}

/// How much room the statusline row is giving the branch name.
enum BranchWidth {
    /// As wide as the name needs, up to `statuslineBranchMaxWidth`.
    case natural
    /// Whatever the row has left, between `statuslineBranchMinWidth` and
    /// `statuslineBranchMaxWidth`.
    case flexible
}
