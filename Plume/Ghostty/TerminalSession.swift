import Combine
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

    /// `TerminalViewState` is a Combine `ObservableObject`, whose `@Published`
    /// changes `@Observable` cannot see. Mirroring them into stored properties
    /// here is what lets SwiftUI views track the title without each one
    /// holding the state as an `@ObservedObject`.
    private(set) var title = ""
    private(set) var workingDirectory: String?

    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

    init(id: UUID, options: TerminalSurfaceOptions) {
        self.id = id
        state = TerminalViewState(controller: GhosttyRuntime.shared.requireController())
        state.configuration = options
        state.onClose = { [weak self] processAlive in
            self?.markExited(processAlive: processAlive)
        }

        state.$title
            .sink { [weak self] in self?.title = $0 }
            .store(in: &cancellables)
        state.$workingDirectory
            .sink { [weak self] in self?.workingDirectory = $0 }
            .store(in: &cancellables)
    }

    var displayTitle: String {
        title.isEmpty ? "Terminal" : title
    }

    /// PID of the pty's foreground process group, for correlating this
    /// surface with the system process list. Nil until a view presents the
    /// surface and a process exists.
    var foregroundPid: pid_t? {
        state.attachedPlatformView?.foregroundPid
    }

    private func markExited(processAlive: Bool) {
        hasExited = true
        exitedWhileProcessAlive = processAlive
        Log.ghostty.info("Surface \(self.id, privacy: .public) closed (processAlive: \(processAlive))")
    }
}
