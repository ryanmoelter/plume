import Testing
import Foundation
import GhosttyTerminal
@testable import Plume

/// Exercises real Ghostty surfaces, so each test spawns an actual PTY.
@MainActor
struct SurfaceManagerTests {
    @Test func sessionIsReusedForTheSameTab() {
        let manager = SurfaceManager.shared
        let id = UUID()
        defer { manager.closeSession(for: id) }

        let first = manager.session(for: id, options: TerminalSurfaceOptions())
        let second = manager.session(for: id, options: TerminalSurfaceOptions())

        #expect(first === second)
    }

    @Test func distinctTabsGetDistinctSessions() {
        let manager = SurfaceManager.shared
        let (a, b) = (UUID(), UUID())
        defer { manager.closeSession(for: a); manager.closeSession(for: b) }

        let first = manager.session(for: a, options: TerminalSurfaceOptions())
        let second = manager.session(for: b, options: TerminalSurfaceOptions())

        #expect(first !== second)
        #expect(manager.existingSession(for: a) === first)
        #expect(manager.existingSession(for: b) === second)
    }

    /// Options describe surface identity; re-requesting must not silently
    /// rebuild the surface and drop the running process.
    @Test func changedOptionsDoNotReplaceALiveSession() {
        let manager = SurfaceManager.shared
        let id = UUID()
        defer { manager.closeSession(for: id) }

        let original = manager.session(for: id, options: TerminalSurfaceOptions(workingDirectory: "/tmp"))
        let again = manager.session(for: id, options: TerminalSurfaceOptions(workingDirectory: "/usr"))

        #expect(original === again)
        #expect(again.state.configuration.workingDirectory == "/tmp")
    }

    @Test func closingRemovesTheSession() {
        let manager = SurfaceManager.shared
        let id = UUID()

        _ = manager.session(for: id, options: TerminalSurfaceOptions())
        #expect(manager.existingSession(for: id) != nil)

        manager.closeSession(for: id)
        #expect(manager.existingSession(for: id) == nil)
    }

    @Test func closingAnUnknownTabIsHarmless() {
        SurfaceManager.shared.closeSession(for: UUID())
    }

    @Test func newSessionHasNotExited() {
        let manager = SurfaceManager.shared
        let id = UUID()
        defer { manager.closeSession(for: id) }

        let session = manager.session(for: id, options: TerminalSurfaceOptions())

        #expect(!session.hasExited)
        #expect(session.exitedWhileProcessAlive == nil)
    }

    @Test func sessionCarriesItsLaunchOptions() {
        let manager = SurfaceManager.shared
        let id = UUID()
        defer { manager.closeSession(for: id) }

        let session = manager.session(for: id, options: TerminalSurfaceOptions(
            workingDirectory: "/tmp",
            envVars: ["PLUME_TAB_ID": id.uuidString],
            command: "/bin/echo hello"
        ))

        #expect(session.state.configuration.workingDirectory == "/tmp")
        #expect(session.state.configuration.envVars["PLUME_TAB_ID"] == id.uuidString)
        #expect(session.state.configuration.command == "/bin/echo hello")
    }
}
