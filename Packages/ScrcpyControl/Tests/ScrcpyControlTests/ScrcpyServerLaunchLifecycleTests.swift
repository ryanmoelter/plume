import Foundation
import Testing
@testable import ScrcpyControl

/// Runs `ScrcpyServerLaunch` and `ScrcpyConnection` against a fake `adb` script that logs each
/// invocation. `push` and `forward tcp:0` block until the test creates their release file, so a
/// test can stop the launch while either is in flight.
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
              *" push "*) wait_for push-release ;;
              *"forward tcp:0"*) wait_for forward-release; echo 27183 ;;
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

        func release(_ name: String) {
            FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: nil)
        }

        func waitForLog(containing text: String) async {
            for _ in 0..<200 where !log.contains(where: { $0.contains(text) }) {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
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

        #expect(!adb.log.contains { $0.contains("forward") || $0.contains("shell") })
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
        #expect(!adb.log.contains { $0.contains(" shell ") })
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
