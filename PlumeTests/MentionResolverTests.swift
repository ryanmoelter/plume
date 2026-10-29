import Foundation
import Synchronization
import Testing
@testable import Plume

struct MentionExpansionTests {
    private func expand(_ text: String, _ known: [MentionReference.Kind: String]) -> String {
        MentionExpansion.expanding(text) { kind in
            known[kind].map { ResolvedMention(target: $0, title: nil, state: .file(isDirectory: false)) }
        }
    }

    @Test func aResolvedReferenceBecomesALink() {
        let text = expand("fix @DROID-1 and #12, see @Plume/UI/.", [
            .linear(identifier: "DROID-1"): "https://linear.app/acme/issue/DROID-1",
            .pullRequest(number: 12): "https://github.com/o/r/pull/12",
            .file(path: "Plume/UI", isDirectory: true): "Plume/UI",
        ])
        #expect(text == "fix [DROID-1](https://linear.app/acme/issue/DROID-1) and "
            + "[#12](https://github.com/o/r/pull/12), see [UI/](Plume/UI).")
    }

    @Test func anUnresolvedReferenceIsSentAsTyped() {
        #expect(expand("ask @DROID-9 about #3", [:]) == "ask @DROID-9 about #3")
        #expect(expand("ask @DROID-9 about #3", [.pullRequest(number: 3): "u"]) == "ask @DROID-9 about [#3](u)")
    }

    @Test func aQuotedPathLinksByNameWithItsTargetBracketed() {
        let text = expand(#"read @"Docs/My Notes.md""#, [.file(path: "Docs/My Notes.md", isDirectory: false): "Docs/My Notes.md"])
        #expect(text == "read [My Notes.md](<Docs/My Notes.md>)")
    }

    @Test func referencesInCodeAndLinksStayAsTyped() {
        let known: [MentionReference.Kind: String] = [.linear(identifier: "DROID-1"): "u"]
        #expect(expand("`@DROID-1` [@DROID-1](x)", known) == "`@DROID-1` [@DROID-1](x)")
    }

    @Test func labelsName() {
        #expect(MentionExpansion.label(for: .linear(identifier: "DROID-1")) == "DROID-1")
        #expect(MentionExpansion.label(for: .pullRequest(number: 7)) == "#7")
        #expect(MentionExpansion.label(for: .file(path: "a/b.swift", isDirectory: false)) == "b.swift")
        #expect(MentionExpansion.label(for: .file(path: "/", isDirectory: true)) == "/")
    }
}

@MainActor
struct MentionResolverTests {
    private final class PathLog: Sendable {
        let paths = Mutex<[String]>([])
    }

    private let tab = UUID()
    private let other = UUID()
    private let checked = PathLog()

    private func resolver(
        linear: [String: MentionCandidate.LinearIssue] = [:],
        pulls: [Int: MentionCandidate.PullRequestEntry] = [:],
        files: [String: Bool] = [:]
    ) -> MentionResolver {
        let checked = checked
        return MentionResolver(dependencies: .init(
            linearIssue: { linear[$0] },
            lookUpLinear: { _ in },
            pullRequest: { number, _ in pulls[number] },
            fileIsDirectory: { path in
                checked.paths.withLock { $0.append(path) }
                return files[path]
            },
            homeDirectory: "/Users/test"
        ))
    }

    @Test func anAcceptedRowExpandsOnlyInItsTab() {
        let resolver = resolver()
        let pull = MentionFixtures.pull(12, "Fix")
        resolver.remember(ResolvedMention(pull), for: .pullRequest(number: 12), tabID: tab)

        #expect(resolver.expandingReferences(in: "see #12", tabID: tab) == "see [#12](https://github.com/acme/app/pull/12)")
        #expect(resolver.expandingReferences(in: "see #12", tabID: other) == "see #12")

        resolver.forgetTab(tab)
        #expect(resolver.expandingReferences(in: "see #12", tabID: tab) == "see #12")
    }

    @Test func aCachedLinearIssueExpandsWithoutBeingAccepted() {
        let issue = MentionFixtures.issue("DROID-7", "Cached")
        let resolver = resolver(linear: ["DROID-7": issue])

        #expect(resolver.expandingReferences(in: "@droid-7", tabID: tab) == "[DROID-7](\(issue.url))")
        #expect(resolver.cachedResolution(of: .linear(identifier: "DROID-7"), tabID: tab)?.title == "Cached")
    }

    @Test func aResolvedPullRequestIsRememberedForSending() async {
        let resolver = resolver(pulls: [5: MentionFixtures.pull(5, "Five")])

        #expect(resolver.expandingReferences(in: "#5", tabID: tab) == "#5")
        #expect(await resolver.resolve(.pullRequest(number: 5), tabID: tab, directory: "/repo")?.title == "Five")
        #expect(resolver.expandingReferences(in: "#5", tabID: tab) == "[#5](https://github.com/acme/app/pull/5)")
        #expect(await resolver.resolve(.pullRequest(number: 6), tabID: tab, directory: "/repo") == nil)
    }

    @Test func aFileResolvesAgainstTheTabDirectoryAndHome() async {
        let resolver = resolver(files: ["/repo/a.swift": false, "/Users/test/notes": true])

        let relative = await resolver.resolve(.file(path: "a.swift", isDirectory: false), tabID: tab, directory: "/repo")
        #expect(relative == ResolvedMention(target: "a.swift", title: nil, state: .file(isDirectory: false)))
        let home = await resolver.resolve(.file(path: "~/notes", isDirectory: true), tabID: tab, directory: nil)
        #expect(home?.target == "/Users/test/notes")
        #expect(await resolver.resolve(.file(path: "gone.swift", isDirectory: false), tabID: tab, directory: "/repo") == nil)
        #expect(await resolver.resolve(.file(path: "a.swift", isDirectory: false), tabID: tab, directory: nil) != nil)
        #expect(checked.paths.withLock { $0 } == ["/repo/a.swift", "/Users/test/notes", "/repo/gone.swift"])
    }

    @Test func anAcceptedFileOrFolderRowNamesTheReferenceItLeaves() throws {
        let folder = MentionCandidate.file(MentionFixtures.file("~/Development", isDirectory: true))
        let (kind, resolution) = try #require(folder.resolvedReference(homeDirectory: "/Users/test"))
        #expect(kind == .file(path: "~/Development", isDirectory: true))
        #expect(resolution.target == "/Users/test/Development")
        #expect(MentionCandidate.filter(.linear).resolvedReference(homeDirectory: "/") == nil)
    }
}
