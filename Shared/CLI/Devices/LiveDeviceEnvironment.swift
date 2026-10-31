import Foundation

/// The real adb, emulator and git behind `plume devices`.
nonisolated final class LiveDeviceEnvironment: DeviceEnvironment {
    static let adbTimeout: TimeInterval = 15

    private let processEnvironment: [String: String]
    private let workingDirectory: String?
    private lazy var sdk: AndroidSDK? = AndroidSDKLocator.locateSkippingShellWhenPossible(environment: processEnvironment).sdk
    private lazy var avdHome = AVDCatalog.defaultAVDHome(environment: processEnvironment)
    private var avdDirectories: [String: URL] = [:]

    init(environment: [String: String], workingDirectory: String? = nil) {
        self.processEnvironment = environment
        self.workingDirectory = workingDirectory
    }

    func sleep(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    func now() -> Date { Date() }

    private func adbURL() throws -> URL {
        guard let adb = sdk?.adbURL else {
            throw CLIFailure("adb not found; install the Android SDK platform-tools or set ANDROID_HOME")
        }
        return adb
    }

    private func adb(_ arguments: [String]) -> String? {
        guard let adb = try? adbURL() else { return nil }
        return AndroidSDKLocator.runCapturingOutput(executable: adb.path, arguments: arguments, timeout: Self.adbTimeout)
    }

    func adbDevices() throws -> [PhysicalDevice] {
        let adb = try adbURL()
        guard let output = AndroidSDKLocator.runCapturingOutput(executable: adb.path, arguments: ["devices", "-l"], timeout: Self.adbTimeout) else {
            throw CLIFailure("`adb devices` failed or timed out")
        }
        return ADBDeviceList.parseIncludingEmulators(output)
    }

    func emulatorAVDs() -> [String: String] {
        let pairs = EmulatorScanner.scanAll().compactMap { emulator in emulator.adbSerial.map { ($0, emulator.avdID) } }
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }

    func form(of device: PhysicalDevice, avd: String?) -> DeviceForm? {
        if let avd, let form = avdForm(avd) { return form }
        let shell = ["-s", device.serial, "shell"]
        guard let size = adb(shell + ["wm", "size"]), let density = adb(shell + ["wm", "density"]) else { return nil }
        var model: String?
        if !DevicePool.isEmulator(device.serial) {
            model = device.model ?? adb(shell + ["getprop", "ro.product.model"]) ?? ""
        }
        return DeviceForm.liveForm(wmSize: size, wmDensity: density, model: model)
    }

    func avds() throws -> [String] {
        guard let sdk, sdk.emulatorURL != nil else {
            throw CLIFailure("no free emulator, and the Android emulator isn't installed; start a device yourself and claim its serial")
        }
        let avds = AVDCatalog.listBlocking(sdk: sdk, avdHome: avdHome)
        for avd in avds { avdDirectories[avd.id] = avd.directory }
        return avds.map(\.id)
    }

    func avdForm(_ avd: String) -> DeviceForm? {
        let directory = avdDirectories[avd] ?? AVDCatalog.avdDirectory(
            id: avd,
            rootINI: try? String(contentsOf: avdHome.appending(path: "\(avd).ini"), encoding: .utf8),
            avdHome: avdHome
        )
        guard let config = try? String(contentsOf: directory.appending(path: "config.ini"), encoding: .utf8) else { return nil }
        return DeviceForm.avdForm(configINI: config)
    }

    func boot(avd: String, log: (String) -> Void) throws -> String {
        guard let sdk, let adb = sdk.adbURL else { throw CLIFailure("adb not found; install the Android SDK platform-tools or set ANDROID_HOME") }
        log("booting emulator \(avd)…")
        let logDirectory = URL(fileURLWithPath: CLISocket.releaseApplicationSupport, isDirectory: true).appending(path: "Emulators")
        let launch = try EmulatorLauncher.boot(avdID: avd, sdk: sdk, logDirectory: logDirectory)
        do {
            let serial = try EmulatorBootWaiter.live(adbURL: adb).wait(avdID: avd, launch: launch)
            log("\(avd) booted on \(serial)")
            return serial
        } catch let failure as EmulatorBootWaiter.Failure {
            throw CLIFailure(failure.message)
        }
    }

    func ownerInfo() -> DeviceOwnerInfo? {
        guard let toplevel = try? CLIProcess.run(["git", "rev-parse", "--show-toplevel"], check: false, workingDirectory: workingDirectory),
              toplevel.status == 0
        else { return nil }
        let worktree = toplevel.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !worktree.isEmpty else { return nil }
        let branch = (try? CLIProcess.run(["git", "symbolic-ref", "--short", "-q", "HEAD"], check: false, workingDirectory: workingDirectory))
            .map { $0.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
        return DeviceOwnerInfo(worktree: worktree, branch: branch?.isEmpty == false ? branch : nil)
    }
}
