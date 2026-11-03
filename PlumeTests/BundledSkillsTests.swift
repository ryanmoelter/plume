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

    private func state(_ skill: BundledSkill) -> BundledSkills.State {
        BundledSkills.state(of: skill, in: skills)
    }

    private func install(_ skill: BundledSkill, replacing: Bool = false) throws {
        try BundledSkills.install(skill, in: skills, replacing: replacing, plumeVersion: "1.0") { url in
            try FileManager.default.moveItem(at: url, to: trash.appending(path: url.lastPathComponent))
        }
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
        #expect(manifest == BundledSkills.Manifest(hash: skill.hash, plumeVersion: "1.0"))
    }

    @Test func aCopyFromAnotherBundleIsOutdated() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try install(try bundle(contents: "v1"))
        let newer = try bundle(contents: "v2")
        #expect(state(newer) == .outdated)

        try install(newer)
        #expect(state(newer) == .installed)
        #expect(try installedText("plume-demo") == "v2")
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

    @Test(arguments: [false, true])
    func replacingTrashesWhatWasThereAndInstalls(isSymlink: Bool) throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let skill = try bundle()
        let outside = scratch.appending(path: "theirs")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("theirs".utf8).write(to: outside.appending(path: "SKILL.md"))
        let name = skills.appending(path: "plume-demo")
        if isSymlink {
            try FileManager.default.createSymbolicLink(at: name, withDestinationURL: outside)
        } else {
            try FileManager.default.copyItem(at: outside, to: name)
        }

        try install(skill, replacing: true)
        #expect(state(skill) == .installed)
        #expect(try installedText("plume-demo") == "v1")
        let trashed = trash.appending(path: "plume-demo")
        #expect(FileManager.default.fileExists(atPath: trashed.path))
        let trashedALink = (try? FileManager.default.destinationOfSymbolicLink(atPath: trashed.path)) != nil
        #expect(trashedALink == isSymlink)
        // The link's target is never followed into.
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

    @Test func refreshOutdatedUpdatesOnlyPlumesUneditedCopies() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        for name in ["plume-outdated", "plume-modified"] {
            try install(try bundle(name, contents: "v1"))
        }
        try Data("edited".utf8).write(to: skills.appending(path: "plume-modified/SKILL.md"))
        let other = skills.appending(path: "plume-other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("theirs".utf8).write(to: other.appending(path: "SKILL.md"))
        let bundled = try ["plume-outdated", "plume-modified", "plume-other"].map { try bundle($0, contents: "v2") }

        try BundledSkills.refreshOutdated(bundled, in: skills)

        #expect(bundled.map(state) == [.installed, .modified, .ownedByOther])
        #expect(try installedText("plume-outdated") == "v2")
        #expect(try installedText("plume-modified") == "edited")
        #expect(try installedText("plume-other") == "theirs")
    }

    @Test func uninstallRemovesOnlyPlumesUneditedCopy() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let kept = try bundle("plume-kept")
        try install(kept)
        try Data("edited".utf8).write(to: skills.appending(path: "plume-kept/SKILL.md"))
        let removed = try bundle("plume-removed")
        try install(removed)

        try BundledSkills.uninstall(kept, in: skills)
        try BundledSkills.uninstall(removed, in: skills)

        #expect(state(kept) == .modified)
        #expect(state(removed) == .notInstalled)
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
