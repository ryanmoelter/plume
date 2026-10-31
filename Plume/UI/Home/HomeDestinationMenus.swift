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

    @ViewBuilder
    var projectItems: some View {
        Picker(
            "Project",
            selection: Binding(get: { model.destination.projectPath ?? "" }, set: { model.chooseProject($0) })
        ) {
            ForEach(model.catalog.projects) { project in
                Text(project.name).tag(project.path)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
        Divider()
        Button("Choose Folder…", action: chooseFolder)
    }

    var workspaceItems: some View {
        Picker(
            "Workspace",
            selection: Binding(get: { model.destination.workspace }, set: { model.chooseWorkspace($0) })
        ) {
            ForEach(model.workspaceChoices, id: \.self) { choice in
                Text(choice.title).tag(choice)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
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

    func chooseWorkspace(named name: String) {
        let match = HomeWorkspaceChoice.allCases.first {
            $0.rawValue.caseInsensitiveCompare(name) == .orderedSame
                || $0.title.caseInsensitiveCompare(name) == .orderedSame
        }
        if let match { chooseWorkspace(match) }
    }
}
