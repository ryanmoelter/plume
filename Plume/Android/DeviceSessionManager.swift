import Foundation
import Observation

/// Owns every device tab's `DeviceSession`, keyed by tab ID. Closing a
/// session stops streaming, never the emulator.
@MainActor
@Observable
final class DeviceSessionManager {
    static let shared = DeviceSessionManager()

    private var sessions: [UUID: DeviceSession] = [:]

    func session(for tabID: UUID, avdID: String?, displayName: String?) -> DeviceSession {
        if let existing = sessions[tabID] { return existing }
        let session = DeviceSession(tabID: tabID, avdID: avdID, displayName: displayName)
        sessions[tabID] = session
        return session
    }

    func existingSession(for tabID: UUID) -> DeviceSession? {
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
