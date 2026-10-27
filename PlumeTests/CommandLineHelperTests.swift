import Foundation
import Testing

@testable import Plume

/// Covers how `CommandLineHelper` classifies whatever sits at each install
/// path — absent, Plume's own link, another copy of Plume's, someone else's,
/// or a link whose target has gone away — and that install, uninstall and
/// the launch-time repoint touch only links some copy of Plume placed.
@MainActor
struct CommandLineHelperTests {
    private let scratch: URL
    private let bin: URL
    private let bundle: URL
    private let tool: URL

    init() throws {
        scratch = URL.temporaryDirectory.appending(path: "helper-\(UUID().uuidString)")
        bin = scratch.appending(path: "bin")
        bundle = scratch.appending(path: "Plume.app")
        tool = CommandLineHelper.toolURL(inBundle: bundle)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: tool)
    }

    private func link(_ name: String, to destination: URL) throws {
        try FileManager.default.createSymbolicLink(at: bin.appending(path: name), withDestinationURL: destination)
    }

    private func state(_ name: String) -> CommandLineHelper.State {
        CommandLineHelper.state(of: bin.appending(path: name), bundledURL: tool)
    }

    private func destination(_ name: String) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: bin.appending(path: name).path)
    }

    @Test func nothingAtThePathIsNotInstalled() {
        defer { try? FileManager.default.removeItem(at: scratch) }
        #expect(state("plume") == .notInstalled)
    }

    @Test func aLinkToTheBundledToolIsInstalled() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try link("plume", to: tool)
        #expect(state("plume") == .installed)
    }

    @Test func aRegularFileIsNotOverwritable() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try Data().write(to: bin.appending(path: "plume"))
        #expect(state("plume") == .occupiedByOther(nil))
    }

    @Test func aLinkToAnotherToolIsNotOverwritable() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let other = scratch.appending(path: "some-other-tool")
        try Data().write(to: other)
        try link("plume", to: other)
        #expect(state("plume") == .occupiedByOther(other.standardizedFileURL))
    }

    @Test func aLinkToThisBundlesLegacyScriptIsOutdated() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let legacy = CommandLineHelper.legacyScriptURL(inBundle: bundle)
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: legacy)
        try link("plume-notify", to: legacy)
        #expect(state("plume-notify") == .outdated(legacy.standardizedFileURL))
    }

    @Test func aLinkIntoAnotherPlumeBundleIsAnotherCopys() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let otherTool = try makeOtherPlumeTool()
        try link("plume", to: otherTool)
        #expect(state("plume") == .ownedByOtherPlume(otherTool.standardizedFileURL))
    }

    @Test func turningOnRepointsAnotherPlumesLinksAndTurningOffRemovesThem() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let otherTool = try makeOtherPlumeTool()
        try link("plume", to: otherTool)

        try CommandLineHelper.install(in: bin, bundledURL: tool)
        #expect(try destination("plume") == tool.path)
        #expect(try destination("plume-notify") == tool.path)

        try FileManager.default.removeItem(at: bin.appending(path: "plume"))
        try link("plume", to: otherTool)
        try link("wt", to: otherTool)
        try CommandLineHelper.uninstall(in: bin, bundledURL: tool)
        #expect(state("plume") == .notInstalled)
        #expect(state("plume-notify") == .notInstalled)
        #expect(wtState() == .notInstalled)
    }

    private func makeOtherPlumeTool() throws -> URL {
        let otherTool = CommandLineHelper.toolURL(inBundle: scratch.appending(path: "Applications/Plume.app"))
        try FileManager.default.createDirectory(at: otherTool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: otherTool)
        return otherTool
    }

    private func summary() -> CommandLineHelper.Summary {
        CommandLineHelper.summary(of: CommandLineHelper.states(in: bin, bundledURL: tool))
    }

    @Test func nothingLinkedIsOffAndCanBeTurnedOn() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        #expect(summary() == .init(isOn: false, canToggle: true, needsUpdate: false, notes: []))

        try CommandLineHelper.install(in: bin, bundledURL: tool)
        #expect(summary() == .init(isOn: true, canToggle: true, needsUpdate: false, notes: []))
    }

    /// The switch must still turn off the Plume link beside a name another
    /// tool owns, and say which name that is.
    @Test func aPartialInstallBesideAForeignFileIsOnAndCanBeTurnedOff() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try Data().write(to: bin.appending(path: "plume"))
        try link("plume-notify", to: tool)

        #expect(summary() == .init(isOn: true, canToggle: true, needsUpdate: false, notes: ["Another tool owns plume"]))
    }

    @Test func linkedOnlyByAnotherPlumeIsOnAndCanBeTurnedOffOrUpdated() {
        let summary = CommandLineHelper.summary(of: [
            ("plume", .ownedByOtherPlume(URL(fileURLWithPath: "/Applications/Plume.app/Contents/Helpers/plume"))),
            ("plume-notify", .notInstalled),
        ])
        #expect(summary == .init(isOn: true, canToggle: true, needsUpdate: true, notes: ["Another copy of Plume owns plume"]))
    }

    @Test func anOutdatedLinkIsOnAndNeedsUpdating() {
        let summary = CommandLineHelper.summary(of: [
            ("plume", .outdated(URL(fileURLWithPath: "/Old/Plume.app/Contents/Helpers/plume"))),
            ("plume-notify", .installed),
        ])
        #expect(summary == .init(isOn: true, canToggle: true, needsUpdate: true, notes: ["Needs updating"]))
    }

    @Test func everyNameTakenIsOffAndLocked() {
        let summary = CommandLineHelper.summary(of: [("plume", .occupiedByOther(nil)), ("plume-notify", .occupiedByOther(nil))])
        #expect(summary == .init(
            isOn: false, canToggle: false, needsUpdate: false,
            notes: ["Another tool owns plume", "Another tool owns plume-notify"]
        ))
    }

    @Test func aLinkIntoAVanishedPlumeBundleIsBroken() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try link("plume", to: CommandLineHelper.toolURL(inBundle: scratch.appending(path: "Gone/Plume.app")))
        #expect(state("plume") == .brokenLink)
    }

    @Test func aDanglingLinkOutsideAnyPlumeBundleIsAnotherTools() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let vanished = scratch.appending(path: "vanished")
        try link("plume", to: vanished)
        #expect(state("plume") == .occupiedByOther(vanished))
    }

    @Test func launchLeavesADanglingForeignLinkAlone() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try link("plume-notify", to: CommandLineHelper.legacyScriptURL(inBundle: bundle))
        let vanished = scratch.appending(path: "vanished")
        try link("plume", to: vanished)

        let outcomes = CommandLineHelper.repointLegacyLinks(in: bin, bundleURL: bundle, bundledURL: tool)

        #expect(outcomes.map(\.isLinked) == [false, true])
        #expect(try destination("plume") == vanished.path)
    }

    @Test func installLinksEveryNameAndSkipsAForeignFile() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try Data("mine".utf8).write(to: bin.appending(path: "plume-notify"))

        #expect(throws: CommandLineHelper.InstallError.self) {
            try CommandLineHelper.install(in: bin, bundledURL: tool)
        }
        #expect(state("plume") == .installed)
        #expect(try Data(contentsOf: bin.appending(path: "plume-notify")) == Data("mine".utf8))
        #expect(summary().notes == ["Another tool owns plume-notify"])
    }

    @Test func uninstallRemovesOnlyPlumesLinks() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try CommandLineHelper.install(in: bin, bundledURL: tool)
        try FileManager.default.removeItem(at: bin.appending(path: "plume-notify"))
        try Data("mine".utf8).write(to: bin.appending(path: "plume-notify"))
        #expect(summary().isOn)

        try CommandLineHelper.uninstall(in: bin, bundledURL: tool)

        #expect(state("plume") == .notInstalled)
        #expect(try Data(contentsOf: bin.appending(path: "plume-notify")) == Data("mine".utf8))
        #expect(!summary().isOn)
    }

    /// A dangling link counts as Plume's only when it pointed into a Plume
    /// bundle; one pointing anywhere else may be the user's own, moved.
    @Test func uninstallRemovesADanglingPlumeLinkButNotADanglingForeignOne() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let foreign = scratch.appending(path: "scripts/plume")
        try link("plume", to: foreign)
        try link("plume-notify", to: scratch.appending(path: "Old/Plume.app/Contents/Helpers/plume"))

        try CommandLineHelper.uninstall(in: bin, bundledURL: tool)

        #expect(try destination("plume") == foreign.path)
        #expect(state("plume-notify") == .notInstalled)
    }

    @Test func uninstallRemovesWTButNotAnotherToolsWT() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try CommandLineHelper.install(in: bin, bundledURL: tool)
        try CommandLineHelper.installWT(in: bin, bundledURL: tool)

        try CommandLineHelper.uninstall(in: bin, bundledURL: tool)
        #expect(wtState() == .notInstalled)

        try CommandLineHelper.install(in: bin, bundledURL: tool)
        try Data("mine".utf8).write(to: bin.appending(path: "wt"))
        try CommandLineHelper.uninstall(in: bin, bundledURL: tool)
        #expect(try Data(contentsOf: bin.appending(path: "wt")) == Data("mine".utf8))
    }

    @Test func launchRepointsTheLegacyScriptLinkAndAddsPlume() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try link("plume-notify", to: CommandLineHelper.legacyScriptURL(inBundle: bundle))
        #expect(state("plume-notify") == .brokenLink)

        CommandLineHelper.repointLegacyLinks(in: bin, bundleURL: bundle, bundledURL: tool)

        #expect(try destination("plume-notify") == tool.path)
        #expect(try destination("plume") == tool.path)
    }

    @Test func launchReportsEachNameItCouldNotLink() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try link("plume-notify", to: CommandLineHelper.legacyScriptURL(inBundle: bundle))
        #expect(FileManager.default.createFile(atPath: bin.appending(path: "plume").path, contents: Data()))

        let outcomes = CommandLineHelper.repointLegacyLinks(in: bin, bundleURL: bundle, bundledURL: tool)

        #expect(outcomes.map(\.name) == ["plume", "plume-notify"])
        #expect(outcomes.map(\.isLinked) == [false, true])
        #expect(try destination("plume-notify") == tool.path)
    }

    @Test func launchLeavesAnotherBundlesLinksAlone() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let installed = scratch.appending(path: "Applications/Plume.app")
        let legacy = CommandLineHelper.legacyScriptURL(inBundle: installed)
        try link("plume-notify", to: legacy)

        #expect(CommandLineHelper.repointLegacyLinks(in: bin, bundleURL: bundle, bundledURL: tool).isEmpty)

        #expect(try destination("plume-notify") == legacy.path)
        #expect(state("plume") == .notInstalled)
    }

    // MARK: wt

    private func wtState() -> CommandLineHelper.State {
        CommandLineHelper.wtState(in: bin, bundledURL: tool)
    }

    @Test func wtIsLinkedOnlyWhenAskedAndRemovableOnItsOwn() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try link("plume-notify", to: CommandLineHelper.legacyScriptURL(inBundle: bundle))
        CommandLineHelper.repointLegacyLinks(in: bin, bundleURL: bundle, bundledURL: tool)
        try CommandLineHelper.install(in: bin, bundledURL: tool)
        #expect(wtState() == .notInstalled)
        #expect(CommandLineHelper.wtSummary(of: wtState()) == .init(isOn: false, canToggle: true, needsUpdate: false, note: nil))

        try CommandLineHelper.installWT(in: bin, bundledURL: tool)
        #expect(try destination("wt") == tool.path)
        #expect(CommandLineHelper.wtSummary(of: wtState()) == .init(isOn: true, canToggle: true, needsUpdate: false, note: nil))

        try CommandLineHelper.uninstallWT(in: bin, bundledURL: tool)
        #expect(wtState() == .notInstalled)
        #expect(try destination("plume") == tool.path)
    }

    @Test func anotherToolsWTIsNeverReplaced() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let homebrew = scratch.appending(path: "Cellar/wt/1.0/bin/wt")
        try FileManager.default.createDirectory(at: homebrew.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: homebrew)
        try link("wt", to: homebrew)

        #expect(CommandLineHelper.wtSummary(of: wtState())
            == .init(isOn: false, canToggle: false, needsUpdate: false, note: "Another tool owns wt"))
        #expect(throws: CommandLineHelper.InstallError.self) {
            try CommandLineHelper.installWT(in: bin, bundledURL: tool)
        }
        try CommandLineHelper.uninstallWT(in: bin, bundledURL: tool)
        #expect(try destination("wt") == homebrew.path)
    }

    /// A dangling `wt` outside any Plume bundle may be the user's own tool,
    /// moved, so it is not Plume's to replace.
    @Test func aDanglingForeignWTIsTakenButADanglingPlumeOneIsOurs() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let gone = scratch.appending(path: "scripts/wt")
        try link("wt", to: gone)
        #expect(wtState() == .occupiedByOther(gone.standardizedFileURL))

        try FileManager.default.removeItem(at: bin.appending(path: "wt"))
        try link("wt", to: scratch.appending(path: "Old/Plume.app/Contents/Helpers/plume"))
        #expect(wtState() == .brokenLink)
        try CommandLineHelper.installWT(in: bin, bundledURL: tool)
        #expect(try destination("wt") == tool.path)
    }

    @Test func anotherPlumesWTIsRepointedOnAndRemovedOff() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let otherTool = try makeOtherPlumeTool()
        try link("wt", to: otherTool)

        #expect(wtState() == .ownedByOtherPlume(otherTool.standardizedFileURL))
        #expect(CommandLineHelper.wtSummary(of: wtState())
            == .init(isOn: true, canToggle: true, needsUpdate: true, note: "Another copy of Plume owns wt"))

        try CommandLineHelper.installWT(in: bin, bundledURL: tool)
        #expect(try destination("wt") == tool.path)

        try FileManager.default.removeItem(at: bin.appending(path: "wt"))
        try link("wt", to: otherTool)
        try CommandLineHelper.uninstallWT(in: bin, bundledURL: tool)
        #expect(wtState() == .notInstalled)
    }
}
