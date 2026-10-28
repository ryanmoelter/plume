import Foundation
import Observation

/// Owns every device tab's `EmulatorSession`, keyed by tab ID. Closing a
/// session stops streaming, never the emulator.
@MainActor
@Observable
final class EmulatorSessionManager {
    static let shared = EmulatorSessionManager()

    private var sessions: [UUID: EmulatorSession] = [:]

    func session(for tabID: UUID, avdID: String?, displayName: String?) -> EmulatorSession {
        if let existing = sessions[tabID] { return existing }
        let session = EmulatorSession(tabID: tabID, avdID: avdID, displayName: displayName)
        sessions[tabID] = session
        return session
    }

    func existingSession(for tabID: UUID) -> EmulatorSession? {
        sessions[tabID]
    }

    func closeSession(for tabID: UUID) {
        sessions.removeValue(forKey: tabID)?.close()
    }

    func closeAll() {
        for session in sessions.values { session.close() }
        sessions.removeAll()
    }

    func shutDownEmulator(for tabID: UUID) {
        sessions[tabID]?.shutDownEmulator()
    }

    func canShutDownEmulator(for tabID: UUID) -> Bool {
        sessions[tabID]?.isConnected ?? false
    }
}
