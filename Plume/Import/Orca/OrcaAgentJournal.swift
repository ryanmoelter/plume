import Foundation

/// Reads Claude session ids out of Orca's agent-session journal.
///
/// Orca's agent tab names its own session (`claude_<uuid>`, the tab's
/// `entityId`), and the journal record for it holds the chain of Claude
/// sessions that conversation has run as. The last link is the live one.
nonisolated enum OrcaAgentJournal {
    /// Orca agent session id → Claude session id. Any failure reads as empty,
    /// which leaves agent tabs to import as terminals.
    static func claudeSessionIDs(at url: URL) -> [String: String] {
        let rows = SQLitePrivateCopy.read(url) { db in
            SQLitePrivateCopy.textRows(db, "SELECT session_id, record_json FROM agent_session_records", columns: 2)
        }
        var result: [String: String] = [:]
        for row in (rows ?? nil) ?? [] {
            guard let orcaID = row[0], let json = row[1],
                  let claudeID = claudeSessionID(fromRecord: Data(json.utf8))
            else { continue }
            result[orcaID] = claudeID
        }
        return result
    }

    static func claudeSessionID(fromRecord data: Data) -> String? {
        guard let record = try? JSONDecoder().decode(Record.self, from: data),
              record.provider == "claude",
              let handle = record.providerHandleChain?.compactMap(\.value).last?.handle,
              handle.provider == nil || handle.provider == "claude",
              let id = handle.sessionId, !id.isEmpty
        else { return nil }
        return id
    }

    private struct Record: Decodable {
        let provider: String?
        let providerHandleChain: [FailableDecodable<Link>]?
    }

    private struct Link: Decodable {
        let handle: Handle?
    }

    private struct Handle: Decodable {
        let provider: String?
        let sessionId: String?
    }
}
