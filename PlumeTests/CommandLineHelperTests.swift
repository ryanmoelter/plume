import Foundation
import Testing

@testable import Plume

/// Covers how `CommandLineHelper` classifies whatever sits at each install
/// path — absent, Plume's own link, an older Plume's, someone else's, or a
/// link whose target has gone away — and that install, uninstall and the
/// launch-time repoint touch only links Plume owns.
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

    @Test(arguments: [false, true])
    func aLinkToThisBundlesLegacyScriptIsOutdated(claimsOtherPlumeBundles: Bool) throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let legacy = CommandLineHelper.legacyScriptURL(inBundle: bundle)
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: legacy)
        try link("plume-notify", to: legacy)
        let state = CommandLineHelper.state(
            of: bin.appending(path: "plume-notify"), bundledURL: tool, claimsOtherPlumeBundles: claimsOtherPlumeBundles
        )
        #expect(state == .outdated(legacy.standardizedFileURL))
    }

    /// A release build takes over another Plume's link; a debug build leaves
    /// it to that Plume.
    @Test func aLinkIntoAnotherPlumeBundleIsOursOnlyInARelease() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let otherTool = try makeOtherPlumeTool()
        try link("plume", to: otherTool)
        let url = bin.appending(path: "plume")

        #expect(CommandLineHelper.state(of: url, bundledURL: tool, claimsOtherPlumeBundles: true)
            == .outdated(otherTool.standardizedFileURL))
        #expect(CommandLineHelper.state(of: url, bundledURL: tool, claimsOtherPlumeBundles: false)
            == .ownedByOtherPlume(otherTool.standardizedFileURL))
    }

    @Test func aDebugBuildNeitherReplacesNorRemovesAnotherPlumesLink() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let otherTool = try makeOtherPlumeTool()
        try link("plume", to: otherTool)

        #expect(throws: CommandLineHelper.InstallError.self) {
            try CommandLineHelper.install(in: bin, bundledURL: tool, claimsOtherPlumeBundles: false)
        }
        #expect(try destination("plume") == otherTool.path)
        #expect(try destination("plume-notify") == tool.path)

        try CommandLineHelper.uninstall(in: bin, bundledURL: tool, claimsOtherPlumeBundles: false)
        #expect(try destination("plume") == otherTool.path)
        #expect(state("plume-notify") == .notInstalled)
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

    /// Settings must still offer Remove for the Plume link beside a name
    /// another tool owns, and say which name that is.
    @Test func aPartialInstallBesideAForeignFileCanBeRemoved() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try Data().write(to: bin.appending(path: "plume"))
        try link("plume-notify", to: tool)

        let summary = summary()
        #expect(summary.progress == .installed)
        #expect(summary.taken == [.init(name: "plume", byOtherPlume: false)])
        #expect(summary.canRemove)
        #expect(summary.installTitle == nil)
        #expect(summary.statusLines == ["plume-notify: installed", "Another tool owns plume"])
    }

    @Test func aNameTakenByAnotherPlumeSaysSo() {
        let summary = CommandLineHelper.summary(of: [
            ("plume", .ownedByOtherPlume(URL(fileURLWithPath: "/Applications/Plume.app/Contents/Helpers/plume"))),
            ("plume-notify", .notInstalled),
        ])
        #expect(summary.installTitle == "Install")
        #expect(!summary.canRemove)
        #expect(summary.statusLines == ["plume-notify: not installed", "Another copy of Plume owns plume"])
    }

    @Test func everyNameTakenOffersNothing() {
        let summary = CommandLineHelper.summary(of: [("plume", .occupiedByOther(nil)), ("plume-notify", .occupiedByOther(nil))])
        #expect(summary.progress == .allTaken)
        #expect(summary.installTitle == nil)
        #expect(!summary.canRemove)
        #expect(summary.statusLines == ["Another tool owns plume", "Another tool owns plume-notify"])
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
        #expect(summary().taken == [.init(name: "plume-notify", byOtherPlume: false)])
    }

    @Test func uninstallRemovesOnlyPlumesLinks() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try CommandLineHelper.install(in: bin, bundledURL: tool)
        #expect(summary().progress == .installed)

        try CommandLineHelper.uninstall(in: bin, bundledURL: tool)
        #expect(summary().progress == .notInstalled)
    }

    @Test func launchRepointsTheLegacyScriptLinkAndAddsPlume() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try link("plume-notify", to: CommandLineHelper.legacyScriptURL(inBundle: bundle))
        #expect(summary().progress == .needsUpdate)

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
}
