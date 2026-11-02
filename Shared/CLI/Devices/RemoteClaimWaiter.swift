import Foundation

/// Waits for the app to turn a remote claim into a lease. It reads the registry without the lock,
/// which every write's rename makes safe, so a long wait never blocks another claimant.
nonisolated struct RemoteClaimWaiter {
    /// Device Streaming usually connects within a few minutes. Giving up leaves the reservation
    /// with its tab, and claiming again resumes the wait.
    static let timeout: TimeInterval = 660
    static let pollInterval: TimeInterval = 1
    /// A crashed app leaves its pending entry behind until it expires, so silence is the sign.
    static let pingInterval: TimeInterval = 15
    static let progressInterval: TimeInterval = 30

    let store: DeviceRegistryStore
    let app: any DeviceAppClient
    let socket: String
    let now: () -> Date
    let sleep: (TimeInterval) -> Void
    let log: (String) -> Void

    func wait(for claimID: UUID) throws -> (key: String, lease: DeviceLease) {
        let pendingKey = DeviceRegistry.pendingKey(claim: claimID)
        let started = now()
        var lastPing = started
        var lastProgress = started
        while true {
            let registry = try store.load()
            if let leased = registry.devices.first(where: { $0.value.remote?.claimID == claimID }) {
                return (leased.key, leased.value)
            }
            guard let pending = registry.pending[pendingKey] else {
                throw CLIFailure("the reservation stopped before its device connected: its tab closed, or Plume quit")
            }
            if let error = pending.error {
                store.dropPending(pendingKey)
                throw CLIFailure("Device Streaming couldn't reserve a device: \(error)")
            }
            let elapsed = now().timeIntervalSince(started)
            if elapsed >= Self.timeout {
                throw CLIFailure(
                    "still reserving after \(Int(Self.timeout / 60)) minutes; the reservation stays with its device tab, and claiming again waits for it"
                )
            }
            if now().timeIntervalSince(lastPing) >= Self.pingInterval {
                lastPing = now()
                do {
                    _ = try app.send(.ping, to: socket)
                } catch {
                    throw CLIFailure("Plume stopped answering while reserving the device: \(Devices.describe(error))")
                }
            }
            if now().timeIntervalSince(lastProgress) >= Self.progressInterval {
                lastProgress = now()
                log("still reserving (\(DevicePool.relativeTime(elapsed)))")
            }
            sleep(Self.pollInterval)
        }
    }
}
