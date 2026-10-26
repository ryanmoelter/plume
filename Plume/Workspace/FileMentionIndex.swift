import Foundation

/// The files and folders a mention can name, per tab directory.
///
/// Inside a git checkout the list is what `git ls-files` reports, so ignored
/// files stay out; elsewhere it is a bounded walk, which never lists the home
/// directory itself or enters the folders macOS asks permission for. A cached
/// list older than `maxAge` is still served while a refresh runs, and only the
/// `maxCachedDirectories` most recently used directories stay cached.
actor FileMentionIndex {
    static let shared = FileMentionIndex()

    nonisolated struct Limits: Sendable {
        var maxDepth = 6
        var maxEntries = 20_000
        var maxGitPaths = 200_000
        var gitTimeout: Duration = .seconds(10)
        var maxCachedDirectories = 8
    }

    nonisolated enum GitListing: Sendable, Equatable {
        case paths([String])
        case notARepository
        case timedOut
    }

    typealias ListGitPaths = @Sendable (_ directory: String, _ limits: Limits) -> GitListing

    private struct Listing {
        let entries: [FileMentionMatcher.Prepared]
        let fetchedAt: Date
    }

    private var listings: [String: Listing] = [:]
    /// Least recently used first.
    private var recentDirectories: [String] = []
    private var loads: [String: Task<[FileMentionMatcher.Prepared], Never>] = [:]

    private let homeDirectory: String
    private let maxAge: TimeInterval
    private let limits: Limits
    private let now: @Sendable () -> Date
    private let listGitPaths: ListGitPaths

    init(
        homeDirectory: String = NSHomeDirectory(),
        maxAge: TimeInterval = 15,
        limits: Limits = Limits(),
        now: @escaping @Sendable () -> Date = { Date() },
        listGitPaths: @escaping ListGitPaths = { FileMentionIndex.gitPaths(in: $0, limits: $1) }
    ) {
        self.homeDirectory = homeDirectory
        self.maxAge = maxAge
        self.limits = limits
        self.now = now
        self.listGitPaths = listGitPaths
    }

    /// Empty for a `#` query, or a relative one with no tab directory.
    func matches(
        for query: MentionQuery,
        in directory: String?,
        limit: Int = FileMentionMatcher.defaultLimit
    ) async -> [RankedMention] {
        guard query.scope != .pullRequests else { return [] }
        let entries: [FileMentionMatcher.Prepared]
        if query.isAbsolutePath {
            entries = Self.listing(typedPath: query.text, homeDirectory: homeDirectory).map(FileMentionMatcher.Prepared.init)
        } else if let directory {
            entries = await prepared(in: directory)
        } else {
            return []
        }
        guard !Task.isCancelled else { return [] }
        return FileMentionMatcher.matches(query.text, in: entries, limit: limit)
    }

    func entries(in directory: String) async -> [MentionCandidate.FileEntry] {
        await prepared(in: directory).map(\.entry)
    }

    private func prepared(in directory: String) async -> [FileMentionMatcher.Prepared] {
        if let listing = listings[directory] {
            markUsed(directory)
            if now().timeIntervalSince(listing.fetchedAt) > maxAge { startLoad(directory) }
            return listing.entries
        }
        return await startLoad(directory).value
    }

    /// Waits for every refresh in flight.
    func settle() async {
        while let load = loads.values.first {
            _ = await load.value
        }
    }

    @discardableResult
    private func startLoad(_ directory: String) -> Task<[FileMentionMatcher.Prepared], Never> {
        if let load = loads[directory] { return load }
        let limits = limits
        let homeDirectory = homeDirectory
        let listGitPaths = listGitPaths
        let load = Task {
            let entries = await Task.detached(priority: .userInitiated) {
                Self.loadEntries(in: directory, limits: limits, homeDirectory: homeDirectory, listGitPaths: listGitPaths)
                    .map { $0.map(FileMentionMatcher.Prepared.init) }
            }.value
            finishLoad(directory, entries: entries)
            return entries ?? []
        }
        loads[directory] = load
        return load
    }

    /// A timed-out listing is cached empty and already stale, so the next
    /// lookup serves it at once and retries.
    private func finishLoad(_ directory: String, entries: [FileMentionMatcher.Prepared]?) {
        listings[directory] = Listing(entries: entries ?? [], fetchedAt: entries == nil ? .distantPast : now())
        loads[directory] = nil
        markUsed(directory)
    }

    private func markUsed(_ directory: String) {
        recentDirectories.removeAll { $0 == directory }
        recentDirectories.append(directory)
        while recentDirectories.count > limits.maxCachedDirectories {
            listings[recentDirectories.removeFirst()] = nil
        }
    }

    // MARK: - Loading

    /// Nil when git timed out. The home directory lists nothing before git
    /// runs, so a dotfiles repository at home never lists the whole tree.
    nonisolated static func loadEntries(
        in directory: String,
        limits: Limits,
        homeDirectory: String,
        listGitPaths: ListGitPaths
    ) -> [MentionCandidate.FileEntry]? {
        let root = standardizedPath(directory)
        let home = standardizedPath(homeDirectory)
        guard root != home else { return [] }
        switch listGitPaths(directory, limits) {
        case .paths(let paths):
            let protected = protectedPrefixes(from: root, homeDirectory: home)
            guard !protected.isEmpty else { return entries(fromFilePaths: paths) }
            return entries(fromFilePaths: paths.filter { path in !protected.contains { path.hasPrefix($0) } })
        case .timedOut:
            return nil
        case .notARepository:
            return walk(directory, limits: limits, homeDirectory: homeDirectory)
        }
    }

    /// Paths relative to `directory`.
    nonisolated static func gitPaths(in directory: String, limits: Limits) -> GitListing {
        do {
            let output = try GitRunner.run(
                ["ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                in: directory,
                timeout: limits.gitTimeout
            )
            return .paths(output.lazy.split(separator: "\0").prefix(limits.maxGitPaths).map(String.init))
        } catch let error as GitError where error.timedOut {
            return .timedOut
        } catch {
            return .notARepository
        }
    }

    /// The protected home folders below `root`, as relative path prefixes.
    nonisolated static func protectedPrefixes(from root: String, homeDirectory home: String) -> [String] {
        let base = root.hasSuffix("/") ? root : root + "/"
        let homeFromRoot: String
        if home == root {
            homeFromRoot = ""
        } else if home.hasPrefix(base) {
            homeFromRoot = String(home.dropFirst(base.count)) + "/"
        } else {
            return []
        }
        return protectedHomeFolders.map { homeFromRoot + $0 + "/" }
    }

    nonisolated static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    /// The files plus every folder that holds one.
    nonisolated static func entries(fromFilePaths paths: [String]) -> [MentionCandidate.FileEntry] {
        var files = Set<String>()
        var folders = Set<String>()
        for path in paths {
            guard files.insert(path).inserted else { continue }
            var parent = Substring(path)
            while let slash = parent.lastIndex(of: "/") {
                parent = parent[..<slash]
                guard folders.insert(String(parent)).inserted else { break }
            }
        }
        return folders.sorted().map { .init(path: $0, isDirectory: true) }
            + files.subtracting(folders).sorted().map { .init(path: $0, isDirectory: false) }
    }

    nonisolated static let skippedDirectoryNames: Set<String> = [".git", "node_modules", ".build", "DerivedData"]

    /// Folders under home that macOS guards with a permission prompt, or
    /// that hold far more than anyone mentions.
    nonisolated static let protectedHomeFolders = [
        "Library", "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music",
    ]

    /// Starting inside a protected folder is fine: the user is working there.
    nonisolated static func walk(
        _ directory: String,
        limits: Limits,
        homeDirectory: String
    ) -> [MentionCandidate.FileEntry] {
        let root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        let home = standardizedPath(homeDirectory)
        guard root.path != home else { return [] }
        let protected = Set(protectedHomeFolders.map { (home as NSString).appendingPathComponent($0) })
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.producesRelativePathURLs]
        ) else { return [] }

        var entries: [MentionCandidate.FileEntry] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                if name.hasPrefix(".") || skippedDirectoryNames.contains(name) {
                    enumerator.skipDescendants()
                    continue
                }
                if enumerator.level >= limits.maxDepth
                    || protected.contains(root.appending(path: url.relativePath).path) {
                    enumerator.skipDescendants()
                }
            }
            entries.append(.init(path: url.relativePath, isDirectory: isDirectory))
            if entries.count >= limits.maxEntries { break }
        }
        return entries
    }

    /// The children of the deepest folder typed so far, in the form typed:
    /// `~/Development/Pl` lists `~/Development` as `~/Development/…`.
    nonisolated static func listing(typedPath: String, homeDirectory: String) -> [MentionCandidate.FileEntry] {
        let typedFolder: String
        if let slash = typedPath.lastIndex(of: "/") {
            typedFolder = String(typedPath[...slash])
        } else {
            typedFolder = typedPath + "/"
        }
        let typedName = typedPath.hasSuffix("/") ? "" : (typedPath as NSString).lastPathComponent
        let showsHidden = typedName.hasPrefix(".")
        let folder = MentionInsertion.expandingTilde(String(typedFolder.dropLast()), homeDirectory: homeDirectory)
        let resolved = folder.isEmpty ? "/" : folder

        guard let names = try? FileManager.default.contentsOfDirectory(atPath: resolved) else { return [] }
        return names.sorted().compactMap { name in
            if name.hasPrefix("."), !showsHidden { return nil }
            var isDirectory: ObjCBool = false
            let absolute = (resolved as NSString).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: absolute, isDirectory: &isDirectory) else { return nil }
            return .init(path: typedFolder + name, isDirectory: isDirectory.boolValue)
        }
    }
}
