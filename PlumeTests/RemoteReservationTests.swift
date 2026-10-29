import CoreGraphics
import Foundation
import ScrcpyControl
import Testing

@testable import Plume

/// Answers `android` commands from a table keyed by verb (`create`, `connect`, `list`, …), and
/// records every call. A verb with a queue answers from it in order, then repeats its last answer.
nonisolated final class FakeAndroidCLI: AndroidCLIRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private var _answers: [String: [AndroidCLIResult]] = [:]

    var calls: [[String]] { lock.withLock { _calls } }
    /// The verb of each `device remote` call, in order.
    var verbs: [String] { calls.compactMap { $0.count > 2 && $0[0] == "device" ? $0[2] : nil } }

    func answer(_ verb: String, _ results: AndroidCLIResult...) {
        lock.withLock { _answers[verb] = results }
    }

    func run(_ arguments: [String], timeout: Duration, onOutput: (@Sendable (String) -> Void)?) async throws -> AndroidCLIResult {
        let verb = arguments.count > 2 && arguments[0] == "device" ? arguments[2] : arguments.joined(separator: " ")
        let result = lock.withLock { () -> AndroidCLIResult in
            _calls.append(arguments)
            guard var queue = _answers[verb], let first = queue.first else {
                return AndroidCLIResult(status: 0, stdout: "", stderr: "")
            }
            if queue.count > 1 {
                queue.removeFirst()
                _answers[verb] = queue
            }
            return first
        }
        if !result.stdout.isEmpty { onOutput?(result.stdout) }
        return result
    }
}

private func ok(_ stdout: String) -> AndroidCLIResult {
    AndroidCLIResult(status: 0, stdout: stdout, stderr: "")
}

private func failure(_ stderr: String) -> AndroidCLIResult {
    AndroidCLIResult(status: 1, stdout: "", stderr: stderr)
}

private let now: Date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 22, minute: 36))!

private func at(_ hour: Int, _ minute: Int) -> Date {
    Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: now)!
}

private let created = ok("""
New reservation created with id r1. Reservation ends at 10:51\u{202F}PM
Waiting for reservation to activate...
Reservation is ACTIVE

""")
private let connected = ok("Starting connection in background...\nDevice connected on port 59095\nConnection process started in background.\n")
private let activeRow = ok("""
Reservation  State   Expires   Manufacturer  Model    Codename  API Level
r1           ACTIVE  10:52\u{202F}PM  Google        Pixel 6  oriole    31

""")
private let finishedRow = ok("""
Reservation  State     Expires   Manufacturer  Model    Codename  API Level
r1           FINISHED  10:39\u{202F}PM  Google        Pixel 6  oriole    31

""")

private func makeLedger() -> RemoteReservationLedger {
    RemoteReservationLedger(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("remote-reservations-\(UUID().uuidString).json"))
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<10_000 {
        if condition() { return }
        await Task.yield()
    }
}

/// Covers a reservation's lifecycle against a fake `android` tool: the ledger records an id as
/// soon as it's printed and forgets it only once `remove` succeeds, and a release always
/// disconnects before it removes.
@MainActor
struct RemoteReservationTests {
    @Test func createRecordsTheReservationInTheLedger() async throws {
        let cli = FakeAndroidCLI()
        cli.answer("create", created)
        let ledger = makeLedger()
        let reservation = RemoteReservation(projectID: "p", model: "oriole/31", cli: cli, ledger: ledger, now: { now })

        try await reservation.create()

        #expect(reservation.reservationID == "r1")
        #expect(reservation.expiresAt == at(22, 51))
        #expect(ledger.entries == [.init(reservationID: "r1", projectID: "p")])
        #expect(cli.calls.first == ["device", "remote", "create", "oriole/31", "--project=p"])
    }

    @Test func aCreateThatFailsAfterPrintingAnIDStillLeavesItInTheLedger() async {
        let cli = FakeAndroidCLI()
        cli.answer("create", AndroidCLIResult(status: 1, stdout: "New reservation created with id r1. Reservation ends at 10:51 PM\n", stderr: "Error: timed out"))
        let ledger = makeLedger()
        let reservation = RemoteReservation(projectID: "p", model: "oriole/31", cli: cli, ledger: ledger, now: { now })

        await #expect(throws: AndroidCLIError.self) { try await reservation.create() }
        #expect(ledger.entries.map(\.reservationID) == ["r1"])
    }

    @Test func releaseDisconnectsThenRemovesAndForgetsTheLedgerEntry() async throws {
        let cli = FakeAndroidCLI()
        cli.answer("create", created)
        let ledger = makeLedger()
        let reservation = RemoteReservation(projectID: "p", model: "oriole/31", cli: cli, ledger: ledger, now: { now })
        try await reservation.create()

        await reservation.release().value

        #expect(cli.verbs == ["create", "disconnect", "remove"])
        #expect(cli.calls.last == ["device", "remote", "remove", "r1", "--project=p"])
        #expect(ledger.entries.isEmpty)
        #expect(reservation.isReleased)
    }

    @Test func releaseRunsOnceHoweverOftenItIsCalled() async {
        let cli = FakeAndroidCLI()
        let reservation = RemoteReservation(projectID: "p", model: nil, reservationID: "r1", cli: cli, ledger: makeLedger())

        let first = reservation.release()
        let second = reservation.release()
        await first.value
        await second.value

        #expect(cli.verbs == ["disconnect", "remove"])
    }

    @Test func releaseToleratesAReservationThatAlreadyEnded() async {
        let cli = FakeAndroidCLI()
        cli.answer("disconnect", failure("No active connection found for reservation r1 in project p\n"))
        cli.answer("remove", failure("Reservation r1 has already ended.\n"))
        let ledger = makeLedger()
        ledger.add(reservationID: "r1", projectID: "p")

        let released = await RemoteReservation.release(reservationID: "r1", projectID: "p", cli: cli, ledger: ledger)

        #expect(released)
        #expect(ledger.entries.isEmpty)
    }

    @Test func aFailedRemoveKeepsTheLedgerEntry() async {
        let cli = FakeAndroidCLI()
        cli.answer("remove", failure("Error: Failed to obtain auth token: HTTP connect timed out\n"))
        let ledger = makeLedger()
        ledger.add(reservationID: "r1", projectID: "p")

        let released = await RemoteReservation.release(reservationID: "r1", projectID: "p", cli: cli, ledger: ledger)

        #expect(!released)
        #expect(ledger.entries.map(\.reservationID) == ["r1"])
    }

    @Test func connectReturnsTheLocalhostSerial() async throws {
        let cli = FakeAndroidCLI()
        cli.answer("connect", connected)
        let reservation = RemoteReservation(projectID: "p", model: nil, reservationID: "r1", cli: cli, ledger: makeLedger())

        #expect(try await reservation.connect() == "localhost:59095")
        #expect(reservation.serial == "localhost:59095")
    }

    @Test func aStaleConnectionIsDroppedAndTheConnectRetriedOnce() async throws {
        let cli = FakeAndroidCLI()
        cli.answer("connect", failure("Reservation r1 is already connected on port 59050.\n"), connected)
        let reservation = RemoteReservation(projectID: "p", model: nil, reservationID: "r1", cli: cli, ledger: makeLedger())

        #expect(try await reservation.connect() == "localhost:59095")
        #expect(cli.verbs == ["connect", "disconnect", "connect"])
    }

    @Test func aConnectThatStaysStaleFails() async {
        let cli = FakeAndroidCLI()
        cli.answer("connect", failure("Reservation r1 is already connected on port 59050.\n"))
        let reservation = RemoteReservation(projectID: "p", model: nil, reservationID: "r1", cli: cli, ledger: makeLedger())

        await #expect(throws: AndroidCLIError.self) { try await reservation.connect() }
        #expect(cli.verbs == ["connect", "disconnect", "connect"])
    }

    @Test func extendMovesTheExpiry() async throws {
        let cli = FakeAndroidCLI()
        cli.answer("extend", ok("Reservation extended. New expire time: 11:06\u{202F}PM\n"))
        let reservation = RemoteReservation(
            projectID: "p", model: nil, reservationID: "r1", expiresAt: at(22, 51), cli: cli, ledger: makeLedger(), now: { now }
        )

        try await reservation.extend(minutes: 15)

        #expect(reservation.expiresAt == at(23, 6))
        #expect(cli.calls.last == ["device", "remote", "extend", "--duration=15", "r1", "--project=p"])
    }

    @Test func statusReadsTheListRow() async {
        let cli = FakeAndroidCLI()
        cli.answer("list", activeRow, finishedRow)
        let reservation = RemoteReservation(projectID: "p", model: nil, reservationID: "r1", cli: cli, ledger: makeLedger(), now: { now })

        #expect(await reservation.status() == .active)
        #expect(reservation.expiresAt == at(22, 52))
        #expect(await reservation.status() == .ended)
    }

    @Test func statusIsUnknownWhenTheServiceCantBeReached() async {
        let cli = FakeAndroidCLI()
        cli.answer("list", failure("Error: Failed to obtain auth token: HTTP connect timed out\n"))
        let reservation = RemoteReservation(projectID: "p", model: nil, reservationID: "r1", cli: cli, ledger: makeLedger())

        #expect(await reservation.status() == .unknown("Error: Failed to obtain auth token: HTTP connect timed out"))
    }

    @Test func theLaunchSweepKeepsLiveTabsReservationsAndReleasesTheRest() async {
        let cli = FakeAndroidCLI()
        let ledger = makeLedger()
        ledger.add(reservationID: "live", projectID: "p")
        ledger.add(reservationID: "leaked", projectID: "p")

        await ledger.sweep(keeping: ["live"], cli: cli)

        #expect(ledger.entries.map(\.reservationID) == ["live"])
        #expect(cli.calls.map { $0.prefix(4) } == [
            ["device", "remote", "disconnect", "leaked"], ["device", "remote", "remove", "leaked"],
        ])
    }
}

/// A remote device tab: its reservation's lifecycle drives the session, and closing or
/// quitting releases it.
@MainActor
struct RemoteDeviceSessionTests {
    private let cli = FakeAndroidCLI()
    private let fake = FakeConnection()
    private let ledger = makeLedger()
    private let idleSleeper = ManualSleeper()
    private let reservationSleeper = ManualSleeper()
    private let resolved = LockedValue<[String]>([])

    private func makeSession(target: DeviceTarget?, details: RemoteDeviceDetails? = nil) -> DeviceSession {
        let adb = ListingBox(ADBListing(adbURL: URL(fileURLWithPath: "/sdk/platform-tools/adb"), devices: []))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("remote-session-\(UUID().uuidString)")
        let (fake, idleSleeper, reservationSleeper, resolved) = (fake, idleSleeper, reservationSleeper, resolved)
        return DeviceSession(
            tabID: UUID(), target: target, displayName: "Pixel 6", remoteDetails: details,
            discovery: EmulatorDiscovery(directories: [directory]),
            physicalDiscovery: PhysicalDeviceDiscovery { adb.list() },
            makeConnection: { device in
                if case .physical(let serial, _, let limits) = device {
                    resolved.value.append("\(serial) \(limits == .remoteDevice)")
                }
                return fake
            },
            idleSleep: { await idleSleeper.sleep($0) },
            remoteCLI: cli,
            ledger: ledger,
            reservationSleep: { await reservationSleeper.sleep($0) },
            now: { now }
        )
    }

    private let pixel6 = RemoteDeviceModel(manufacturer: "Google", name: "Pixel 6", codename: "oriole", api: 31)

    @Test func reservingConnectsWithRemoteVideoLimitsAndPersistsTheReservation() async {
        cli.answer("create", created)
        cli.answer("connect", connected)
        let session = makeSession(target: nil)
        var targets: [DeviceTarget?] = []
        var details: [RemoteDeviceDetails?] = []
        session.onDeviceChange = { target, _ in targets.append(target) }
        session.onRemoteDetailsChange = { details.append($0) }

        session.reserve(pixel6, projectID: "p")
        #expect(session.state == .reserving)
        await waitUntil { session.state == .connected }

        #expect(session.state == .connected)
        #expect(session.isRemote)
        #expect(session.isPhysical)
        #expect(resolved.value == ["localhost:59095 true"])
        #expect(targets == [.remote(reservationID: "r1")])
        #expect(details.last == RemoteDeviceDetails(projectID: "p", model: "oriole/31", expiresAt: at(22, 51)))
        #expect(session.remoteSerial == "localhost:59095")
        #expect(ledger.entries.map(\.reservationID) == ["r1"])
    }

    @Test func aFailedReservationOffersToReserveAgain() async {
        cli.answer("create", failure("Error: Failed to obtain auth token: HTTP connect timed out\n"))
        let session = makeSession(target: nil)

        session.reserve(pixel6, projectID: "p")
        await waitUntil { if case .reservationFailed = session.state { true } else { false } }

        #expect(session.state == .reservationFailed("Error: Failed to obtain auth token: HTTP connect timed out"))
        #expect(session.remoteDetails?.model == "oriole/31")
        #expect(!session.hasLiveReservation)
    }

    @Test func aReservationThatEndedWhilePlumeWasAwayShowsAsEnded() async {
        cli.answer("list", finishedRow)
        let session = makeSession(target: .remote(reservationID: "r1"), details: RemoteDeviceDetails(projectID: "p", model: "oriole/31"))

        session.start()
        await waitUntil { session.state == .reservationEnded }

        #expect(session.state == .reservationEnded)
        #expect(fake.connectCount == 0)
        await session.reservation?.release().value
        #expect(cli.verbs == ["list", "disconnect", "remove"])
    }

    @Test func anActiveReservationReconnectsOnStart() async {
        cli.answer("list", activeRow)
        cli.answer("connect", connected)
        let session = makeSession(target: .remote(reservationID: "r1"), details: RemoteDeviceDetails(projectID: "p", model: "oriole/31"))
        let sink = FakeSink(size: CGSize(width: 100, height: 200))
        session.addSink(sink)

        session.start()
        await waitUntil { session.state == .connected }

        #expect(session.state == .connected)
        #expect(sink.presented.isEmpty)
        #expect(cli.verbs == ["list", "connect"])
    }

    @Test func closingReleasesTheReservationOnce() async {
        cli.answer("list", activeRow)
        cli.answer("connect", connected)
        let session = makeSession(target: .remote(reservationID: "r1"), details: RemoteDeviceDetails(projectID: "p", model: "oriole/31"))
        session.start()
        await waitUntil { session.state == .suspended }

        session.close()
        session.close()
        await session.reservation?.release().value

        #expect(cli.verbs == ["list", "connect", "disconnect", "remove"])
    }

    @Test func terminatingReleasesTheReservationOnce() async {
        cli.answer("list", activeRow)
        cli.answer("connect", connected)
        let session = makeSession(target: .remote(reservationID: "r1"), details: RemoteDeviceDetails(projectID: "p", model: "oriole/31"))
        session.start()
        await waitUntil { session.state == .suspended }

        session.terminate()
        session.terminate()
        await session.reservation?.release().value

        #expect(cli.verbs == ["list", "connect", "disconnect", "remove"])
    }

    @Test func theMonitorEndsTheTabWhenTheServiceSaysTheReservationEnded() async {
        cli.answer("list", activeRow, finishedRow)
        cli.answer("connect", connected)
        let session = makeSession(target: .remote(reservationID: "r1"), details: RemoteDeviceDetails(projectID: "p", model: "oriole/31"))
        session.start()
        await waitUntil { session.state == .suspended && reservationSleeper.pending == 1 }

        reservationSleeper.fire()
        await waitUntil { session.state == .reservationEnded }

        #expect(session.state == .reservationEnded)
        #expect(session.reservation?.isReleased == true)
    }

    @Test func aRemoteTabLingersLikeAPhysicalOne() async {
        cli.answer("list", activeRow)
        cli.answer("connect", connected)
        let session = makeSession(target: .remote(reservationID: "r1"), details: RemoteDeviceDetails(projectID: "p", model: "oriole/31"))
        let sink = FakeSink(size: CGSize(width: 100, height: 200))
        session.addSink(sink)
        session.start()
        await waitUntil { session.isStreaming }

        session.removeSink(sink)
        await waitUntil { idleSleeper.pending == 1 }
        #expect(session.state == .connected)

        idleSleeper.fire()
        await waitUntil { session.state == .suspended }
        #expect(session.state == .suspended)
        #expect(session.reservation?.isReleased == false)
    }

    @Test func endingTheReservationReleasesItAndKeepsTheDevice() async {
        cli.answer("list", activeRow)
        cli.answer("connect", connected)
        let session = makeSession(target: .remote(reservationID: "r1"), details: RemoteDeviceDetails(projectID: "p", model: "oriole/31"))
        session.start()
        await waitUntil { session.state == .suspended }

        session.endReservation()
        await session.reservation?.release().value

        #expect(session.state == .reservationEnded)
        #expect(session.target == .remote(reservationID: "r1"))
        #expect(cli.verbs == ["list", "connect", "disconnect", "remove"])
    }
}
