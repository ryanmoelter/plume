import Foundation

/// Whether a plan file is on disk, answered from a short-lived cache.
///
/// `ChatTabView` asks this from `body`, which SwiftUI re-evaluates far more
/// often than a file appears or disappears. The answer is re-checked on an
/// interval instead of on every render pass, so a plan written or deleted
/// outside Plume still shows up — just not within the same frame.
@MainActor
enum PlanFileExistence {
    /// Short enough that a newly written plan appears promptly, long enough
    /// that scrolling never touches the filesystem.
    static let staleAfter: TimeInterval = 2

    private struct Entry {
        let exists: Bool
        let checkedAt: Date
    }

    private static var entries: [String: Entry] = [:]

    static func exists(_ path: String) -> Bool {
        if let entry = entries[path], Date().timeIntervalSince(entry.checkedAt) < staleAfter {
            return entry.exists
        }
        let exists = FileManager.default.fileExists(atPath: path)
        entries[path] = Entry(exists: exists, checkedAt: Date())
        return exists
    }

    /// Drops the cache. For tests.
    static func reset() {
        entries.removeAll()
    }
}
