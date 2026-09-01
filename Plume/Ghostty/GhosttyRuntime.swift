import Foundation
import GhosttyTerminal
import Observation
import os // Logger string interpolation

/// Owns the process-wide Ghostty app handle.
///
/// One controller per process, many surfaces — matching Ghostty.app. Every
/// terminal surface in Plume is created through this runtime, and all
/// Ghostty-specific types stay behind this folder.
@MainActor
@Observable
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var controller: TerminalController?
    private(set) var startupError: String?

    /// Path of the user's ghostty config that was loaded, if any. Nil means
    /// the wrapper's built-in defaults are in use.
    private(set) var loadedConfigPath: String?

    private init() {}

    /// Idempotent, so a repeated call (e.g. from a re-created scene) is safe.
    func start() {
        guard controller == nil else { return }

        loadedConfigPath = GhosttyConfigLoader.userConfigPath()
        let controller = TerminalController(configFilePath: loadedConfigPath)
        self.controller = controller

        if let issue = controller.lastConfigurationIssue {
            startupError = issue
            Log.ghostty.error("Ghostty config issue: \(issue, privacy: .public)")
        }

        Log.ghostty.info("Ghostty runtime started (config: \(self.loadedConfigPath ?? "built-in defaults", privacy: .public))")
    }
}
