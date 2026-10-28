import Darwin
import Foundation
import Testing
@testable import Plume

/// The bundled tool's pure-output commands exit promptly however they are
/// started: from a `.zshrc` inside a Plume tab, with the tab's tty on stdin and
/// a command substitution's pipe on stdout. The tool never links a UI
/// framework, so it can never become the app.
struct PlumeToolLaunchTests {
    private func tool() throws -> URL {
        try #require(CommandLineHelper.bundledURL, "the test host carries no Contents/Helpers/plume")
    }

    @Test func toolLinksNoUIFramework() throws {
        let otool = Process()
        otool.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
        otool.arguments = ["-L", try tool().path]
        let output = Pipe()
        otool.standardOutput = output
        try otool.run()
        let libraries = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        otool.waitUntilExit()
        #expect(otool.terminationStatus == 0)
        #expect(libraries.contains("libSystem"))
        for framework in ["SwiftUI.framework", "AppKit.framework", "Plume.debug.dylib"] {
            #expect(!libraries.contains(framework), "\(framework) in:\n\(libraries)")
        }
    }

    @Test(arguments: [["init", "zsh"], ["init", "zsh", "--aliases"], ["help"]])
    func pureOutputCommandExitsWithATtyOnStdin(_ arguments: [String]) throws {
        let link = FileManager.default.temporaryDirectory.appending(path: "plume-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: link) }
        let plume = link.appending(path: "plume")
        try FileManager.default.createSymbolicLink(at: plume, withDestinationURL: try tool())

        var primary: Int32 = -1
        var secondary: Int32 = -1
        try #require(openpty(&primary, &secondary, nil, nil, nil) == 0)
        let terminal = FileHandle(fileDescriptor: secondary, closeOnDealloc: true)
        defer { close(primary) }

        let process = Process()
        process.executableURL = plume
        process.arguments = arguments
        process.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin",
            "PLUME": "1",
            "TERM": "xterm-ghostty",
            "TERM_PROGRAM": "ghostty",
            "__CFBundleIdentifier": "com.ryanmoelter.Plume",
            "XPC_SERVICE_NAME": "0",
        ]
        let output = Pipe()
        process.standardInput = terminal
        process.standardOutput = output
        process.standardError = terminal

        let collected = Collected()
        let drained = DispatchSemaphore(value: 0)
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        DispatchQueue.global().async {
            collected.append(output.fileHandleForReading.readDataToEndOfFile())
            drained.signal()
        }

        let timedOut = exited.wait(timeout: .now() + 5) == .timedOut
        if timedOut {
            kill(process.processIdentifier, SIGKILL)
            exited.wait()
        }
        drained.wait()

        #expect(!timedOut, "plume \(arguments.joined(separator: " ")) still running after 5 s")
        #expect(process.terminationStatus == 0)
        #expect(!collected.data.isEmpty)
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()

        var data: Data { lock.withLock { bytes } }

        func append(_ chunk: Data) {
            lock.withLock { bytes.append(chunk) }
        }
    }
}
