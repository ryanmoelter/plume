import Foundation
import Testing
@testable import Plume

/// How Settings ▸ Projects resolves for one repository: the repository's
/// own value wins, an explicit empty string is a value, and a list replaces
/// the defaults' list. Replaces the git-config chain tests of
/// `test_shared_config.py`.
struct ProjectSettingsTests {
    private func resolve(_ repository: ProjectSettings?, defaults: ProjectSettings = ProjectSettings()) -> ProjectSettings {
        var repositories: [String: ProjectSettings] = [:]
        repositories["/repo"] = repository
        return ProjectsConfiguration(defaults: defaults, repositories: repositories).settings(forRepository: "/repo")
    }

    @Test func theRepositorysValueWinsOverTheDefaults() {
        #expect(resolve(ProjectSettings(baseBranch: "tool"), defaults: ProjectSettings(baseBranch: "shared")).baseBranch == "tool")
    }

    @Test func theDefaultsApplyWhereTheRepositoryIsUnset() {
        #expect(resolve(ProjectSettings(), defaults: ProjectSettings(baseBranch: "shared")).baseBranch == "shared")
    }

    @Test func anUnknownRepositoryGetsTheDefaults() {
        #expect(resolve(nil, defaults: ProjectSettings(baseBranch: "shared", nerdFont: true))
            == ProjectSettings(baseBranch: "shared", nerdFont: true))
    }

    @Test func neitherSetStaysNil() {
        #expect(resolve(ProjectSettings()).baseBranch == nil)
    }

    /// An empty prefix means "no prefix" and must not fall through to the
    /// defaults.
    @Test func anExplicitEmptyPrefixBeatsTheDefaults() {
        #expect(resolve(ProjectSettings(branchPrefix: ""), defaults: ProjectSettings(branchPrefix: "me/")).branchPrefix == "")
    }

    @Test func aListComesFromTheDefaults() {
        #expect(resolve(ProjectSettings(), defaults: ProjectSettings(ignoredPendingChecks: ["a", "b"])).ignoredPendingChecks == ["a", "b"])
    }

    @Test func theRepositorysListReplacesTheDefaultsList() {
        let resolved = resolve(ProjectSettings(ignoredPendingChecks: ["only"]), defaults: ProjectSettings(ignoredPendingChecks: ["a", "b"]))
        #expect(resolved.ignoredPendingChecks == ["only"])
    }

    @Test func theRepositoryCanTurnOffADefaultOptIn() {
        #expect(resolve(ProjectSettings(nerdFont: false), defaults: ProjectSettings(nerdFont: true)).nerdFont == false)
    }

    @Test func overridingKeepsEveryFieldIndependently() {
        let mine = ProjectSettings(branchPrefix: "", forge: .gitlab)
        let fallback = ProjectSettings(
            baseBranch: "main", branchPrefix: "me/", forge: .github, nerdFont: true,
            protectedWorktrees: ["keep"], ignoredPendingChecks: ["slow"]
        )
        #expect(mine.overriding(fallback) == ProjectSettings(
            baseBranch: "main", branchPrefix: "", forge: .gitlab, nerdFont: true,
            protectedWorktrees: ["keep"], ignoredPendingChecks: ["slow"]
        ))
    }

    // MARK: storage

    private func withSuite(_ body: (String, UserDefaults) throws -> Void) throws {
        let suite = "com.ryanmoelter.Plume.tests.projects-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(suite, defaults)
    }

    /// The app stores the configuration as JSON data under one key, which the
    /// tool reads from the app's domain.
    @Test func theUserDefaultsSourceReadsWhatTheAppStored() throws {
        let configuration = ProjectsConfiguration(
            defaults: ProjectSettings(nerdFont: true),
            repositories: ["/repo": ProjectSettings(baseBranch: "staging", branchPrefix: "", forge: .gitlab)]
        )
        try withSuite { suite, defaults in
            defaults.set(try JSONEncoder().encode(configuration), forKey: ProjectsConfiguration.userDefaultsKey)
            #expect(UserDefaultsProjectSettingsSource(suiteName: suite).load() == configuration)
        }
    }

    @Test func nothingStoredIsAnEmptyConfiguration() throws {
        try withSuite { suite, _ in
            #expect(UserDefaultsProjectSettingsSource(suiteName: suite).load() == ProjectsConfiguration())
        }
    }

    @Test func undecodableDataIsAnEmptyConfiguration() throws {
        try withSuite { suite, defaults in
            defaults.set(Data("not json".utf8), forKey: ProjectsConfiguration.userDefaultsKey)
            #expect(UserDefaultsProjectSettingsSource(suiteName: suite).load() == ProjectsConfiguration())
        }
    }

    @Test func theBundleIDComesFromTheEnvironment() {
        let source = UserDefaultsProjectSettingsSource(environment: [UserDefaultsProjectSettingsSource.bundleIDEnvironmentKey: "com.ryanmoelter.Plume.debug"])
        #expect(source.suiteName == "com.ryanmoelter.Plume.debug")
    }

    @Test func outsidePlumeTheReleaseBundleIDApplies() {
        #expect(UserDefaultsProjectSettingsSource(environment: [:]).suiteName == "com.ryanmoelter.Plume")
    }

    @Test func aConfigurationRoundTripsThroughJSON() throws {
        let configuration = ProjectsConfiguration(
            defaults: ProjectSettings(protectedWorktrees: ["keep"]),
            repositories: ["/repo": ProjectSettings(forge: ForgeKind.none, ignoredPendingChecks: [])]
        )
        let data = try JSONEncoder().encode(configuration)
        #expect(try JSONDecoder().decode(ProjectsConfiguration.self, from: data) == configuration)
    }
}
