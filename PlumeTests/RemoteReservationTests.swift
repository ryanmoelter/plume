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
    private var _finished: [String] = []
    private var held: Set<String> = []
    private var awaited: [String: String] = [:]

    var calls: [[String]] { lock.withLock { _calls } }
    /// Verbs in the order their calls returned.
    var finished: [String] { lock.withLock { _finished } }
    /// The verb of each `device remote` call, in order.
    var verbs: [String] { calls.compactMap { $0.count > 2 && $0[0] == "device" ? $0[2] : nil } }

    func answer(_ verb: String, _ results: AndroidCLIResult...) {
        lock.withLock { _answers[verb] = results }
    }

    /// `verb` prints its answer's stdout, then runs until cancelled, like a `create` still waiting.
    func hold(_ verb: String) {
        lock.withLock { _ = held.insert(verb) }
    }

    /// `verb` waits up to a second for `other` to return before it answers.
    func make(_ verb: String, await other: String) {
        lock.withLock { awaited[verb] = other }
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
        if lock.withLock({ held.contains(verb) }) {
            while true { try await Task.sleep(for: .milliseconds(5)) }
        }
        if let other = lock.withLock({ awaited[verb] }) {
            for _ in 0..<200 where !finished.contains(other) { try? await Task.sleep(for: .milliseconds(5)) }
        }
        lock.withLock { _finished.append(verb) }
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

/// For work on detached tasks, which yielding the main actor doesn't advance.
@MainActor
private func waitUntilSoon(_ condition: () -> Bool) async {
    for _ in 0..<400 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// Covers a reservation's lifecycle against a fake `android` tool: the ledger records an id as
/// soon as it's printed and forgets it only once `remove` succeeds. A tab's release disconnects
/// before it removes; a quit's runs both at once, and a launch releases every entry.
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

    @Test func releasingDuringCreateRemovesAnIDPrintedWithoutANewline() async {
        let cli = FakeAndroidCLI()
        cli.answer("create", ok("New reservation created with id r1. Reservation ends at 10:51\u{202F}PM"))
        cli.hold("create")
        let ledger = makeLedger()
        let reservation = RemoteReservation(projectID: "p", model: "oriole/31", cli: cli, ledger: ledger, now: { now })
        let creating = Task { try await reservation.create() }
        await waitUntilSoon { !cli.calls.isEmpty }

        await reservation.release().value
        _ = await creating.result

        #expect(cli.calls.last == ["device", "remote", "remove", "r1", "--project=p"])
        #expect(ledger.entries.isEmpty)
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

    @Test func statusCallsAMissingRowEndedOnlyInARecognizedListing() async {
        let cli = FakeAndroidCLI()
        cli.answer(
            "list",
            ok("Reservation  State  Expires  Manufacturer  Model  Codename  API Level\n"),
            ok("There are no active reservations.\n"),
            ok("Something new the tool prints\n")
        )
        let reservation = RemoteReservation(projectID: "p", model: nil, reservationID: "r1", cli: cli, ledger: makeLedger(), now: { now })

        #expect(await reservation.status() == .ended)
        #expect(await reservation.status() == .ended)
        #expect(await reservation.status() == .unknown("Device Streaming's reply wasn't recognized."))
    }

    @Test func statusKeepsTheTabForAnUnrecognizedState() async {
        let cli = FakeAndroidCLI()
        cli.answer("list", ok("Reservation  State   Expires  Manufacturer  Model    Codename  API Level\nr1           PAUSED  10:52\u{202F}PM  Google        Pixel 6  oriole    31\n"))
        let reservation = RemoteReservation(projectID: "p", model: nil, reservationID: "r1", cli: cli, ledger: makeLedger(), now: { now })

        #expect(await reservation.status() == .unknown("Device Streaming reports the reservation as PAUSED."))
    }

    @Test func statusIsUnknownWhenTheServiceCantBeReached() async {
        let cli = FakeAndroidCLI()
        cli.answer("list", failure("Error: Failed to obtain auth token: HTTP connect timed out\n"))
        let reservation = RemoteReservation(projectID: "p", model: nil, reservationID: "r1", cli: cli, ledger: makeLedger())

        #expect(await reservation.status() == .unknown("Error: Failed to obtain auth token: HTTP connect timed out"))
    }

    @Test func theLaunchSweepReleasesEveryEntry() async {
        let cli = FakeAndroidCLI()
        let ledger = makeLedger()
        ledger.add(reservationID: "a", projectID: "p")
        ledger.add(reservationID: "b", projectID: "q")

        await ledger.sweep(cli: cli)

        #expect(ledger.entries.isEmpty)
        #expect(cli.calls.map { $0.prefix(4) } == [
            ["device", "remote", "disconnect", "a"], ["device", "remote", "remove", "a"],
            ["device", "remote", "disconnect", "b"], ["device", "remote", "remove", "b"],
        ])
    }

    @Test func aTerminationReleaseRemovesWithoutWaitingForTheDisconnect() async {
        let cli = FakeAndroidCLI()
        cli.make("disconnect", await: "remove")
        let ledger = makeLedger()
        ledger.add(reservationID: "r1", projectID: "p")

        let released = await RemoteReservation.release(reservationID: "r1", projectID: "p", cli: cli, ledger: ledger, concurrently: true)

        #expect(released)
        #expect(cli.finished == ["remove", "disconnect"])
        #expect(ledger.entries.isEmpty)
    }

    @Test func quittingReleasesReservationsNoSessionHolds() async {
        let cli = FakeAndroidCLI()
        let ledger = makeLedger()
        ledger.add(reservationID: "unmounted", projectID: "p")

        DeviceSessionManager().terminateAll(ledger: ledger, cli: cli)
        await waitUntilSoon { ledger.entries.isEmpty }

        #expect(ledger.entries.isEmpty)
        #expect(Set(cli.verbs) == ["disconnect", "remove"])
    }
}

/// A remote device tab: its reservation's lifecycle drives the session, closing or quitting
/// releases it, and a tab from an earlier run never reconnects.
@MainActor
struct RemoteDeviceSessionTests {
    private let cli = FakeAndroidCLI()
    private let fake = FakeConnection()
    private let ledger = makeLedger()
    private let idleSleeper = ManualSleeper()
    private let reservationSleeper = ManualSleeper()
    private let reservationSleeps = LockedValue<[Duration]>([])
    private let resolved = LockedValue<[String]>([])
    private let recents = LockedValue<[String]>([])

    private func makeSession(target: DeviceTarget? = nil, details: RemoteDeviceDetails? = nil) -> DeviceSession {
        let adb = ListingBox(ADBListing(adbURL: URL(fileURLWithPath: "/sdk/platform-tools/adb"), devices: []))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("remote-session-\(UUID().uuidString)")
        let (fake, idleSleeper, reservationSleeper, reservationSleeps, resolved) = (fake, idleSleeper, reservationSleeper, reservationSleeps, resolved)
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
            reservationSleep: { duration in
                reservationSleeps.value.append(duration)
                await reservationSleeper.sleep(duration)
            },
            now: { now },
            recordReservation: { [recents] in recents.value.append($0) }
        )
    }

    private let pixel6 = RemoteDeviceModel(manufacturer: "Google", name: "Pixel 6", codename: "oriole", api: 31)

    private func reservedSession(created createdAnswer: AndroidCLIResult = created) async -> DeviceSession {
        cli.answer("create", createdAnswer)
        cli.answer("connect", connected)
        let session = makeSession()
        session.reserve(pixel6, projectID: "p")
        await waitUntil { session.state == .connected }
        return session
    }

    @Test func reservingConnectsWithRemoteVideoLimitsAndPersistsTheReservation() async {
        cli.answer("create", created)
        cli.answer("connect", connected)
        let session = makeSession()
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
        #expect(recents.value == ["oriole/31"])
    }

    @Test func aFailedReservationOffersToReserveAgain() async {
        cli.answer("create", failure("Error: Failed to obtain auth token: HTTP connect timed out\n"))
        let session = makeSession()

        session.reserve(pixel6, projectID: "p")
        await waitUntil { if case .reservationFailed = session.state { true } else { false } }

        #expect(session.state == .reservationFailed("Error: Failed to obtain auth token: HTTP connect timed out"))
        #expect(session.remoteDetails?.model == "oriole/31")
        #expect(!session.hasLiveReservation)
        #expect(recents.value.isEmpty)
    }

    @Test func aTabFromAnEarlierRunOffersToReserveAgainWithoutAskingTheService() async {
        let session = makeSession(target: .remote(reservationID: "r1"), details: RemoteDeviceDetails(projectID: "p", model: "oriole/31"))
        #expect(session.state == .reservationEnded)

        session.start()
        await waitUntil { session.state == .reservationEnded }

        #expect(session.state == .reservationEnded)
        #expect(session.reservation == nil)
        #expect(session.remoteDetails?.model == "oriole/31")
        #expect(cli.calls.isEmpty)
        #expect(fake.connectCount == 0)
    }

    @Test func closingReleasesTheReservationOnce() async {
        let session = await reservedSession()

        session.close()
        session.close()
        await session.reservation?.release().value

        #expect(cli.verbs == ["create", "connect", "disconnect", "remove"])
    }

    @Test func terminatingReleasesTheReservationOnce() async {
        let session = await reservedSession()

        session.terminate()
        session.terminate()
        await session.reservation?.release().value

        #expect(cli.verbs.prefix(2) == ["create", "connect"])
        #expect(cli.verbs.dropFirst(2).sorted() == ["disconnect", "remove"])
    }

    @Test func quittingRetriesAReleaseThatFailed() async {
        let session = await reservedSession()
        cli.answer("remove", failure("Error: timed out\n"), ok(""))
        let reservation = session.reservation
        session.endReservation()
        await reservation?.release().value

        #expect(ledger.entries.map(\.reservationID) == ["r1"])
        let manager = DeviceSessionManager()
        manager.register(session)
        manager.terminateAll(ledger: ledger, cli: cli)
        await waitUntilSoon { ledger.entries.isEmpty }

        #expect(cli.verbs.filter { $0 == "remove" }.count == 2)
        #expect(ledger.entries.isEmpty)
    }

    @Test func theMonitorEndsTheTabWhenTheServiceSaysTheReservationEnded() async {
        cli.answer("list", finishedRow)
        let session = await reservedSession()
        await waitUntil { reservationSleeper.pending == 1 }

        reservationSleeper.fire()
        await waitUntil { session.state == .reservationEnded }

        #expect(session.state == .reservationEnded)
        #expect(session.reservation?.isReleased == true)
    }

    @Test func theMonitorReattachesWhenAnUnansweredStatusTurnsOutActive() async {
        let session = await reservedSession()
        cli.answer("list", failure("Error: HTTP connect timed out\n"), activeRow)
        session.locate()
        await waitUntil { if case .reservationFailed = session.state { true } else { false } }
        #expect(session.hasLiveReservation)
        await waitUntil { reservationSleeper.pending == 1 }

        reservationSleeper.fire()
        await waitUntil { session.state == .suspended }

        #expect(session.state == .suspended)
        #expect(cli.verbs.filter { $0 == "connect" }.count == 2)
    }

    @Test func theMonitorPollsNoFasterThanItsFloorPastTheExpiry() async {
        // Expired six minutes before `now`, so the time until expiry is negative.
        let expired = ok("New reservation created with id r1. Reservation ends at 10:30\u{202F}PM\n")
        let session = await reservedSession(created: expired)
        await waitUntil { reservationSleeper.pending == 1 }

        #expect(session.reservation?.expiresAt == at(22, 30))
        #expect(reservationSleeps.value == [.seconds(DeviceSession.reservationMinimumPoll)])
    }

    @Test func aRemoteTabLingersLikeAPhysicalOne() async {
        let session = await reservedSession()
        let sink = FakeSink(size: CGSize(width: 100, height: 200))
        session.addSink(sink)
        await waitUntil { session.isStreaming }

        session.removeSink(sink)
        await waitUntil { idleSleeper.pending == 1 }
        #expect(session.state == .connected)

        idleSleeper.fire()
        await waitUntil { session.state == .suspended }
        #expect(session.state == .suspended)
        #expect(session.reservation?.isReleased == false)
    }

    @Test func pausingStreamingKeepsTheReservation() async {
        let session = await reservedSession()
        let sink = FakeSink(size: CGSize(width: 100, height: 200))
        session.addSink(sink)
        await waitUntil { session.isStreaming }

        session.pauseStreaming()
        #expect(session.state == .streamingPaused)
        #expect(session.reservation?.isReleased == false)
        #expect(session.hasLiveReservation)
    }

    @Test func endingTheReservationReleasesItAndKeepsTheDevice() async {
        let session = await reservedSession()

        let reservation = session.reservation
        var reported: [DeviceTarget?] = []
        session.onDeviceChange = { target, _ in reported.append(target) }
        session.endReservation()
        await reservation?.release().value

        #expect(session.state == .needsDevice)
        #expect(session.target == nil)
        #expect(session.reservation == nil)
        #expect(reported.count == 1 && reported[0] == nil)
        #expect(cli.verbs == ["create", "connect", "disconnect", "remove"])
    }

    @Test func endingWhileReservingStopsTheCreateAndReleasesWhatItPrinted() async {
        cli.answer("create", ok("New reservation created with id r1. Reservation ends at 10:51\u{202F}PM\n"))
        cli.hold("create")
        let session = makeSession()
        session.reserve(pixel6, projectID: "p")
        await waitUntilSoon { !ledger.entries.isEmpty }
        #expect(session.canEndReservation)

        let reservation = session.reservation
        session.endReservation()
        await reservation?.release().value

        #expect(session.state == .needsDevice)
        #expect(cli.verbs == ["create", "disconnect", "remove"])
        #expect(ledger.entries.isEmpty)
        #expect(recents.value.isEmpty)
    }
}
