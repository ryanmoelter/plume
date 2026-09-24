import Foundation

/// Owns every live agent conversation, keyed by tab ID.
///
/// The counterpart to `SurfaceManager` for the headless transport: views ask
/// for a session and render it, they never create or tear one down. Which
/// concrete session a tab gets follows from its provider.
@MainActor
@Observable
final class AgentSessionManager {
    static let shared = AgentSessionManager()

    private var sessions: [UUID: any AgentSession] = [:]
    @ObservationIgnored private let codexClientFactory: @MainActor () -> CodexAppServerClient

    init(codexClientFactory: @escaping @MainActor () -> CodexAppServerClient = { .sharedSessionClient() }) {
        self.codexClientFactory = codexClientFactory
    }
    /// Reserves resumed threads before the asynchronous handshake publishes
    /// sessionID, closing the window in which two tabs could both resume.
    private var codexThreadClaims: [UUID: String] = [:]

    func isCodexThreadOwnedElsewhere(_ threadID: String?, by tabID: UUID) -> Bool {
        guard let threadID, !threadID.isEmpty else { return false }
        if CodexTerminalMonitor.shared.owns(threadID: threadID, excludingTabID: tabID) { return true }
        return sessions.contains { otherID, session in
            otherID != tabID && session is CodexSession && !session.hasExited &&
                (session.sessionID == threadID || codexThreadClaims[otherID] == threadID)
        }
    }

    @discardableResult
    func claimCodexThread(_ threadID: String?, for tabID: UUID) -> Bool {
        guard !isCodexThreadOwnedElsewhere(threadID, by: tabID) else { return false }
        codexThreadClaims[tabID] = threadID
        return true
    }

    func reparent(tabID: UUID, taskID: UUID) {
        sessions[tabID]?.taskID = taskID
    }

    /// Handed to every session so the title policy can read its tab, without
    /// this layer or the session itself depending on SwiftData.
    @ObservationIgnored
    var titleContextProvider: ((UUID) -> (transport: AgentTransport, userTaskName: String?)?)?

    func existingSession(for tabID: UUID) -> (any AgentSession)? {

        sessions[tabID]
    }

    func session(
        for tabID: UUID,
        taskID: UUID,
        provider: AgentProviderKind = .claudeCode,
        initialEffort: AgentEffort? = nil
    ) -> any AgentSession {
        if let existing = sessions[tabID] { return existing }
        let session: any AgentSession = switch provider {
        case .claudeCode: HeadlessSession(tabID: tabID, taskID: taskID, initialEffort: initialEffort)
        case .codex: CodexSession(tabID: tabID, taskID: taskID, initialEffort: initialEffort, client: codexClientFactory())
        }
        (session as? HeadlessSession)?.titleContextProvider = titleContextProvider
        (session as? CodexSession)?.titleContextProvider = titleContextProvider

        sessions[tabID] = session
        return session
    }

    func closeSession(for tabID: UUID) {
        sessions.removeValue(forKey: tabID)?.stop()
        codexThreadClaims.removeValue(forKey: tabID)
    }

    func closeAll() {
        for session in sessions.values { session.stop() }
        sessions.removeAll()
        codexThreadClaims.removeAll()
    }

    /// Claude publishes individual conversations; Codex publishes one shared
    /// server. Keep one stable representative tab per server in Stay Awake.
    var remoteControlledTabs: [(taskID: UUID, tabID: UUID)] {
        var codexHosts = Set<ObjectIdentifier>()
        return sessions.values.sorted { $0.tabID.uuidString < $1.tabID.uuidString }.compactMap { session in
            guard session.isRemotelyControlled else { return nil }
            if let codex = session as? CodexSession,
               !codexHosts.insert(ObjectIdentifier(codex.remoteControl)).inserted { return nil }
            return (session.taskID, session.tabID)
        }
    }

    var activeSessionCount: Int { sessions.count }

    /// Pids of every agent this app currently owns. A `claude` process that
    /// looks like Plume's but is absent here outlived a previous run.
    var ownedProcessIdentifiers: Set<pid_t> {
        Set(sessions.values.compactMap(\.processIdentifier))
    }
}
