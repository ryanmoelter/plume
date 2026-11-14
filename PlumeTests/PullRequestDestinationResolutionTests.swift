import Foundation
import Testing
@testable import Plume

struct PullRequestDestinationResolutionTests {
    @Test func fallsBackToGitHubWhenNothingIsSet() {
        let configuration = ProjectsConfiguration()
        #expect(configuration.pullRequestDestination(forRoot: nil) == .github)
        #expect(configuration.pullRequestDestination(forRoot: "/p") == .github)
    }

    @Test func aProjectInheritsTheDefaultsRow() {
        let configuration = ProjectsConfiguration(
            defaults: ProjectSettings(pullRequestDestination: .linearDiffs),
            repositories: ["/p": ProjectSettings()]
        )
        #expect(configuration.pullRequestDestination(forRoot: "/p") == .linearDiffs)
        #expect(configuration.pullRequestDestination(forRoot: "/unlisted") == .linearDiffs)
        #expect(configuration.pullRequestDestination(forRoot: nil) == .linearDiffs)
    }

    @Test func aProjectOverridesTheDefaultsRow() {
        let configuration = ProjectsConfiguration(
            defaults: ProjectSettings(pullRequestDestination: .linearDiffs),
            repositories: ["/p": ProjectSettings(pullRequestDestination: .github)]
        )
        #expect(configuration.pullRequestDestination(forRoot: "/p") == .github)
        #expect(configuration.pullRequestDestination(forRoot: "/q") == .linearDiffs)
    }

    @Test func theSettingSurvivesEncoding() throws {
        let configuration = ProjectsConfiguration(
            defaults: ProjectSettings(pullRequestDestination: .linearDiffs),
            repositories: ["/p": ProjectSettings(pullRequestDestination: .github)]
        )
        let decoded = try JSONDecoder().decode(ProjectsConfiguration.self, from: JSONEncoder().encode(configuration))
        #expect(decoded == configuration)
    }

    @Test func migrationMovesTheGlobalValueIntoTheDefaultsRow() {
        let migrated = AppSettings.migratingPullRequestDestination(legacy: "linearDiffs", into: ProjectsConfiguration())
        #expect(migrated.defaults.pullRequestDestination == .linearDiffs)
    }

    @Test func migrationKeepsAValueTheDefaultsRowAlreadyHas() {
        let existing = ProjectsConfiguration(defaults: ProjectSettings(pullRequestDestination: .github))
        let migrated = AppSettings.migratingPullRequestDestination(legacy: "linearDiffs", into: existing)
        #expect(migrated.defaults.pullRequestDestination == .github)
    }

    @Test func migrationIgnoresAnUnknownValue() {
        let migrated = AppSettings.migratingPullRequestDestination(legacy: "bogus", into: ProjectsConfiguration())
        #expect(migrated.defaults.pullRequestDestination == nil)
    }
}
