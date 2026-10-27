import Foundation
import Testing

@testable import Plume

/// Settings ▸ Projects writes a project's settings under `ProjectRoot`, and
/// `plume wt` finds them from any checkout of that repository: the main
/// worktree, a linked one, or a worktree of a bare layout. Git runs off the
/// main actor, which the socket tests running alongside need free.
@MainActor
struct ProjectSettingsRoundTripTests {
    private let scratch = FileManager.default.temporaryDirectory
        .appending(path: "plume-projects-\(UUID().uuidString)").path
    private let suite = "plume-projects-\(UUID().uuidString)"

    nonisolated private static func makeRepository(at path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try GitRunner.run(["init", "-b", "main"], in: path)
        try GitRunner.run(["config", "user.email", "test@example.com"], in: path)
        try GitRunner.run(["config", "user.name", "Test"], in: path)
        try GitRunner.run(["config", "commit.gpgsign", "false"], in: path)
        try "hello\n".write(toFile: "\(path)/README.md", atomically: true, encoding: .utf8)
        try GitRunner.run(["add", "."], in: path)
        try GitRunner.run(["commit", "-m", "init"], in: path)
    }

    nonisolated private static func settingsTheToolReads(from directory: String, suite: String) throws -> ProjectSettings {
        try WorktreeContext.detect(
            git: ProcessWorktreeGit(workingDirectory: directory),
            settingsSource: UserDefaultsProjectSettingsSource(suiteName: suite),
            console: BufferConsole(),
            environment: [:]
        ).settings
    }

    /// Writes through `AppSettings` under the root found from `checkout`,
    /// then reads as the tool does from `directory`.
    private func roundTrip(savingFrom checkout: String, readingFrom directory: String) async throws -> ProjectSettings {
        let root = try #require(await Task.detached { ProjectRoot.containing(checkout) }.value)
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = AppSettings(defaults: defaults, domainName: suite)
        app.projectsConfiguration.defaults.nerdFont = true
        app.projectsConfiguration.repositories = [root: ProjectSettings(branchPrefix: "", protectedWorktrees: ["keep"])]
        let suite = suite
        return try await Task.detached { try Self.settingsTheToolReads(from: directory, suite: suite) }.value
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(atPath: scratch)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    @Test func theToolReadsWhatTheAppWroteFromEveryCheckout() async throws {
        defer { cleanUp() }
        let repository = "\(scratch)/repo"
        let worktree = "\(repository)/.plume/worktrees/feature"
        try await Task.detached {
            try Self.makeRepository(at: repository)
            try GitRunner.run(["worktree", "add", "-b", "feature", worktree], in: repository)
        }.value

        for (saving, reading) in [(repository, worktree), (worktree, repository)] {
            let settings = try await roundTrip(savingFrom: saving, readingFrom: reading)
            #expect(settings.branchPrefix == "")
            #expect(settings.protectedWorktrees == ["keep"])
            #expect(settings.nerdFont == true)
        }
    }

    @Test func aBareLayoutIsKeyedByTheFolderHoldingBare() async throws {
        defer { cleanUp() }
        let source = "\(scratch)/source"
        let layout = "\(scratch)/layout"
        let worktree = "\(layout)/feature"
        try await Task.detached {
            try Self.makeRepository(at: source)
            try FileManager.default.createDirectory(atPath: layout, withIntermediateDirectories: true)
            try GitRunner.run(["clone", "--bare", source, "\(layout)/.bare"], in: layout)
            try GitRunner.run(["worktree", "add", "-b", "feature", worktree], in: "\(layout)/.bare")
        }.value

        for saving in [layout, "\(layout)/.bare"] {
            let settings = try await roundTrip(savingFrom: saving, readingFrom: worktree)
            #expect(settings.protectedWorktrees == ["keep"])
        }
    }

    @Test func aFolderOutsideGitHasNoProjectRoot() async throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        let scratch = scratch
        #expect(await Task.detached { ProjectRoot.containing(scratch) }.value == nil)
    }

    @Test func theToolReadsTheIntegrationsIgnoredChecksTheAppWrote() throws {
        defer { cleanUp() }
        let defaults = try #require(UserDefaults(suiteName: suite))
        AppSettings(defaults: defaults, domainName: suite).ignoredPendingChecks = ["flaky-lint"]
        #expect(UserDefaultsProjectSettingsSource(suiteName: suite).loadPlumeIgnoredPendingChecks() == ["flaky-lint"])
    }

    @Test func aStoredConfigurationSurvivesAReload() throws {
        defer { cleanUp() }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let configuration = ProjectsConfiguration(
            defaults: ProjectSettings(baseBranch: "develop", forge: .gitlab),
            repositories: ["/r": ProjectSettings(nerdFont: false, ignoredPendingChecks: ["slow"])]
        )
        AppSettings(defaults: defaults, domainName: suite).projectsConfiguration = configuration

        #expect(AppSettings(defaults: defaults, domainName: suite).projectsConfiguration == configuration)
        #expect(UserDefaultsProjectSettingsSource(suiteName: suite).load() == configuration)
    }
}
