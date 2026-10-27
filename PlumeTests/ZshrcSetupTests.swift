import Foundation
import Testing
@testable import Plume

/// Settings ▸ Command line's Add to .zshrc: appends the init line once,
/// creates a missing file, separates it from a last line with no newline, and
/// keeps a symlinked `.zshrc` a symlink.
struct ZshrcSetupTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "zshrc-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func contents(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    @Test func createsAMissingFile() throws {
        let file = directory.appending(path: "zdotdir/.zshrc")
        try ZshrcSetup.add(to: file)
        #expect(try contents(file) == ZshrcSetup.initLine + "\n")
        #expect(ZshrcSetup.isAdded(to: file))
    }

    @Test func appendsAfterAFinalNewline() throws {
        let file = directory.appending(path: ".zshrc")
        try "export A=1\n".write(to: file, atomically: true, encoding: .utf8)
        try ZshrcSetup.add(to: file)
        #expect(try contents(file) == "export A=1\n" + ZshrcSetup.initLine + "\n")
    }

    @Test func addsALeadingNewlineWhenTheFileLacksOne() throws {
        let file = directory.appending(path: ".zshrc")
        try "export A=1".write(to: file, atomically: true, encoding: .utf8)
        try ZshrcSetup.add(to: file)
        #expect(try contents(file) == "export A=1\n" + ZshrcSetup.initLine + "\n")
    }

    @Test func addingTwiceAppendsOnce() throws {
        let file = directory.appending(path: ".zshrc")
        try ZshrcSetup.add(to: file)
        try ZshrcSetup.add(to: file)
        #expect(try contents(file) == ZshrcSetup.initLine + "\n")
    }

    @Test func anExistingVariantCountsAsAdded() throws {
        let file = directory.appending(path: ".zshrc")
        let original = "  eval \"$(~/.local/bin/plume init zsh)\"\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        #expect(ZshrcSetup.isAdded(to: file))
        try ZshrcSetup.add(to: file)
        #expect(try contents(file) == original)
    }

    @Test func aLineWithAliasFlagsCounts() {
        #expect(ZshrcSetup.containsInitLine("eval \"$(plume init zsh --alias wt --alias stack)\"\n"))
    }

    @Test func aCommentedOutLineDoesNotCount() {
        #expect(!ZshrcSetup.containsInitLine("# eval \"$(plume init zsh --aliases)\"\n"))
    }

    @Test func aMissingFileIsNotAdded() {
        #expect(!ZshrcSetup.isAdded(to: directory.appending(path: "absent")))
    }

    @Test func keepsASymlinkedZshrcALink() throws {
        let target = directory.appending(path: "dotfiles-zshrc")
        try "export A=1\n".write(to: target, atomically: true, encoding: .utf8)
        let link = directory.appending(path: ".zshrc")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try ZshrcSetup.add(to: link)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
        #expect(try contents(target) == "export A=1\n" + ZshrcSetup.initLine + "\n")
    }

    @Test func zdotdirWinsOverHome() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(ZshrcSetup.zshrcURL(zdotdir: "/Users/me/.config/zsh", home: home).path == "/Users/me/.config/zsh/.zshrc")
        #expect(ZshrcSetup.zshrcURL(zdotdir: nil, home: home).path == "/Users/me/.zshrc")
        #expect(ZshrcSetup.zshrcURL(zdotdir: "", home: home).path == "/Users/me/.zshrc")
    }

    @Test func theDisplayPathAbbreviatesHome() {
        let zdotdir = URL.homeDirectory.appending(path: ".config/zsh").path
        #expect(ZshrcSetup.displayPath(ZshrcSetup.zshrcURL(zdotdir: zdotdir)) == "~/.config/zsh/.zshrc")
        #expect(ZshrcSetup.displayPath(ZshrcSetup.zshrcURL(zdotdir: nil)) == "~/.zshrc")
    }
}
