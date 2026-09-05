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
        case .codex: CodexSession(tabID: tabID, taskID: taskID, initialEffort: initialEffort)
        }
        sessions[tabID] = session
        return session
    }

    func closeSession(for tabID: UUID) {
        sessions.removeValue(forKey: tabID)?.stop()
    }

    func closeAll() {
        for session in sessions.values { session.stop() }
        sessions.removeAll()
    }

    /// Tabs whose conversation is published to claude.ai/code, or on its way
    /// there. Connecting counts, because sleeping through the handshake is
    /// how it fails to finish.
    ///
    /// A stopped session is excluded: `stop()` leaves `remoteControl` alone,
    /// so a tab the user closed would otherwise read as connected forever.
    var remoteControlledTabs: [(taskID: UUID, tabID: UUID)] {
        sessions.values.compactMap { session in
            guard !session.hasExited else { return nil }
            switch session.remoteControl {
            case .connected, .connecting:
                return (session.taskID, session.tabID)
            case .disconnected, .failed:
                return nil
            }
        }
    }

    var activeSessionCount: Int { sessions.count }
}
