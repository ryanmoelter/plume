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

    func registry() throws -> DeviceRegistry { try store.load() }

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
        let (_, lease, reused) = try pool.claimSerial("emulator-5554", claimant: me, ttl: hour)
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
        let (_, lease, reused) = try pool.claimSerial("R5", claimant: me, ttl: 60)
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

    /// adb is read before the forms, so a lease written while they are read is newer than adb's
    /// list and must not read as vanished.
    @Test func aLeaseNewerThanTheAdbReadIsNotReaped() throws {
        env.connect("R5")
        env.forms["R5"] = .phone
        let (store, env, other) = (store, env, other)
        env.duringForm = {
            env.clock += 1
            try? store.withLock {
                var registry = try store.load()
                registry.devices["emulator-5556"] = DeviceLease(
                    kind: .emulator, serial: "emulator-5556", avd: "Tablet", owner: other.owner,
                    claimedAt: env.clock, expiresAt: env.clock.addingTimeInterval(3600)
                )
                try store.save(registry)
            }
        }

        _ = try pool.acquire(claimant: me, ttl: hour, kind: .any, form: .phone)

        #expect(try registry().devices.keys.sorted() == ["R5", "emulator-5556"])
        #expect(warnings.isEmpty)
    }

    @Test func anOfflineOrUnauthorizedDeviceCantBeClaimed() {
        env.connect("R5", state: .offline)
        env.connect("R6", state: .unauthorized)
        #expect(throws: CLIFailure("R5 is offline, not ready to use")) { _ = try pool.claimSerial("R5", claimant: me, ttl: hour) }
        #expect(throws: CLIFailure("R6 is unauthorized, not ready to use")) { _ = try pool.claimSerial("R6", claimant: me, ttl: hour) }
    }

    @Test func aVanishedDevicesLeaseIsReapedWithAWarning() throws {
        env.connect("R5")
        _ = try pool.claimSerial("R5", claimant: other, ttl: hour)
        env.devices = []
        env.connect("R6")
        env.clock += 1
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

    @Test func acquireRenewsYourOwnDeviceBeforeTakingAnother() throws {
        env.connect("emulator-5554", avd: "Pixel_8")
        env.connect("emulator-5556", avd: "Tablet")
        _ = try pool.claimSerial("emulator-5556", claimant: me, ttl: 60)

        let result = try pool.acquire(claimant: me, ttl: hour, kind: .emulator, form: nil)

        #expect(result.serial == "emulator-5556")
        #expect(result.reused)
        #expect(try registry().devices.keys.sorted() == ["emulator-5556"])
    }

    @Test func aFailingAdbStillReleasesAndReapsByExpiry() throws {
        env.connect("R5")
        env.connect("R6")
        _ = try pool.claimSerial("R5", claimant: me, ttl: hour)
        _ = try pool.claimSerial("R6", claimant: other, ttl: 60)
        env.adbFailure = "`adb devices` failed or timed out"
        env.clock += 120

        #expect(try pool.release("R5", owner: me.owner, force: false)?.serial == "R5")
        #expect(try registry().devices.isEmpty)
        #expect(warnings == ["reaped expired lease on R6 (/repo/other)"])
        #expect(throws: CLIFailure("`adb devices` failed or timed out")) {
            _ = try pool.claimSerial("R5", claimant: me, ttl: hour)
        }
    }

    @Test func acquireReadsNoLiveFormsWithoutAFormFilter() throws {
        env.connect("R5")
        var reads = 0
        env.duringForm = { reads += 1 }

        _ = try pool.acquire(claimant: me, ttl: hour, kind: .physical, form: nil)
        _ = try pool.claimSerial("R5", claimant: me, ttl: hour)

        #expect(reads == 0)
    }

    @Test func acquireBootsAnAVDHoldingAPendingEntryMeanwhile() throws {
        env.avdList = ["Pixel_8"]
        env.avdForms["Pixel_8"] = .phone
        var pendingDuringBoot: [String: PendingDevice] = [:]
        let store = store
        env.duringBoot = { pendingDuringBoot = (try? store.load())?.pending ?? [:] }
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

    /// A claim interrupted between the boot and the lease leaves the claimant's own pending entry.
    @Test func acquireLeasesAnEmulatorTheClaimantWasBooting() throws {
        env.connect("emulator-5554", avd: "Pixel_8")
        try pendingBoot("Pixel_8", for: me)

        let result = try pool.acquire(claimant: me, ttl: hour, kind: .emulator, form: nil)

        #expect(result.serial == "emulator-5554")
        #expect(env.booted.isEmpty)
        #expect(try registry().pending.isEmpty)
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
            var registry = try store.load()
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
            var registry = try store.load()
            registry.pending["avd:Booting"] = PendingDevice(
                owner: other.owner, kind: .emulator, avd: "Booting", startedAt: env.clock, expiresAt: env.clock.addingTimeInterval(900)
            )
            try store.save(registry)
        }
        env.avdList = ["Booting"]
        #expect(exhausted { _ = try pool.acquire(claimant: me, ttl: hour, kind: .emulator, form: nil) })
    }

    func pendingBoot(_ avd: String, for claimant: DeviceClaimant) throws {
        try store.withLock {
            var registry = try store.load()
            registry.pending[DeviceRegistry.pendingKey(avd: avd)] = PendingDevice(
                owner: claimant.owner, kind: .emulator, avd: avd, startedAt: env.clock, expiresAt: env.clock.addingTimeInterval(900)
            )
            try store.save(registry)
        }
    }

    @Test func claimingAnEmulatorBootingForSomeoneElseConflicts() throws {
        env.connect("emulator-5554", avd: "Booting")
        try pendingBoot("Booting", for: other)

        do {
            _ = try pool.claimSerial("emulator-5554", claimant: me, ttl: hour)
            Issue.record("claimed an emulator booting for someone else")
        } catch DevicePoolError.booting(let key, let pending) {
            #expect(key == "avd:Booting")
            #expect(pending.owner == other.owner)
        }
        #expect(try registry().devices.isEmpty)
        #expect(try pool.claimSerial("emulator-5554", claimant: other, ttl: hour).key == "emulator-5554")
    }

    @Test func aBootNeverOverwritesALeaseTakenMeanwhile() throws {
        env.avdList = ["Pixel_8"]
        let pool = pool
        let (store, other, clock) = (store, other, env.clock)
        env.duringBoot = {
            try? store.withLock {
                var registry = try store.load()
                registry.devices["emulator-5554"] = DeviceLease(
                    kind: .emulator, serial: "emulator-5554", owner: other.owner, claimedAt: clock, expiresAt: clock.addingTimeInterval(3600)
                )
                try store.save(registry)
            }
        }

        #expect(conflict { _ = try pool.acquire(claimant: me, ttl: hour, kind: .emulator, form: nil) } == "emulator-5554")
        #expect(try registry().devices["emulator-5554"]?.owner == other.owner)
        #expect(try registry().pending.isEmpty)
    }

    @Test func aRemoteSerialIsNeverClaimedAsALocalDevice() throws {
        env.connect("localhost:40001", model: "Pixel_8")

        #expect(exhausted { _ = try pool.acquire(claimant: me, ttl: hour, kind: .physical, form: nil) })
        #expect(throws: CLIFailure("localhost:40001 is a remote device; reserve one with --kind=remote")) {
            _ = try pool.claimSerial("localhost:40001", claimant: me, ttl: hour)
        }
        #expect(try pool.listing().first?.kind == .remote)
        #expect(try registry().devices.isEmpty)
    }

    /// A physical device's form costs `adb shell` round trips, which must not hold the lock.
    @Test func formsAreReadWithoutTheLock() throws {
        env.connect("R5")
        env.forms["R5"] = .tablet
        try FileManager.default.createDirectory(atPath: store.directory, withIntermediateDirectories: true)
        let lockFile = store.directory + "/lock"
        var lockedDuringForm: [Bool] = []
        env.duringForm = {
            let descriptor = open(lockFile, O_WRONLY | O_CREAT | O_CLOEXEC, 0o644)
            defer { close(descriptor) }
            let free = flock(descriptor, LOCK_EX | LOCK_NB) == 0
            if free { flock(descriptor, LOCK_UN) }
            lockedDuringForm.append(!free)
        }

        #expect(try pool.acquire(claimant: me, ttl: hour, kind: .physical, form: .tablet).lease.form == .tablet)
        let readings = lockedDuringForm
        #expect(!readings.isEmpty)
        #expect(readings.allSatisfy { !$0 }, "\(readings)")
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

    @Test func listingReadsNoLiveForms() throws {
        env.connect("R5")
        env.forms["R5"] = .phone
        var reads = 0
        env.duringForm = { reads += 1 }

        #expect(try pool.listing().first?.form == nil)
        #expect(reads == 0)
    }

    @Test func listingMergesLiveDevicesLeasesAndPendingBoots() throws {
        env.connect("emulator-5554", avd: "Pixel_8")
        env.connect("R5", state: .unauthorized)
        _ = try pool.claimSerial("emulator-5554", claimant: me, ttl: hour)
        try store.withLock {
            var registry = try store.load()
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

    /// With nothing connected at all, adb's empty list reaps nothing, so the leases stay listed.
    @Test func aLeaseAdbDoesntListIsAbsentUnlessItIsRemote() throws {
        env.connect("R5")
        _ = try pool.claimSerial("R5", claimant: me, ttl: hour)
        try store.withLock {
            var registry = try store.load()
            registry.devices["remote:r1"] = DeviceLease(
                kind: .remote, serial: "localhost:40001", owner: other.owner, claimedAt: env.clock,
                expiresAt: env.clock.addingTimeInterval(hour), remote: .init(reservationID: "r1", projectID: "p")
            )
            try store.save(registry)
        }
        env.devices = []

        let states = Dictionary(uniqueKeysWithValues: try pool.listing().map { ($0.serial, $0.state) })

        #expect(states == ["R5": "absent", "localhost:40001": "remote"])
    }
}
