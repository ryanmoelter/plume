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
                closeTab: { recorder.closed.append($0) }
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

    @Test func nothingHappensBeforeStart() async throws {
        let mine = DeviceLeaseOwner.tab(id: ownerTab, app: me)
        try save(DeviceRegistry(devices: ["emulator-5554": lease(.emulator, owner: mine, serial: "emulator-5554")]))
        let idle = DeviceLeaseCoordinator(store: store, leases: DeviceLeaseStore())

        idle.tabForgotten(ownerTab)
        await idle.settle()

        #expect(try registry().devices.count == 1)
    }
}
