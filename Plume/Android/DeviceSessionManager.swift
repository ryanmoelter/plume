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

    func session(
        for tabID: UUID,
        target: DeviceTarget?,
        displayName: String?,
        remoteDetails: RemoteDeviceDetails? = nil
    ) -> DeviceSession {
        if let existing = sessions[tabID] { return existing }
        let session = DeviceSession(tabID: tabID, target: target, displayName: displayName, remoteDetails: remoteDetails)
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

    /// Blocks until physical devices' servers are stopped, their forwards removed and remote
    /// reservations released, or gives up. Only for app termination.
    nonisolated static func awaitTerminations() {
        let reservations = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: reservations) {
            RemoteReservation.awaitTerminations()
        }
        ScrcpyServerLaunch.awaitTerminations()
        reservations.wait()
    }

    /// Serials of remote devices this app's reservations attached to adb.
    var remoteSerials: Set<String> {
        Set(sessions.values.compactMap(\.remoteSerial))
    }

    func endReservation(for tabID: UUID) {
        sessions[tabID]?.endReservation()
    }

    func hasLiveReservation(for tabID: UUID) -> Bool {
        sessions[tabID]?.hasLiveReservation ?? false
    }

    func shutDownEmulator(for tabID: UUID) {
        sessions[tabID]?.shutDownEmulator()
    }

    func canShutDownEmulator(for tabID: UUID) -> Bool {
        sessions[tabID]?.canShutDownEmulator ?? false
    }
}
