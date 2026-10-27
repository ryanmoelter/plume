import Foundation

/// The settings `wt` and `stack` share for one repository, as Settings ▸
/// Projects stores them. Every field is optional: nil means "not set here",
/// so the defaults row, then a derived fallback, decides.
///
/// An explicit empty `branchPrefix` is a value, not an absence: it means "no
/// prefix", and wins over the defaults row and the `user.email` fallback.
nonisolated struct ProjectSettings: Codable, Equatable, Sendable {
    /// Default: `origin/HEAD`, else `main`.
    var baseBranch: String?
    /// Default: the local part of `user.email`, plus `/`.
    var branchPrefix: String?
    /// Default: sniffed from the origin URL.
    var forge: ForgeKind?
    /// Default: `automatic`.
    var nerdFont: NerdFontMode?
    /// Worktree folder names (basenames, never branches) that refuse delete,
    /// rename and foreground. Default: none.
    var protectedWorktrees: [String]?
    /// CI checks whose perpetual pending shouldn't mask the rollup. Default:
    /// none.
    var ignoredPendingChecks: [String]?

    init(
        baseBranch: String? = nil,
        branchPrefix: String? = nil,
        forge: ForgeKind? = nil,
        nerdFont: NerdFontMode? = nil,
        protectedWorktrees: [String]? = nil,
        ignoredPendingChecks: [String]? = nil
    ) {
        self.baseBranch = baseBranch
        self.branchPrefix = branchPrefix
        self.forge = forge
        self.nerdFont = nerdFont
        self.protectedWorktrees = protectedWorktrees
        self.ignoredPendingChecks = ignoredPendingChecks
    }

    /// These settings over `fallback`: each non-nil field here wins, and a
    /// list replaces the fallback's list rather than adding to it.
    func overriding(_ fallback: ProjectSettings) -> ProjectSettings {
        ProjectSettings(
            baseBranch: baseBranch ?? fallback.baseBranch,
            branchPrefix: branchPrefix ?? fallback.branchPrefix,
            forge: forge ?? fallback.forge,
            nerdFont: nerdFont ?? fallback.nerdFont,
            protectedWorktrees: protectedWorktrees ?? fallback.protectedWorktrees,
            ignoredPendingChecks: ignoredPendingChecks ?? fallback.ignoredPendingChecks
        )
    }
}

/// Every repository's settings plus the defaults row, keyed by the
/// repository's root path: the main worktree, or the folder holding `.bare`.
nonisolated struct ProjectsConfiguration: Codable, Equatable, Sendable {
    var defaults: ProjectSettings
    var repositories: [String: ProjectSettings]

    init(defaults: ProjectSettings = ProjectSettings(), repositories: [String: ProjectSettings] = [:]) {
        self.defaults = defaults
        self.repositories = repositories
    }

    /// The UserDefaults key, in the app's domain, holding this as JSON.
    static let userDefaultsKey = "projectsConfiguration"

    /// The repository's own settings over the defaults row. Fallbacks that
    /// need git (`user.email`, `origin/HEAD`, the origin URL) are applied by
    /// the caller.
    func settings(forRepository root: String) -> ProjectSettings {
        (repositories[root] ?? ProjectSettings()).overriding(defaults)
    }
}

nonisolated protocol ProjectSettingsSource {
    func load() -> ProjectsConfiguration
}

/// Reads the app's own UserDefaults domain, so the tool sees Settings ▸
/// Projects with the app closed. A debug or worktree build exports its own
/// bundle ID in `PLUME_BUNDLE_ID`; outside Plume the release ID applies.
nonisolated struct UserDefaultsProjectSettingsSource: ProjectSettingsSource {
    static let bundleIDEnvironmentKey = "PLUME_BUNDLE_ID"
    static let releaseBundleID = "com.ryanmoelter.Plume"

    var suiteName: String

    init(suiteName: String) {
        self.suiteName = suiteName
    }

    init(environment: [String: String]) {
        let bundleID = environment[Self.bundleIDEnvironmentKey] ?? ""
        self.init(suiteName: bundleID.isEmpty ? Self.releaseBundleID : bundleID)
    }

    /// UserDefaults refuses a suite named for the running app's own bundle,
    /// where the app keeps its values in its standard defaults.
    private var defaults: UserDefaults? {
        suiteName == Bundle.main.bundleIdentifier ? .standard : UserDefaults(suiteName: suiteName)
    }

    /// An empty configuration when nothing is stored or it doesn't decode.
    func load() -> ProjectsConfiguration {
        guard let data = defaults?.data(forKey: ProjectsConfiguration.userDefaultsKey),
              let configuration = try? JSONDecoder().decode(ProjectsConfiguration.self, from: data)
        else { return ProjectsConfiguration() }
        return configuration
    }
}
