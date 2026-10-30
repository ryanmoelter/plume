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

    func now() -> Date { clock }
    func adbDevices() throws -> [PhysicalDevice] { devices }
    func emulatorAVDs() -> [String: String] { runningAVDs }
    func form(of device: PhysicalDevice, avd: String?) -> DeviceForm? {
        avd.flatMap { avdForms[$0] } ?? forms[device.serial]
    }
    func avds() throws -> [String] { avdList }
    func avdForm(_ avd: String) -> DeviceForm? { avdForms[avd] }
    func ownerInfo() -> DeviceOwnerInfo? { owner }

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
