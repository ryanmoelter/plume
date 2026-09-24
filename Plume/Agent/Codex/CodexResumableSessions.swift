import Foundation

/// A read-only connection for the picker. Listing never takes ownership of a
/// conversation; only selecting one lets the normal session resume it.
@MainActor
final class CodexResumableSessions {
    private let client: CodexAppServerClient

    init(client: CodexAppServerClient? = nil) {
        self.client = client ?? CodexAppServerClient()
    }

    func stop() { client.stop() }

    func load(workingDirectory: String, repoPath: String?) async throws -> [StoredSession] {
        let worktrees = if let repoPath {
            await GitService.shared.worktrees(in: repoPath).map(\.path)
        } else { [String]() }
        try Task.checkCancellation()
        let directories = ResumableSessions.searchDirectories(
            workingDirectory: workingDirectory, worktreePaths: worktrees
        )
        try client.start(workingDirectory: workingDirectory, environment: [:])
        defer { client.stop() }
        _ = try await client.send("initialize", .object([
            "clientInfo": .object(["name": .string("Plume"), "version": .string("1")]),
            "capabilities": .object(["experimentalApi": .bool(true)])
        ]))
        client.notify("initialized")
        return try await Self.loadPages(directories: directories) { [client] params in
            try await client.send("thread/list", params)
        }
    }

    static func loadPages(
        directories: [String],
        request: (JSONValue) async throws -> JSONValue
    ) async throws -> [StoredSession] {
        var sessions: [String: StoredSession] = [:]
        var cursor: String?
        var seenCursors: Set<String> = []
        repeat {
            try Task.checkCancellation()
            var params: [String: JSONValue] = [
                "cwd": .array(directories.map(JSONValue.string)),
                "sortKey": .string("updated_at"), "limit": .number(100),
                "sourceKinds": .array(["cli", "vscode", "exec", "appServer", "unknown"].map(JSONValue.string))
            ]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await request(.object(params))
            for thread in result["data"]?.arrayValue ?? [] {
                if let session = storedSession(thread: thread) { sessions[session.id] = session }
            }
            cursor = result["nextCursor"]?.stringValue
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw DiscoveryError.repeatedCursor
            }
        } while cursor != nil
        return sessions.values.sorted { $0.lastModified > $1.lastModified }
    }

    enum DiscoveryError: Error { case repeatedCursor }

    static func storedSession(thread: JSONValue) -> StoredSession? {
        guard let id = thread["id"]?.stringValue, !id.isEmpty,
              let cwd = thread["cwd"]?.stringValue,
              thread["source"]?["subAgent"] == nil else { return nil }
        return StoredSession(
            sessionID: id, transcriptPath: "", workingDirectory: cwd,
            title: CodexThreadTitle.name(thread["name"]?.stringValue),
            firstUserMessage: CodexThreadTitle.preview(thread["preview"]?.stringValue),
            lastModified: Date(timeIntervalSince1970: thread["updatedAt"]?.doubleValue ?? 0)
        )
    }
}

nonisolated enum CodexThreadTitle {
    static func name(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func preview(_ value: String?) -> String? {
        guard let value = name(value) else { return nil }
        return SessionJSONLReader.shortenedOpeningLine(value)
    }

    static func title(thread: JSONValue) -> String? {
        name(thread["name"]?.stringValue) ?? preview(thread["preview"]?.stringValue)
    }
}
