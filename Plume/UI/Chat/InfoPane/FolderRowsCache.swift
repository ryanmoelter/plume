import Foundation
import Observation

/// Each tab's last folder rows. Building them resolves symlinks off the main
/// actor, and the chat view remounts on every task switch, so a remount
/// shows these at once while it rebuilds.
@MainActor
@Observable
final class FolderRowsCache {
    static let shared = FolderRowsCache()

    private var rowsByTab: [UUID: [FolderRow]] = [:]

    func rows(for tabID: UUID) -> [FolderRow] {
        rowsByTab[tabID] ?? []
    }

    func setRows(_ rows: [FolderRow], for tabID: UUID) {
        guard rowsByTab[tabID] != rows else { return }
        rowsByTab[tabID] = rows
    }

    func forget(tabID: UUID) {
        rowsByTab[tabID] = nil
    }
}
