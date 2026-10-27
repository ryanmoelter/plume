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

    // MARK: Recommended line

    private func tool(_ path: String) -> URL { URL(fileURLWithPath: path) }

    private let otherStack = ["stack": [URL(fileURLWithPath: "/Users/me/.scripts/stack")]]
    private let otherWT = ["wt": [URL(fileURLWithPath: "/Users/me/.scripts/wt")]]

    @Test func withNoOtherToolItRecommendsAliases() {
        #expect(ZshrcSetup.recommendedLine(executables: [:]) == #"eval "$(plume init zsh --aliases)""#)
    }

    @Test func anotherStackLeavesOnlyWt() {
        #expect(ZshrcSetup.recommendedLine(executables: otherStack) == #"eval "$(plume init zsh --alias wt)""#)
    }

    @Test func anotherWtLeavesOnlyStack() {
        #expect(ZshrcSetup.recommendedLine(executables: otherWT) == #"eval "$(plume init zsh --alias stack)""#)
    }

    @Test func bothTakenRecommendsNoAliases() {
        #expect(ZshrcSetup.recommendedLine(executables: otherStack.merging(otherWT) { $1 }) == #"eval "$(plume init zsh)""#)
    }

    @Test func aPlumeOwnedLinkAloneDoesNotCount() {
        let ours = [
            "wt": [tool("/Users/me/Library/Developer/Xcode/DerivedData/Plume-abc/Build/Products/Debug/Plume.app/Contents/Helpers/plume")],
            "stack": [tool("/Applications/Plume.app/Contents/Helpers/plume")],
        ]
        #expect(ZshrcSetup.recommendedLine(executables: ours) == ZshrcSetup.initLine)
    }

    @Test func anotherToolCountsBesideAPlumeOwnedLink() {
        let both = ["wt": [tool("/Applications/Plume.app/Contents/Helpers/plume"), tool("/Users/me/.scripts/wt")]]
        #expect(ZshrcSetup.recommendedLine(executables: both) == #"eval "$(plume init zsh --alias stack)""#)
    }

    @Test func scanningResolvesLinksAndSkipsNonExecutables() throws {
        let manager = FileManager.default
        let bundleTool = directory.appending(path: "Plume.app/Contents/Helpers/plume")
        try manager.createDirectory(at: bundleTool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: bundleTool, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundleTool.path)
        let local = directory.appending(path: "local")
        let scripts = directory.appending(path: "scripts")
        try manager.createDirectory(at: local, withIntermediateDirectories: true)
        try manager.createDirectory(at: scripts, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: local.appending(path: "wt"), withDestinationURL: bundleTool)
        let script = scripts.appending(path: "stack")
        try "#!/bin/sh\n".write(to: script, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try "not executable".write(to: scripts.appending(path: "wt"), atomically: true, encoding: .utf8)
        try manager.createSymbolicLink(at: scripts.appending(path: "dangling"), withDestinationURL: directory.appending(path: "gone"))

        let found = ZshrcSetup.executables(in: [local.path, scripts.path, directory.appending(path: "absent").path])

        #expect(found["wt"]?.map(\.lastPathComponent) == ["plume"])
        #expect(found["stack"]?.map(\.lastPathComponent) == ["stack"])
        #expect(ZshrcSetup.recommendedLine(executables: found) == #"eval "$(plume init zsh --alias wt)""#)
    }

    // MARK: Login shell PATH

    @Test func theLoginPathComesFromTheLastMarkerLine() {
        #expect(LoginShellPath.parse("motd\n__PLUME_PATH__/a:/b\n") == "/a:/b")
        #expect(LoginShellPath.parse("__PLUME_PATH__/old\nnoise\n__PLUME_PATH__/new\n") == "/new")
        #expect(LoginShellPath.parse("no marker\n") == nil)
        #expect(LoginShellPath.parse("__PLUME_PATH__\n") == nil)
    }

    private func fakeShell(_ body: String) throws -> String {
        let file = directory.appending(path: "shell-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file.path
    }

    @Test func aShellsPathIsSplitIntoDirectories() throws {
        let shell = try fakeShell("printf 'banner\\n\\n__PLUME_PATH__/x/bin:/y/bin\\n'")
        #expect(LoginShellPath.directories(shell: shell, timeout: 5, fallback: ["/fallback"]) == ["/x/bin", "/y/bin"])
    }

    @Test func aFailingShellFallsBack() throws {
        let shell = try fakeShell("exit 3")
        #expect(LoginShellPath.directories(shell: shell, timeout: 5, fallback: ["/fallback"]) == ["/fallback"])
    }

    @Test func aHungShellFallsBackAfterTheTimeout() throws {
        let shell = try fakeShell("exec sleep 30")
        let started = Date()
        #expect(LoginShellPath.directories(shell: shell, timeout: 0.5, fallback: ["/fallback"]) == ["/fallback"])
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func theFallbackIncludesLocalBin() {
        #expect(LoginShellPath.fallbackDirectories().contains(URL.homeDirectory.appending(path: ".local/bin").path))
    }

    @Test func addingATailoredLineAppendsThatLine() throws {
        let file = directory.appending(path: ".zshrc")
        let line = #"eval "$(plume init zsh --alias wt)""#
        try ZshrcSetup.add(to: file, line: line)
        #expect(try contents(file) == line + "\n")
    }
}
