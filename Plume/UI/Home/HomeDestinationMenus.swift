import AppKit
import SwiftUI

/// The menu contents every destination picker shares, so the variants differ
/// only in how they present them.
struct HomeDestinationMenus {
    let model: HomeComposerModel

    var groupItems: some View {
        Picker("Group", selection: Binding(get: { model.destination.groupID }, set: { model.chooseGroup($0) })) {
            Text(HomeDestinationCatalog.noGroupTitle).tag(UUID?.none)
            ForEach(model.catalog.groups) { group in
                Text(group.name).tag(Optional(group.id))
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    /// Each project over its path, as the new conversation screen's folder
    /// menu shows its folders.
    @ViewBuilder
    var projectItems: some View {
        ForEach(model.catalog.projects) { project in
            Toggle(isOn: selecting(project.path == model.destination.projectPath) { model.chooseProject(project.path) }) {
                Text(project.name)
                Text(HomeDestinationPath.abbreviated(project.path))
            }
        }
        if !model.catalog.projects.isEmpty {
            Divider()
        }
        Button("Choose Folder…", action: chooseFolder)
    }

    /// Each worktree over its branch, then a new one, as the new conversation
    /// screen's worktree menu lists them.
    @ViewBuilder
    var workspaceItems: some View {
        let existing = model.workspaceChoices.filter { $0 != .newWorktree }
        ForEach(existing, id: \.self) { choice in
            Toggle(isOn: selecting(choice == model.destination.workspace) { model.chooseWorkspace(choice) }) {
                Text(model.workspaceTitle(for: choice))
                if let branch = model.workspaceBranch(for: choice) {
                    Text(branch)
                }
            }
        }
        Divider()
        Toggle(
            HomeWorkspaceChoice.newWorktreeTitle,
            isOn: selecting(model.destination.workspace == .newWorktree) { model.chooseWorkspace(.newWorktree) }
        )
    }

    /// A menu item's checkmark: choosing it selects, and choosing it again
    /// keeps it selected.
    private func selecting(_ isSelected: Bool, choose: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { isSelected }, set: { _ in choose() })
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.addFolder(url.path) }
    }
}

/// What the control server's `setValue` accepts for each picker: a name as
/// shown, matched without regard to case.
extension HomeComposerModel {
    func chooseGroup(named name: String) {
        if name.caseInsensitiveCompare(HomeDestinationCatalog.noGroupTitle) == .orderedSame {
            chooseGroup(nil)
        } else if let group = catalog.groups.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            chooseGroup(group.id)
        }
    }

    func chooseProject(named name: String) {
        let match = catalog.projects.first {
            $0.path == name || $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
        if let match { chooseProject(match.path) }
    }

    /// Also takes a worktree's path or branch.
    func chooseWorkspace(named name: String) {
        let match = workspaceChoices.first { choice in
            if workspaceTitle(for: choice).caseInsensitiveCompare(name) == .orderedSame { return true }
            guard case .worktree(let path, let branch) = choice else { return false }
            return path == name || branch == name
        }
        if let match { chooseWorkspace(match) }
    }
}
