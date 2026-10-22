import Foundation

/// An agent conversation Orca recorded for one tab or pane, which an import can
/// resume. Built only from a record Orca itself could resume.
nonisolated struct OrcaAgentSession: Sendable, Hashable {
    enum Source: String, Sendable, Hashable {
        /// A structured chat tab's record in `agent-session-journal.db`.
        case agentJournal
        /// `workspaceSession.sleepingAgentSessionsByPaneKey`.
        case sleepingAgent
        /// `agent-hooks/last-status.json`.
        case lastStatus
    }

    /// Orca's agent name: `claude`, `codex`, `gemini` and so on.
    let agent: String
    let sessionID: String
    let transcriptPath: String?
    let source: Source

    /// Nil for an agent Plume cannot run, whose pane imports as a terminal.
    var provider: AgentProviderKind? {
        switch agent {
        case "claude": .claudeCode
        case "codex": .codex
        default: nil
        }
    }

    init(agent: String, sessionID: String, transcriptPath: String?, source: Source) {
        self.agent = agent
        self.sessionID = sessionID
        self.transcriptPath = transcriptPath
        self.source = source
    }

    /// Nil unless Orca would resume it: Claude and Codex resume only by
    /// `session_id`, and a session recorded on another machine names a
    /// transcript this one does not have.
    init?(agent: String?, providerSession: OrcaProviderSession?, connectionId: String?, source: Source) {
        guard let agent, !agent.isEmpty,
              let providerSession, providerSession.key == "session_id",
              let id = providerSession.id, !id.isEmpty,
              (connectionId ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        let path = providerSession.transcriptPath.flatMap { $0.isEmpty ? nil : $0 }
        self.init(agent: agent, sessionID: id, transcriptPath: path, source: source)
    }
}

/// Reads `agent-hooks/last-status.json`, the hook status Orca keeps for every
/// pane running an agent, with the same filters Orca applies when it restores
/// a pane.
nonisolated enum OrcaLastStatus {
    static let supportedVersion = 2
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    /// What a pane's hook status says about restoring it.
    enum Status: Sendable, Hashable {
        case resumable(OrcaAgentSession)
        /// Orca would resume nothing here, and does not fall back to the
        /// pane's sleeping record.
        case unresumable

        var session: OrcaAgentSession? {
            if case .resumable(let session) = self { session } else { nil }
        }
    }

    /// Keyed by pane key. A file of another version reads as empty, as Orca
    /// treats it.
    static func statuses(from data: Data?, now: Date) -> [String: Status] {
        guard let data,
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.version == supportedVersion
        else { return [:] }
        let cutoff = (now.timeIntervalSince1970 - maxAge) * 1000
        return (file.entries ?? [:]).compactMapValues { wrapped in
            // A finished turn or a stale entry leaves the pane to its
            // sleeping record.
            guard let entry = wrapped.value,
                  entry.payload?.state != "done",
                  let receivedAt = entry.receivedAt, receivedAt >= cutoff
            else { return nil }
            let session = OrcaAgentSession(
                agent: entry.payload?.agentType,
                providerSession: entry.providerSession,
                connectionId: entry.connectionId,
                source: .lastStatus
            )
            return session.map(Status.resumable) ?? .unresumable
        }
    }

    private struct File: Decodable {
        let version: Int?
        let entries: [String: FailableDecodable<Entry>]?
    }

    private struct Entry: Decodable {
        let providerSession: OrcaProviderSession?
        let payload: Payload?
        let receivedAt: Double?
        let connectionId: String?
    }

    private struct Payload: Decodable {
        let agentType: String?
        let state: String?
    }
}
