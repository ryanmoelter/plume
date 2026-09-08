import Testing
import Foundation
@testable import Plume

struct IgnoredChecksResolverTests {
    @Test func unionsANameFromGitConfigAlone() {
        let result = IgnoredChecksResolver.union(["flaky-lint"], [])
        #expect(result == ["flaky-lint"])
    }

    @Test func unionsANameFromThePlumeSettingAlone() {
        let result = IgnoredChecksResolver.union([], ["flaky-lint"])
        #expect(result == ["flaky-lint"])
    }

    @Test func unionsNamesPresentInBothSources() {
        let result = IgnoredChecksResolver.union(["from-git"], ["from-plume"])
        #expect(result == ["from-git", "from-plume"])
    }

    @Test func neitherSourceSuppressesTheOther() {
        // The CLI's tool-key-wins rule would drop one side; Plume unions both.
        let result = IgnoredChecksResolver.union(["only-in-git"], ["only-in-plume"])
        #expect(result.contains("only-in-git"))
        #expect(result.contains("only-in-plume"))
    }

    @Test func duplicatesAcrossSourcesCollapse() {
        let result = IgnoredChecksResolver.union(["shared-name"], ["shared-name"])
        #expect(result == ["shared-name"])
    }

    @Test func duplicatesWithinTheSameSourceCollapse() {
        let result = IgnoredChecksResolver.union(["dup", "dup"], [])
        #expect(result == ["dup"])
    }

    // `git config --get-all` merges the repo-local file with the user's real
    // global config (by design — see IgnoredChecksResolver's doc comment), so
    // these assert containment rather than exact equality: this machine's own
    // global `wt`/`stack` config may legitimately add more names.

    @Test func resolveReadsGitConfigFromARealRepository() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }

        try GitRunner.run(["config", "--add", "wt.ignoredPendingChecks", "wt-check"], in: repository)
        try GitRunner.run(
            ["config", "--add", "ryanmoelter-cli-tools.ignoredPendingChecks", "shared-check"],
            in: repository
        )

        let result = IgnoredChecksResolver.resolve(repository: repository, plumeSetting: ["plume-check"])
        #expect(result.isSuperset(of: ["wt-check", "shared-check", "plume-check"]))
    }

    @Test func resolveWithNoGitConfigStillIncludesThePlumeSetting() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }

        let result = IgnoredChecksResolver.resolve(repository: repository, plumeSetting: ["plume-check"])
        #expect(result.contains("plume-check"))
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
