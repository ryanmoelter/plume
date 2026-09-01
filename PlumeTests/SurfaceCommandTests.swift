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

        try await Task.sleep(for: .seconds(4))

        let running = try runningCommands()
        #expect(running.contains(first.marker), "first surface did not run its command")
        #expect(running.contains(second.marker), "second surface did not run its command")

        first.close()
        second.close()
    }

    /// One terminal, its surface and window, running `sleep` under a marker
    /// unique enough to find in the process list.
    @MainActor
    private struct Probe {
        let marker = "PlumeSurfaceCommandTest-\(UUID().uuidString)"
        let window: NSWindow
        let session: TerminalSession

        init() {
            session = TerminalSession(
                id: UUID(),
                options: TerminalSurfaceOptions(
                    workingDirectory: NSTemporaryDirectory(),
                    command: "/bin/sh -c 'sleep 30 # \(marker)'"
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
        try await Task.sleep(for: .seconds(4))
        #expect(try runningCommands().contains(only.marker), "lone surface did not run its command")
        only.close()
    }
}
