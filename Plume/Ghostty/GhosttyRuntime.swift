import Foundation
import GhosttyTerminal
import GhosttyTheme
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

    /// The same theme resolution passed to the controller, kept in its raw
    /// form so SwiftUI chrome can read the background/foreground hex —
    /// `TerminalConfiguration` (what the controller takes) exposes no
    /// accessors to get them back out.
    private(set) var resolvedThemeDefinitions: GhosttyThemeResolver.ResolvedDefinitions?

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
            resolvedThemeDefinitions = GhosttyThemeResolver.resolveDefinitions(
                configContents: contents,
                userThemesDirectory: themesDirectory
            )
            if let theme = resolvedThemeDefinitions.map({
                TerminalTheme(
                    light: $0.light?.toTerminalConfiguration() ?? .init(),
                    dark: $0.dark?.toTerminalConfiguration() ?? .init()
                )
            }) {
                resolvedTheme = theme
            }
        }

        // The config reaches libghostty as generated contents, not as a file
        // path, so the `theme` directive can be stripped first — see
        // GhosttyConfigLoader.configContentsForGhostty.
        let configSource: TerminalController.ConfigSource = loadedConfigPath
            .flatMap { GhosttyConfigLoader.configContentsForGhostty(atPath: $0) }
            .map { .generated($0) } ?? .none

        let controller = TerminalController(configSource: configSource, theme: resolvedTheme)
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
