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

    @Test func writeCreatesAnExecutableScriptAtTheExpectedPath() throws {
        let url = try StatuslineCaptureWriter.write(chainCommand: "echo hi")
        #expect(url == AppPaths.statuslineScriptFile)
        #expect(FileManager.default.isExecutableFile(atPath: url.path))
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("echo hi"))
    }
}
