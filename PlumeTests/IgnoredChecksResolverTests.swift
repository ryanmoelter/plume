import Testing
import Foundation
@testable import Plume

struct IgnoredChecksResolverTests {
    @Test func unionsANameFromTheProjectAlone() {
        let result = IgnoredChecksResolver.union(["flaky-lint"], [])
        #expect(result == ["flaky-lint"])
    }

    @Test func unionsANameFromThePlumeSettingAlone() {
        let result = IgnoredChecksResolver.union([], ["flaky-lint"])
        #expect(result == ["flaky-lint"])
    }

    @Test func unionsNamesPresentInBothSources() {
        let result = IgnoredChecksResolver.union(["from-project"], ["from-plume"])
        #expect(result == ["from-project", "from-plume"])
    }

    @Test func duplicatesAcrossSourcesCollapse() {
        let result = IgnoredChecksResolver.union(["shared-name"], ["shared-name"])
        #expect(result == ["shared-name"])
    }

    @Test func duplicatesWithinTheSameSourceCollapse() {
        let result = IgnoredChecksResolver.union(["dup", "dup"], [])
        #expect(result == ["dup"])
    }

    @Test func resolveReadsTheProjectsListFromASubdirectory() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        let nested = "\(repository)/sub"
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        let root = try #require(ProjectRoot.containing(repository))
        let configuration = ProjectsConfiguration(
            defaults: ProjectSettings(ignoredPendingChecks: ["default-check"]),
            repositories: [root: ProjectSettings(ignoredPendingChecks: ["project-check"])]
        )

        let result = IgnoredChecksResolver.resolve(repository: nested, plumeSetting: ["plume-check"], configuration: configuration)
        #expect(result == ["project-check", "plume-check"])
    }

    @Test func aProjectWithNoListTakesTheDefaultsRow() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        let configuration = ProjectsConfiguration(defaults: ProjectSettings(ignoredPendingChecks: ["default-check"]))

        let result = IgnoredChecksResolver.resolve(repository: repository, plumeSetting: [], configuration: configuration)
        #expect(result == ["default-check"])
    }

    /// Ignored checks live in Settings ▸ Projects, never in git config.
    @Test func gitConfigIsNotASource() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        try GitRunner.run(["config", "--add", "wt.ignoredPendingChecks", "wt-check"], in: repository)

        let result = IgnoredChecksResolver.resolve(repository: repository, plumeSetting: ["plume-check"], configuration: ProjectsConfiguration())
        #expect(result == ["plume-check"])
    }

    private func makeRepository() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "plume-ignored-checks-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try GitRunner.run(["init", "-b", "main"], in: path)
        try GitRunner.run(["config", "commit.gpgsign", "false"], in: path)
        return path
    }
}

struct IgnoredChecksResolverExactMatchTests {
    /// The resolver itself only unions strings; these confirm the exact-match
    /// contract callers rely on, so a future rollup implementation doesn't
    /// accidentally add fuzzy matching.
    @Test func differingCaseDoesNotMatch() {
        let ignored = IgnoredChecksResolver.union(["Build"], [])
        #expect(!ignored.contains("build"))
        #expect(ignored.contains("Build"))
    }

    @Test func surroundingWhitespaceDoesNotMatch() {
        let ignored = IgnoredChecksResolver.union([" build "], [])
        #expect(!ignored.contains("build"))
        #expect(ignored.contains(" build "))
    }

    @Test func substringDoesNotMatch() {
        let ignored = IgnoredChecksResolver.union(["build"], [])
        #expect(!ignored.contains("build-and-test"))
        #expect(ignored.contains("build"))
    }
}
