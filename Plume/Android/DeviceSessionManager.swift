import Foundation
import Observation
import ScrcpyControl

/// Owns every device tab's `DeviceSession`, keyed by tab ID. Closing a
/// session stops streaming, never the emulator.
@MainActor
@Observable
final class DeviceSessionManager {
    static let shared = DeviceSessionManager()

    private var sessions: [UUID: DeviceSession] = [:]

    func session(for tabID: UUID, target: DeviceTarget?, displayName: String?) -> DeviceSession {
        if let existing = sessions[tabID] { return existing }
        let session = DeviceSession(tabID: tabID, target: target, displayName: displayName)
        sessions[tabID] = session
        return session
    }

    func existingSession(for tabID: UUID) -> DeviceSession? {
        sessions[tabID]
    }

    func closeSession(for tabID: UUID) {
        sessions.removeValue(forKey: tabID)?.close()
    }

    /// Starts tearing every session down for app termination; `awaitTerminations()` waits for it.
    func terminateAll() {
        for session in sessions.values { session.terminate() }
        sessions.removeAll()
    }

    /// Blocks until physical devices' servers are stopped and their forwards removed, or gives up.
    /// Only for app termination.
    nonisolated static func awaitTerminations() {
        ScrcpyServerLaunch.awaitTerminations()
    }

    func shutDownEmulator(for tabID: UUID) {
        sessions[tabID]?.shutDownEmulator()
    }

    func canShutDownEmulator(for tabID: UUID) -> Bool {
        sessions[tabID]?.canShutDownEmulator ?? false
    }
}
