import Darwin
import Foundation
import Testing
@testable import Plume

/// Reading a clone lock's holder without taking the lock: a holder counts only while its pid is
/// alive with the start time it recorded, and this process's own lock never counts.
struct VMCloneLockTests {
    let path = FileManager.default.temporaryDirectory.appending(path: "vm-lock-\(UUID().uuidString).lock").path

    func write(_ text: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Another live process of this user's; the test host's parent can be launchd, which it can't inspect.
    func withOtherProcess(_ body: (pid_t) throws -> Void) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { process.terminate() }
        try body(process.processIdentifier)
    }

    @Test func aLiveHolderWithItsStartTimeIsHeld() throws {
        defer { try? FileManager.default.removeItem(atPath: path) }
        try withOtherProcess { pid in
            let holder = try #require(VMCloneLock.Holder.running(pid: pid))
            try write(holder.record)
            #expect(VMCloneLock.isHeldElsewhere(path: path))
        }
    }

    @Test func aReusedPidWithAnotherStartTimeIsFree() throws {
        defer { try? FileManager.default.removeItem(atPath: path) }
        try withOtherProcess { pid in
            var stale = try #require(VMCloneLock.Holder.running(pid: pid))
            stale.startSeconds -= 1
            try write(stale.record)
            #expect(!VMCloneLock.isHeldElsewhere(path: path))
        }
    }

    @Test func thisProcesssOwnLockIsNotHeldElsewhere() throws {
        defer { try? FileManager.default.removeItem(atPath: path) }
        let lock = try #require(VMCloneLock.acquire(path: path))
        defer { lock.release() }
        let recorded = try String(contentsOfFile: path, encoding: .utf8)
        #expect(VMCloneLock.Holder(record: recorded) == VMCloneLock.Holder.running(pid: getpid()))
        #expect(!VMCloneLock.isHeldElsewhere(path: path))
    }

    @Test func aPidOnlyRecordCountsWhileThePidIsAlive() throws {
        defer { try? FileManager.default.removeItem(atPath: path) }
        try withOtherProcess { pid in
            try write("\(pid)")
            #expect(VMCloneLock.isHeldElsewhere(path: path))
        }
        // macOS pids stop at 99998 (PID_MAX), so no process has this one.
        try write("99999")
        #expect(!VMCloneLock.isHeldElsewhere(path: path))
    }

    @Test func aMissingOrEmptyLockIsFree() throws {
        #expect(!VMCloneLock.isHeldElsewhere(path: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        try write("")
        #expect(!VMCloneLock.isHeldElsewhere(path: path))
    }
}
