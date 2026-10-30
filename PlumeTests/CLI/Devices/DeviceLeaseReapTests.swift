import Foundation
import Testing
@testable import Plume

struct DeviceLeaseReapTests {
    let now = Date(timeIntervalSince1970: 10_000)

    func lease(_ kind: DeviceKind, avd: String? = nil, expiresIn: TimeInterval = 600) -> DeviceLease {
        DeviceLease(kind: kind, avd: avd, owner: .label("o"), claimedAt: now.addingTimeInterval(-60), expiresAt: now.addingTimeInterval(expiresIn))
    }

    @Test func dropsExpiredLeases() {
        var registry = DeviceRegistry(devices: ["R5": lease(.physical, expiresIn: -1), "R6": lease(.physical)])
        let messages = registry.reap(liveSerials: ["R5", "R6"], emulatorAVDs: [:], now: now)
        #expect(Set(registry.devices.keys) == ["R6"])
        #expect(messages == ["reaped expired lease on R5 (o)"])
    }

    @Test func dropsLocalLeasesWhoseSerialVanished() {
        var registry = DeviceRegistry(devices: ["R5": lease(.physical), "emulator-5554": lease(.emulator, avd: "P")])
        registry.reap(liveSerials: [], emulatorAVDs: [:], now: now)
        #expect(registry.devices.isEmpty)
    }

    @Test func dropsAnEmulatorSerialNowOnAnotherAVD() {
        var registry = DeviceRegistry(devices: ["emulator-5554": lease(.emulator, avd: "Pixel_8")])
        let kept = registry
        registry.reap(liveSerials: ["emulator-5554"], emulatorAVDs: ["emulator-5554": "Tablet"], now: now)
        #expect(registry.devices.isEmpty)

        var unresolved = kept
        unresolved.reap(liveSerials: ["emulator-5554"], emulatorAVDs: [:], now: now)
        #expect(unresolved == kept)
        var same = kept
        same.reap(liveSerials: ["emulator-5554"], emulatorAVDs: ["emulator-5554": "Pixel_8"], now: now)
        #expect(same == kept)
    }

    /// The grace leaves the owning app time to end the reservation before anyone drops its lease.
    @Test func remoteLeasesIgnoreAdbAndGoOnlyAfterTheGracePastExpiry() {
        var registry = DeviceRegistry(devices: [
            "remote:a": lease(.remote), "remote:b": lease(.remote, expiresIn: -1), "remote:c": lease(.remote, expiresIn: -301),
        ])
        registry.reap(liveSerials: [], emulatorAVDs: [:], now: now)
        #expect(Set(registry.devices.keys) == ["remote:a", "remote:b"])
    }

    @Test func dropsPendingEntriesByTTL() {
        let fresh = PendingDevice(owner: .label("o"), kind: .emulator, avd: "A", startedAt: now, expiresAt: now.addingTimeInterval(900))
        var stale = fresh
        stale.expiresAt = now.addingTimeInterval(-1)
        var registry = DeviceRegistry(pending: ["avd:A": fresh, "avd:B": stale])
        let messages = registry.reap(liveSerials: [], emulatorAVDs: [:], now: now)
        #expect(Set(registry.pending.keys) == ["avd:A"])
        #expect(messages == ["reaped stale pending avd:B (o)"])
        #expect(registry.pendingAVDs == ["A"])
    }
}
