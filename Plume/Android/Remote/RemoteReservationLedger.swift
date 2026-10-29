import Foundation

/// Every reservation Plume created and hasn't yet removed, on disk. Reservations are billed, so
/// a crash or force-quit must not leak one past the next launch: `sweep` removes them all.
nonisolated final class RemoteReservationLedger: @unchecked Sendable {
    struct Entry: Codable, Hashable, Sendable {
        var reservationID: String
        var projectID: String
    }

    static let shared = RemoteReservationLedger(fileURL: AppPaths.applicationSupport.appending(path: "remote-reservations.json"))

    let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    var entries: [Entry] {
        lock.withLock { read() }
    }

    func add(reservationID: String, projectID: String) {
        lock.withLock {
            var entries = read()
            guard !entries.contains(where: { $0.reservationID == reservationID }) else { return }
            entries.append(Entry(reservationID: reservationID, projectID: projectID))
            write(entries)
        }
    }

    func remove(reservationID: String) {
        lock.withLock {
            let entries = read()
            let kept = entries.filter { $0.reservationID != reservationID }
            if kept.count != entries.count { write(kept) }
        }
    }

    /// Releases every entry. An entry stays when its release fails, so the next launch tries again.
    func sweep(cli: AndroidCLIRunning) async {
        for entry in entries {
            EmulatorLog.info("releasing leftover reservation \(entry.reservationID)")
            await RemoteReservation.release(reservationID: entry.reservationID, projectID: entry.projectID, cli: cli, ledger: self)
        }
    }

    private func read() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func write(_ entries: [Entry]) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            EmulatorLog.error("couldn't write the reservation ledger: \(error.localizedDescription)")
        }
    }
}

extension RemoteReservationLedger {
    /// A quit ends every reservation, so whatever is left at launch was leaked by a crash or a
    /// release that failed. A remote tab never reconnects; it offers Reserve Again.
    static func sweepAtLaunch() {
        let ledger = shared
        Task.detached(priority: .utility) {
            await ledger.sweep(cli: AndroidCLI.shared)
        }
    }
}
