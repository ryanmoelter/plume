import Foundation
import GhosttyTerminal
import SwiftUI
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

    /// The `font-family` the user's ghostty config resolves to, if any. Chat
    /// code prefers this over the bundled Cascadia Code NF, so the terminal
    /// and the chat's code spans read in the same face.
    private(set) var resolvedCodeFontFamily: String?

    /// The `font-weight` from the same config, applied to chat code so it
    /// matches the terminal's weight as well as its face. Nil when unset or
    /// unreadable, which leaves the face's regular weight.
    private(set) var resolvedCodeFontWeight: Font.Weight?

    /// The `font-style` from the same config: the name of a face within the
    /// family, which is how a variable font's named instances are reached.
    private(set) var resolvedCodeFontStyle: String?

    private init() {}

    /// Idempotent, so a repeated call (e.g. from a re-created scene) is safe.
    func start() {
        guard controller == nil else { return }

        loadedConfigPath = GhosttyConfigLoader.userConfigPath()

        var resolvedTheme = TerminalTheme()
        var configSource: TerminalController.ConfigSource = .none

        if let loadedConfigPath,
           let expanded = GhosttyConfigLoader.expandConfig(rootPath: loadedConfigPath) {
            resolvedThemeDefinitions = resolveThemeDefinitions(in: expanded)
            if let definitions = resolvedThemeDefinitions {
                resolvedTheme = TerminalTheme(
                    light: definitions.light?.toTerminalConfiguration() ?? .init(),
                    dark: definitions.dark?.toTerminalConfiguration() ?? .init()
                )
            }
            resolvedCodeFontFamily = GhosttyConfigLoader.resolvedFontFamily(in: expanded)
            resolvedCodeFontWeight = GhosttyConfigLoader.resolvedFontWeight(in: expanded)
            resolvedCodeFontStyle = GhosttyConfigLoader.resolvedFontStyle(in: expanded)

            // The config reaches libghostty as generated contents, not as a
            // file path, so the `theme` directive can be stripped first — see
            // GhosttyConfigLoader.flattenedContentsForGhostty.
            configSource = .generated(GhosttyConfigLoader.flattenedContentsForGhostty(expanded))
        }

        let controller = TerminalController(configSource: configSource, theme: resolvedTheme)
        self.controller = controller

        if let issue = controller.lastConfigurationIssue {
            startupError = issue
            Log.ghostty.error("Ghostty config issue: \(issue, privacy: .public)")
        }

        Log.ghostty.info("Ghostty runtime started (config: \(self.loadedConfigPath ?? "built-in defaults", privacy: .public))")
    }

    /// The wrapper never resolves a config file's `theme = name` directive
    /// itself — see GhosttyThemeResolver — so do it before creating the
    /// controller. Themes resolve against the directory of the file that
    /// declared the directive, which an including config's own directory need
    /// not be.
    private func resolveThemeDefinitions(
        in expanded: GhosttyConfigLoader.ExpandedConfig
    ) -> GhosttyThemeResolver.ResolvedDefinitions? {
        Self.resolveThemeDefinitions(
            in: expanded,
            bundledDefault: Self.bundledLumDefinitions
        )
    }

    /// Pure form of the above, taking the bundled default as a parameter so
    /// tests can exercise the fallback logic without touching `Bundle.main`.
    static func resolveThemeDefinitions(
        in expanded: GhosttyConfigLoader.ExpandedConfig,
        bundledDefault: GhosttyThemeResolver.ResolvedDefinitions?
    ) -> GhosttyThemeResolver.ResolvedDefinitions? {
        guard let themeSourcePath = GhosttyConfigLoader.winningThemeSourcePath(in: expanded) else {
            Log.ghostty.info("Ghostty config declares no theme; defaulting to the bundled Lum palette")
            return bundledDefault
        }

        guard let definitions = GhosttyThemeResolver.resolveDefinitions(
            configContents: expanded.rawContents,
            userThemesDirectory: GhosttyConfigLoader.themesDirectory(forConfigPath: themeSourcePath)
        ) else {
            Log.ghostty.error("Ghostty theme in \(themeSourcePath, privacy: .public) resolved to nothing; defaulting to the bundled Lum palette")
            return bundledDefault
        }

        Log.ghostty.info("Ghostty theme resolved from \(themeSourcePath, privacy: .public)")
        return definitions
    }

    /// Plume's default palette when the user's config names no theme (or
    /// names one that fails to resolve). Vendored from Ryan's own ghostty
    /// themes rather than referencing `~/dotfiles`, which would not exist on
    /// another machine.
    ///
    /// Nil only if the bundled files are missing or malformed, which would be
    /// a packaging bug — `Palette.init` still has its system-color fallback
    /// as a last resort.
    static let bundledLumDefinitions: GhosttyThemeResolver.ResolvedDefinitions? = {
        guard
            let dark = bundledThemeDefinition(name: "Lum dark"),
            let light = bundledThemeDefinition(name: "Lum light")
        else {
            Log.ghostty.error("Bundled Lum theme files are missing or malformed")
            return nil
        }
        return GhosttyThemeResolver.ResolvedDefinitions(light: light, dark: dark)
    }()

    private static func bundledThemeDefinition(name: String) -> GhosttyThemeDefinition? {
        guard
            let url = Bundle.main.url(forResource: name, withExtension: nil),
            let contents = try? String(contentsOf: url, encoding: .utf8)
        else {
            return nil
        }
        return GhosttyThemeResolver.parseThemeFile(name: name, contents: contents)
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
