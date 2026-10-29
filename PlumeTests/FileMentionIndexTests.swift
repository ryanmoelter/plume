import Foundation
import Synchronization
import Testing
@testable import Plume

struct FileMentionIndexTests {
    private func makeDirectory() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "plume-mentions-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func write(_ relativePath: String, in root: String) throws {
        let url = URL(fileURLWithPath: root).appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "x\n".write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeRepository() throws -> String {
        let path = try makeDirectory()
        try GitRunner.run(["init", "-b", "main"], in: path)
        try write(".gitignore", in: path)
        try "ignored.txt\nbuild/\n".write(toFile: "\(path)/.gitignore", atomically: true, encoding: .utf8)
        try write("Sources/App/Main.swift", in: path)
        try write("Sources/App/Untracked.swift", in: path)
        try write("ignored.txt", in: path)
        try write("build/output.o", in: path)
        try GitRunner.run(["add", ".gitignore", "Sources/App/Main.swift"], in: path)
        return path
    }

    private func query(_ text: String) throws -> MentionQuery {
        let typed = "@" + text
        return try #require(MentionQuery.query(text: typed, caretLocation: (typed as NSString).length))
    }

    private func paths(_ entries: [MentionCandidate.FileEntry]) -> Set<String> {
        Set(entries.map(\.path))
    }

    private func paths(_ ranked: [RankedMention]) -> [String] {
        ranked.compactMap { if case .file(let entry) = $0.candidate { entry.path } else { nil } }
    }

    @Test func aRepositoryListsTrackedAndUntrackedFilesButNotIgnoredOnes() async throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }

        let entries = await FileMentionIndex().entries(in: repository)

        #expect(paths(entries) == [
            ".gitignore",
            "Sources",
            "Sources/App",
            "Sources/App/Main.swift",
            "Sources/App/Untracked.swift",
        ])
        #expect(entries.first { $0.path == "Sources/App" }?.isDirectory == true)
        #expect(entries.first { $0.path == "Sources/App/Main.swift" }?.isDirectory == false)
    }

    @Test func aSubdirectoryListsPathsRelativeToItself() async throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }

        let entries = await FileMentionIndex().entries(in: "\(repository)/Sources")

        #expect(paths(entries) == ["App", "App/Main.swift", "App/Untracked.swift"])
    }

    @Test func matchesRankAgainstTheIndex() async throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }

        let results = await FileMentionIndex().matches(for: try query("main"), in: repository)

        #expect(paths(results).first == "Sources/App/Main.swift")
    }

    @Test func aHashQueryOrAMissingDirectoryFindsNoFiles() async throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        let index = FileMentionIndex()
        let hash = try #require(MentionQuery.query(text: "#main", caretLocation: 5))

        #expect(await index.matches(for: hash, in: repository).isEmpty)
        #expect(await index.matches(for: try query("main"), in: nil).isEmpty)
    }

    @Test func aStaleListingIsServedWhileItRefreshes() async throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        let index = FileMentionIndex(maxAge: 0)

        _ = await index.entries(in: repository)
        try write("Sources/Late.swift", in: repository)

        #expect(!paths(await index.entries(in: repository)).contains("Sources/Late.swift"))
        await index.settle()
        #expect(paths(await index.entries(in: repository)).contains("Sources/Late.swift"))
    }

    @Test func aWalkOutsideGitSkipsHiddenAndBuildFolders() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        for path in [
            "notes.md",
            ".env",
            "src/app.js",
            "node_modules/left-pad/index.js",
            ".build/debug/app",
            "DerivedData/Build/x",
            ".hidden/secret.txt",
        ] {
            try write(path, in: root)
        }

        let entries = FileMentionIndex.walk(root, limits: .init(), homeDirectory: "/nowhere").entries

        #expect(paths(entries) == ["notes.md", ".env", "src", "src/app.js"])
    }

    @Test func aWalkNeverListsHomeOrEntersItsProtectedFolders() throws {
        let parent = try makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: parent) }
        let home = parent + "/home"
        for path in ["home/notes.md", "home/Documents/private.txt", "home/Library/Prefs/x.plist", "home/code/app.js"] {
            try write(path, in: parent)
        }

        #expect(FileMentionIndex.walk(home, limits: .init(), homeDirectory: home).entries.isEmpty)
        #expect(paths(FileMentionIndex.walk(parent, limits: .init(), homeDirectory: home).entries) == [
            "home", "home/notes.md", "home/Documents", "home/Library", "home/code", "home/code/app.js",
        ])
        #expect(paths(FileMentionIndex.walk(home + "/Documents", limits: .init(), homeDirectory: home).entries) == ["private.txt"])
    }

    @Test func aWalkStopsAtItsDepthAndEntryCaps() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("a/b/c/d.txt", in: root)

        let shallow = FileMentionIndex.walk(root, limits: .init(maxDepth: 2, maxEntries: 100), homeDirectory: "/nowhere").entries
        #expect(paths(shallow) == ["a", "a/b"])

        let capped = FileMentionIndex.walk(root, limits: .init(maxDepth: 6, maxEntries: 3), homeDirectory: "/nowhere").entries
        #expect(capped.count == 3)
    }

    @Test func aWalkPastItsDeadlineIsMarkedIncomplete() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("a.txt", in: root)

        let late = FileMentionIndex.walk(root, limits: .init(walkTimeout: .zero), homeDirectory: "/nowhere")
        #expect(!late.isComplete)
        #expect(FileMentionIndex.walk(root, limits: .init(), homeDirectory: "/nowhere").isComplete)
    }

    @Test func aGitListingIsCapped() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }

        guard case .paths(let paths) = FileMentionIndex.gitPaths(in: repository, limits: .init(maxGitPaths: 2)) else {
            Issue.record("expected a git listing")
            return
        }
        #expect(paths.count == 2)
    }

    @Test func aGitListingKeepsLeadingSpacesInNames() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: repository) }
        try write(" lead.txt", in: repository)

        guard case .paths(let paths) = FileMentionIndex.gitPaths(in: repository, limits: .init()) else {
            Issue.record("expected a listing")
            return
        }
        #expect(paths.contains(" lead.txt"))
    }

    @Test func aGitTimeoutKillsTheCommand() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let fifo = directory + "/pipe"
        #expect(mkfifo(fifo, 0o600) == 0)
        let start = Date()

        #expect {
            // Opening a FIFO with no writer blocks inside git itself.
            try GitRunner.run(["hash-object", fifo], in: directory, timeout: .milliseconds(200))
        } throws: { ($0 as? GitError)?.timedOut == true }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func aTimedOutGitListingIsRetriedOnTheNextLookup() async {
        let calls = GitCalls(answers: [.timedOut, .paths(["a.swift"])])
        let index = FileMentionIndex(homeDirectory: "/nowhere", listGitPaths: { directory, _ in calls.answer(directory) })

        #expect(await index.entries(in: "/repo").isEmpty)
        #expect(await index.entries(in: "/repo").isEmpty)
        await index.settle()
        #expect(paths(await index.entries(in: "/repo")) == ["a.swift"])
    }

    @Test func aRepositoryAtHomeListsNothingAndNeverRunsGit() async throws {
        let home = try makeRepository()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let calls = GitCalls(answers: [])
        let index = FileMentionIndex(homeDirectory: home, listGitPaths: { directory, _ in calls.answer(directory) })

        #expect(await index.entries(in: home).isEmpty)
        #expect(calls.directories.withLock { $0 }.isEmpty)
    }

    @Test func aGitListingFromAboveHomeSkipsItsProtectedFolders() async throws {
        let parent = try makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: parent) }
        try GitRunner.run(["init", "-b", "main"], in: parent)
        for path in ["home/notes.md", "home/Documents/private.txt", "home/Library/Prefs/x.plist", "home/code/app.js"] {
            try write(path, in: parent)
        }
        let index = FileMentionIndex(homeDirectory: parent + "/home")

        #expect(paths(await index.entries(in: parent)) == [
            "home", "home/notes.md", "home/code", "home/code/app.js",
        ])
        #expect(paths(await index.entries(in: parent + "/home/Documents")) == ["private.txt"])
    }

    @Test func onlyTheMostRecentlyUsedDirectoriesStayCached() async {
        let calls = GitCalls(answers: [])
        let index = FileMentionIndex(
            homeDirectory: "/nowhere",
            limits: .init(maxCachedDirectories: 2),
            listGitPaths: { directory, _ in calls.answer(directory) }
        )

        for directory in ["/a", "/b", "/a", "/c", "/a", "/b"] {
            _ = await index.entries(in: directory)
        }

        #expect(calls.directories.withLock { $0 } == ["/a", "/b", "/c", "/b"])
    }

    @Test func aTildeQueryListsTheDeepestTypedFolderUnderTheInjectedHome() async throws {
        let home = try makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try write("Development/Plume/README.md", in: home)
        try write("Development/Other/README.md", in: home)
        try write("Development/.secret/x", in: home)
        let index = FileMentionIndex(homeDirectory: home)

        let results = await index.matches(for: try query("~/Development/Pl"), in: nil)
        #expect(paths(results) == ["~/Development/Plume"])

        let inside = await index.matches(for: try query("~/Development/"), in: nil)
        #expect(Set(paths(inside)) == ["~/Development/Plume", "~/Development/Other"])
    }

    @Test func anAbsoluteQueryKeepsItsTypedForm() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write("folder/file.txt", in: root)

        let entries = FileMentionIndex.listing(typedPath: root + "/fo", homeDirectory: "/nowhere")

        #expect(entries == [.init(path: root + "/folder", isDirectory: true)])
    }
}

private final class GitCalls: Sendable {
    let directories = Mutex<[String]>([])
    private let answers: Mutex<[FileMentionIndex.GitListing]>

    /// Answers in order, then `.paths(["f"])` once they run out.
    init(answers: [FileMentionIndex.GitListing]) {
        self.answers = Mutex(answers)
    }

    func answer(_ directory: String) -> FileMentionIndex.GitListing {
        directories.withLock { $0.append(directory) }
        return answers.withLock { $0.isEmpty ? .paths(["f"]) : $0.removeFirst() }
    }
}
