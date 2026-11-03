import Foundation
import Testing

@testable import Plume

/// Covers how `BundledSkills` classifies whatever sits at a skill's name in
/// the skills directory, and that install, refresh and uninstall write over
/// only Plume's own unedited copies unless told to replace.
struct BundledSkillsTests {
    private let scratch: URL
    private let resources: URL
    private let skills: URL
    private let trash: URL

    init() throws {
        scratch = URL.temporaryDirectory.appending(path: "skills-\(UUID().uuidString)")
        resources = scratch.appending(path: "Resources")
        skills = scratch.appending(path: "skills")
        trash = scratch.appending(path: "Trash")
        for directory in [resources, skills, trash] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func bundle(_ name: String = "plume-demo", contents: String = "v1") throws -> BundledSkill {
        try Data(contents.utf8).write(to: resources.appending(path: "\(name).skill.md"))
        return try #require(BundledSkills.bundled(in: resources).first { $0.name == name })
    }

    private func state(_ skill: BundledSkill, running build: String = "10") -> BundledSkills.State {
        BundledSkills.state(of: skill, in: skills, runningBuild: build)
    }

    private func moveToScratchTrash(_ url: URL) throws {
        try FileManager.default.moveItem(at: url, to: trash.appending(path: url.lastPathComponent))
    }

    private func install(_ skill: BundledSkill, replacing: Bool = false, build: String = "10") throws {
        try BundledSkills.install(skill, in: skills, replacing: replacing, plumeBuild: build, trash: moveToScratchTrash)
    }

    private func installedText(_ name: String) throws -> String {
        try String(contentsOf: skills.appending(path: "\(name)/SKILL.md"), encoding: .utf8)
    }

    @Test func listsBundledSkillsByNameWithoutTheSuffix() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try Data().write(to: resources.appending(path: "not-a-skill.md"))
        let skill = try bundle()
        #expect(BundledSkills.bundled(in: resources).map(\.name) == ["plume-demo"])
        #expect(skill.hash == BundledSkills.hash(of: Data("v1".utf8)))
    }

    @Test func nothingAtTheNameIsNotInstalled() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        #expect(state(try bundle()) == .notInstalled)
    }

    @Test func installWritesTheSkillAndItsManifest() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let skill = try bundle()
        try install(skill)
        #expect(state(skill) == .installed)
        #expect(try installedText("plume-demo") == "v1")
        let manifestData = try Data(contentsOf: skills.appending(path: "plume-demo/.plume-skill.json"))
        let manifest = try JSONDecoder().decode(BundledSkills.Manifest.self, from: manifestData)
        #expect(manifest == BundledSkills.Manifest(hash: skill.hash, plumeBuild: "10"))
    }

    @Test func aCopyFromAnOlderBuildIsOutdated() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try install(try bundle(contents: "v1"), build: "10")
        let newer = try bundle(contents: "v2")
        #expect(state(newer, running: "11") == .outdated)

        try install(newer, build: "11")
        #expect(state(newer, running: "11") == .installed)
        #expect(try installedText("plume-demo") == "v2")
    }

    @Test(arguments: ["10", "9"])
    func aCopyFromANewerOrEqualBuildIsInstalledAndLeftAlone(runningBuild: String) throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try install(try bundle(contents: "v1"), build: "10")
        let other = try bundle(contents: "v2")
        #expect(state(other, running: runningBuild) == .installed)

        try BundledSkills.refreshPending([other], in: skills, plumeBuild: runningBuild)
        try install(other, build: runningBuild)
        #expect(try installedText("plume-demo") == "v1")
    }

    @Test(arguments: [nil, "unparseable"] as [String?])
    func aCopyWithoutAUsableBuildIsOutdated(build: String?) throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let skill = try bundle(contents: "v1")
        try install(skill)
        let manifest = BundledSkills.Manifest(hash: skill.hash, plumeBuild: build)
        try JSONEncoder().encode(manifest).write(to: skills.appending(path: "plume-demo/.plume-skill.json"))
        #expect(state(try bundle(contents: "v2")) == .outdated)
    }

    @Test func extraFilesMakeACopyModifiedAndSurviveUpdate() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try install(try bundle(contents: "v1"))
        let notes = skills.appending(path: "plume-demo/notes.md")
        try Data("mine".utf8).write(to: notes)
        let newer = try bundle(contents: "v2")
        #expect(state(newer, running: "11") == .modified)

        try BundledSkills.refreshPending([newer], in: skills, plumeBuild: "11")
        #expect(try String(contentsOf: notes, encoding: .utf8) == "mine")
        #expect(try installedText("plume-demo") == "v1")
    }

    @Test func updateKeepsTheFolderAndReplacesBothFiles() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try install(try bundle(contents: "v1"), build: "10")
        let newer = try bundle(contents: "v2")
        try install(newer, build: "11")
        let manifestData = try Data(contentsOf: skills.appending(path: "plume-demo/.plume-skill.json"))
        let manifest = try JSONDecoder().decode(BundledSkills.Manifest.self, from: manifestData)
        #expect(manifest == BundledSkills.Manifest(hash: newer.hash, plumeBuild: "11"))
        #expect(try installedText("plume-demo") == "v2")
    }

    @Test func updateLeavesNoStagingFolderAndNoExtraFiles() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try install(try bundle(contents: "v1"), build: "10")
        try install(try bundle(contents: "v2"), build: "11")
        let manager = FileManager.default
        #expect(try manager.contentsOfDirectory(atPath: skills.path) == ["plume-demo"])
        let files = try manager.contentsOfDirectory(atPath: skills.appending(path: "plume-demo").path)
        #expect(Set(files) == ["SKILL.md", ".plume-skill.json"])
    }

    @Test func aFailedUpdateKeepsTheOldCopyAndCleansUp() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try install(try bundle(contents: "v1"), build: "10")
        let newer = try bundle(contents: "v2")
        try FileManager.default.removeItem(at: newer.url)

        #expect(throws: (any Error).self) { try install(newer, build: "11") }
        #expect(try installedText("plume-demo") == "v1")
        #expect(try FileManager.default.contentsOfDirectory(atPath: skills.path) == ["plume-demo"])
    }

    @Test func aFolderWithoutAManifestIsOwnedByOther() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let skill = try bundle()
        let folder = skills.appending(path: "plume-demo")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: folder.appending(path: "SKILL.md"))
        #expect(state(skill) == .ownedByOther)
    }

    @Test func aSymlinkToAnOutsideFolderIsOwnedByOther() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let skill = try bundle()
        try install(skill)
        let outside = scratch.appending(path: "dotfiles/plume-demo")
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: skills.appending(path: "plume-demo"), to: outside)
        try FileManager.default.createSymbolicLink(at: skills.appending(path: "plume-demo"), withDestinationURL: outside)
        // A manifest behind the link still doesn't make the link Plume's.
        #expect(state(skill) == .ownedByOther)
    }

    @Test func anEditedCopyIsModified() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let skill = try bundle()
        try install(skill)
        try Data("edited".utf8).write(to: skills.appending(path: "plume-demo/SKILL.md"))
        #expect(state(skill) == .modified)
    }

    @Test(arguments: [false, true])
    func installRefusesWhatPlumeDoesNotOwn(isSymlink: Bool) throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let skill = try bundle()
        let outside = scratch.appending(path: "theirs")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("theirs".utf8).write(to: outside.appending(path: "SKILL.md"))
        let name = skills.appending(path: "plume-demo")
        if isSymlink {
            try FileManager.default.createSymbolicLink(at: name, withDestinationURL: outside)
        } else {
            try FileManager.default.moveItem(at: outside, to: name)
        }

        #expect(throws: BundledSkills.InstallError.self) { try install(skill) }
        #expect(state(skill) == .ownedByOther)
        #expect(try installedText("plume-demo") == "theirs")
    }

    @Test func replacingARealFolderTrashesIt() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let skill = try bundle()
        let name = skills.appending(path: "plume-demo")
        try FileManager.default.createDirectory(at: name, withIntermediateDirectories: true)
        try Data("theirs".utf8).write(to: name.appending(path: "SKILL.md"))

        try install(skill, replacing: true)
        #expect(state(skill) == .installed)
        #expect(try installedText("plume-demo") == "v1")
        #expect(try String(contentsOf: trash.appending(path: "plume-demo/SKILL.md"), encoding: .utf8) == "theirs")
    }

    @Test func replacingASymlinkRemovesOnlyTheLink() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let skill = try bundle()
        let outside = scratch.appending(path: "theirs")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("theirs".utf8).write(to: outside.appending(path: "SKILL.md"))
        try FileManager.default.createSymbolicLink(at: skills.appending(path: "plume-demo"), withDestinationURL: outside)

        try install(skill, replacing: true)
        #expect(state(skill) == .installed)
        #expect(try installedText("plume-demo") == "v1")
        #expect(!FileManager.default.fileExists(atPath: trash.appending(path: "plume-demo").path))
        #expect(try String(contentsOf: outside.appending(path: "SKILL.md"), encoding: .utf8) == "theirs")
    }

    @Test func replacingAModifiedCopyTrashesIt() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let skill = try bundle()
        try install(skill)
        try Data("edited".utf8).write(to: skills.appending(path: "plume-demo/SKILL.md"))

        #expect(throws: BundledSkills.InstallError.self) { try install(skill) }
        try install(skill, replacing: true)
        #expect(state(skill) == .installed)
        #expect(try String(contentsOf: trash.appending(path: "plume-demo/SKILL.md"), encoding: .utf8) == "edited")
    }

    @Test func refreshPendingUpdatesOnlyPlumesUneditedCopies() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        for name in ["plume-outdated", "plume-modified"] {
            try install(try bundle(name, contents: "v1"))
        }
        try Data("edited".utf8).write(to: skills.appending(path: "plume-modified/SKILL.md"))
        let other = skills.appending(path: "plume-other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("theirs".utf8).write(to: other.appending(path: "SKILL.md"))
        let bundled = try ["plume-outdated", "plume-modified", "plume-other"].map { try bundle($0, contents: "v2") }

        try BundledSkills.refreshPending(bundled, in: skills, plumeBuild: "11")

        #expect(bundled.map { state($0) } == [.installed, .modified, .ownedByOther])
        #expect(try installedText("plume-outdated") == "v2")
        #expect(try installedText("plume-modified") == "edited")
        #expect(try installedText("plume-other") == "theirs")
    }

    @Test func refreshPendingAddsNewSkillsOnceTheUserOwnsAny() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let first = try bundle("plume-first")
        let added = try bundle("plume-added")
        try BundledSkills.refreshPending([added], in: skills, plumeBuild: "10")
        #expect(state(added) == .notInstalled)

        try install(first)
        try BundledSkills.refreshPending([first, added], in: skills, plumeBuild: "10")
        #expect(state(added) == .installed)
    }

    @Test func refreshPendingLeavesANameAnotherSkillHoldsAlone() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let first = try bundle("plume-first")
        try install(first)
        let theirs = skills.appending(path: "plume-theirs")
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        let held = try bundle("plume-theirs")

        try BundledSkills.refreshPending([first, held], in: skills, plumeBuild: "10")
        #expect(state(held) == .ownedByOther)
        #expect(!FileManager.default.fileExists(atPath: theirs.appending(path: "SKILL.md").path))
    }

    @Test func pendingCountIncludesNewSkillsOnlyOnceTheUserOwnsAny() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let skill = try bundle()
        func entry(_ state: BundledSkills.State) -> BundledSkillsStatus.Entry {
            .init(skill: skill, state: state, isSymlink: false)
        }
        func count(_ states: [BundledSkills.State], retired: Int = 0) -> Int {
            let snapshot = BundledSkillsStatus.Snapshot(
                entries: states.map(entry), retired: Array(repeating: skills, count: retired)
            )
            return BundledSkillsStatus.pendingUpdateCount(of: snapshot)
        }
        #expect(count([.notInstalled, .notInstalled]) == 0)
        #expect(count([.installed, .notInstalled]) == 1)
        #expect(count([.outdated, .notInstalled]) == 2)
        #expect(count([.modified, .notInstalled]) == 1)
        #expect(count([.ownedByOther, .notInstalled]) == 0)
        #expect(count([.installed, .ownedByOther, .modified]) == 0)
        #expect(count([.installed], retired: 2) == 2)
    }

    @Test func retiredFoldersAreUneditedPlumeCopiesOutsideTheBundle() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let kept = try bundle("plume-kept")
        let retired = try bundle("plume-retired")
        let edited = try bundle("plume-edited")
        for skill in [kept, retired, edited] { try install(skill) }
        try Data("edited".utf8).write(to: skills.appending(path: "plume-edited/SKILL.md"))
        let theirs = skills.appending(path: "theirs")
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        try Data("theirs".utf8).write(to: theirs.appending(path: "SKILL.md"))
        let target = scratch.appending(path: "target")
        try FileManager.default.moveItem(at: skills.appending(path: "plume-retired"), to: target)
        try FileManager.default.createSymbolicLink(at: skills.appending(path: "plume-link"), withDestinationURL: target)
        try FileManager.default.moveItem(at: target, to: skills.appending(path: "plume-retired"))

        let found = BundledSkills.retiredFolders(keeping: [kept], in: skills).map(\.lastPathComponent)
        #expect(found == ["plume-retired"])
    }

    @Test func refreshPendingTrashesRetiredCopiesAndKeepsEditedOnes() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let kept = try bundle("plume-kept")
        let retired = try bundle("plume-retired")
        let edited = try bundle("plume-edited")
        for skill in [kept, retired, edited] { try install(skill) }
        try Data("edited".utf8).write(to: skills.appending(path: "plume-edited/SKILL.md"))

        try BundledSkills.refreshPending([kept], in: skills, plumeBuild: "10", trash: moveToScratchTrash)

        #expect(FileManager.default.fileExists(atPath: trash.appending(path: "plume-retired/SKILL.md").path))
        #expect(!FileManager.default.fileExists(atPath: skills.appending(path: "plume-retired").path))
        #expect(try installedText("plume-edited") == "edited")
        #expect(try installedText("plume-kept") == "v1")
    }

    @Test func uninstallRemovesOnlyPlumesUneditedCopy() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let kept = try bundle("plume-kept")
        try install(kept)
        try Data("edited".utf8).write(to: skills.appending(path: "plume-kept/SKILL.md"))
        let removed = try bundle("plume-removed")
        try install(removed)

        try BundledSkills.uninstall(kept, in: skills, trash: moveToScratchTrash)
        try BundledSkills.uninstall(removed, in: skills, trash: moveToScratchTrash)

        #expect(state(kept) == .modified)
        #expect(state(removed) == .notInstalled)
        #expect(FileManager.default.fileExists(atPath: trash.appending(path: "plume-removed/SKILL.md").path))
    }

    @Test func installMissingKeepsGoingAfterAFailureAndThrowsTheFirst() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let broken = try bundle("plume-a")
        let fine = try bundle("plume-b")
        try FileManager.default.removeItem(at: broken.url)

        #expect(throws: (any Error).self) { try BundledSkills.installMissing([broken, fine], in: skills) }
        #expect(state(fine) == .installed)
    }
}

/// The skills and the formatting rule the app bundle actually ships.
struct BundledSkillResourceTests {
    @Test func everyBundledSkillNamesItselfInItsFrontmatter() throws {
        let skills = BundledSkills.bundled()
        #expect(Set(skills.map(\.name)) == ["plume-cli", "plume-devices", "plume-stack", "plume-worktrees"])
        for skill in skills {
            let text = try String(contentsOf: skill.url, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            #expect(lines.first == "---")
            let frontmatter = lines.dropFirst().prefix { $0 != "---" }
            #expect(frontmatter.contains("name: \(skill.name)"), "\(skill.name)")
            #expect(frontmatter.contains { $0.hasPrefix("description: ") }, "\(skill.name)")
        }
    }

    @Test func theFormattingRuleIsBundled() throws {
        let path = try #require(AgentPromptRule.formattingPath)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.contains("mermaid"))
        #expect(text.contains("linear.app"))
    }
}
