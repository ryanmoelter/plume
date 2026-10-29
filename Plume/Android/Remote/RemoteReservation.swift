import Foundation
import Observation

nonisolated enum RemoteReservationStatus: Equatable, Sendable {
    case active
    case ended
    /// The service couldn't be asked, so the reservation may still be running.
    case unknown(String)
}

/// One Device Streaming reservation, from `create` to `remove`. Reservations are billed, so
/// `release()` always runs `disconnect` and `remove`, and nothing outlives the tab or the app.
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
        let lines = LineBuffer()
        let run = Task.detached {
            try await cli.run(arguments, timeout: Self.createTimeout) { text in
                guard createdID.value == nil,
                      let created = lines.completeLines(appending: text).lazy.compactMap({ RemoteDeviceParsers.createdReservation($0) }).first
                else { return }
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
        guard let row = RemoteDeviceParsers.reservations(result.stdout, now: now()).first(where: { $0.id == reservationID }) else {
            guard RemoteDeviceParsers.isReservationListing(result.stdout) else {
                EmulatorLog.error("listing \(reservationID) printed something unrecognized: \(result.output)")
                return .unknown("Device Streaming's reply wasn't recognized.")
            }
            return .ended
        }
        switch row.phase {
        case .ended:
            return .ended
        case .unknown:
            EmulatorLog.error("reservation \(reservationID) is in an unrecognized state: \(result.output)")
            return .unknown("Device Streaming reports the reservation as \(row.state).")
        case .active:
            if let expires = row.expiresAt { expiresAt = expires }
            return .active
        }
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

    /// The id as soon as `create` printed it, which a release ends even before `create` returns.
    nonisolated var knownReservationID: String? { createdID.value }

    /// Ends the reservation. Safe to call any number of times; only the first does anything. A
    /// create still running is stopped first, and its id released if it printed one.
    /// `concurrently` is for app termination; see `release(reservationID:…)`.
    @discardableResult
    func release(concurrently: Bool = false) -> Task<Void, Never> {
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
                await Self.release(reservationID: id, projectID: projectID, cli: cli, ledger: ledger, concurrently: concurrently)
            }
            group.leave()
        }
        releaseTask = task
        return task
    }

    /// Releases a reservation no session holds, counted in `awaitTerminations()`.
    nonisolated static func releaseForTermination(reservationID: String, projectID: String, cli: AndroidCLIRunning, ledger: RemoteReservationLedger) {
        terminations.enter()
        Task.detached {
            await release(reservationID: reservationID, projectID: projectID, cli: cli, ledger: ledger, concurrently: true)
            terminations.leave()
        }
    }

    /// Blocks until every release in flight finishes, or gives up. Only for app termination.
    nonisolated static func awaitTerminations() {
        _ = terminations.wait(timeout: .now() + terminationWait)
    }

    /// Disconnects, then removes. "Not connected" and "already ended" count as done. Returns
    /// whether the reservation is gone, which is when the ledger forgets it. `concurrently` runs
    /// both at once, so a quit's bounded wait always reaches `remove`, the call that stops billing.
    @discardableResult
    nonisolated static func release(
        reservationID: String,
        projectID: String,
        cli: AndroidCLIRunning,
        ledger: RemoteReservationLedger,
        concurrently: Bool = false
    ) async -> Bool {
        let project = "--project=\(projectID)"
        let disconnectArguments = ["device", "remote", "disconnect", reservationID, project]
        let removeArguments = ["device", "remote", "remove", reservationID, project]
        do {
            let disconnect: AndroidCLIResult
            let remove: AndroidCLIResult
            if concurrently {
                async let disconnecting = cli.run(disconnectArguments, timeout: commandTimeout)
                async let removing = cli.run(removeArguments, timeout: commandTimeout)
                (disconnect, remove) = try await (disconnecting, removing)
            } else {
                disconnect = try await cli.run(disconnectArguments, timeout: commandTimeout)
                remove = try await cli.run(removeArguments, timeout: commandTimeout)
            }
            if !disconnect.succeeded, !RemoteDeviceParsers.saysNotConnected(disconnect.output) {
                EmulatorLog.error("disconnecting \(reservationID) failed: \(disconnect.failureMessage)")
            }
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

/// Collects streamed text and hands back only the lines it completed, so a scan never sees half an id.
nonisolated final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var partial = ""

    func completeLines(appending text: String) -> [String] {
        lock.withLock {
            partial += text
            guard let lastBreak = partial.lastIndex(where: \.isNewline) else { return [] }
            let complete = partial[..<lastBreak]
            partial = String(partial[partial.index(after: lastBreak)...])
            return complete.split(whereSeparator: \.isNewline).map(String.init)
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
