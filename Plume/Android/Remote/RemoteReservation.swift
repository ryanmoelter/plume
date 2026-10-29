import Foundation
import Observation

nonisolated enum RemoteReservationStatus: Equatable, Sendable {
    case active
    case ended
    /// The service couldn't be asked, so the reservation may still be running.
    case unknown(String)
}

/// One Device Streaming reservation, from `create` to `remove`. Reservations are billed, so
/// `release()` always runs `disconnect` then `remove`, and nothing outlives the tab or the app.
@MainActor
@Observable
final class RemoteReservation {
    nonisolated static let createTimeout: Duration = .seconds(600)
    nonisolated static let commandTimeout: Duration = .seconds(30)
    /// How long a quit waits for releases. A `remove` still running after that finishes on its
    /// own, and the ledger sweep catches one that didn't.
    nonisolated static let terminationWait: TimeInterval = 10

    let projectID: String
    /// `codename/api`.
    let model: String?
    private(set) var reservationID: String?
    private(set) var expiresAt: Date?
    private(set) var serial: String?
    private(set) var isReleased = false

    @ObservationIgnored private let cli: AndroidCLIRunning
    @ObservationIgnored private let ledger: RemoteReservationLedger
    @ObservationIgnored private let now: () -> Date
    /// Written from the create command's output as it arrives, so a release can find an id the
    /// main actor hasn't seen yet.
    @ObservationIgnored private let createdID = LockedValue<String?>(nil)
    @ObservationIgnored private var createRun: Task<AndroidCLIResult, Error>?
    @ObservationIgnored private var releaseTask: Task<Void, Never>?

    private nonisolated static let terminations = DispatchGroup()

    init(
        projectID: String,
        model: String?,
        reservationID: String? = nil,
        expiresAt: Date? = nil,
        cli: AndroidCLIRunning = AndroidCLI.shared,
        ledger: RemoteReservationLedger = .shared,
        now: @escaping () -> Date = Date.init
    ) {
        self.projectID = projectID
        self.model = model
        self.reservationID = reservationID
        self.expiresAt = expiresAt
        self.cli = cli
        self.ledger = ledger
        self.now = now
        createdID.value = reservationID
    }

    private var projectArgument: String { "--project=\(projectID)" }

    /// Reserves `model` and waits until the reservation is active. The ledger records the id as
    /// soon as the tool prints it, before activation.
    func create() async throws {
        guard let model else { throw AndroidCLIError(message: "No device model was chosen.") }
        guard !isReleased else { throw CancellationError() }
        let (cli, ledger, projectID, createdID) = (cli, ledger, projectID, createdID)
        let arguments = ["device", "remote", "create", model, projectArgument]
        let run = Task.detached {
            try await cli.run(arguments, timeout: Self.createTimeout) { output in
                guard createdID.value == nil, let created = RemoteDeviceParsers.createdReservation(output) else { return }
                createdID.value = created.id
                ledger.add(reservationID: created.id, projectID: projectID)
            }
        }
        createRun = run
        let result = try await withTaskCancellationHandler {
            try await run.value
        } onCancel: {
            run.cancel()
        }
        let created = RemoteDeviceParsers.createdReservation(result.output, now: now())
        if let id = created?.id ?? createdID.value {
            if createdID.value == nil {
                createdID.value = id
                ledger.add(reservationID: id, projectID: projectID)
            }
            reservationID = id
        }
        if let endsAt = created?.endsAt { expiresAt = endsAt }
        guard result.succeeded, reservationID != nil else { throw AndroidCLIError(message: result.failureMessage) }
    }

    /// Attaches the device to adb and returns its serial. A connection left from an earlier
    /// `connect` makes the tool refuse, so that one is dropped and the connect tried once more.
    func connect() async throws -> String {
        guard let reservationID else { throw AndroidCLIError(message: "The reservation has no id.") }
        for attempt in 0..<2 {
            let result = try await cli.run(["device", "remote", "connect", reservationID, projectArgument], timeout: Self.commandTimeout)
            switch RemoteDeviceParsers.connectOutcome(result) {
            case .connected(let port):
                let serial = "localhost:\(port)"
                self.serial = serial
                return serial
            case .alreadyConnected where attempt == 0:
                _ = try await cli.run(["device", "remote", "disconnect", reservationID, projectArgument], timeout: Self.commandTimeout)
            case .alreadyConnected, .failed:
                throw AndroidCLIError(message: result.failureMessage)
            }
        }
        throw AndroidCLIError(message: "The device didn't connect.")
    }

    func status() async -> RemoteReservationStatus {
        guard let reservationID else { return .ended }
        let result: AndroidCLIResult
        do {
            result = try await cli.run(["device", "remote", "list", reservationID, projectArgument], timeout: Self.commandTimeout)
        } catch {
            return .unknown(error.localizedDescription)
        }
        guard result.succeeded else { return .unknown(result.failureMessage) }
        guard let row = RemoteDeviceParsers.reservations(result.stdout, now: now()).first(where: { $0.id == reservationID }),
              row.isActive
        else { return .ended }
        if let expires = row.expiresAt { expiresAt = expires }
        return .active
    }

    func extend(minutes: Int) async throws {
        guard let reservationID else { return }
        let result = try await cli.run(
            ["device", "remote", "extend", "--duration=\(minutes)", reservationID, projectArgument],
            timeout: Self.commandTimeout
        )
        guard result.succeeded else { throw AndroidCLIError(message: result.failureMessage) }
        expiresAt = RemoteDeviceParsers.extendedExpiry(result.output, now: now())
            ?? (expiresAt ?? now()).addingTimeInterval(TimeInterval(minutes * 60))
    }

    /// Ends the reservation. Safe to call any number of times; only the first does anything. A
    /// create still running is stopped first, and its id released if it printed one.
    @discardableResult
    func release() -> Task<Void, Never> {
        if let releaseTask { return releaseTask }
        isReleased = true
        serial = nil
        let createRun = createRun
        createRun?.cancel()
        let (cli, ledger, projectID, createdID) = (cli, ledger, projectID, createdID)
        let group = Self.terminations
        group.enter()
        let task = Task.detached {
            _ = await createRun?.result
            if let id = createdID.value {
                await Self.release(reservationID: id, projectID: projectID, cli: cli, ledger: ledger)
            }
            group.leave()
        }
        releaseTask = task
        return task
    }

    /// Blocks until every release in flight finishes, or gives up. Only for app termination.
    nonisolated static func awaitTerminations() {
        _ = terminations.wait(timeout: .now() + terminationWait)
    }

    /// Disconnects, then removes. "Not connected" and "already ended" count as done. Returns
    /// whether the reservation is gone, which is when the ledger forgets it.
    @discardableResult
    nonisolated static func release(
        reservationID: String,
        projectID: String,
        cli: AndroidCLIRunning,
        ledger: RemoteReservationLedger
    ) async -> Bool {
        let project = "--project=\(projectID)"
        do {
            let disconnect = try await cli.run(["device", "remote", "disconnect", reservationID, project], timeout: commandTimeout)
            if !disconnect.succeeded, !RemoteDeviceParsers.saysNotConnected(disconnect.output) {
                EmulatorLog.error("disconnecting \(reservationID) failed: \(disconnect.failureMessage)")
            }
            let remove = try await cli.run(["device", "remote", "remove", reservationID, project], timeout: commandTimeout)
            guard remove.succeeded || RemoteDeviceParsers.saysAlreadyEnded(remove.output) else {
                EmulatorLog.error("removing \(reservationID) failed: \(remove.failureMessage)")
                return false
            }
            ledger.remove(reservationID: reservationID)
            EmulatorLog.info("released reservation \(reservationID)")
            return true
        } catch {
            EmulatorLog.error("releasing \(reservationID) failed: \(error.localizedDescription)")
            return false
        }
    }
}

nonisolated final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
