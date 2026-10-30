import Foundation
import Testing
@testable import Plume

/// `plume devices` with remote devices: a claim asks the tab's app to reserve one and waits on the
/// registry for the lease, a release goes through the app that holds the reservation, and a remote
/// device's adb serial never reads as a free local device.
struct RemoteDeviceClaimTests {
    typealias Run = DevicesArgumentTests.Run

    let caller = UUID()
    let socket = "/app/cli.sock"
    var inTab: [String: String] { ["PLUME_TAB_ID": caller.uuidString, "PLUME_SOCKET": socket] }
    var owner: DeviceLeaseOwner { .tab(id: caller, app: socket) }

    func remoteLease(owner: DeviceLeaseOwner, serial: String = "localhost:40001", claimID: UUID? = nil, at now: Date) -> DeviceLease {
        DeviceLease(
            kind: .remote, serial: serial, model: "akita/34", owner: owner, claimedAt: now, expiresAt: now.addingTimeInterval(600),
            remote: .init(reservationID: "r1", projectID: "p", claimID: claimID)
        )
    }

    func update(_ store: DeviceRegistryStore, _ change: (inout DeviceRegistry) -> Void) {
        try? store.withLock {
            var registry = try store.load { _ in }
            change(&registry)
            try store.save(registry)
        }
    }

    /// Plays the app: records the claim as pending when asked to reserve.
    func reserving(_ run: Run, claimID: UUID = UUID()) -> UUID {
        let (store, owner, now) = (run.store, owner, run.env.clock)
        run.app.reply = { request in
            guard case .reserveDevice = request else { return .success }
            update(store) {
                $0.pending[DeviceRegistry.pendingKey(claim: claimID)] = PendingDevice(
                    owner: owner, kind: .remote, model: "akita/34", startedAt: now, expiresAt: now.addingTimeInterval(900)
                )
            }
            var response = CLIResponse.success
            response.claimID = claimID
            return response
        }
        return claimID
    }

    // MARK: Parsing

    @Test func parsesARemoteClaim() throws {
        #expect(try Devices.parse(["claim", "--kind=remote"]) == .claimRemote(model: nil, owner: nil, ttl: 3600, json: false))
        #expect(try Devices.parse(["claim", "--kind", "remote", "--model", "akita/34", "--ttl=60", "--json"])
            == .claimRemote(model: "akita/34", owner: nil, ttl: 60, json: true))
    }

    @Test func rejectsRemoteFlagsThatDontApply() {
        for arguments in [["claim", "--kind=remote", "R5"], ["claim", "--kind=remote", "--form=phone"], ["claim", "--model=akita/34"]] {
            #expect(throws: Devices.UsageError.self, "\(arguments)") { try Devices.parse(arguments) }
        }
    }

    // MARK: Claiming

    @Test func aRemoteDeviceNeedsATabAndAnAnsweringApp() throws {
        let run = try Run()
        let outside = run(["claim", "--kind=remote"])
        #expect(outside.code == 1)
        #expect(outside.console.stderr.contains(Devices.remoteNeedsATab))

        run.app.reply = { _ in throw CLIFailure("connection refused") }
        let unanswered = run(["claim", "--kind=remote"], environment: inTab)
        #expect(unanswered.code == 1)
        #expect(unanswered.console.stderr.contains("isn't answering: connection refused"))
        #expect(!run.app.sent.contains { if case .reserveDevice = $0.request { true } else { false } })
    }

    @Test func aClaimReservesThenPrintsTheSerialOnceTheDeviceConnects() throws {
        let run = try Run()
        let claimID = reserving(run)
        var polls = 0
        let (store, owner) = (run.store, owner)
        run.env.duringSleep = {
            polls += 1
            guard polls == 3 else { return }
            update(store) {
                $0.pending = [:]
                $0.devices["remote:r1"] = remoteLease(owner: owner, claimID: claimID, at: run.env.clock)
            }
        }

        let (code, console) = run(["claim", "--kind=remote", "--model=akita/34", "--ttl=600"], environment: inTab)

        #expect(code == 0)
        #expect(console.stdout == "localhost:40001\n")
        #expect(console.stderr.contains("==> claimed localhost:40001 (akita/34)"))
        let reserve = run.app.sent.compactMap { if case .reserveDevice(let params) = $0.request { params } else { nil } }
        #expect(reserve == [.init(tabID: caller, model: "akita/34", ttl: 600, worktree: "/repo/wt", branch: "feature")])
        #expect(run.app.sent.allSatisfy { $0.socket == socket })
    }

    @Test func aFailedReservationExitsWithItsErrorAndClearsTheClaim() throws {
        let run = try Run()
        let claimID = reserving(run)
        let store = run.store
        run.env.duringSleep = {
            update(store) { $0.pending[DeviceRegistry.pendingKey(claim: claimID)]?.error = "quota exceeded" }
        }

        let (code, console) = run(["claim", "--kind=remote"], environment: inTab)

        #expect(code == 1)
        #expect(console.stderr.contains("couldn't reserve a device: quota exceeded"))
        #expect(try store.load { _ in }.pending.isEmpty)
    }

    @Test func aClaimThatVanishesExitsWithoutALease() throws {
        let run = try Run()
        _ = reserving(run)
        let store = run.store
        run.env.duringSleep = { update(store) { $0.pending = [:] } }

        let (code, console) = run(["claim", "--kind=remote"], environment: inTab)

        #expect(code == 1)
        #expect(console.stderr.contains("stopped before its device connected"))
    }

    @Test func aClaimGivesUpButLeavesTheReservationToItsTab() throws {
        let run = try Run()
        let claimID = reserving(run)

        let (code, console) = run(["claim", "--kind=remote"], environment: inTab)

        #expect(code == 1)
        #expect(console.stderr.contains("still reserving after 11 minutes"))
        #expect(console.stderr.contains("==> still reserving (10m)"))
        #expect(run.env.slept == RemoteClaimWaiter.timeout)
        #expect(try run.store.load { _ in }.pending[DeviceRegistry.pendingKey(claim: claimID)] != nil)
    }

    @Test func claimingAgainWaitsOnTheSameReservation() throws {
        let run = try Run()
        let claimID = UUID()
        let (store, owner) = (run.store, owner)
        update(store) {
            $0.pending[DeviceRegistry.pendingKey(claim: claimID)] = PendingDevice(
                owner: owner, kind: .remote, startedAt: run.env.clock, expiresAt: run.env.clock.addingTimeInterval(900)
            )
        }
        run.env.duringSleep = {
            update(store) { $0.devices["remote:r1"] = remoteLease(owner: owner, claimID: claimID, at: run.env.clock) }
        }

        let (code, console) = run(["claim", "--kind=remote"], environment: inTab)

        #expect(code == 0)
        #expect(console.stdout == "localhost:40001\n")
        #expect(!run.app.sent.contains { if case .reserveDevice = $0.request { true } else { false } })
    }

    @Test func aHeldRemoteDeviceIsRenewedRatherThanReservedAgain() throws {
        let run = try Run()
        let (store, owner) = (run.store, owner)
        update(store) { $0.devices["remote:r1"] = remoteLease(owner: owner, at: run.env.clock) }

        let (code, console) = run(["claim", "--kind=remote", "--ttl=7200"], environment: inTab)

        #expect(code == 0)
        #expect(console.stdout == "localhost:40001\n")
        #expect(console.stderr.contains("renewed lease on localhost:40001"))
        #expect(try store.load { _ in }.devices["remote:r1"]?.expiresAt == run.env.clock.addingTimeInterval(7200))
        #expect(run.app.sent.map(\.request) == [.ping])
    }

    // MARK: Releasing

    @Test func releasingARemoteDeviceAsksItsAppByKey() throws {
        let run = try Run()
        let (store, owner) = (run.store, owner)
        update(store) { $0.devices["remote:r1"] = remoteLease(owner: owner, at: run.env.clock) }
        run.app.reply = { request in
            if case .releaseDevice(let params) = request { update(store) { $0.devices[params.key] = nil } }
            return .success
        }

        let (code, console) = run(["release", "localhost:40001"], environment: inTab)

        #expect(code == 0)
        #expect(console.stdout == "released localhost:40001\n")
        #expect(run.app.sent.map(\.request) == [.releaseDevice(.init(key: "remote:r1"))])
        #expect(try store.load { _ in }.devices.isEmpty)
    }

    @Test func anAppThatCantBeReachedLeavesTheLeaseToBeDroppedHere() throws {
        let run = try Run()
        let (store, owner) = (run.store, owner)
        update(store) { $0.devices["remote:r1"] = remoteLease(owner: owner, at: run.env.clock) }
        run.app.reply = { _ in throw CLIFailure("connection refused") }

        let (code, console) = run(["release", "--mine"], environment: inTab)

        #expect(code == 0)
        #expect(console.stdout == "released remote:r1\n")
        #expect(console.stderr.contains("couldn't reach the Plume holding remote:r1"))
        #expect(try store.load { _ in }.devices.isEmpty)
    }

    @Test func anotherOwnersRemoteDeviceNeedsForce() throws {
        let run = try Run()
        let store = run.store
        update(store) { $0.devices["remote:r1"] = remoteLease(owner: .tab(id: UUID(), app: "/other.sock"), at: run.env.clock) }

        #expect(run(["release", "remote:r1"], environment: inTab).code == Devices.conflictExitCode)
        #expect(run.app.sent.isEmpty)
        #expect(run(["release", "remote:r1", "--force"], environment: inTab).code == 0)
        #expect(run.app.sent.map(\.socket) == ["/other.sock"])
    }

    // MARK: The pool

    @Test func aRemoteDevicesSerialIsNeverFree() throws {
        let run = try Run()
        let store = run.store
        update(store) { $0.devices["remote:r1"] = remoteLease(owner: .tab(id: UUID(), app: "/other.sock"), at: run.env.clock) }
        run.env.connect("localhost:40001")

        let listing = run(["ls", "--json"])
        #expect(listing.console.stdout.contains("\"state\" : \"device\""))
        #expect(listing.console.stdout.components(separatedBy: "localhost:40001").count == 3)
        #expect(listing.console.stdout.contains("\"kind\" : \"remote\""))
        #expect(run(["claim", "--kind=physical"]).code == Devices.exhaustedExitCode)
        #expect(run(["claim", "localhost:40001"]).code == Devices.conflictExitCode)
    }
}
