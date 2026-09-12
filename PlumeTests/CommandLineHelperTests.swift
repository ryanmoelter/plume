import Foundation
import Testing

@testable import Plume

/// Covers how `CommandLineHelper` classifies whatever sits at the install
/// path: absent, Plume's own link, someone else's, or a link whose target
/// has gone away.
@MainActor
struct CommandLineHelperTests {
    private func makeScratch() throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeBundled(in directory: URL) throws -> URL {
        let url = directory.appending(path: "bundled-plume-notify")
        try Data().write(to: url)
        return url
    }

    @Test func nothingAtThePathIsNotInstalled() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let state = CommandLineHelper.state(
            installedURL: scratch.appending(path: "plume-notify"),
            bundledURL: try makeBundled(in: scratch)
        )
        #expect(state == .notInstalled)
    }

    @Test func aLinkToTheBundledScriptIsInstalled() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let bundled = try makeBundled(in: scratch)
        let installed = scratch.appending(path: "plume-notify")
        try FileManager.default.createSymbolicLink(at: installed, withDestinationURL: bundled)

        #expect(CommandLineHelper.state(installedURL: installed, bundledURL: bundled) == .installed)
    }

    @Test func aRegularFileIsNotOverwritable() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let installed = scratch.appending(path: "plume-notify")
        try Data().write(to: installed)

        let state = CommandLineHelper.state(
            installedURL: installed, bundledURL: try makeBundled(in: scratch)
        )
        #expect(state == .occupiedByOther(nil))
    }

    @Test func aLinkToAnotherToolIsNotOverwritable() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let other = scratch.appending(path: "some-other-tool")
        try Data().write(to: other)
        let installed = scratch.appending(path: "plume-notify")
        try FileManager.default.createSymbolicLink(at: installed, withDestinationURL: other)

        let state = CommandLineHelper.state(
            installedURL: installed, bundledURL: try makeBundled(in: scratch)
        )
        #expect(state == .occupiedByOther(other.standardizedFileURL))
    }

    @Test func aLinkWhoseTargetIsGoneIsBroken() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let installed = scratch.appending(path: "plume-notify")
        try FileManager.default.createSymbolicLink(
            at: installed, withDestinationURL: scratch.appending(path: "vanished")
        )

        let state = CommandLineHelper.state(
            installedURL: installed, bundledURL: try makeBundled(in: scratch)
        )
        #expect(state == .brokenLink)
    }
}
