import Foundation
import Testing
@testable import Plume

/// The lease operations over a fake adb and emulator, with the registry in a scratch directory.
struct DevicePoolTests {
    let env = FakeDeviceEnvironment()
    let store: DeviceRegistryStore
    var warnings: [String] { warningsBox.lines }
    private let warningsBox = Lines()

    let me = DeviceClaimant(owner: .label("/repo/me"), worktree: "/repo/me", branch: "mine")
    let other = DeviceClaimant(owner: .label("/repo/other"), worktree: "/repo/other", branch: nil)
    let hour = DevicePool.defaultTTL

    private final class Lines {
        var lines: [String] = []
    }

    init() throws {
        store = try makeDeviceStore()
    }

    var pool: DevicePool {
        let box = warningsBox
        return DevicePool(store: store, environment: env, warn: { box.lines.append($0) }, log: { _ in })
    }

    func registry() throws -> DeviceRegistry { try store.load { _ in } }

    func conflict(_ body: () throws -> Void) -> String? {
        do {
            try body()
        } catch DevicePoolError.conflict(let key, _) {
            return key
        } catch {
            Issue.record("unexpected \(error)")
        }
        return nil
    }

    func exhausted(_ body: () throws -> Void) -> Bool {
        do {
            try body()
        } catch DevicePoolError.exhausted {
            return true
        } catch {
            Issue.record("unexpected \(error)")
        }
        return false
    }

    // MARK: claim <serial>

    @Test func claimsAFreeDevice() throws {
        env.connect("emulator-5554", avd: "Pixel_8")
        env.avdForms["Pixel_8"] = .phone
        let (lease, reused) = try pool.claimSerial("emulator-5554", claimant: me, ttl: hour)
        #expect(!reused)
        #expect(lease.kind == .emulator)
        #expect(lease.avd == "Pixel_8")
        #expect(lease.form == .phone)
        #expect(lease.branch == "mine")
        #expect(lease.expiresAt == env.clock.addingTimeInterval(3600))
        #expect(try registry().devices["emulator-5554"] == lease)
    }

    @Test func reclaimingYourOwnLeaseRenewsIt() throws {
        env.connect("R5", model: "Pixel_8")
        _ = try pool.claimSerial("R5", claimant: me, ttl: hour)
        env.clock += 600
        let (lease, reused) = try pool.claimSerial("R5", claimant: me, ttl: 60)
        #expect(reused)
        #expect(lease.kind == .physical)
        #expect(lease.model == "Pixel_8")
        #expect(lease.expiresAt == env.clock.addingTimeInterval(60))
    }

    @Test func claimingAnotherOwnersDeviceConflicts() throws {
        env.connect("R5")
        _ = try pool.claimSerial("R5", claimant: other, ttl: hour)
        #expect(conflict { _ = try pool.claimSerial("R5", claimant: me, ttl: hour) } == "R5")
    }

    @Test func aDisconnectedSerialCantBeClaimed() {
        #expect(throws: CLIFailure.self) { _ = try pool.claimSerial("R5", claimant: me, ttl: hour) }
    }

    @Test func theSameTabInAnotherAppIsAnotherOwner() throws {
        let tab = UUID()
        env.connect("R5")
        let release = DeviceClaimant(owner: .tab(id: tab, app: "/release/cli.sock"))
        let debug = DeviceClaimant(owner: .tab(id: tab, app: "/debug/cli.sock"))
        _ = try pool.claimSerial("R5", claimant: release, ttl: hour)
        #expect(conflict { _ = try pool.claimSerial("R5", claimant: debug, ttl: hour) } == "R5")
        #expect(try pool.claimSerial("R5", claimant: release, ttl: hour).reused)
    }

    @Test func aVanishedDevicesLeaseIsReapedWithAWarning() throws {
        env.connect("R5")
        _ = try pool.claimSerial("R5", claimant: other, ttl: hour)
        env.devices = []
        env.connect("R6")
        _ = try pool.claimSerial("R6", claimant: me, ttl: hour)
        #expect(try registry().devices.keys.sorted() == ["R6"])
        #expect(warnings == ["reaped lease on vanished device R5 (/repo/other)"])
    }

    // MARK: claim (acquire)

    @Test func acquireReusesAFreeBootedEmulator() throws {
        env.connect("emulator-5554", avd: "Pixel_8")
        env.avdList = ["Pixel_8", "Tablet"]
        let result = try pool.acquire(claimant: me, ttl: hour, kind: .emulator, form: nil)
        #expect(result.serial == "emulator-5554")
        #expect(!result.reused)
        #expect(env.booted.isEmpty)
    }

    @Test func acquireRenewsWhatYouAlreadyHold() throws {
        env.connect("emulator-5554", avd: "Pixel_8")
        _ = try pool.claimSerial("emulator-5554", claimant: me, ttl: 60)
        let result = try pool.acquire(claimant: me, ttl: hour, kind: .emulator, form: nil)
        #expect(result.reused)
        #expect(result.lease.expiresAt == env.clock.addingTimeInterval(hour))
    }

    @Test func acquireBootsAnAVDHoldingAPendingEntryMeanwhile() throws {
        env.avdList = ["Pixel_8"]
        env.avdForms["Pixel_8"] = .phone
        var pendingDuringBoot: [String: PendingDevice] = [:]
        let store = store
        env.duringBoot = { pendingDuringBoot = (try? store.load { _ in })?.pending ?? [:] }
        let result = try pool.acquire(claimant: me, ttl: hour, kind: .emulator, form: nil)
        #expect(env.booted == ["Pixel_8"])
        #expect(result.serial == "emulator-5554")
        #expect(result.lease.avd == "Pixel_8")
        #expect(result.lease.form == .phone)
        #expect(pendingDuringBoot["avd:Pixel_8"]?.owner == me.owner)
        #expect(pendingDuringBoot["avd:Pixel_8"]?.expiresAt == env.clock.addingTimeInterval(900))
        #expect(try registry().pending.isEmpty)
        #expect(try registry().devices["emulator-5554"]?.owner == me.owner)
    }

    @Test func aFailedBootClearsItsPendingEntry() throws {
        env.avdList = ["Pixel_8"]
        env.bootFailure = "the emulator for Pixel_8 exited during boot"
        #expect(throws: CLIFailure("the emulator for Pixel_8 exited during boot")) {
            _ = try pool.acquire(claimant: me, ttl: hour, kind: .emulator, form: nil)
        }
        #expect(try registry() == DeviceRegistry())
    }

    @Test func acquireSkipsRunningAndPendingAVDs() throws {
        env.connect("emulator-5554", avd: "Running")
        _ = try pool.claimSerial("emulator-5554", claimant: other, ttl: hour)
        try store.withLock {
            var registry = try store.load { _ in }
            registry.pending["avd:Booting"] = PendingDevice(
                owner: other.owner, kind: .emulator, avd: "Booting", startedAt: env.clock, expiresAt: env.clock.addingTimeInterval(900)
            )
            try store.save(registry)
        }
        env.avdList = ["Running", "Booting", "Free"]
        let result = try pool.acquire(claimant: me, ttl: hour, kind: .any, form: nil)
        #expect(env.booted == ["Free"])
        #expect(result.lease.avd == "Free")
        #expect(try registry().pending.keys.sorted() == ["avd:Booting"])
    }

    @Test func acquireLeavesAnEmulatorBootingForSomeoneElse() throws {
        env.connect("emulator-5554", avd: "Booting")
        try store.withLock {
            var registry = try store.load { _ in }
            registry.pending["avd:Booting"] = PendingDevice(
                owner: other.owner, kind: .emulator, avd: "Booting", startedAt: env.clock, expiresAt: env.clock.addingTimeInterval(900)
            )
            try store.save(registry)
        }
        env.avdList = ["Booting"]
        #expect(exhausted { _ = try pool.acquire(claimant: me, ttl: hour, kind: .emulator, form: nil) })
    }

    @Test func acquireIsExhaustedWhenEverythingIsHeld() throws {
        env.connect("emulator-5554", avd: "Pixel_8")
        _ = try pool.claimSerial("emulator-5554", claimant: other, ttl: hour)
        env.avdList = ["Pixel_8"]
        #expect(exhausted { _ = try pool.acquire(claimant: me, ttl: hour, kind: .emulator, form: nil) })
        #expect(exhausted { _ = try pool.acquire(claimant: me, ttl: hour, kind: .physical, form: nil) })
        #expect(env.booted.isEmpty)
    }

    @Test func noAVDsAtAllIsAnError() {
        #expect(throws: CLIFailure.self) { _ = try pool.acquire(claimant: me, ttl: hour, kind: .emulator, form: nil) }
    }

    @Test func kindFiltersWhatIsReused() throws {
        env.connect("R5")
        env.connect("emulator-5554", avd: "Pixel_8")
        #expect(try pool.acquire(claimant: me, ttl: hour, kind: .physical, form: nil).serial == "R5")
        #expect(try pool.acquire(claimant: other, ttl: hour, kind: .emulator, form: nil).serial == "emulator-5554")
    }

    @Test func offlineDevicesAreNotReused() throws {
        env.connect("R5", state: .offline)
        #expect(exhausted { _ = try pool.acquire(claimant: me, ttl: hour, kind: .physical, form: nil) })
    }

    @Test func formFiltersBothReuseAndBoot() throws {
        env.connect("R5")
        env.forms["R5"] = .phone
        env.connect("R6")
        env.forms["R6"] = .tablet
        #expect(try pool.acquire(claimant: me, ttl: hour, kind: .physical, form: .tablet).serial == "R6")

        env.avdList = ["Phone", "Fold"]
        env.avdForms = ["Phone": .phone, "Fold": .foldable]
        let fold = try pool.acquire(claimant: me, ttl: hour, kind: .emulator, form: .foldable)
        #expect(env.booted == ["Fold"])
        #expect(fold.lease.form == .foldable)
    }

    // MARK: release, renew, installed

    @Test func releaseNeedsForceForAnotherOwnersLease() throws {
        env.connect("R5")
        _ = try pool.claimSerial("R5", claimant: other, ttl: hour)
        #expect(conflict { _ = try pool.release("R5", owner: me.owner, force: false) } == "R5")
        #expect(try pool.release("R5", owner: me.owner, force: true)?.owner == other.owner)
        #expect(try pool.release("R5", owner: me.owner, force: false) == nil)
    }

    @Test func releaseMineDropsOnlyMine() throws {
        env.connect("R5")
        env.connect("R6")
        env.connect("R7")
        _ = try pool.claimSerial("R5", claimant: me, ttl: hour)
        _ = try pool.claimSerial("R6", claimant: other, ttl: hour)
        _ = try pool.claimSerial("R7", claimant: me, ttl: hour)
        #expect(try pool.releaseMine(owner: me.owner).map(\.key) == ["R5", "R7"])
        #expect(try registry().devices.keys.sorted() == ["R6"])
        #expect(try pool.releaseMine(owner: me.owner).isEmpty)
    }

    @Test func renewExtendsOnlyYourOwnLease() throws {
        env.connect("R5")
        _ = try pool.claimSerial("R5", claimant: other, ttl: hour)
        #expect(conflict { _ = try pool.renew("R5", owner: me.owner, ttl: hour) } == "R5")
        env.clock += 100
        #expect(try pool.renew("R5", owner: other.owner, ttl: 30).expiresAt == env.clock.addingTimeInterval(30))
        #expect(throws: CLIFailure("R6 is not leased")) { _ = try pool.renew("R6", owner: me.owner, ttl: hour) }
    }

    @Test func installedAnnotatesALease() throws {
        env.connect("R5")
        #expect(try !pool.noteInstalled("R5", branch: "b", worktree: "/w"))
        _ = try pool.claimSerial("R5", claimant: me, ttl: hour)
        #expect(try pool.noteInstalled("R5", branch: "b", worktree: "/w"))
        #expect(try registry().devices["R5"]?.installed == .init(branch: "b", worktree: "/w", at: env.clock))
    }

    @Test func pruneReportsWhatExpired() throws {
        env.connect("R5")
        _ = try pool.claimSerial("R5", claimant: me, ttl: 10)
        env.clock += 11
        #expect(try pool.prune() == ["reaped expired lease on R5 (/repo/me)"])
        #expect(try pool.prune().isEmpty)
        #expect(warnings.isEmpty)
    }

    @Test func listingMergesLiveDevicesLeasesAndPendingBoots() throws {
        env.connect("emulator-5554", avd: "Pixel_8")
        env.connect("R5", state: .unauthorized)
        _ = try pool.claimSerial("emulator-5554", claimant: me, ttl: hour)
        try store.withLock {
            var registry = try store.load { _ in }
            registry.pending["avd:Tablet"] = PendingDevice(
                owner: other.owner, kind: .emulator, avd: "Tablet", startedAt: env.clock, expiresAt: env.clock.addingTimeInterval(900)
            )
            try store.save(registry)
        }
        let rows = try pool.listing()
        #expect(rows.map(\.serial) == ["emulator-5554", "R5", nil])
        #expect(rows.map(\.state) == ["device", "unauthorized", "booting"])
        #expect(rows[0].lease?.owner == me.owner)
        #expect(rows[2].pending?.avd == "Tablet")
    }
}
