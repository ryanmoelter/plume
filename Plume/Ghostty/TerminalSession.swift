import AppKit
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

    /// Viewport geometry, mirrored for the same reason as `title`. This is
    /// the only readable evidence that a remount kept the surface: scroll
    /// position lives in ghostty's grid, so an unchanged offset across a
    /// task switch is what proves the surface was never rebuilt.
    private(set) var scrollbar: TerminalScrollbar?

    /// The platform view presenting this session, held strongly.
    ///
    /// The view owns the Ghostty surface, which owns the PTY child, and
    /// `TerminalViewState.attachedView` is weak. Without this reference the
    /// view dies whenever SwiftUI unmounts it — on a task switch, say — and
    /// takes the running process with it. Holding it here is what makes
    /// "views never destroy surfaces" true.
    @ObservationIgnored private var hostedView: TerminalView?

    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

    init(id: UUID, options: TerminalSurfaceOptions) {
        self.id = id
        state = TerminalViewState(controller: GhosttyRuntime.shared.requireController())
        state.configuration = options
        state.onClose = { [weak self] processAlive in
            self?.markExited(processAlive: processAlive)
        }
        // Read once, when the surface view is first made, so it must be set
        // before anything mounts this session.
        state.makePlatformView = { [weak self] in
            guard let self else { return TerminalView(frame: .zero) }
            return hostView()
        }

        state.$title
            .sink { [weak self] in self?.title = $0 }
            .store(in: &cancellables)
        state.$workingDirectory
            .sink { [weak self] in self?.workingDirectory = $0 }
            .store(in: &cancellables)
        state.$scrollbar
            .sink { [weak self] in self?.scrollbar = $0 }
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

    /// Sends text and then presses Enter, for a composer outside the
    /// terminal.
    ///
    /// Two calls rather than a trailing `\r` in the text: the wrapper's text
    /// path is a *paste*, so a program with bracketed paste enabled receives
    /// the carriage return as content and leaves it sitting in the edit line
    /// unsent. Enter has to arrive as a keystroke.
    func submit(text: String) {
        guard !text.isEmpty else { return }
        state.paste(text: text)
        state.sendKey(.enter)
    }

    /// Hands back the same view on every remount, so the surface it owns
    /// survives. A reused view may still be parented if SwiftUI mounted the
    /// new host before unmounting the old one; AppKit would reparent it
    /// anyway, and detaching first keeps the window transitions in order.
    private func hostView() -> TerminalView {
        if let hostedView {
            hostedView.removeFromSuperview()
            Log.ghostty.debug("Reused hosted view for tab \(self.id, privacy: .public)")
            return hostedView
        }
        let view = TerminalView(frame: .zero)
        hostedView = view
        Log.ghostty.info("Created hosted view for tab \(self.id, privacy: .public)")
        return view
    }

    /// Releases the view, and so the surface and its process. Only
    /// `SurfaceManager` calls this, when the tab is actually closed.
    func releaseHostedView() {
        state.makePlatformView = nil
        hostedView?.removeFromSuperview()
        hostedView = nil
    }

    private func markExited(processAlive: Bool) {
        hasExited = true
        exitedWhileProcessAlive = processAlive
        Log.ghostty.info("Surface \(self.id, privacy: .public) closed (processAlive: \(processAlive))")
    }
}
