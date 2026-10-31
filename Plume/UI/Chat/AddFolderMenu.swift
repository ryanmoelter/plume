import SwiftUI

/// The add-folder menu's items: recently linked folders, recent projects,
/// then the open panel.
struct AddFolderMenuItems: View {
    let candidates: AddFolderCandidates
    let add: (String) -> Void
    let choose: () -> Void

    /// Read while the menu draws, so the lists are as fresh as the last
    /// render of the view holding it.
    init(linked: [String], workingDirectory: String?, add: @escaping (String) -> Void, choose: @escaping () -> Void) {
        candidates = AddFolderCandidates(
            recentFolders: RecentLinkedFolders.load(),
            recentProjects: RecentFolders.load(),
            linked: linked,
            workingDirectory: workingDirectory
        )
        self.add = add
        self.choose = choose
    }

    var body: some View {
        if !candidates.folders.isEmpty {
            Section("Recent Folders") {
                ForEach(candidates.folders, id: \.self) { item($0, id: AccessibilityID.addFolderMenuRecentFolder) }
            }
        }
        if !candidates.projects.isEmpty {
            Section("Recent Projects") {
                ForEach(candidates.projects, id: \.self) { item($0, id: AccessibilityID.addFolderMenuRecentProject) }
            }
        }
        if !candidates.isEmpty {
            Divider()
        }
        Button("Choose Folder…", action: choose)
            .plumeID(AccessibilityID.addFolderMenuChooseButton, invoke: choose)
    }

    private func item(_ path: String, id: String) -> some View {
        Button(FolderActions.abbreviated(path)) { add(path) }
            .plumeID(id, label: path) { add(path) }
    }
}
