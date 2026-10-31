import Foundation

/// What the waiter needs from a spawned emulator. `EmulatorLaunch` is the real one.
nonisolated protocol EmulatorBootProcess: AnyObject {
    var launchedAt: Date { get }
    var logURL: URL { get }
    var hasExited: Bool { get }
    func logTail(lines: Int) -> String
}

nonisolated extension EmulatorLaunch: EmulatorBootProcess {}

/// Waits, blocking, for a launched AVD to get an adb serial and finish booting.
nonisolated struct EmulatorBootWaiter {
    struct Failure: Error, Equatable, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static let defaultTimeout: TimeInterval = 300

    var scan: () -> [RunningEmulator]
    var modificationDate: (RunningEmulator) -> Date?
    /// `adb -s <serial> shell getprop sys.boot_completed`'s output, or nil when adb fails.
    var bootCompletedProperty: (_ serial: String) -> String?
    var now: () -> Date = Date.init
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    var timeout: TimeInterval = defaultTimeout
    var pollInterval: TimeInterval = 1

    static func live(adbURL: URL) -> EmulatorBootWaiter {
        EmulatorBootWaiter(
            scan: { EmulatorScanner.scanAll() },
            modificationDate: EmulatorScanner.modificationDate(of:),
            bootCompletedProperty: { serial in
                AndroidSDKLocator.runCapturingOutput(
                    executable: adbURL.path,
                    arguments: ["-s", serial, "shell", "getprop", "sys.boot_completed"],
                    timeout: 10
                )
            }
        )
    }

    /// Returns the booted emulator's serial.
    func wait(avdID: String, launch: some EmulatorBootProcess) throws -> String {
        let deadline = now().addingTimeInterval(timeout)
        var serial: String?
        while true {
            if serial == nil {
                serial = scan().first { isBoot(of: launch, avdID: avdID, $0) }?.adbSerial
            }
            if let serial, bootCompletedProperty(serial)?.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                return serial
            }
            if launch.hasExited {
                let tail = launch.logTail(lines: 20)
                throw Failure(message: "the emulator for \(avdID) exited during boot"
                    + (tail.isEmpty ? "" : ":\n\(tail)"))
            }
            if now() >= deadline {
                let what = serial.map { "\(avdID) (\($0)) did not finish booting" } ?? "\(avdID) did not appear"
                throw Failure(message: "emulator \(what) within \(Int(timeout))s; its log is at \(launch.logURL.path)")
            }
            sleep(pollInterval)
        }
    }

    func isBoot(of launch: some EmulatorBootProcess, avdID: String, _ emulator: RunningEmulator) -> Bool {
        emulator.adbSerial != nil
            && Self.isInstance(emulator, avdID: avdID, launchedAt: launch.launchedAt, written: modificationDate(emulator))
    }

    /// Whether `emulator` is the one launched at `launchedAt`. A discovery file older than the
    /// launch belongs to an instance still shutting down.
    static func isInstance(_ emulator: RunningEmulator, avdID: String, launchedAt: Date, written: @autoclosure () -> Date?) -> Bool {
        guard emulator.avdID == avdID, let written = written() else { return false }
        return written >= launchedAt.addingTimeInterval(-1)
    }
}
