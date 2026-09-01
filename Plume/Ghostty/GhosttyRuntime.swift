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

        // The wrapper never resolves a config file's `theme = name` directive
        // itself — see GhosttyThemeResolver — so do it before creating the
        // controller and pass the result in as an explicit TerminalTheme.
        var resolvedTheme = TerminalTheme()
        if let loadedConfigPath,
           let contents = try? String(contentsOfFile: loadedConfigPath, encoding: .utf8) {
            let themesDirectory = GhosttyConfigLoader.themesDirectory(forConfigPath: loadedConfigPath)
            if let theme = GhosttyThemeResolver.resolveTheme(
                configContents: contents,
                userThemesDirectory: themesDirectory
            ) {
                resolvedTheme = theme
            }
        }

        let controller = TerminalController(configFilePath: loadedConfigPath, theme: resolvedTheme)
        self.controller = controller

        if let issue = controller.lastConfigurationIssue {
            startupError = issue
            Log.ghostty.error("Ghostty config issue: \(issue, privacy: .public)")
        }

        Log.ghostty.info("Ghostty runtime started (config: \(self.loadedConfigPath ?? "built-in defaults", privacy: .public))")
    }

    /// The controller, starting the runtime if a surface is requested before
    /// `start()` ran. A terminal cannot exist without it, so failing here is
    /// a programmer error rather than something to recover from.
    func requireController() -> TerminalController {
        if controller == nil { start() }
        guard let controller else {
            fatalError("Ghostty runtime failed to start")
        }
        return controller
    }
}
