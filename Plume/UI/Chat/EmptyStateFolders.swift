import SwiftUI

/// The new conversation's extra folders, under the sentence saying where it
/// runs: a menu to add one, and a removable chip per folder already added.
struct EmptyStateFolders: View, ThemedView {
    @Environment(\.theme) var theme

    let tab: TaskTab

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Menu {
                AddFolderMenuItems(
                    linked: tab.additionalDirectories,
                    workingDirectory: TabDirectoryStore.shared.directory(for: tab),
                    add: add,
                    choose: choose
                )
            } label: {
                Label("Add folder", systemImage: "plus")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(colors.selection)
            .help("Let this conversation reach another folder")
            .plumeID(AccessibilityID.emptyStateAddFolderMenu)

            ForEach(tab.additionalDirectories, id: \.self) { path in
                chip(path)
            }
        }
        .font(typography.body.font)
    }

    private func choose() {
        AddFolderPanel.present(for: tab)
    }

    private func add(_ path: String) {
        Task { AddFolderPanel.report(await AdditionalDirectoryStore.add([path], to: tab)) }
    }

    private func chip(_ path: String) -> some View {
        let name = (path as NSString).lastPathComponent
        let remove = { AdditionalDirectoryStore.remove(path, from: tab) }
        return HStack(spacing: 4) {
            Image(systemName: "folder")
                .emphasis(.secondary)
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .emphasis(.secondary)
            .help("Remove \(name)")
            .accessibilityLabel("Remove \(name)")
            .plumeID(AccessibilityID.emptyStateFolderRemoveButton, label: path, invoke: remove)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(colors.surfaceTint, in: .capsule)
        .help(FolderActions.abbreviated(path))
        .plumeID(AccessibilityID.emptyStateFolderChip, label: path)
    }
}
