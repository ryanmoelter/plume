import Testing
import Foundation
@testable import Plume

struct StatuslineCaptureWriterTests {
    /// A scratch directory this test owns, cleaned up after each run.
    private func makeScratchDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "StatuslineCaptureWriterTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func generatedScriptCapturesAndChainsThrough() throws {
        let scratch = makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let chainScript = scratch.appending(path: "fake_chain.sh")
        try #"""
        #!/bin/bash
        cat > /dev/null
        echo "CHAINED"
        """#.write(to: chainScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chainScript.path)

        let captureScript = scratch.appending(path: "capture.sh")
        try StatuslineCaptureWriter.script(chainCommand: chainScript.path)
            .write(to: captureScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: captureScript.path)

        let eventsDir = scratch.appending(path: "events")
        let taskID = "task-1"
        let tabID = "tab-1"

        let process = Process()
        process.executableURL = captureScript
        process.environment = [
            "PLUME_EVENTS_DIR": eventsDir.path,
            "PLUME_TASK_ID": taskID,
            "PLUME_TAB_ID": tabID,
            "PATH": "/bin:/usr/bin",
        ]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe

        try process.run()
        let payload = #"{"cost":{"total_cost_usd":1.5}}"#
        stdinPipe.fileHandleForWriting.write(Data(payload.utf8))
        try stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        #expect(stdout?.trimmingCharacters(in: .whitespacesAndNewlines) == "CHAINED")
        #expect(process.terminationStatus == 0)

        let capturedFile = eventsDir.appending(path: taskID).appending(path: "\(tabID).statusline.json")
        let captured = try String(contentsOf: capturedFile, encoding: .utf8)
        #expect(captured == payload)
    }

    @Test func exitsZeroWhenChainTargetIsMissing() throws {
        let scratch = makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let captureScript = scratch.appending(path: "capture.sh")
        try StatuslineCaptureWriter.script(chainCommand: "/nonexistent/does-not-exist.sh")
            .write(to: captureScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: captureScript.path)

        let eventsDir = scratch.appending(path: "events")
        let taskID = "task-1"
        let tabID = "tab-1"

        let process = Process()
        process.executableURL = captureScript
        process.environment = [
            "PLUME_EVENTS_DIR": eventsDir.path,
            "PLUME_TASK_ID": taskID,
            "PLUME_TAB_ID": tabID,
            "PATH": "/bin:/usr/bin",
        ]

        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = Pipe()

        try process.run()
        stdinPipe.fileHandleForWriting.write(Data(#"{"a":1}"#.utf8))
        try stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)

        let capturedFile = eventsDir.appending(path: taskID).appending(path: "\(tabID).statusline.json")
        let captured = try String(contentsOf: capturedFile, encoding: .utf8)
        #expect(captured == #"{"a":1}"#)
    }

    /// `settings.json` is global, so the script runs in every terminal. With
    /// no `PLUME_*` variables it must still hand the user their own statusline.
    @Test func chainsThroughWhenPlumeVariablesAreAbsent() throws {
        let result = try runCaptureScript(environment: [:])

        #expect(result.stdout == "CHAINED")
        #expect(result.status == 0)
        #expect(!result.wroteAnything)
    }

    /// A half-set environment behaves the same as no environment.
    @Test func chainsThroughWhenPlumeVariablesAreEmpty() throws {
        let result = try runCaptureScript(environment: [
            "PLUME_EVENTS_DIR": "",
            "PLUME_TASK_ID": "",
            "PLUME_TAB_ID": "",
        ])

        #expect(result.stdout == "CHAINED")
        #expect(result.status == 0)
        #expect(!result.wroteAnything)
    }

    /// Runs the generated script against a chain target that echoes `CHAINED`,
    /// with `environment` on top of a bare `PATH`. `wroteAnything` is measured
    /// before the scratch directory is torn down: it reports whether the script
    /// left behind anything beyond the two scripts the harness put there.
    private func runCaptureScript(
        environment: [String: String]
    ) throws -> (stdout: String, status: Int32, wroteAnything: Bool) {
        let scratch = makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let chainScript = scratch.appending(path: "fake_chain.sh")
        try #"""
        #!/bin/bash
        cat > /dev/null
        echo "CHAINED"
        """#.write(to: chainScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chainScript.path)

        let captureScript = scratch.appending(path: "capture.sh")
        try StatuslineCaptureWriter.script(chainCommand: chainScript.path)
            .write(to: captureScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: captureScript.path)

        let process = Process()
        process.executableURL = captureScript
        process.environment = environment.merging(["PATH": "/bin:/usr/bin"]) { current, _ in current }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe

        try process.run()
        stdinPipe.fileHandleForWriting.write(Data(#"{"cost":{"total_cost_usd":1.5}}"#.utf8))
        try stdinPipe.fileHandleForWriting.close()
        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        process.waitUntilExit()

        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: scratch.path)
            .filter { $0 != "fake_chain.sh" && $0 != "capture.sh" }

        return (
            stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            process.terminationStatus,
            !leftovers.isEmpty
        )
    }

    @Test func writeCreatesAnExecutableScriptAtTheExpectedPath() throws {
        let url = try StatuslineCaptureWriter.write(chainCommand: "echo hi")
        #expect(url == AppPaths.statuslineScriptFile)
        #expect(FileManager.default.isExecutableFile(atPath: url.path))
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("echo hi"))
    }
}
