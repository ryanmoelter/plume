import Foundation
import os
import SwiftData

/// Moves the settings the Python `wt` and `stack` tools kept in git config
/// into Settings ▸ Projects, once. `docs/wt-port.md` lists the keys.
nonisolated enum GitConfigSettingsImport {
    /// Set once an import has merged, so it never runs again.
    static let completedDefaultsKey = "importedGitConfigProjectSettings"

    static let sharedSection = "ryanmoelter-cli-tools"

    /// Each field's keys in the order they win. The Python tools let their
    /// own section beat the shared one; Plume has one value for both tools,
    /// so `wt` (the tool Projects drives) wins and `stack` fills only what
    /// neither `wt` nor the shared section sets.
    private static func chain(_ name: String, stack: Bool = true) -> [String] {
        ["wt.\(name)", "\(sharedSection).\(name)"] + (stack ? ["stack.\(name)"] : [])
    }

    /// `git config --list -z` as every value of each key, in config order.
    /// git prints section and variable names lowercased, so lookups are too.
    /// A key with no `=` reads as an empty value, as `git config --get`
    /// reports it.
    static func parseList(_ output: String) -> [String: [String]] {
        var values: [String: [String]] = [:]
        for entry in output.split(separator: "\0", omittingEmptySubsequences: true) {
            let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let key = parts[0].lowercased()
            values[key, default: []].append(parts.count > 1 ? String(parts[1]) : "")
        }
        return values
    }

    /// What the Python tools resolved from one config view. A single-valued
    /// key takes its last value, as `git config --get` does; a list comes
    /// from the first key in its chain that has any values.
    static func settings(from values: [String: [String]]) -> ProjectSettings {
        func first(_ keys: [String]) -> String? {
            keys.lazy.compactMap { values[$0.lowercased()]?.last }.first
        }
        func list(_ keys: [String]) -> [String]? {
            keys.lazy
                .map { (values[$0.lowercased()] ?? []).filter { !$0.isEmpty } }
                .first { !$0.isEmpty }
        }
        // An empty base branch or forge made Python fall back, so neither
        // is a value; an empty prefix meant "no prefix", so it is.
        let baseBranch = first(chain("baseBranch")).flatMap { $0.isEmpty ? nil : $0 }
        let forge = first(chain("forge")).flatMap { ForgeKind(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) }
        let nerdFont = first(chain("nerdFont")).map {
            ["true", "yes", "on", "1"].contains($0.trimmingCharacters(in: .whitespaces).lowercased())
        }
        return ProjectSettings(
            baseBranch: baseBranch,
            branchPrefix: first(chain("branchPrefix")),
            forge: forge,
            nerdFont: nerdFont,
            protectedWorktrees: list(["wt.protected", "\(sharedSection).protectedWorktrees"]),
            ignoredPendingChecks: list(chain("ignoredPendingChecks"))
        )
    }

    /// The fields where a repository's merged config resolves differently
    /// from the global one: the only ones its Projects row needs.
    static func repositoryOverrides(repository: ProjectSettings, global: ProjectSettings) -> ProjectSettings {
        func differing<T: Equatable>(_ value: T?, _ inherited: T?) -> T? {
            value == inherited ? nil : value
        }
        return ProjectSettings(
            baseBranch: differing(repository.baseBranch, global.baseBranch),
            branchPrefix: differing(repository.branchPrefix, global.branchPrefix),
            forge: differing(repository.forge, global.forge),
            nerdFont: differing(repository.nerdFont, global.nerdFont),
            protectedWorktrees: differing(repository.protectedWorktrees, global.protectedWorktrees),
            ignoredPendingChecks: differing(repository.ignoredPendingChecks, global.ignoredPendingChecks)
        )
    }

    /// `imported` under `existing`: a field already set in Projects keeps
    /// its value, and a repository that imports nothing gets no row.
    static func merging(_ imported: ProjectsConfiguration, into existing: ProjectsConfiguration) -> ProjectsConfiguration {
        var merged = existing
        merged.defaults = existing.defaults.overriding(imported.defaults)
        for (root, settings) in imported.repositories where settings != ProjectSettings() {
            merged.repositories[root] = (existing.repositories[root] ?? ProjectSettings()).overriding(settings)
        }
        return merged
    }

    // MARK: Reading git

    /// Blocks on `git`, so call it off the main actor. `repositoryPaths` are
    /// tasks' `repoPath`s or project roots; each maps to its Projects key
    /// through `ProjectRoot`.
    static func read(repositoryPaths: [String]) -> ProjectsConfiguration {
        // `/` is no repository, so this is the system and global config only.
        let global = settings(from: parseList(configList(in: "/")))
        let roots = Set(repositoryPaths.compactMap(ProjectRoot.containing))
        var repositories: [String: ProjectSettings] = [:]
        for root in roots {
            let directory = ProjectRoot.repositoryDirectory(forRoot: root)
            let merged = settings(from: parseList(configList(in: directory)))
            repositories[root] = repositoryOverrides(repository: merged, global: global)
        }
        return ProjectsConfiguration(defaults: global, repositories: repositories)
    }

    private static func configList(in directory: String) -> String {
        guard let result = try? CLIProcess.run(["git", "-C", directory, "config", "--list", "-z"], check: false),
              result.status == 0
        else { return "" }
        return result.stdout
    }
}

extension GitConfigSettingsImport {
    /// Runs the import once per install, at launch: before the New Worktree
    /// sheet or a `wt` from a Plume tab could want the values.
    @MainActor
    static func runOnce(modelContext: ModelContext, settings: AppSettings = .shared, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: completedDefaultsKey) else { return }
        let taskPaths = ((try? modelContext.fetch(FetchDescriptor<WorkTask>())) ?? []).compactMap(\.repoPath)
        let paths = Array(Set(taskPaths).union(settings.projectsConfiguration.repositories.keys))
        Task {
            let imported = await Task.detached { read(repositoryPaths: paths) }.value
            settings.projectsConfiguration = merging(imported, into: settings.projectsConfiguration)
            defaults.set(true, forKey: completedDefaultsKey)
            Log.app.info("Imported git config settings for \(imported.repositories.count) repositories")
        }
    }
}
