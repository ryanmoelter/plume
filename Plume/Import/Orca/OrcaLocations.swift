import Foundation

/// The Orca files Plume reads. Orca keeps its state per profile, so the
/// profile index decides which profile is live.
nonisolated enum OrcaLocations {
    static let defaultProfileID = "local-default"

    static var rootDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/orca")
    }

    static var profileIndexFile: URL {
        rootDirectory.appendingPathComponent("orca-profile-index.json")
    }

    static var agentJournalFile: URL {
        rootDirectory.appendingPathComponent("agent-session-journal.db")
    }

    static var lastStatusFile: URL {
        rootDirectory.appendingPathComponent("agent-hooks/last-status.json")
    }

    /// Holds a `daemon-v<protocol>.pid` for each terminal daemon Orca started.
    static var daemonDirectory: URL {
        rootDirectory.appendingPathComponent("daemon")
    }

    static func dataFile(profileID: String) -> URL {
        rootDirectory.appendingPathComponent("profiles/\(profileID)/orca-data.json")
    }

    static func profileStateFile(profileID: String) -> URL {
        rootDirectory.appendingPathComponent("profiles/\(profileID)/profile-state.db")
    }

    static var activeProfileID: String {
        OrcaProfileIndex.activeProfileID(from: try? Data(contentsOf: profileIndexFile))
    }

    static func isInstalled() -> Bool {
        let profileID = activeProfileID
        return FileManager.default.fileExists(atPath: profileStateFile(profileID: profileID).path)
            || FileManager.default.fileExists(atPath: dataFile(profileID: profileID).path)
    }
}

nonisolated enum OrcaProfileIndex {
    private struct File: Decodable {
        let activeProfileId: String?
    }

    /// Falls back to Orca's built-in profile, which predates the index. An id
    /// that could escape `profiles/` is treated as missing.
    static func activeProfileID(from data: Data?) -> String {
        guard let data,
              let id = (try? JSONDecoder().decode(File.self, from: data))?.activeProfileId,
              !id.isEmpty, !id.contains("/"), id != ".", id != ".."
        else { return OrcaLocations.defaultProfileID }
        return id
    }
}
