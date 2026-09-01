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

    /// The factory is the seam that keeps a terminal alive across a task
    /// switch. Nothing else reports its absence, so a refactor that dropped
    /// it would regress silently.
    @Test func aSessionSuppliesAPlatformViewFactory() {
        let manager = SurfaceManager.shared
        let id = UUID()
        defer { manager.closeSession(for: id) }

        let session = manager.session(for: id, options: TerminalSurfaceOptions())

        #expect(session.state.makePlatformView != nil)
    }

    @Test func theFactoryReturnsTheSameViewEachTime() {
        let manager = SurfaceManager.shared
        let id = UUID()
        defer { manager.closeSession(for: id) }

        let session = manager.session(for: id, options: TerminalSurfaceOptions())
        let first = session.state.makePlatformView?()
        let second = session.state.makePlatformView?()

        #expect(first != nil)
        #expect(first === second)
    }

    /// The view owns the surface and its process, and the wrapper holds it
    /// weakly, so only the session's own reference keeps a terminal alive
    /// while no view presents it.
    @Test func theHostedViewOutlivesTheViewsThatPresentIt() {
        let manager = SurfaceManager.shared
        let id = UUID()
        defer { manager.closeSession(for: id) }

        let session = manager.session(for: id, options: TerminalSurfaceOptions())
        weak var hosted: TerminalView?
        // The pool would otherwise keep the view alive on its own, and the
        // test would pass without the session holding anything.
        autoreleasepool {
            hosted = session.state.makePlatformView?()
        }

        #expect(hosted != nil)
    }

    @Test func closingASessionReleasesItsHostedView() {
        let manager = SurfaceManager.shared
        let id = UUID()
        let session = manager.session(for: id, options: TerminalSurfaceOptions())
        weak var hosted: TerminalView?
        autoreleasepool {
            let view = session.state.makePlatformView?()
            hosted = view
            #expect(hosted != nil, "factory produced no view")
        }

        manager.closeSession(for: id)

        #expect(session.state.makePlatformView == nil, "factory still set")
        #expect(hosted == nil, "hosted view still alive")
    }

    /// Mirrors what `TabContentView.session(for:)` builds for a plain
    /// terminal tab: the task's working directory, plus a login shell so the
    /// terminal has the same environment as a normal one.
    @Test func plainTerminalTabGetsTheTasksWorkingDirectory() {
        let manager = SurfaceManager.shared
        let id = UUID()
        defer { manager.closeSession(for: id) }

        let session = manager.session(for: id, options: TerminalSurfaceOptions(
            workingDirectory: "/tmp/some-task-worktree",
            command: LoginShellCommand.loginShell(shell: "/bin/zsh")
        ))

        #expect(session.state.configuration.workingDirectory == "/tmp/some-task-worktree")
        #expect(session.state.configuration.command == "/bin/zsh -li")
    }
}
