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

    @Test func aLinkIntoAnotherPlumeBundleIsOutdated() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let legacy = CommandLineHelper.legacyScriptURL(inBundle: bundle)
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: legacy)
        try link("plume-notify", to: legacy)
        #expect(state("plume-notify") == .outdated(legacy.standardizedFileURL))
    }

    @Test func aLinkWhoseTargetIsGoneIsBroken() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try link("plume", to: scratch.appending(path: "vanished"))
        #expect(state("plume") == .brokenLink)
    }

    @Test func installLinksEveryNameAndSkipsAForeignFile() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try Data("mine".utf8).write(to: bin.appending(path: "plume-notify"))

        #expect(throws: CommandLineHelper.InstallError.self) {
            try CommandLineHelper.install(in: bin, bundledURL: tool)
        }
        #expect(state("plume") == .installed)
        #expect(try Data(contentsOf: bin.appending(path: "plume-notify")) == Data("mine".utf8))
        #expect(CommandLineHelper.summary(of: CommandLineHelper.states(in: bin, bundledURL: tool))
            == .occupied(name: "plume-notify"))
    }

    @Test func uninstallRemovesOnlyPlumesLinks() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try CommandLineHelper.install(in: bin, bundledURL: tool)
        #expect(CommandLineHelper.summary(of: CommandLineHelper.states(in: bin, bundledURL: tool)) == .installed)

        try CommandLineHelper.uninstall(in: bin, bundledURL: tool)
        #expect(CommandLineHelper.summary(of: CommandLineHelper.states(in: bin, bundledURL: tool)) == .notInstalled)
    }

    @Test func launchRepointsTheLegacyScriptLinkAndAddsPlume() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try link("plume-notify", to: CommandLineHelper.legacyScriptURL(inBundle: bundle))
        #expect(CommandLineHelper.summary(of: CommandLineHelper.states(in: bin, bundledURL: tool)) == .needsUpdate)

        CommandLineHelper.repointLegacyLinks(in: bin, bundleURL: bundle, bundledURL: tool)

        #expect(try destination("plume-notify") == tool.path)
        #expect(try destination("plume") == tool.path)
    }

    @Test func launchLeavesAnotherBundlesLinksAlone() throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        let installed = scratch.appending(path: "Applications/Plume.app")
        let legacy = CommandLineHelper.legacyScriptURL(inBundle: installed)
        try link("plume-notify", to: legacy)

        CommandLineHelper.repointLegacyLinks(in: bin, bundleURL: bundle, bundledURL: tool)

        #expect(try destination("plume-notify") == legacy.path)
        #expect(state("plume") == .notInstalled)
    }
}
