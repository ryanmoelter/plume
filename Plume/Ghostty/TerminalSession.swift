import Foundation
import GhosttyTerminal
import Observation
import os

/// One live terminal: its Ghostty surface state plus the exit tracking Plume
/// needs for status.
///
/// Lives as long as its tab, independent of whether the tab is on screen, so
/// hiding a tab never kills its process.
@MainActor
@Observable
final class TerminalSession {
    let id: UUID

    /// The wrapper's observable state, handed to `TerminalSurfaceView`.
    @ObservationIgnored let state: TerminalViewState

    private(set) var hasExited = false
    /// Nil until the process exits; true when it died while still running,
    /// which is how an abnormal exit is distinguished from a clean one.
    private(set) var exitedWhileProcessAlive: Bool?

    init(id: UUID, options: TerminalSurfaceOptions) {
        self.id = id
        state = TerminalViewState(controller: GhosttyRuntime.shared.requireController())
        state.configuration = options
        state.onClose = { [weak self] processAlive in
            self?.markExited(processAlive: processAlive)
        }
    }

    var title: String {
        state.title.isEmpty ? "Terminal" : state.title
    }

    /// OSC 7 working directory, when the shell reports one.
    var workingDirectory: String? {
        state.workingDirectory
    }

    private func markExited(processAlive: Bool) {
        hasExited = true
        exitedWhileProcessAlive = processAlive
        Log.ghostty.info("Surface \(self.id, privacy: .public) closed (processAlive: \(processAlive))")
    }
}
