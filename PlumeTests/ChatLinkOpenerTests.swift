import Testing
import Foundation
@testable import Plume

/// Covers how a clicked link's URL resolves to something openable. The agent
/// writes file citations as bare paths, which arrive with no scheme at all,
/// so most of these are about the scheme-less cases.
struct ChatLinkOpenerTests {
    /// A directory with a file in it, to resolve paths against.
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "hello".write(
            to: directory.appendingPathComponent("Notes.md"),
            atomically: true,
            encoding: .utf8
        )
        return directory
    }

    @Test func aWebLinkOpensAsIs() {
        let url = URL(string: "https://example.com/a")!
        #expect(ChatLinkOpener.target(for: url, relativeTo: nil) == .web(url))
    }

    @Test func mailtoOpens() {
        let url = URL(string: "mailto:someone@example.com")!
        #expect(ChatLinkOpener.target(for: url, relativeTo: nil) == .web(url))
    }

    /// Chat content is model output, so an executable scheme never reaches
    /// the system.
    @Test func anUnsupportedSchemeIsRefused() {
        let url = URL(string: "javascript:alert(1)")!
        #expect(ChatLinkOpener.target(for: url, relativeTo: nil) == .unopenable)
    }

    @Test func aRelativePathResolvesAgainstTheDirectory() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = URL(string: "Notes.md")!
        let expected = directory.appendingPathComponent("Notes.md").standardizedFileURL
        #expect(ChatLinkOpener.target(for: url, relativeTo: directory) == .file(expected))
    }

    @Test func anAbsolutePathResolvesWithoutADirectory() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = directory.appendingPathComponent("Notes.md").path
        let url = URL(string: path)!
        #expect(url.scheme == nil)
        let expected = URL(fileURLWithPath: path).standardizedFileURL
        #expect(ChatLinkOpener.target(for: url, relativeTo: nil) == .file(expected))
    }

    /// `Foo.swift#L42` is how a citation carries a line number.
    @Test func aLineFragmentIsStrippedFromAPath() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = URL(string: "Notes.md#L42")!
        let expected = directory.appendingPathComponent("Notes.md").standardizedFileURL
        #expect(ChatLinkOpener.target(for: url, relativeTo: directory) == .file(expected))
    }

    @Test func aPathThatDoesNotExistIsUnopenable() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = URL(string: "Missing.md")!
        #expect(ChatLinkOpener.target(for: url, relativeTo: directory) == .unopenable)
    }

    /// Without a base there is nothing to resolve against, and guessing a
    /// directory would open the wrong file.
    @Test func aRelativePathWithNoDirectoryIsUnopenable() {
        let url = URL(string: "Plume/UI/Chat/MarkdownView.swift")!
        #expect(ChatLinkOpener.target(for: url, relativeTo: nil) == .unopenable)
    }

    @Test func aFileURLPointingNowhereIsUnopenable() {
        let url = URL(fileURLWithPath: "/definitely/not/here-\(UUID().uuidString).md")
        #expect(ChatLinkOpener.target(for: url, relativeTo: nil) == .unopenable)
    }

    @Test func aFileURLThatExistsOpens() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("Notes.md")
        #expect(ChatLinkOpener.target(for: url, relativeTo: nil) == .file(url.standardizedFileURL))
    }

    /// The parse these targets come from, so the suite covers the real input
    /// rather than hand-built URLs.
    @Test func markdownGivesAScheme_lessURLForAPathCitation() {
        let parsed = try? AttributedString(
            markdown: "See [Notes.md](docs/Notes.md) for more.",
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        let link = parsed?.runs.compactMap(\.link).first
        #expect(link?.scheme == nil)
        #expect(link?.absoluteString == "docs/Notes.md")
    }
}
