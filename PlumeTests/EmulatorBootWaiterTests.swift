import Foundation
import Testing
@testable import Plume

/// Drives the waiter on a fake clock: each `sleep` advances it, and the scan and `getprop`
/// answers change with the number of polls taken.
struct EmulatorBootWaiterTests {
    private final class FakeLaunch: EmulatorBootProcess {
        let launchedAt: Date
        let logURL = URL(fileURLWithPath: "/logs/Pixel_8.log")
        var hasExited = false
        var tail = ""

        init(launchedAt: Date) { self.launchedAt = launchedAt }
        func logTail(lines: Int) -> String { tail }
    }

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000)
        var polls = 0
    }

    private func emulator(avd: String = "Pixel_8", port: Int? = 5554, file: String = "pid_1.ini") -> RunningEmulator {
        RunningEmulator(
            pid: 1, avdID: avd, avdName: avd, avdDirectory: nil, grpcPort: 8554, grpcToken: "t",
            adbPort: port.map { $0 + 1 }, serialPort: port, version: nil, fileURL: URL(fileURLWithPath: "/run/\(file)")
        )
    }

    private func waiter(
        clock: Clock,
        scan: @escaping (Int) -> [RunningEmulator],
        written: Date? = nil,
        bootCompleted: @escaping (Int) -> String? = { _ in "1\n" }
    ) -> EmulatorBootWaiter {
        EmulatorBootWaiter(
            scan: { scan(clock.polls) },
            modificationDate: { _ in written ?? clock.now },
            bootCompletedProperty: { _ in bootCompleted(clock.polls) },
            now: { clock.now },
            sleep: { seconds in
                clock.now = clock.now.addingTimeInterval(seconds)
                clock.polls += 1
            },
            timeout: 10,
            pollInterval: 1
        )
    }

    @Test func waitsForTheSerialThenTheBootProperty() throws {
        let clock = Clock()
        let launch = FakeLaunch(launchedAt: clock.now)
        let waiter = waiter(
            clock: clock,
            scan: { [emulator(avd: "Other", port: 5556)] + ($0 >= 2 ? [emulator()] : []) },
            bootCompleted: { $0 >= 4 ? "1\n" : "\n" }
        )
        #expect(try waiter.wait(avdID: "Pixel_8", launch: launch) == "emulator-5554")
        #expect(clock.polls == 4)
    }

    @Test func ignoresADiscoveryFileOlderThanTheLaunch() {
        let clock = Clock()
        let launch = FakeLaunch(launchedAt: clock.now)
        let waiter = waiter(clock: clock, scan: { _ in [emulator()] }, written: clock.now.addingTimeInterval(-5))
        #expect(throws: EmulatorBootWaiter.Failure.self) { try waiter.wait(avdID: "Pixel_8", launch: launch) }
    }

    @Test func failsWithTheLogTailWhenTheEmulatorExits() {
        let clock = Clock()
        let launch = FakeLaunch(launchedAt: clock.now)
        launch.hasExited = true
        launch.tail = "PANIC: Missing emulator engine program"
        let waiter = waiter(clock: clock, scan: { _ in [] })
        do {
            _ = try waiter.wait(avdID: "Pixel_8", launch: launch)
            Issue.record("expected a failure")
        } catch let failure as EmulatorBootWaiter.Failure {
            #expect(failure.message.contains("exited during boot"))
            #expect(failure.message.contains("PANIC"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func timesOutNamingTheSerialItFound() {
        let clock = Clock()
        let launch = FakeLaunch(launchedAt: clock.now)
        let waiter = waiter(clock: clock, scan: { _ in [emulator()] }, bootCompleted: { _ in nil })
        do {
            _ = try waiter.wait(avdID: "Pixel_8", launch: launch)
            Issue.record("expected a failure")
        } catch let failure as EmulatorBootWaiter.Failure {
            #expect(failure.message.contains("emulator-5554"))
            #expect(failure.message.contains("/logs/Pixel_8.log"))
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(clock.polls == 10)
    }
}

struct AndroidSDKQuickLookupTests {
    private let full: (String) -> Bool = { $0 == "/sdk/emulator/emulator" || $0 == "/sdk/platform-tools/adb" }

    @Test func androidHomeAnswersWithoutTheShell() {
        let sdk = AndroidSDKLocator.quickLookup(
            environment: ["ANDROID_HOME": "/sdk", "ANDROID_AVD_HOME": "/avds", "PATH": ""],
            isExecutable: full, home: "/home"
        )
        #expect(sdk?.root.path == "/sdk")
        #expect(sdk?.adbURL?.path == "/sdk/platform-tools/adb")
        #expect(sdk?.launchEnvironment["ANDROID_AVD_HOME"] == "/avds")
    }

    @Test func aPartialInstallFallsBackToTheShell() {
        let adbOnly: (String) -> Bool = { $0 == "/sdk/platform-tools/adb" }
        #expect(AndroidSDKLocator.quickLookup(environment: ["ANDROID_HOME": "/sdk", "PATH": ""], isExecutable: adbOnly, home: "/home") == nil)
        #expect(AndroidSDKLocator.quickLookup(environment: ["PATH": ""], isExecutable: full, home: "/home") == nil)
    }

    @Test func theChildEnvironmentDropsPlumeVariables() {
        let sdk = AndroidSDK(root: URL(fileURLWithPath: "/sdk"), emulatorURL: nil, adbURL: nil, launchEnvironment: ["ANDROID_HOME": "/sdk"])
        let child = EmulatorLauncher.childEnvironment(
            ["PLUME_TAB_ID": "x", "PLUME_SOCKET": "/s", "HOME": "/h", "ANDROID_HOME": "/old"], sdk: sdk
        )
        #expect(child == ["HOME": "/h", "ANDROID_HOME": "/sdk"])
    }
}
