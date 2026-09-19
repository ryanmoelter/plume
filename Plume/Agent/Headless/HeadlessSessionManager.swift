import Foundation

/// Owns every live headless conversation, keyed by tab ID.
///
/// The counterpart to `SurfaceManager` for the headless transport: views ask
/// for a session and render it, they never create or tear one down.
@MainActor
@Observable
final class HeadlessSessionManager {
    static let shared = HeadlessSessionManager()

    private var sessions: [UUID: HeadlessSession] = [:]

    /// Handed to every session so the title policy can read its tab, without
    /// this layer or the session itself depending on SwiftData.
    @ObservationIgnored
    var titleContextProvider: ((UUID) -> (transport: AgentTransport, userTaskName: String?)?)?

    func existingSession(for tabID: UUID) -> HeadlessSession? {
        sessions[tabID]
    }

    func session(for tabID: UUID, taskID: UUID, initialEffort: AgentEffort? = nil) -> HeadlessSession {
        if let existing = sessions[tabID] { return existing }
        let session = HeadlessSession(tabID: tabID, taskID: taskID, initialEffort: initialEffort)
        session.titleContextProvider = titleContextProvider
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
