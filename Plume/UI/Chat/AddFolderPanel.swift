import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Picks folders to add to a tab's `--add-dir` list.
@MainActor
enum AddFolderPanel {
    static func present(for tab: TaskTab) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders this conversation can reach"
        if let directory = TabDirectoryStore.shared.directory(for: tab) {
            panel.directoryURL = URL(fileURLWithPath: directory)
        }
        // Not modal, so no tracking loop runs inside the click that opened it.
        panel.begin { [weak tab] response in
            guard response == .OK, let tab else { return }
            try? AdditionalDirectoryStore.add(panel.urls.map(\.path), to: tab)
        }
    }
}

/// Accepts dropped folders and declines everything else, so an image dropped
/// on the same surface still reaches the composer.
struct AddFolderDropDelegate: DropDelegate {
    let isEnabled: Bool
    @Binding var isTargeted: Bool
    let add: ([String]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        isEnabled && !folders(in: info).isEmpty
    }

    func dropEntered(info: DropInfo) { isTargeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { isTargeted = false }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let folders = folders(in: info)
        guard !folders.isEmpty else { return false }
        add(folders.map(\.path))
        return true
    }

    /// `NSItemProvider` only loads asynchronously, so the URLs come off the
    /// drag pasteboard instead — `validateDrop` has to answer now.
    private func folders(in info: DropInfo) -> [URL] {
        guard info.hasItemsConforming(to: [.fileURL]) else { return [] }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = NSPasteboard(name: .drag)
            .readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.filter(\.hasDirectoryPath)
    }
}

enum FolderActions {
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    static func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
