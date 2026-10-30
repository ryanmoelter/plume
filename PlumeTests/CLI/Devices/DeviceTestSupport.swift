import Foundation
@testable import Plume

/// adb, the emulator and git as plain data. `boot` brings the AVD up on the next free emulator
/// serial unless `bootFailure` is set.
final class FakeDeviceEnvironment: DeviceEnvironment {
    var clock = Date(timeIntervalSince1970: 1_000_000)
    var devices: [PhysicalDevice] = []
    var runningAVDs: [String: String] = [:]
    var forms: [String: DeviceForm] = [:]
    var avdList: [String] = []
    var avdForms: [String: DeviceForm] = [:]
    var bootFailure: String?
    var owner: DeviceOwnerInfo? = DeviceOwnerInfo(worktree: "/repo/wt", branch: "feature")
    private(set) var booted: [String] = []
    /// Runs inside `boot`, while the registry lock is free.
    var duringBoot: () -> Void = {}

    /// Plays adb missing or timing out.
    var adbFailure: String?

    func now() -> Date { clock }
    func adbDevices() throws -> [PhysicalDevice] {
        if let adbFailure { throw CLIFailure(adbFailure) }
        return devices
    }
    func emulatorAVDs() -> [String: String] { runningAVDs }
    /// Runs inside every `form(of:)`, which reads the live device.
    var duringForm: () -> Void = {}
    func form(of device: PhysicalDevice, avd: String?) -> DeviceForm? {
        duringForm()
        return avd.flatMap { avdForms[$0] } ?? forms[device.serial]
    }
    func avds() throws -> [String] { avdList }
    func avdForm(_ avd: String) -> DeviceForm? { avdForms[avd] }
    func ownerInfo() -> DeviceOwnerInfo? { owner }

    /// Advances the clock, then runs `duringSleep`, which plays whatever happens meanwhile.
    var duringSleep: () -> Void = {}
    private(set) var slept: TimeInterval = 0
    func sleep(_ seconds: TimeInterval) {
        slept += seconds
        clock = clock.addingTimeInterval(seconds)
        duringSleep()
    }

    func boot(avd: String, log: (String) -> Void) throws -> String {
        booted.append(avd)
        duringBoot()
        if let bootFailure { throw CLIFailure(bootFailure) }
        let port = 5554 + 2 * runningAVDs.count
        let serial = "emulator-\(port)"
        runningAVDs[serial] = avd
        devices.append(PhysicalDevice(serial: serial, state: .ready, model: nil))
        return serial
    }

    func connect(_ serial: String, avd: String? = nil, state: PhysicalDevice.State = .ready, model: String? = nil) {
        devices.append(PhysicalDevice(serial: serial, state: state, model: model))
        if let avd { runningAVDs[serial] = avd }
    }
}

func makeDeviceStore() throws -> DeviceRegistryStore {
    DeviceRegistryStore(directory: try makeScratchDirectory() + "/devices")
}

/// Records each request with its socket and answers through `reply`, which may throw to play an
/// app that can't be reached.
final class FakeDeviceAppClient: DeviceAppClient {
    private(set) var sent: [(request: CLIRequest, socket: String)] = []
    var reply: (CLIRequest) throws -> CLIResponse = { _ in .success }

    func send(_ request: CLIRequest, to socket: String) throws -> CLIResponse {
        sent.append((request, socket))
        return try reply(request)
    }
}
