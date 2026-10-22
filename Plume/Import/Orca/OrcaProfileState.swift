import Foundation

/// Reads a profile's `profile-state.db`, where Orca keeps its live state.
/// `orca-data.json` beside it is only an export, and can be days stale.
///
/// Each top-level section of the old data file is one row here, keyed by
/// `domain`, so the rows an import needs are reassembled into that file's
/// shape and decoded by `OrcaDataFile`.
nonisolated enum OrcaProfileState {
    static let supportedDomainVersion = 1

    enum Contents: Sendable {
        /// The rows as one `orca-data.json`-shaped document.
        case document(Data)
        /// A domain carries a `domain_version` Plume does not read.
        case unsupportedSchema
        case missing
        /// The file exists but cannot be copied, opened or decoded, or holds
        /// none of the domains an import reads.
        case unreadable
    }

    private static let domains = ["schemaVersion", "repos", "worktreeMeta", "workspaceSession"]

    static func read(at url: URL) -> Contents {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let list = domains.map { "'\($0)'" }.joined(separator: ",")
        let rows = SQLitePrivateCopy.read(url) { db in
            SQLitePrivateCopy.textRows(
                db,
                "SELECT domain, domain_version, payload FROM profile_state_documents WHERE domain IN (\(list))",
                columns: 3
            )
        }
        guard let rows = rows ?? nil, !rows.isEmpty else { return .unreadable }

        var document: [String: Any] = ["schemaVersion": OrcaSnapshot.supportedSchemaVersion]
        for row in rows {
            guard let domain = row[0], let payload = row[2] else { return .unreadable }
            guard row[1].flatMap(Int.init) == supportedDomainVersion else { return .unsupportedSchema }
            guard let value = try? JSONSerialization.jsonObject(with: Data(payload.utf8), options: .fragmentsAllowed)
            else { return .unreadable }
            document[domain] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: document) else { return .unreadable }
        return .document(data)
    }
}
