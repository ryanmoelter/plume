import Foundation
import os

/// Reads and writes the Linear cache files off the main thread: one catalog
/// and one `LinearSyncCache` per workspace.
///
/// Each write and removal carries a sequence number from the store, and the
/// actor ignores anything older than what it last applied to that file,
/// so a save that arrives late never overwrites a newer one or recreates a
/// removed workspace's files.
actor LinearCacheDisk {
    let directory: URL
    private var applied: [String: Int] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    nonisolated func catalogFile(orgID: String) -> URL {
        directory.appending(path: "catalog-\(orgID).json")
    }

    nonisolated func issuesFile(orgID: String) -> URL {
        directory.appending(path: "issues-\(orgID).json")
    }

    func loadCatalog(orgID: String) -> LinearCatalog? {
        guard let data = try? Data(contentsOf: catalogFile(orgID: orgID)),
              let catalog = try? JSONDecoder().decode(LinearCatalog.self, from: data),
              catalog.orgID == orgID
        else { return nil }
        return catalog
    }

    /// A file from another format version is discarded; the next sync
    /// backfills from scratch.
    func loadIssues(orgID: String) -> LinearSyncCache? {
        guard let data = try? Data(contentsOf: issuesFile(orgID: orgID)),
              let cache = try? JSONDecoder().decode(LinearSyncCache.self, from: data),
              cache.orgID == orgID, cache.formatVersion == LinearSyncCache.formatVersion
        else { return nil }
        return cache
    }

    func save(_ catalog: LinearCatalog, sequence: Int) {
        guard admit(sequence, key: "catalog-\(catalog.orgID)") else { return }
        write(catalog, to: catalogFile(orgID: catalog.orgID))
    }

    func save(_ cache: LinearSyncCache, sequence: Int) {
        guard admit(sequence, key: "issues-\(cache.orgID)") else { return }
        write(cache, to: issuesFile(orgID: cache.orgID))
    }

    func remove(orgID: String, sequence: Int) {
        let catalog = admit(sequence, key: "catalog-\(orgID)")
        let issues = admit(sequence, key: "issues-\(orgID)")
        guard catalog || issues else { return }
        try? FileManager.default.removeItem(at: catalogFile(orgID: orgID))
        try? FileManager.default.removeItem(at: issuesFile(orgID: orgID))
    }

    private func admit(_ sequence: Int, key: String) -> Bool {
        guard sequence > applied[key, default: -1] else { return false }
        applied[key] = sequence
        return true
    }

    private func write(_ value: some Encodable, to file: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: file, options: .atomic)
        } catch {
            Log.app.error("Could not write the Linear cache: \(error, privacy: .public)")
        }
    }
}
