import Testing
import Foundation
import os
@testable import Plume

struct IgnoredChecksResolverTests {
    @Test func resolvesTheProjectsList() {
        #expect(IgnoredChecksResolver.resolve(settings: ProjectSettings(ignoredPendingChecks: ["flaky-lint"])) == ["flaky-lint"])
    }

    @Test func noListIgnoresNothing() {
        #expect(IgnoredChecksResolver.resolve(settings: ProjectSettings()).isEmpty)
    }

    @Test func duplicatesCollapse() {
        #expect(IgnoredChecksResolver.resolve(settings: ProjectSettings(ignoredPendingChecks: ["dup", "dup"])) == ["dup"])
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

        let result = IgnoredChecksResolver.resolve(repository: nested, configuration: configuration)
        #expect(result == ["project-check"])
    }

    @Test func aProjectWithNoListTakesTheDefaultsRow() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        let configuration = ProjectsConfiguration(defaults: ProjectSettings(ignoredPendingChecks: ["default-check"]))

        let result = IgnoredChecksResolver.resolve(repository: repository, configuration: configuration)
        #expect(result == ["default-check"])
    }

    /// Ignored checks live in Settings ▸ Projects, never in git config.
    @Test func gitConfigIsNotASource() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        try GitRunner.run(["config", "--add", "wt.ignoredPendingChecks", "wt-check"], in: repository)

        let result = IgnoredChecksResolver.resolve(repository: repository, configuration: ProjectsConfiguration())
        #expect(result.isEmpty)
    }

    @Test func aRepositorysRootIsLookedUpOnce() {
        let lookups = OSAllocatedUnfairLock(initialState: 0)
        let cache = ProjectRootCache { path in
            lookups.withLock { $0 += 1 }
            return path == "/repo/sub" ? "/repo" : nil
        }
        #expect(cache.root(containing: "/repo/sub") == "/repo")
        #expect(cache.root(containing: "/repo/sub") == "/repo")
        #expect(lookups.withLock { $0 } == 1)
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
    /// The resolver itself only collects strings; these confirm the exact-match
    /// contract callers rely on, so a future rollup implementation doesn't
    /// accidentally add fuzzy matching.
    @Test func differingCaseDoesNotMatch() {
        let ignored = IgnoredChecksResolver.resolve(settings: ProjectSettings(ignoredPendingChecks: ["Build"]))
        #expect(!ignored.contains("build"))
        #expect(ignored.contains("Build"))
    }

    @Test func surroundingWhitespaceDoesNotMatch() {
        let ignored = IgnoredChecksResolver.resolve(settings: ProjectSettings(ignoredPendingChecks: [" build "]))
        #expect(!ignored.contains("build"))
        #expect(ignored.contains(" build "))
    }

    @Test func substringDoesNotMatch() {
        let ignored = IgnoredChecksResolver.resolve(settings: ProjectSettings(ignoredPendingChecks: ["build"]))
        #expect(!ignored.contains("build-and-test"))
        #expect(ignored.contains("build"))
    }
}
