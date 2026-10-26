import Foundation
import Testing
@testable import Plume

struct FileMentionMatcherTests {
    private func entries(_ paths: [String]) -> [MentionCandidate.FileEntry] {
        paths.map { path in
            path.hasSuffix("/")
                ? .init(path: String(path.dropLast()), isDirectory: true)
                : .init(path: path, isDirectory: false)
        }
    }

    private func paths(_ query: String, in paths: [String]) -> [String] {
        FileMentionMatcher.matches(query, in: entries(paths)).compactMap {
            if case .file(let entry) = $0.candidate { entry.path } else { nil }
        }
    }

    private let tree = [
        "Plume/UI/Chat/",
        "Plume/UI/Chat/ChatComposer.swift",
        "Plume/UI/Chat/ChatComposerTests.swift",
        "Plume/UI/Chat/MarkdownView.swift",
        "Plume/UI/Sidebar/SidebarView.swift",
        "Plume/Models/TaskStore.swift",
        "docs/chat-list.md",
        "README.md",
    ]

    @Test func anExactNameRanksFirst() {
        let results = FileMentionMatcher.matches("chatcomposer.swift", in: entries(tree))
        #expect(results.first?.candidate.id == "file:Plume/UI/Chat/ChatComposer.swift")
        #expect(results.first?.quality == .exact)
    }

    @Test func aNamePrefixBeatsAFolderMatch() {
        let results = paths("chat", in: tree)
        #expect(results.first == "Plume/UI/Chat")
        #expect(results.prefix(4).contains("Plume/UI/Chat/ChatComposer.swift"))
        #expect(results.contains("docs/chat-list.md"))
        #expect(results.contains("Plume/UI/Chat/MarkdownView.swift"))
    }

    @Test func aShorterNameWinsAmongPrefixes() {
        let results = paths("chatcomp", in: tree)
        #expect(results == ["Plume/UI/Chat/ChatComposer.swift", "Plume/UI/Chat/ChatComposerTests.swift"])
    }

    @Test func folderPartsMatchInOrder() {
        let results = FileMentionMatcher.matches("ui/chat/mark", in: entries(tree))
        #expect(results.first?.candidate.id == "file:Plume/UI/Chat/MarkdownView.swift")
        #expect(results.first?.quality == .prefix)
        #expect(paths("chat/ui", in: tree).allSatisfy { !$0.hasPrefix("Plume/UI/Sidebar") })
    }

    @Test func folderPartsMatchWithoutANamePrefix() {
        let results = FileMentionMatcher.matches("plume/models", in: entries(tree))
        #expect(results.first?.candidate.id == "file:Plume/Models/TaskStore.swift")
        #expect(results.first?.quality == .words)
    }

    @Test func aPathLikeQueryMatchesASubsequenceLoosely() {
        let results = FileMentionMatcher.matches("models/tskstr", in: entries(tree))
        #expect(results.map(\.candidate.id) == ["file:Plume/Models/TaskStore.swift"])
        #expect(results.first?.quality == .loose)
    }

    @Test func aTighterSubsequenceScoresHigher() {
        let results = paths("./cv", in: ["a/c/x/y/v.swift", "ChatView.swift"])
        #expect(results.first == "ChatView.swift")
    }

    @Test func aWordLikeQueryNeverMatchesASubsequence() {
        let scattered = ["src/a/l/i/c/e.txt", "malice.txt", "Sources/ALargeImageCache.swift"]
        #expect(paths("alice", in: scattered).isEmpty)
        #expect(paths("tskstr", in: tree).isEmpty)
        #expect(!paths("./alice", in: scattered).isEmpty)
        #expect(!paths("ali.t", in: scattered).isEmpty)
    }

    @Test func aWordStartInsideTheNameMatches() {
        let results = FileMentionMatcher.matches("composer", in: entries(tree))
        #expect(results.first?.candidate.id == "file:Plume/UI/Chat/ChatComposer.swift")
        #expect(results.first?.quality == .words)
        #expect(paths("list", in: tree) == ["docs/chat-list.md"])
    }

    @Test func aFolderScoresSlightlyBelowAFileOfTheSameName() {
        let results = FileMentionMatcher.matches("build", in: entries(["x/build/", "y/build"]))
        #expect(results.first?.candidate.id == "file:y/build")
    }

    @Test func aLeadingDotSlashIsIgnored() {
        #expect(paths("./README", in: tree) == ["README.md"])
    }

    @Test func aHomeQueryMatchesHomePaths() {
        let home = ["~/Desktop/", "~/Development/", "~/Documents/", "~/Development/Plume/"]
        #expect(paths("~/Dev", in: home) == ["~/Development", "~/Development/Plume"])
        #expect(paths("~/Development/", in: home) == ["~/Development/Plume"])
    }

    @Test func nothingMatchesReturnsNothing() {
        #expect(paths("zzz", in: tree).isEmpty)
    }

    @Test func anEmptyQueryListsShallowEntriesFirst() {
        #expect(paths("", in: tree).first == "README.md")
    }

    @Test func resultsAreCappedAtTwenty() {
        let many = (0..<50).map { "Sources/File\($0).swift" }
        #expect(FileMentionMatcher.matches("file", in: entries(many)).count == 20)
    }

    @Test func aBareQueryKeepsTheShallowestShortestPathsInOrder() {
        let deep = (0..<5_000).map { "Sources/Deep/File\($0).swift" }
        let shallow = ["b.md", "a.md", "README.md", "Sources/x.swift"]
        let results = paths("", in: deep + shallow)
        #expect(Array(results.prefix(4)) == ["a.md", "b.md", "README.md", "Sources/x.swift"])
        #expect(results.count == 20)
    }

    @Test func aCancelledSearchOverALargeListingStopsEarly() async {
        let many = entries((0..<10_000).map { "Sources/File\($0).swift" })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return FileMentionMatcher.matches("", in: many)
        }
        #expect(await task.value.isEmpty)
    }
}
