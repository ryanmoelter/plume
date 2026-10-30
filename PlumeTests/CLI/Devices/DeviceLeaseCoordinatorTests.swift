import Foundation
import Testing
@testable import Plume

/// The app's side of the registry: forgetting a tab drops what it owns and ends a remote
/// reservation, launch and expiry clear stale leases, and every change leaves other apps' leases
/// alone.
@MainActor
struct DeviceLeaseCoordinatorTests {
    let store: DeviceRegistryStore
    let me = "/me/cli.sock"
    let otherApp = "/other/cli.sock"
    let now = Date(timeIntervalSince1970: 1_000_000)
    let ownerTab = UUID()
    let deviceTab = UUID()
    private let recorder = Recorder()
    let coordinator: DeviceLeaseCoordinator

    @MainActor private final class Recorder {
        var ended: [String] = []
        var closed: [UUID] = []
        var returnedToPicker: [UUID] = []
    }

    init() throws {
        store = try makeDeviceStore()
        let recorder = recorder
        let now = now
        coordinator = DeviceLeaseCoordinator(
            store: store,
            leases: DeviceLeaseStore(),
            effects: .init(
                endReservation: { recorder.ended.append($0.remote?.reservationID ?? "?") },
                closeTab: { recorder.closed.append($0) },
                endTabReservation: { recorder.returnedToPicker.append($0) }
            ),
            appSocket: me,
            now: { now }
        )
    }

    func lease(
        _ kind: DeviceKind,
        owner: DeviceLeaseOwner,
        serial: String,
        deviceTab: UUID? = nil,
        createdByClaim: Bool = false,
        expiresIn: TimeInterval = 600
    ) -> DeviceLease {
        DeviceLease(
            kind: kind,
            serial: serial,
            avd: kind == .emulator ? "Pixel_8" : nil,
            owner: owner,
            claimedAt: now,
            expiresAt: now.addingTimeInterval(expiresIn),
            deviceTabID: deviceTab,
            deviceTabCreatedByClaim: createdByClaim,
            remote: kind == .remote ? .init(reservationID: serial, projectID: "p") : nil
        )
    }

    func pending(owner: DeviceLeaseOwner, deviceTab: UUID? = nil, expiresIn: TimeInterval = 600) -> PendingDevice {
        PendingDevice(owner: owner, kind: .remote, deviceTabID: deviceTab, startedAt: now, expiresAt: now.addingTimeInterval(expiresIn))
    }

    func save(_ registry: DeviceRegistry) throws { try store.save(registry) }
    func registry() throws -> DeviceRegistry { try store.load { _ in } }

    @Test func forgettingAnOwnerDropsItsLeasesAndEndsItsReservation() async throws {
        let mine = DeviceLeaseOwner.tab(id: ownerTab, app: me)
        let sameTabOtherApp = DeviceLeaseOwner.tab(id: ownerTab, app: otherApp)
        let preexisting = UUID()
        try save(DeviceRegistry(
            devices: [
                "emulator-5554": lease(.emulator, owner: mine, serial: "emulator-5554"),
                "remote:r1": lease(.remote, owner: mine, serial: "r1", deviceTab: deviceTab, createdByClaim: true),
                "remote:r2": lease(.remote, owner: mine, serial: "r2", deviceTab: preexisting),
                "R5": lease(.physical, owner: sameTabOtherApp, serial: "R5"),
            ],
            pending: ["claim:x": pending(owner: mine)]
        ))

        coordinator.tabForgotten(ownerTab)
        await coordinator.settle()

        let after = try registry()
        #expect(Set(after.devices.keys) == ["R5"])
        #expect(after.pending.isEmpty)
        #expect(Set(recorder.ended) == ["r1", "r2"])
        #expect(recorder.closed == [deviceTab])
    }

    @Test func forgettingADeviceTabKeepsALocalLeaseButDropsARemoteOne() async throws {
        let mine = DeviceLeaseOwner.tab(id: ownerTab, app: me)
        try save(DeviceRegistry(
            devices: [
                "emulator-5554": lease(.emulator, owner: mine, serial: "emulator-5554", deviceTab: deviceTab, createdByClaim: true),
                "remote:r1": lease(.remote, owner: mine, serial: "r1", deviceTab: deviceTab, createdByClaim: true),
            ],
            pending: ["claim:x": pending(owner: mine, deviceTab: deviceTab)]
        ))

        coordinator.tabForgotten(deviceTab)
        await coordinator.settle()

        let after = try registry()
        #expect(Set(after.devices.keys) == ["emulator-5554"])
        #expect(after.devices["emulator-5554"]?.deviceTabID == nil)
        #expect(after.devices["emulator-5554"]?.deviceTabCreatedByClaim == false)
        #expect(after.pending.isEmpty)
        #expect(recorder.ended.isEmpty)
        #expect(recorder.closed.isEmpty)
    }

    @Test func theLaunchSweepLeavesOtherAppsLeasesAlone() async throws {
        let live = DeviceLeaseOwner.tab(id: ownerTab, app: me)
        let gone = DeviceLeaseOwner.tab(id: UUID(), app: me)
        let other = DeviceLeaseOwner.tab(id: UUID(), app: otherApp)
        try save(DeviceRegistry(
            devices: [
                "emulator-5554": lease(.emulator, owner: live, serial: "emulator-5554", deviceTab: deviceTab),
                "emulator-5556": lease(.emulator, owner: gone, serial: "emulator-5556"),
                "remote:r1": lease(.remote, owner: live, serial: "r1"),
                "remote:r2": lease(.remote, owner: other, serial: "r2"),
                "R5": lease(.physical, owner: other, serial: "R5"),
                "R6": lease(.physical, owner: .label("/repo"), serial: "R6"),
            ],
            pending: ["claim:a": pending(owner: live), "avd:B": pending(owner: gone), "claim:c": pending(owner: other)]
        ))

        coordinator.sweepAtLaunch(liveTabIDs: [ownerTab])
        await coordinator.settle()

        let after = try registry()
        #expect(Set(after.devices.keys) == ["emulator-5554", "remote:r2", "R5", "R6"])
        #expect(after.devices["emulator-5554"]?.deviceTabID == nil)
        #expect(Set(after.pending.keys) == ["claim:c"])
        #expect(recorder.ended.isEmpty)
    }

    @Test func theReapDropsOnlyThisAppsExpiredLeases() async throws {
        let mine = DeviceLeaseOwner.tab(id: ownerTab, app: me)
        let other = DeviceLeaseOwner.tab(id: ownerTab, app: otherApp)
        try save(DeviceRegistry(
            devices: [
                "emulator-5554": lease(.emulator, owner: mine, serial: "emulator-5554", expiresIn: -1),
                "emulator-5556": lease(.emulator, owner: mine, serial: "emulator-5556"),
                "remote:r1": lease(.remote, owner: mine, serial: "r1", deviceTab: deviceTab, createdByClaim: true, expiresIn: -1),
                "R5": lease(.physical, owner: other, serial: "R5", expiresIn: -1),
            ],
            pending: ["claim:a": pending(owner: mine, expiresIn: -1)]
        ))

        coordinator.reapExpired()
        await coordinator.settle()

        let after = try registry()
        #expect(Set(after.devices.keys) == ["emulator-5556", "R5"])
        #expect(after.pending.isEmpty)
        #expect(recorder.ended == ["r1"])
        #expect(recorder.closed == [deviceTab])
    }

    @Test func quittingDropsThisAppsRemoteLeases() throws {
        let mine = DeviceLeaseOwner.tab(id: ownerTab, app: me)
        let other = DeviceLeaseOwner.tab(id: ownerTab, app: otherApp)
        try save(DeviceRegistry(
            devices: [
                "emulator-5554": lease(.emulator, owner: mine, serial: "emulator-5554"),
                "remote:r1": lease(.remote, owner: mine, serial: "r1"),
                "remote:r2": lease(.remote, owner: other, serial: "r2"),
            ],
            pending: ["claim:a": pending(owner: mine)]
        ))

        coordinator.dropRemoteLeasesForTermination()

        let after = try registry()
        #expect(Set(after.devices.keys) == ["emulator-5554", "remote:r2"])
        #expect(after.pending.isEmpty)
    }

    @Test func theStoreHoldsThisAppsLeasesByOwnerTab() async throws {
        let mine = DeviceLeaseOwner.tab(id: ownerTab, app: me)
        try save(DeviceRegistry(devices: [
            "emulator-5554": lease(.emulator, owner: mine, serial: "emulator-5554"),
            "R5": lease(.physical, owner: .tab(id: ownerTab, app: otherApp), serial: "R5"),
        ]))

        coordinator.refresh()
        await coordinator.settle()

        let held = coordinator.leases.leases(ownedBy: [ownerTab, UUID()])
        #expect(held.map(\.serial) == ["emulator-5554"])
        #expect(DeviceLeaseStore.summary(held) == "emulator-5554 (Pixel_8)")
    }

    // MARK: Remote claims

    func claim(created: Bool = true) -> RemoteClaim {
        RemoteClaim(
            owner: .tab(id: ownerTab, app: me), deviceTabID: deviceTab, deviceTabCreated: created,
            model: "akita/34", projectID: "p", ttl: 600, worktree: "/w", branch: "b"
        )
    }

    @Test func aClaimIsPendingUntilItsDeviceConnectsAndThenLeased() async throws {
        let claim = claim()
        try await coordinator.beginClaim(claim)
        let pending = try #require(try registry().pending[DeviceRegistry.pendingKey(claim: claim.id)])
        #expect(pending.owner == claim.owner)
        #expect(pending.deviceTabID == deviceTab)

        coordinator.reservationEvent(.attached(reservationID: "r1", serial: "localhost:40001"), deviceTab: deviceTab)
        await coordinator.settle()

        let after = try registry()
        #expect(after.pending.isEmpty)
        #expect(after.devices["remote:r1"] == DeviceLease(
            kind: .remote, serial: "localhost:40001", model: "akita/34", owner: claim.owner, worktree: "/w", branch: "b",
            claimedAt: now, expiresAt: now.addingTimeInterval(600), deviceTabID: deviceTab, deviceTabCreatedByClaim: true,
            remote: .init(reservationID: "r1", projectID: "p", claimID: claim.id)
        ))
        #expect(coordinator.leases.leases(ownedBy: [ownerTab]).map(\.serial) == ["localhost:40001"])
    }

    @Test func aReconnectMovesTheLeaseToItsNewPort() async throws {
        try await coordinator.beginClaim(claim())
        coordinator.reservationEvent(.attached(reservationID: "r1", serial: "localhost:40001"), deviceTab: deviceTab)
        coordinator.reservationEvent(.attached(reservationID: "r1", serial: "localhost:40002"), deviceTab: deviceTab)
        await coordinator.settle()

        #expect(try registry().devices["remote:r1"]?.serial == "localhost:40002")
    }

    @Test func aFailedReservationMarksItsClaim() async throws {
        let claim = claim()
        try await coordinator.beginClaim(claim)
        coordinator.reservationEvent(.failed("quota exceeded"), deviceTab: deviceTab)
        await coordinator.settle()

        #expect(try registry().pending[DeviceRegistry.pendingKey(claim: claim.id)]?.error == "quota exceeded")
        #expect(recorder.closed.isEmpty)
    }

    @Test func anEndedReservationTakesItsLeaseOrMarksItsClaim() async throws {
        let first = claim()
        try await coordinator.beginClaim(first)
        coordinator.reservationEvent(.attached(reservationID: "r1", serial: "localhost:40001"), deviceTab: deviceTab)
        coordinator.reservationEvent(.ended(reservationID: "r1"), deviceTab: deviceTab)
        let second = claim()
        try await coordinator.beginClaim(second)
        coordinator.reservationEvent(.ended(reservationID: nil), deviceTab: deviceTab)
        await coordinator.settle()

        let after = try registry()
        #expect(after.devices.isEmpty)
        #expect(after.pending[DeviceRegistry.pendingKey(claim: second.id)]?.error == "the reservation ended before the device connected")
        #expect(recorder.ended.isEmpty)
    }

    @Test func releasingALeaseEndsItsReservationAndClosesTheTabItOpened() async throws {
        try await coordinator.beginClaim(claim())
        coordinator.reservationEvent(.attached(reservationID: "r1", serial: "localhost:40001"), deviceTab: deviceTab)
        await coordinator.settle()

        #expect(try await coordinator.releaseLease("remote:r1") != nil)
        #expect(try await coordinator.releaseLease("remote:r1") == nil)

        #expect(try registry().devices.isEmpty)
        #expect(recorder.ended == ["r1"])
        #expect(recorder.closed == [deviceTab])
    }

    @Test func anotherAppsLeaseIsNotReleased() async throws {
        try save(DeviceRegistry(devices: ["remote:r1": lease(.remote, owner: .tab(id: ownerTab, app: otherApp), serial: "r1")]))

        #expect(try await coordinator.releaseLease("remote:r1") == nil)
        #expect(try registry().devices.count == 1)
    }

    @Test func forgettingTheClaimantStopsAReservationStillStarting() async throws {
        try await coordinator.beginClaim(claim(created: true))
        coordinator.tabForgotten(ownerTab)
        await coordinator.settle()
        #expect(recorder.closed == [deviceTab])
        #expect(try registry().pending.isEmpty)

        try await coordinator.beginClaim(claim(created: false))
        coordinator.tabForgotten(ownerTab)
        await coordinator.settle()
        #expect(recorder.returnedToPicker == [deviceTab])
    }

    @Test func nothingHappensBeforeStart() async throws {
        let mine = DeviceLeaseOwner.tab(id: ownerTab, app: me)
        try save(DeviceRegistry(devices: ["emulator-5554": lease(.emulator, owner: mine, serial: "emulator-5554")]))
        let idle = DeviceLeaseCoordinator(store: store, leases: DeviceLeaseStore())

        idle.tabForgotten(ownerTab)
        await idle.settle()

        #expect(try registry().devices.count == 1)
    }
}
