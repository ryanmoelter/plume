import Foundation
import Testing
@testable import ScrcpyControl

/// Runs `ScrcpyServerLaunch` and `ScrcpyConnection` against a fake `adb` script that logs each
/// invocation. `push` and `forward tcp:0` block until the test creates their release file, so a
/// test can stop the launch while either is in flight. `forward --list` prints the `forward-list` file.
/// `forward --remove` takes a moment and then records itself in `removals`, so a test can tell a
/// removal that finished from one that only started. `shell rm -f` records itself in `jar-removals`.
struct ScrcpyServerLaunchLifecycleTests {
    private struct FakeADB {
        let directory: URL
        let adbURL: URL
        let jarURL: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("fake-adb-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            adbURL = directory.appendingPathComponent("adb")
            jarURL = directory.appendingPathComponent("server.jar")
            try Data("PK\u{3}\u{4}".utf8).write(to: jarURL)
            let dir = directory.path
            let script = """
            #!/bin/sh
            echo "$*" >> "\(dir)/log"
            wait_for() { i=0; while [ ! -e "\(dir)/$1" ] && [ $i -lt 300 ]; do sleep 0.05; i=$((i+1)); done; }
            case "$*" in
              *"forward --list"*) cat "\(dir)/forward-list" 2>/dev/null ;;
              *"forward --remove"*) sleep 0.2; echo "$*" >> "\(dir)/removals" ;;
              *" push "*) wait_for push-release ;;
              *"forward tcp:0"*) wait_for forward-release; echo 27183 ;;
              *" shell rm -f "*) echo "$*" >> "\(dir)/jar-removals" ;;
              *" shell settings "*) ;;
              *" shell "*) echo $$ > "\(dir)/shell-pid"; exec sleep 30 ;;
            esac
            exit 0
            """
            try Data(script.utf8).write(to: adbURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adbURL.path)
        }

        var log: [String] {
            ((try? String(contentsOf: directory.appendingPathComponent("log"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }

        var removals: [String] { lines(of: "removals") }
        var jarRemovals: [String] { lines(of: "jar-removals") }

        private func lines(of name: String) -> [String] {
            ((try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }

        func release(_ name: String) {
            FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: nil)
        }

        func waitForLog(containing text: String) async {
            for _ in 0..<200 where !log.contains(where: { $0.contains(text) }) {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }

        func listForwards(_ lines: [String]) throws {
            try Data(lines.joined(separator: "\n").utf8).write(to: directory.appendingPathComponent("forward-list"))
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    /// `awaitTerminations()` blocks its thread, which must not be one of the cooperative pool's.
    private func awaitTerminations() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                ScrcpyServerLaunch.awaitTerminations()
                continuation.resume()
            }
        }
    }

    @Test func closingDuringThePushStartsNothing() async throws {
        let adb = try FakeADB()
        defer { adb.remove() }
        let connection = ScrcpyConnection(adbURL: adb.adbURL, serial: "S1", jarURL: adb.jarURL, version: "5.0.1")
        let connecting = Task { try await connection.connect() }
        await adb.waitForLog(containing: "push")
        await connection.close()
        adb.release("push-release")
        await #expect(throws: (any Error).self) { try await connecting.value }

        #expect(!adb.log.contains { $0.contains("forward") || $0.contains("app_process") })
        #expect(adb.jarRemovals.count == 1)
    }

    @Test func stoppingDuringTheForwardRemovesItAndSpawnsNoServer() async throws {
        let adb = try FakeADB()
        defer { adb.remove() }
        adb.release("push-release")
        let launch = ScrcpyServerLaunch(adbURL: adb.adbURL, serial: "S1", jarURL: adb.jarURL, version: "5.0.1")
        let starting = Task { try await launch.start() }
        await adb.waitForLog(containing: "forward tcp:0")
        await launch.stop()
        adb.release("forward-release")
        await #expect(throws: ScrcpyLaunchError.stopped) { try await starting.value }

        #expect(adb.log.contains { $0.hasSuffix("forward --remove tcp:27183") })
        #expect(!adb.log.contains { $0.contains("app_process") })
        #expect(adb.jarRemovals == ["-s S1 shell rm -f \(launch.remoteJarPath)"])
    }

    @Test func cancellingDuringTheForwardRemovesWhateverItCreated() async throws {
        let adb = try FakeADB()
        defer { adb.remove() }
        adb.release("push-release")
        let launch = ScrcpyServerLaunch(adbURL: adb.adbURL, serial: "S1", jarURL: adb.jarURL, version: "5.0.1")
        try adb.listForwards([
            "S1 tcp:27183 localabstract:scrcpy_\(launch.scid)",
            "S1 tcp:5555 localabstract:scrcpy_other",
            "S2 tcp:6000 localabstract:scrcpy_\(launch.scid)",
        ])
        let starting = Task { try await launch.start() }
        await adb.waitForLog(containing: "forward tcp:0")
        starting.cancel()
        await #expect(throws: CancellationError.self) { try await starting.value }

        #expect(adb.log.contains { $0.hasSuffix("forward --list") })
        let removed = adb.log.filter { $0.contains("forward --remove") }
        #expect(removed == ["-s S1 forward --remove tcp:27183"])
        #expect(!adb.log.contains { $0.contains("app_process") })
        #expect(adb.jarRemovals.count == 1)
    }

    @Test func aHungForwardTimesOutAndRemovesWhateverItCreated() async throws {
        let adb = try FakeADB()
        defer { adb.remove() }
        adb.release("push-release")
        let launch = ScrcpyServerLaunch(adbURL: adb.adbURL, serial: "S1", jarURL: adb.jarURL, version: "5.0.1", forwardTimeout: .milliseconds(300))
        try adb.listForwards(["S1 tcp:27183 localabstract:scrcpy_\(launch.scid)"])
        await #expect(throws: ScrcpyLaunchError.adbTimedOut(command: "-s S1 forward tcp:0 localabstract:scrcpy_\(launch.scid)")) {
            try await launch.start()
        }
        #expect(adb.log.contains { $0.hasSuffix("forward --remove tcp:27183") })
        #expect(adb.jarRemovals.count == 1)
    }

    @Test func aStopStartedByTerminateIsCoveredByAwaitTerminations() async throws {
        let adb = try FakeADB()
        defer { adb.remove() }
        adb.release("push-release")
        adb.release("forward-release")
        let launch = ScrcpyServerLaunch(adbURL: adb.adbURL, serial: "S1", jarURL: adb.jarURL, version: "5.0.1")
        _ = try await launch.start()

        launch.terminate()
        await awaitTerminations()
        #expect(adb.log.contains { $0.hasSuffix("forward --remove tcp:27183") })
    }

    @Test func aQuitDuringTheForwardWaitsForItsCleanup() async throws {
        let adb = try FakeADB()
        defer { adb.remove() }
        adb.release("push-release")
        let launch = ScrcpyServerLaunch(adbURL: adb.adbURL, serial: "S1", jarURL: adb.jarURL, version: "5.0.1")
        let starting = Task { try await launch.start() }
        await adb.waitForLog(containing: "forward tcp:0")

        launch.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { adb.release("forward-release") }
        await awaitTerminations()
        #expect(adb.removals.contains { $0.hasSuffix("forward --remove tcp:27183") })
        await #expect(throws: (any Error).self) { try await starting.value }
    }

    @Test func stopWaitsForARemovalThatTerminateStarted() async throws {
        let adb = try FakeADB()
        defer { adb.remove() }
        adb.release("push-release")
        adb.release("forward-release")
        let launch = ScrcpyServerLaunch(adbURL: adb.adbURL, serial: "S1", jarURL: adb.jarURL, version: "5.0.1")
        _ = try await launch.start()

        launch.terminate()
        await launch.stop()
        #expect(adb.removals.contains { $0.hasSuffix("forward --remove tcp:27183") })
    }

    @Test func stopAfterStartKillsTheServerAndRemovesTheForward() async throws {
        let adb = try FakeADB()
        defer { adb.remove() }
        adb.release("push-release")
        adb.release("forward-release")
        let launch = ScrcpyServerLaunch(adbURL: adb.adbURL, serial: "S1", jarURL: adb.jarURL, version: "5.0.1")
        #expect(try await launch.start() == 27183)
        await adb.waitForLog(containing: " shell ")
        let pidFile = adb.directory.appendingPathComponent("shell-pid")
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(for: .milliseconds(25))
        }
        let pid = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))

        await launch.stop()
        #expect(adb.log.contains { $0.hasSuffix("forward --remove tcp:27183") })
        for _ in 0..<100 where kill(pid, 0) == 0 {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(kill(pid, 0) != 0)
        #expect(adb.log.first { $0.contains(" push ") }?.hasSuffix(launch.remoteJarPath) == true)
        #expect(adb.jarRemovals.isEmpty)
    }

    @Test func aHungPushTimesOut() async throws {
        let adb = try FakeADB()
        defer { adb.remove() }
        let launch = ScrcpyServerLaunch(adbURL: adb.adbURL, serial: "S1", jarURL: adb.jarURL, version: "5.0.1", pushTimeout: .milliseconds(200))
        let started = ContinuousClock.now
        await #expect(throws: ScrcpyLaunchError.adbTimedOut(command: "-s S1 push \(adb.jarURL.path) \(launch.remoteJarPath)")) {
            try await launch.start()
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func cancellingStartKillsTheAdbCommand() async throws {
        let adb = try FakeADB()
        defer { adb.remove() }
        let launch = ScrcpyServerLaunch(adbURL: adb.adbURL, serial: "S1", jarURL: adb.jarURL, version: "5.0.1")
        let starting = Task { try await launch.start() }
        await adb.waitForLog(containing: "push")
        starting.cancel()
        await #expect(throws: CancellationError.self) { try await starting.value }
        #expect(adb.jarRemovals.count == 1)
    }

    @Test func anUnparsableForwardPortRemovesThePushedJar() async throws {
        let adb = try FakeADB()
        defer { adb.remove() }
        adb.release("push-release")
        try Data("""
        #!/bin/sh
        echo "$*" >> "\(adb.directory.path)/log"
        case "$*" in
          *"forward tcp:0"*) echo "error: more than one device" ;;
          *" shell rm -f "*) echo "$*" >> "\(adb.directory.path)/jar-removals" ;;
        esac
        exit 0
        """.utf8).write(to: adb.adbURL)
        let launch = ScrcpyServerLaunch(adbURL: adb.adbURL, serial: "S1", jarURL: adb.jarURL, version: "5.0.1")
        await #expect(throws: ScrcpyLaunchError.unparsableForwardPort("error: more than one device")) {
            try await launch.start()
        }
        #expect(adb.jarRemovals == ["-s S1 shell rm -f \(launch.remoteJarPath)"])
        #expect(!adb.log.contains { $0.contains("app_process") })
    }

    @Test func anInvocationThatFailsToRunFinishesOnceEvenIfAbortedAfter() {
        let invocation = ADBInvocation(adb: URL(fileURLWithPath: "/nonexistent/adb"), arguments: ["devices"])
        let count = Counter()
        invocation.start(timeout: .seconds(5)) { _ in count.increment() }
        invocation.abort(.cancelled)
        invocation.abort(.timedOut)
        #expect(count.value == 1)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    @Test func rotatingLocksAutoRotateOnce() async throws {
        let adb = try FakeADB()
        defer { adb.remove() }
        let connection = ScrcpyConnection(adbURL: adb.adbURL, serial: "S1", jarURL: adb.jarURL, version: "5.0.1")
        await connection.rotate()
        await connection.rotate()

        #expect(adb.log == ["-s S1 shell settings put system accelerometer_rotation 0"])
    }

    @Test func eachLaunchPushesToItsOwnPath() {
        let url = URL(fileURLWithPath: "/usr/bin/false")
        let a = ScrcpyServerLaunch(adbURL: url, serial: "S1", jarURL: url, version: "5.0.1")
        let b = ScrcpyServerLaunch(adbURL: url, serial: "S1", jarURL: url, version: "5.0.1")
        #expect(a.remoteJarPath == "/data/local/tmp/plume-scrcpy-server-\(a.scid).jar")
        #expect(a.remoteJarPath != b.remoteJarPath || a.scid == b.scid)
        #expect(a.serverArguments.first == "CLASSPATH=\(a.remoteJarPath)")
    }
}
