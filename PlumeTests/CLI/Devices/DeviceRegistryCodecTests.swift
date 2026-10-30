import Foundation
import Testing
@testable import Plume

struct DeviceRegistryCodecTests {
    static let tabID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    static let at = Date(timeIntervalSince1970: 1_700_000_000)

    static func sample() -> DeviceRegistry {
        var registry = DeviceRegistry()
        registry.devices["emulator-5554"] = DeviceLease(
            kind: .emulator, serial: "emulator-5554", avd: "Pixel_8", form: .phone,
            owner: .tab(id: tabID, app: "/Users/me/Library/Application Support/Plume/run/cli.sock"),
            worktree: "/repo", branch: "main", claimedAt: at, expiresAt: at.addingTimeInterval(3600),
            deviceTabID: tabID, deviceTabCreatedByClaim: true,
            installed: .init(branch: "main", worktree: "/repo", at: at)
        )
        registry.devices["remote:abc"] = DeviceLease(
            kind: .remote, serial: "localhost:40001", model: "akita/34", owner: .label("ci"),
            claimedAt: at, expiresAt: at.addingTimeInterval(1800),
            remote: .init(reservationID: "abc", projectID: "proj", claimID: tabID)
        )
        registry.pending["avd:Tablet"] = PendingDevice(
            owner: .label("ci"), kind: .emulator, avd: "Tablet", startedAt: at, expiresAt: at.addingTimeInterval(900)
        )
        return registry
    }

    @Test func roundTrips() throws {
        let registry = Self.sample()
        #expect(try DeviceRegistryCodec.decode(DeviceRegistryCodec.encode(registry)) == registry)
    }

    @Test func writesReadableJSON() throws {
        let text = String(decoding: try DeviceRegistryCodec.encode(Self.sample()), as: UTF8.self)
        #expect(text.contains(#""version" : 1"#))
        #expect(text.contains(#""claimedAt" : 1700000000"#))
        #expect(text.contains(#""tab" : "11111111-2222-3333-4444-555555555555""#))
        #expect(text.contains(#""label" : "ci""#))
        #expect(text.contains("/Application Support/Plume/run/cli.sock"))
        #expect(text.hasSuffix("}\n"))
    }

    @Test func aMissingClaimFlagReadsAsFalse() throws {
        let json = """
            {"version": 1, "devices": {"R5": {"kind": "physical", "owner": {"label": "x"},
              "claimedAt": 1, "expiresAt": 2, "form": "hexagon"}}, "pending": {}}
            """
        let lease = try #require(try DeviceRegistryCodec.decode(Data(json.utf8)).devices["R5"])
        #expect(!lease.deviceTabCreatedByClaim)
        #expect(lease.form == nil)
        #expect(lease.owner == .label("x"))
    }

    @Test func refusesANewerVersion() {
        #expect(throws: DeviceRegistryCodec.DecodeError.tooNew(2)) {
            try DeviceRegistryCodec.decode(Data(#"{"version": 2, "devices": {}, "pending": {}}"#.utf8))
        }
    }

    /// A lease of a kind this build doesn't know makes the whole file unreadable.
    @Test func anUnreadableFileIsNeverSavedOver() throws {
        let store = DeviceRegistryStore(directory: try makeScratchDirectory() + "/devices")
        try FileManager.default.createDirectory(atPath: store.directory, withIntermediateDirectories: true)
        let contents = #"{"version": 1, "devices": {"R5": {"kind": "watch", "owner": {"label": "x"}, "claimedAt": 0, "expiresAt": 9999999999}}, "pending": {}}"#
        try contents.write(toFile: store.registryFile, atomically: true, encoding: .utf8)
        let env = FakeDeviceEnvironment()
        env.connect("R6")
        let pool = DevicePool(store: store, environment: env, warn: { _ in }, log: { _ in })

        #expect(throws: CLIFailure.self) { try store.load() }
        #expect((try? pool.claimSerial("R6", claimant: DeviceClaimant(owner: .label("me")), ttl: 60)) == nil)
        #expect((try? pool.release("R5", owner: .label("me"), force: true)) == nil)
        do {
            _ = try store.load()
        } catch let failure as CLIFailure {
            #expect(failure.message?.contains("move it aside") == true)
        }
        #expect(try String(contentsOfFile: store.registryFile, encoding: .utf8) == contents)
    }

    @Test func storeRefusesATooNewFile() throws {
        let store = DeviceRegistryStore(directory: try makeScratchDirectory() + "/devices")
        try FileManager.default.createDirectory(atPath: store.directory, withIntermediateDirectories: true)
        try #"{"version": 9}"#.write(toFile: store.registryFile, atomically: true, encoding: .utf8)
        #expect(throws: CLIFailure.self) { try store.load() }
    }

    @Test func storeSavesUnderTheLock() throws {
        let store = DeviceRegistryStore(directory: try makeScratchDirectory() + "/devices")
        #expect(try store.load() == DeviceRegistry())
        try store.withLock { try store.save(Self.sample()) }
        #expect(try store.load() == Self.sample())
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.directory).sorted()
        #expect(leftovers == ["lock", "registry.json"])
    }

    @Test func defaultDirectoryIsTheReleaseDataDirectory() {
        #expect(DeviceRegistryStore.defaultDirectory.hasSuffix("/Library/Application Support/Plume/devices"))
    }
}
