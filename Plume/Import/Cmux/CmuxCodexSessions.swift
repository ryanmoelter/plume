import Foundation

nonisolated enum CmuxCodexSessions {
    /// Surface IDs are exact evidence; directory/title similarity is not.
    static func match(panel: CmuxPanel, workspaceID: String?, records: [String: CmuxSessionRecord]) -> CmuxSessionRecord? {
        guard let workspaceID else { return nil }
        let surfaces = Set([panel.id, panel.stableSurfaceId].compactMap { $0?.lowercased() })
        let matches = records.values.filter {
            $0.workspaceId?.lowercased() == workspaceID.lowercased()
                && $0.surfaceId.map { surfaces.contains($0.lowercased()) } == true
                && $0.sessionId?.isEmpty == false && $0.isRestorable != false
        }.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
        guard let first = matches.first else { return nil }
        let newest = matches.prefix { ($0.updatedAt ?? 0) == (first.updatedAt ?? 0) }
        guard Set(newest.compactMap(\.sessionId)).count == 1 else { return nil }
        return first
    }

    /// Verify the recorded file belongs to this precise thread before handing
    /// it to app-server. Rollout bytes are never treated as Claude JSONL.
    static func validRollout(path: String?, sessionID: String, cwd: String?) -> Bool {
        guard let path, path.hasPrefix("/"),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return false }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: 64 * 1024),
              let line = bytes.split(separator: 10).first,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
              value["type"]?.stringValue == "session_meta",
              value["payload"]?["id"]?.stringValue == sessionID else { return false }
        if let cwd, let recorded = value["payload"]?["cwd"]?.stringValue {
            return URL(fileURLWithPath: cwd).standardizedFileURL == URL(fileURLWithPath: recorded).standardizedFileURL
        }
        return true
    }
}
