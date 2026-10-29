import Foundation
import Testing
@testable import Plume

struct ReferenceTargetTests {
    private let base = URL(fileURLWithPath: "/repo")

    private func classify(_ string: String, base: URL? = URL(fileURLWithPath: "/repo")) -> ReferenceTarget? {
        URL(string: string).flatMap { ReferenceTarget.classify($0, base: base) }
    }

    @Test func aLinearIssueURLNamesItsIdentifier() {
        #expect(classify("https://linear.app/plume/issue/PLUME-101") == .linear(identifier: "PLUME-101"))
        #expect(classify("https://linear.app/plume/issue/PLUME-101/add-chips") == .linear(identifier: "PLUME-101"))
        #expect(classify("https://linear.app/plume/issue/plume-101/add-chips?foo=1") == .linear(identifier: "PLUME-101"))
    }

    @Test func aLinearURLThatIsNotAnIssueIsNotAReference() {
        #expect(classify("https://linear.app/plume/project/chips") == nil)
        #expect(classify("https://linear.app/plume") == nil)
    }

    @Test func aPullRequestURLNamesItsRepositoryAndNumber() {
        let expected = ReferenceTarget.pullRequest(owner: "ryanmoelter", repo: "Plume", number: 12)
        #expect(classify("https://github.com/ryanmoelter/Plume/pull/12") == expected)
        #expect(classify("https://github.com/ryanmoelter/Plume/pull/12/files") == expected)
        #expect(classify("https://github.com/ryanmoelter/Plume/pull/12#discussion_r1") == expected)
        #expect(classify("https://www.github.com/ryanmoelter/Plume/pull/12") == expected)
    }

    @Test func anIssueOrAnotherHostIsNotAPullRequest() {
        #expect(classify("https://github.com/ryanmoelter/Plume/issues/12") == nil)
        #expect(classify("https://gitlab.com/ryanmoelter/Plume/pull/12") == nil)
        #expect(classify("https://example.com/a") == nil)
        #expect(classify("mailto:someone@example.com") == nil)
    }

    @Test func aRelativePathResolvesAgainstTheBase() {
        #expect(classify("Sources/App.swift") == .file(path: "/repo/Sources/App.swift"))
        #expect(classify("Sources/../App.swift") == .file(path: "/repo/App.swift"))
        #expect(classify("Sources/App.swift", base: nil) == nil)
    }

    @Test func aLineFragmentIsDropped() {
        #expect(classify("Sources/App.swift#L42") == .file(path: "/repo/Sources/App.swift"))
    }

    @Test func absoluteAndHomePathsIgnoreTheBase() {
        #expect(classify("/etc/hosts", base: nil) == .file(path: "/etc/hosts"))
        #expect(classify("file:///etc/hosts", base: nil) == .file(path: "/etc/hosts"))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(classify("~/notes.md", base: nil) == .file(path: home + "/notes.md"))
    }

    @Test func aPercentEncodedSpaceIsDecoded() {
        #expect(classify("My%20Notes.md") == .file(path: "/repo/My Notes.md"))
    }

    @Test func canonicalLabels() {
        #expect(ReferenceTarget.linear(identifier: "PLUME-101").canonicalLabel == "PLUME-101")
        #expect(ReferenceTarget.pullRequest(owner: "o", repo: "r", number: 12).canonicalLabel == "#12")
        #expect(ReferenceTarget.file(path: "/repo/Sources/App.swift").canonicalLabel == "App.swift")
    }
}
