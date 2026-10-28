import Darwin
import Foundation
import Testing
@testable import Plume

struct ToolHandoffTests {
    @Test(arguments: ["plume", "/Applications/Plume.app/Contents/MacOS/plume", "plume-notify", "wt"])
    func toolNamesHandOff(_ argv0: String) {
        #expect(ToolHandoff.handsOff(argv0: argv0))
    }

    @Test(arguments: ["Plume", "/Applications/Plume.app/Contents/MacOS/Plume", "PLUME", "plumes", "Plume.debug", ""])
    func appNamesDoNot(_ argv0: String) {
        #expect(!ToolHandoff.handsOff(argv0: argv0))
    }

    @Test func toolPathIsTheBundledHelper() {
        #expect(
            ToolHandoff.toolPath(executablePath: "/Applications/Plume.app/Contents/MacOS/Plume")
                == "/Applications/Plume.app/Contents/Helpers/plume"
        )
    }

    @Test func appLaunchedAsPlumeRunsTheTool() throws {
        let app = try #require(Bundle.main.executableURL)
        let directory = FileManager.default.temporaryDirectory.appending(path: "plume-handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appending(path: "plume")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        let outputURL = directory.appending(path: "out")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)

        let process = Process()
        process.executableURL = link
        process.arguments = ["help"]
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        let timedOut = exited.wait(timeout: .now() + 5) == .timedOut
        if timedOut {
            kill(process.processIdentifier, SIGKILL)
            exited.wait()
        }
        try output.close()
        let printed = try String(contentsOf: outputURL, encoding: .utf8)

        #expect(!timedOut, "the app launched as plume was still running after 5 s")
        #expect(process.terminationStatus == 0, "\(printed)")
        #expect(printed.contains(CLICommandLine.usage))
    }
}
