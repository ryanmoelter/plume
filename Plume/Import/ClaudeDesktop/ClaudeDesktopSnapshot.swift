import Foundation

/// One local Code session from the Claude desktop app. The format is
/// undocumented, so every field is optional and a field of the wrong type
/// reads as absent.
nonisolated struct ClaudeDesktopSession: Sendable, Hashable, Decodable {
    var sessionID: String?
    /// The Claude Code session id, which `--resume` takes.
    var cliSessionID: String?
    /// The worktree for a worktree session, else the repo.
    var cwd: String?
    var originCwd: String?
    var title: String?
    var worktreeName: String?
    var branch: String?
    var permissionMode: String?
    var lastActivityAt: Double?
    var isArchived = false

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case cliSessionID = "cliSessionId"
        case cwd, originCwd, title, worktreeName, branch, permissionMode, lastActivityAt, isArchived
    }

    init(sessionID: String?, cliSessionID: String?, cwd: String?, originCwd: String? = nil, title: String? = nil, worktreeName: String? = nil, branch: String? = nil, permissionMode: String? = nil, lastActivityAt: Double? = nil, isArchived: Bool = false) {
        self.sessionID = sessionID
        self.cliSessionID = cliSessionID
        self.cwd = cwd
        self.originCwd = originCwd
        self.title = title
        self.worktreeName = worktreeName
        self.branch = branch
        self.permissionMode = permissionMode
        self.lastActivityAt = lastActivityAt
        self.isArchived = isArchived
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try? c.decode(String.self, forKey: .sessionID)
        cliSessionID = try? c.decode(String.self, forKey: .cliSessionID)
        cwd = try? c.decode(String.self, forKey: .cwd)
        originCwd = try? c.decode(String.self, forKey: .originCwd)
        title = try? c.decode(String.self, forKey: .title)
        worktreeName = try? c.decode(String.self, forKey: .worktreeName)
        branch = try? c.decode(String.self, forKey: .branch)
        permissionMode = try? c.decode(String.self, forKey: .permissionMode)
        lastActivityAt = try? c.decode(Double.self, forKey: .lastActivityAt)
        isArchived = (try? c.decode(Bool.self, forKey: .isArchived)) ?? false
    }
}

/// `archived-sessions.idx`, which lists archived sessions by `sessionId`.
nonisolated struct ClaudeDesktopArchiveIndex: Decodable {
    let archived: [String]

    private enum CodingKeys: String, CodingKey { case archived }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        archived = (try? c.decode([FailableDecodable<String>].self, forKey: .archived))?.compactMap(\.value) ?? []
    }

    static func ids(from data: Data?) -> Set<String> {
        guard let data, let index = try? JSONDecoder().decode(ClaudeDesktopArchiveIndex.self, from: data) else { return [] }
        return Set(index.archived)
    }
}

/// Every unarchived session across every account and organization directory.
nonisolated struct ClaudeDesktopSnapshot: Sendable {
    var sessions: [ClaudeDesktopSession] = []
    /// Session files that exist but did not parse.
    var unreadableCount = 0
    /// The sessions directory is missing or holds no `<account>/<org>` layout.
    var isLayoutUnrecognized = false

    static func loadingFromDisk(sessionsDirectory: URL = ClaudeDesktopLocations.sessionsDirectory) -> ClaudeDesktopSnapshot {
        let fileManager = FileManager.default
        func subdirectories(of url: URL) -> [URL] {
            let entries = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            return entries
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        var snapshot = ClaudeDesktopSnapshot()
        var sawOrganization = false
        for account in subdirectories(of: sessionsDirectory) {
            for organization in subdirectories(of: account) {
                sawOrganization = true
                let files = (try? fileManager.contentsOfDirectory(at: organization, includingPropertiesForKeys: nil)) ?? []
                let archived = ClaudeDesktopArchiveIndex.ids(
                    from: try? Data(contentsOf: organization.appendingPathComponent("archived-sessions.idx"))
                )
                for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                where file.lastPathComponent.hasPrefix("local_") && file.pathExtension == "json" {
                    guard let data = try? Data(contentsOf: file),
                          var session = try? JSONDecoder().decode(ClaudeDesktopSession.self, from: data)
                    else {
                        snapshot.unreadableCount += 1
                        continue
                    }
                    let id = session.sessionID ?? file.deletingPathExtension().lastPathComponent
                    session.sessionID = id
                    if session.isArchived || archived.contains(id) { continue }
                    snapshot.sessions.append(session)
                }
            }
        }
        snapshot.isLayoutUnrecognized = !sawOrganization
        snapshot.sessions.sort { ($0.lastActivityAt ?? 0) > ($1.lastActivityAt ?? 0) }
        return snapshot
    }
}
