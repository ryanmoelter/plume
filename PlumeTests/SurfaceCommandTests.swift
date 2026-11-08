import AppKit
import Foundation
import GhosttyTerminal
import SwiftUI
import Testing
@testable import Plume

/// Locks down that a terminal actually runs the command it was given.
///
/// Two surfaces created back-to-back is the case that regressed: ghostty
/// borrows the command pointer past `ghostty_surface_new`, so the second
/// surface's creation used to clobber the first's string and both fell back to
/// a bare login shell. See `GhosttyCommandStorage`.
@MainActor
@Suite struct SurfaceCommandTests {
    @Test func backToBackSurfacesBothRunTheirOwnCommand() async throws {
        let first = Probe()
        let second = Probe()

        let running = try await runningCommands(containing: [first.marker, second.marker])
        #expect(running.contains(first.marker), "first surface did not run its command")
        #expect(running.contains(second.marker), "second surface did not run its command")

        first.close()
        second.close()
    }

    /// libghostty appends `Contents/MacOS` to a child's PATH, where `plume`
    /// finds the app's own `Plume` executable on a case-insensitive volume.
    @Test func surfacePathLeavesOutTheAppExecutableDirectory() async throws {
        let output = FileManager.default.temporaryDirectory.appending(path: "surface-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        let probe = Probe(script: "printf %s \"$PATH\" > \(output.path); sleep 30")
        defer { probe.close() }

        let deadline = ContinuousClock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: output.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let path = try String(contentsOf: output, encoding: .utf8)
        let executableDirectory = try #require(Bundle.main.executableURL).deletingLastPathComponent().path
        #expect(!path.split(separator: ":").contains { $0 == executableDirectory }, "PATH: \(path)")
        let processPath = try #require(ProcessInfo.processInfo.environment["PATH"])
        let helpersDirectory = CommandLineHelper.bundledURL?.deletingLastPathComponent()
        #expect(path == CommandLineHelper.appending(helpersDirectory, toPath: processPath))
    }

    /// One terminal, its surface and window, running `script` under a marker
    /// unique enough to find in the process list.
    @MainActor
    private struct Probe {
        let marker = "PlumeSurfaceCommandTest-\(UUID().uuidString)"
        let window: NSWindow
        let session: TerminalSession

        /// The `; true` keeps the shell alive: a lone simple command is
        /// `exec`ed in its place, and the marker in the shell's arguments goes
        /// with it.
        init(script: String = "sleep 30; true") {
            session = TerminalSession(
                id: UUID(),
                options: TerminalSurfaceOptions(
                    workingDirectory: NSTemporaryDirectory(),
                    command: "/bin/sh -c '\(script) # \(marker)'"
                )
            )

            let host = NSHostingView(rootView: TerminalTabView(session: session))
            host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
            window = NSWindow(
                contentRect: host.frame,
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.contentView = host
            window.orderFrontRegardless()
        }

        func close() {
            window.contentView = nil
            window.close()
        }
    }

    /// The process list once it names every marker, or at the deadline. A
    /// surface spawns when it is first laid out, which a loaded machine can
    /// take seconds to reach, so this waits on the list rather than a clock.
    private func runningCommands(containing markers: [String]) async throws -> String {
        let deadline = ContinuousClock.now + .seconds(20)
        while true {
            let running = try runningCommands()
            if markers.allSatisfy({ running.contains($0) }) || ContinuousClock.now >= deadline { return running }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    private func runningCommands() throws -> String {
        let listing = Process()
        listing.executableURL = URL(fileURLWithPath: "/bin/ps")
        listing.arguments = ["-Ao", "command="]
        let pipe = Pipe()
        listing.standardOutput = pipe
        try listing.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        listing.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test func oneSurfaceAloneRunsItsCommand() async throws {
        let only = Probe()
        let running = try await runningCommands(containing: [only.marker])
        #expect(running.contains(only.marker), "lone surface did not run its command")
        only.close()
    }
}
