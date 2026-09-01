import Foundation
import GhosttyTerminal
import Observation
import os

/// Owns every live terminal, keyed by tab ID.
///
/// Sessions outlive the views that show them: SwiftUI mounts and unmounts
/// `TerminalTabView` freely as tabs and tasks change, and the process keeps
/// running because it belongs here instead. Nothing in this class is
/// persisted — SwiftData holds the tab, this holds the running terminal.
@MainActor
@Observable
final class SurfaceManager {
    static let shared = SurfaceManager()

    private var sessions: [UUID: TerminalSession] = [:]

    private init() {}

    /// The session for a tab, created on first request.
    ///
    /// `options` apply only when the session is created; changing them later
    /// would mean a new surface, discarding scrollback and killing the
    /// process, so an existing session is returned untouched.
    func session(for id: UUID, options: @autoclosure () -> TerminalSurfaceOptions) -> TerminalSession {
        if let existing = sessions[id] {
            if existing.state.configuration.command != options().command {
                Log.ghostty.error(
                    "Tab \(id, privacy: .public) already has a surface running a different command; the new one is ignored"
                )
            }
            return existing
        }

        let session = TerminalSession(id: id, options: options())
        sessions[id] = session
        Log.ghostty.info("Created surface for tab \(id, privacy: .public)")
        return session
    }

    func existingSession(for id: UUID) -> TerminalSession? {
        sessions[id]
    }

    var activeSessionCount: Int {
        sessions.count
    }

    /// Tears down a tab's terminal. Call when the tab or its task is deleted,
    /// never merely because the tab scrolled out of view.
    func closeSession(for id: UUID) {
        guard sessions.removeValue(forKey: id) != nil else { return }
        Log.ghostty.info("Closed surface for tab \(id, privacy: .public)")
    }

    func closeAll() {
        sessions.removeAll()
    }
}
