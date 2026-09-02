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

    func existingSession(for tabID: UUID) -> HeadlessSession? {
        sessions[tabID]
    }

    func session(for tabID: UUID, taskID: UUID) -> HeadlessSession {
        if let existing = sessions[tabID] { return existing }
        let session = HeadlessSession(tabID: tabID, taskID: taskID)
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

    var activeSessionCount: Int { sessions.count }
}
