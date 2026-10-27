import Foundation
import Testing
@testable import Plume

/// The one-time move of the Python tools' git config into Settings ▸
/// Projects: each field resolves as `wt` did (its own key, then the shared
/// section, then `stack`), a repository keeps only what differs from global,
/// and nothing already set in Projects is overwritten.
struct GitConfigSettingsImportTests {
    private func settings(_ entries: [(String, String)]) -> ProjectSettings {
        let list = entries.map { "\($0.0)\n\($0.1)" }.joined(separator: "\0") + "\0"
        return GitConfigSettingsImport.settings(from: GitConfigSettingsImport.parseList(list))
    }

    @Test func parsesEveryValueOfARepeatedKeyInOrder() {
        let parsed = GitConfigSettingsImport.parseList("wt.protected\na\0user.email\nme@x.com\0wt.protected\nb c\0")
        #expect(parsed["wt.protected"] == ["a", "b c"])
        #expect(parsed["user.email"] == ["me@x.com"])
    }

    @Test func aValuelessKeyParsesAsEmpty() {
        #expect(GitConfigSettingsImport.parseList("wt.nerdfont\0")["wt.nerdfont"] == [""])
    }

    @Test func wtBeatsTheSharedSectionWhichBeatsStack() {
        #expect(settings([("stack.branchprefix", "s/"), ("ryanmoelter-cli-tools.branchprefix", "shared/"), ("wt.branchprefix", "w/")]).branchPrefix == "w/")
        #expect(settings([("stack.branchprefix", "s/"), ("ryanmoelter-cli-tools.branchprefix", "shared/")]).branchPrefix == "shared/")
        #expect(settings([("stack.branchprefix", "s/")]).branchPrefix == "s/")
    }

    @Test func anEmptyPrefixIsImportedAsNoPrefix() {
        #expect(settings([("wt.branchprefix", ""), ("ryanmoelter-cli-tools.branchprefix", "shared/")]).branchPrefix == "")
    }

    @Test func aSingleValuedKeyTakesItsLastValue() {
        #expect(settings([("wt.basebranch", "main"), ("wt.basebranch", "develop")]).baseBranch == "develop")
    }

    @Test func anEmptyBaseBranchOrForgeIsUnset() {
        let imported = settings([("wt.basebranch", ""), ("wt.forge", "")])
        #expect(imported.baseBranch == nil)
        #expect(imported.forge == nil)
    }

    @Test func forgeAndNerdFontParse() {
        let imported = settings([("ryanmoelter-cli-tools.forge", "GitLab"), ("stack.nerdfont", "yes")])
        #expect(imported.forge == .gitlab)
        #expect(imported.nerdFont == .on)
        #expect(settings([("wt.nerdfont", "")]).nerdFont == .off)
        #expect(settings([("wt.forge", "bitbucket")]).forge == nil)
    }

    @Test func aListComesWholeFromTheFirstKeyThatHasValues() {
        let imported = settings([
            ("ryanmoelter-cli-tools.ignoredpendingchecks", "shared"),
            ("wt.ignoredpendingchecks", "a"),
            ("wt.ignoredpendingchecks", "b"),
            ("ryanmoelter-cli-tools.protectedworktrees", "keep"),
            ("ryanmoelter-cli-tools.protectedworktrees", "also"),
        ])
        #expect(imported.ignoredPendingChecks == ["a", "b"])
        #expect(imported.protectedWorktrees == ["keep", "also"])
    }

    @Test func protectedWorktreesReadsWtProtectedButNotStack() {
        #expect(settings([("wt.protected", "w")]).protectedWorktrees == ["w"])
        #expect(settings([("stack.protectedworktrees", "s")]).protectedWorktrees == nil)
    }

    @Test func unrelatedConfigImportsNothing() {
        #expect(settings([("user.email", "me@x.com")]) == ProjectSettings())
    }

    @Test func aRepositoryKeepsOnlyWhatDiffersFromGlobal() {
        let global = ProjectSettings(baseBranch: "main", branchPrefix: "me/", ignoredPendingChecks: ["a"])
        let repository = ProjectSettings(baseBranch: "main", branchPrefix: "", ignoredPendingChecks: ["a", "b"])
        #expect(GitConfigSettingsImport.repositoryOverrides(repository: repository, global: global)
            == ProjectSettings(branchPrefix: "", ignoredPendingChecks: ["a", "b"]))
    }

    @Test func mergingNeverOverwritesAValueSetInProjects() {
        let existing = ProjectsConfiguration(
            defaults: ProjectSettings(branchPrefix: "kept/"),
            repositories: ["/repo": ProjectSettings(ignoredPendingChecks: ["mine"])]
        )
        let imported = ProjectsConfiguration(
            defaults: ProjectSettings(branchPrefix: "git/", nerdFont: .on),
            repositories: [
                "/repo": ProjectSettings(baseBranch: "develop", ignoredPendingChecks: ["theirs"]),
                "/other": ProjectSettings(forge: .github),
                "/empty": ProjectSettings(),
            ]
        )
        let merged = GitConfigSettingsImport.merging(imported, into: existing)
        #expect(merged.defaults == ProjectSettings(branchPrefix: "kept/"))
        #expect(merged.repositories["/repo"] == ProjectSettings(baseBranch: "develop", ignoredPendingChecks: ["mine"]))
        #expect(merged.repositories["/other"] == ProjectSettings(forge: .github))
        #expect(merged.repositories["/empty"] == nil)
    }

    @Test func readsARepositorysLocalConfig() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "git-config-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try CLIProcess.run(["git", "-C", directory.path, "init", "-q"])
        try CLIProcess.run(["git", "-C", directory.path, "config", "wt.baseBranch", "plume-import-test"])

        let imported = GitConfigSettingsImport.read(repositoryPaths: [directory.path])
        #expect(imported.repositories.count == 1)
        #expect(imported.repositories.values.first?.baseBranch == "plume-import-test")
    }
}
