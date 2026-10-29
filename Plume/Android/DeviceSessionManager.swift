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
        register(session)
        return session
    }

    func register(_ session: DeviceSession) {
        sessions[session.tabID] = session
    }

    func existingSession(for tabID: UUID) -> DeviceSession? {
        sessions[tabID]
    }

    func closeSession(for tabID: UUID) {
        sessions.removeValue(forKey: tabID)?.close()
    }

    /// Starts tearing every session down for app termination; `awaitTerminations()` waits for it.
    /// Ends every reservation in the ledger too, including those of tabs never shown this run.
    func terminateAll(
        ledger: RemoteReservationLedger = .shared,
        cli: AndroidCLIRunning = AndroidCLI.shared,
        sweepsLedger: Bool = true
    ) {
        // A released reservation may have a release that failed or is still running, so the ledger sweep retries it.
        let held = Set(sessions.values.compactMap { session in
            session.reservation.flatMap { $0.isReleased ? nil : $0.knownReservationID }
        })
        for session in sessions.values { session.terminate() }
        sessions.removeAll()
        guard sweepsLedger else { return }
        for entry in ledger.entries where !held.contains(entry.reservationID) {
            RemoteReservation.releaseForTermination(reservationID: entry.reservationID, projectID: entry.projectID, cli: cli, ledger: ledger)
        }
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

    func canEndReservation(for tabID: UUID) -> Bool {
        sessions[tabID]?.canEndReservation ?? false
    }

    func shutDownEmulator(for tabID: UUID) {
        sessions[tabID]?.shutDownEmulator()
    }

    func canShutDownEmulator(for tabID: UUID) -> Bool {
        sessions[tabID]?.canShutDownEmulator ?? false
    }
}
