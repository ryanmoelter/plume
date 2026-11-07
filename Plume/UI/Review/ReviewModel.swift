#if DEBUG
import Foundation
import Observation
import os

/// One row of a file's rendered diff: a hunk header or a line.
nonisolated struct ReviewDiffRow: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case hunk(String)
        /// The line and its text, highlighted.
        case line(DiffLine, AttributedString)
    }

    let id: Int
    let kind: Kind

    /// Past this a line renders plain: it is a minified dump, not code to
    /// read, and the tokenize would dominate the load.
    static let maxHighlightedLength = 2_000

    /// The widest row in characters, a tab counted at its widest stop, so the
    /// diff can be laid out at its full width before any row is realized.
    static func columns(of rows: [ReviewDiffRow]) -> Int {
        rows.reduce(0) { widest, row in
            let text: String
            switch row.kind {
            case .hunk(let header): text = header
            case .line(let line, _): text = line.text
            }
            let tabs = text.utf8.reduce(0) { $1 == 0x09 ? $0 + 1 : $0 }
            return max(widest, text.count + tabs * 7)
        }
    }

    /// Highlights every line, so build rows off the main actor.
    static func rows(for content: DiffFileContent, language: String?, palette: CodeSyntaxPalette) -> [ReviewDiffRow] {
        guard case .text(let hunks) = content else { return [] }
        var rows: [ReviewDiffRow] = []
        rows.reserveCapacity(hunks.reduce(0) { $0 + $1.lines.count + 1 })
        for hunk in hunks {
            rows.append(ReviewDiffRow(id: rows.count, kind: .hunk(hunk.header)))
            for line in hunk.lines {
                let text: AttributedString
                if line.text.utf16.count <= maxHighlightedLength {
                    text = AttributedString.highlightedCode(line.text, language: language, palette: palette)
                } else {
                    text = AttributedString.highlightedCode(line.text, language: nil, palette: palette)
                }
                rows.append(ReviewDiffRow(id: rows.count, kind: .line(line, text)))
            }
        }
        return rows
    }
}

enum ReviewContentState {
    case loading
    /// `columns` is the widest row's width in characters.
    case loaded(DiffFileContent, rows: [ReviewDiffRow], columns: Int)
    case failed(String)

    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }
}

/// The review of one task folder: the working tree against its merge base
/// with the repository's default branch.
///
/// Shared by every view of that folder, so the detail pane and the review tab
/// agree on the selected file. All `git` work runs detached; only results land
/// here. With no view left, it drops everything but the selection.
@MainActor
@Observable
final class ReviewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    let directory: String
    private(set) var phase: Phase = .idle
    /// Nil until the first listing resolves them.
    private(set) var baseOptions: ReviewBaseOptions?
    /// The reader's pick, held in memory for the folder. Nil follows
    /// `baseOptions.defaultBase`.
    private(set) var chosenBase: ReviewBase?
    private(set) var range: ResolvedDiffRange?
    private(set) var files: [DiffFileSummary] = []
    /// Every tracked and untracked file under the repository root.
    private(set) var tree = ReviewFileTree.empty
    private(set) var changedTree = ReviewFileTree.empty
    private(set) var contents: [String: ReviewContentState] = [:]
    private(set) var lastListDuration: Duration?
    private(set) var lastContentDuration: Duration?
    var selectedPath: String? {
        didSet {
            guard selectedPath != oldValue, let selectedPath else { return }
            loadContent(for: selectedPath)
        }
    }

    @ObservationIgnored private var watcher: DirectoryTreeWatcher?
    @ObservationIgnored private var scope: RepositoryWatchScope?
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var isListing = false
    @ObservationIgnored private var needsRelist = false
    @ObservationIgnored private var repositoryRoot: String?
    @ObservationIgnored private var baseRefIsStale = true
    @ObservationIgnored private var headRef: String?
    @ObservationIgnored private var headRefIsStale = true
    @ObservationIgnored private var triage = ReviewChangeTriage()
    /// Working-tree paths changed since the last listing started.
    @ObservationIgnored private var pendingTouched: Set<String> = []
    /// Something other than a file edit asked for the relist, such as a
    /// moved base, so the selected diff reloads whatever changed.
    @ObservationIgnored private var pendingForcesReload = false
    /// Bumped by every listing and teardown; a load started under an older
    /// one read a file list that no longer holds.
    @ObservationIgnored private var listGeneration = 0
    /// The newest load per path. Only its result lands.
    @ObservationIgnored private var loadTokens: [String: Int] = [:]
    @ObservationIgnored private var nextLoadToken = 0
    /// Paths the reader asked to load past the line cap.
    @ObservationIgnored private var liftedCaps: Set<String> = []
    @ObservationIgnored private var palette: CodeSyntaxPalette?
    @ObservationIgnored private let untrackedCounts = UntrackedCountCache()
    @ObservationIgnored private var ignoredDirectories = IgnoredDirectories()
    /// Bumped by `release()`, which empties the lists a listing in flight
    /// compared its own against.
    @ObservationIgnored private var releaseCount = 0

    init(directory: String) {
        self.directory = directory
    }

    var selectedFile: DiffFileSummary? {
        files.first { $0.path == selectedPath }
    }

    /// The base the review compares against. A pick no longer on offer, such
    /// as an upstream since removed, falls back to the default.
    var base: ReviewBase {
        Self.effectiveBase(chosen: chosenBase, options: baseOptions)
    }

    nonisolated static func effectiveBase(chosen: ReviewBase?, options: ReviewBaseOptions?) -> ReviewBase {
        guard let options else { return chosen ?? .originDefault }
        if let chosen, options.available.contains(chosen) { return chosen }
        return options.defaultBase
    }

    /// The task folder relative to the repository root, or empty when it is
    /// the root.
    nonisolated static func scope(of directory: String, under root: String) -> String {
        let folder = RepositoryWatchScope.realPath(directory)
        let prefix = RepositoryWatchScope.realPath(root) + "/"
        return folder.hasPrefix(prefix) ? String(folder.dropFirst(prefix.count)) : ""
    }

    func selectBase(_ base: ReviewBase) {
        guard base != self.base else { return }
        chosenBase = base
        refresh()
    }

    /// Takes a view's reference. The first starts watching the folder.
    func retain() {
        viewers += 1
        guard viewers == 1 else { return }
        startWatching()
        refresh()
    }

    func release() {
        viewers -= 1
        guard viewers <= 0 else { return }
        viewers = 0
        watcher?.stop()
        watcher = nil
        scope = nil
        baseRefIsStale = true
        headRefIsStale = true
        listGeneration += 1
        loadTokens = [:]
        triage = ReviewChangeTriage()
        pendingTouched = []
        pendingForcesReload = false
        liftedCaps = []
        untrackedCounts.keepOnly([])
        ignoredDirectories.removeAll()
        releaseCount += 1
        contents = [:]
        files = []
        tree = .empty
        changedTree = .empty
        range = nil
        phase = .idle
    }

    /// Highlighting colors rows as they load, so a new palette reloads them.
    func setPalette(_ palette: CodeSyntaxPalette) {
        guard palette != self.palette else { return }
        self.palette = palette
        contents = [:]
        loadTokens = [:]
        if let selectedPath { loadContent(for: selectedPath) }
    }

    func selectFile(offset: Int) {
        guard !files.isEmpty else { return }
        let current = files.firstIndex { $0.path == selectedPath } ?? (offset > 0 ? -1 : files.count)
        let next = min(max(current + offset, 0), files.count - 1)
        selectedPath = files[next].path
    }

    private func startWatching() {
        let directory = directory
        Task {
            let scope = await Task.detached(priority: .utility) {
                try? RepositoryWatchScope.resolve(in: directory)
            }.value
            guard viewers > 0, watcher == nil, let scope else { return }
            self.scope = scope
            let watcher = DirectoryTreeWatcher(paths: scope.watchedPaths) { [weak self] batch in
                self?.handle(batch)
            }
            watcher.start()
            self.watcher = watcher
            // The stream reports only from now on; the first listing may
            // have read the tree before it started.
            refresh(reloadingSelection: false)
        }
    }

    private func handle(_ batch: DirectoryTreeWatcher.Batch) {
        guard let scope, !batch.mustRescan else {
            baseRefIsStale = true
            headRefIsStale = true
            ignoredDirectories.removeAll()
            refresh()
            return
        }
        let outcome = triage.triage(batch.paths.map(scope.classify))
        pendingTouched.formUnion(outcome.touched)
        if outcome.touched.contains(where: { ($0 as NSString).lastPathComponent == ".gitignore" }) {
            ignoredDirectories.removeAll()
        }
        if outcome.headMoved { headRefIsStale = true }
        if outcome.baseRefChanged { baseRefIsStale = true }
        if outcome.relists {
            refresh(reloadingSelection: outcome.headMoved || outcome.baseRefChanged)
            return
        }
        let unknown = outcome.unknown.filter { !ignoredDirectories.covers($0) }
        guard !unknown.isEmpty else { return }
        // Anything not ignored is a new file, or a directory holding some.
        let root = scope.root
        Task {
            let ignored = await Task.detached(priority: .utility) {
                (try? GitDiffEngine.ignoredPaths(IgnoredDirectories.queries(for: unknown), in: root)) ?? []
            }.value
            ignoredDirectories.record(ignored: ignored, above: unknown)
            let relevant = unknown.filter { !ignored.contains($0) && !ignoredDirectories.covers($0) }
            if !relevant.isEmpty { refresh(reloadingSelection: false) }
        }
    }

    private struct Listing: Sendable {
        let root: String
        let baseOptions: ReviewBaseOptions
        let base: ReviewBase
        let headRef: String?
        let range: ResolvedDiffRange
        let files: [DiffFileSummary]
        let tree: ReviewFileTree
        let changedTree: ReviewFileTree
        let knownPaths: Set<String>
        let nestedRepositories: Set<String>
        /// Compared off the main actor against what the model showed when the
        /// listing started; a large tree costs real time to compare.
        let filesUnchanged: Bool
        let treeUnchanged: Bool
        let changedTreeUnchanged: Bool
        let releaseCount: Int
    }

    /// Pass `reloadingSelection: false` when only the files the watcher
    /// named should reload the selected diff.
    func refresh(reloadingSelection: Bool = true) {
        guard viewers > 0 else { return }
        if reloadingSelection { pendingForcesReload = true }
        guard !isListing else {
            needsRelist = true
            return
        }
        isListing = true
        switch phase {
        case .idle, .failed: phase = .loading
        case .loading, .loaded: break
        }
        let directory = directory
        let untrackedCounts = untrackedCounts
        let cachedRoot = repositoryRoot
        let cachedHeadRef: String?? = headRefIsStale ? nil : .some(headRef)
        // A moved `HEAD` can change the branch, and with it the stack parent
        // and upstream.
        let cachedOptions = baseRefIsStale || headRefIsStale ? nil : baseOptions
        let chosenBase = chosenBase
        let shown = (files: files, tree: tree, changedTree: changedTree, releaseCount: releaseCount)
        baseRefIsStale = false
        headRefIsStale = false
        let reload = SelectionReload(touched: pendingTouched, forced: pendingForcesReload)
        pendingTouched = []
        pendingForcesReload = false
        Task {
            let signpost = Log.reviewSignposter.beginInterval("ReviewList")
            let started = ContinuousClock.now
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws -> Listing in
                    let root = try cachedRoot ?? GitDiffEngine.repositoryRoot(of: directory)
                    // Exit 1 means a detached `HEAD`.
                    let headRef = cachedHeadRef ?? (try? GitRunner.run(["symbolic-ref", "-q", "HEAD"], in: root))
                    let options = cachedOptions ?? GitDiffEngine.baseOptions(in: root, headRef: headRef)
                    let base = ReviewModel.effectiveBase(chosen: chosenBase, options: options)
                    let range = try GitDiffEngine.resolveWorkingTree(base: base, options: options, root: root)
                    let snapshot = try GitDiffEngine.snapshot(in: range, cache: untrackedCounts)
                    let files = snapshot.files
                    let scope = ReviewModel.scope(of: directory, under: root)
                    let tree = ReviewFileTree(paths: snapshot.listedPaths, files: files, scope: scope)
                    let changedTree = ReviewFileTree(paths: [], files: files, scope: scope)
                    return Listing(
                        root: root,
                        baseOptions: options,
                        base: base,
                        headRef: headRef,
                        range: range,
                        files: files,
                        tree: tree,
                        changedTree: changedTree,
                        knownPaths: Set(snapshot.listedPaths + files.flatMap { [$0.path, $0.oldPath].compactMap { $0 } }),
                        nestedRepositories: snapshot.nestedRepositories,
                        filesUnchanged: files == shown.files,
                        treeUnchanged: tree == shown.tree,
                        changedTreeUnchanged: changedTree == shown.changedTree,
                        releaseCount: shown.releaseCount
                    )
                }
            }.value
            let elapsed = ContinuousClock.now - started
            Log.reviewSignposter.endInterval("ReviewList", signpost)
            isListing = false
            apply(result, reload: reload, elapsed: elapsed)
            if needsRelist {
                needsRelist = false
                refresh(reloadingSelection: false)
            }
        }
    }

    private struct SelectionReload {
        let touched: Set<String>
        let forced: Bool
    }

    private func apply(_ result: Result<Listing, any Error>, reload: SelectionReload, elapsed: Duration) {
        guard viewers > 0 else { return }
        switch result {
        case .failure(let error):
            baseRefIsStale = true
            headRefIsStale = true
            phase = .failed(error.localizedDescription)
        case .success(let listing):
            lastListDuration = elapsed
            Log.review.info("Listed \(listing.files.count) files in \(String(describing: elapsed), privacy: .public)")
            let previousSelection = selectedFile
            listGeneration += 1
            loadTokens = [:]
            repositoryRoot = listing.root
            baseOptions = listing.baseOptions
            headRef = listing.headRef
            range = listing.range
            triage = ReviewChangeTriage(
                knownPaths: listing.knownPaths,
                nestedRepositories: listing.nestedRepositories,
                headRef: listing.headRef,
                baseRef: listing.baseOptions.watchedRef(for: listing.base)
            )
            let compared = listing.releaseCount == releaseCount
            if !(compared && listing.filesUnchanged) { files = listing.files }
            if !(compared && listing.treeUnchanged) { tree = listing.tree }
            if !(compared && listing.changedTreeUnchanged) { changedTree = listing.changedTree }
            liftedCaps.formIntersection(listing.files.map(\.path))
            phase = .loaded
            // A file's lines can change without its counts changing, so every
            // other cached diff is stale. The selected one reloads in place
            // only if this relist could have changed it.
            contents = contents.filter { $0.key == selectedPath }
            if let selectedPath, let selected = files.first(where: { $0.path == selectedPath }) {
                let touched = ([selected.path] + [selected.oldPath].compactMap { $0 }).contains(where: reload.touched.contains)
                let isCurrent = contents[selectedPath]?.isLoaded == true
                if reload.forced || touched || selected != previousSelection || !isCurrent {
                    loadContent(for: selectedPath, reloading: true)
                }
            } else {
                selectedPath = files.first?.path
            }
        }
    }

    func loadContent(for path: String, liftingCap: Bool = false, reloading: Bool = false) {
        if liftingCap {
            // Every load after the lift is uncapped, so one in flight already
            // answers a repeated click.
            if liftedCaps.contains(path), loadTokens[path] != nil { return }
            liftedCaps.insert(path)
        }
        guard let range, let palette, let file = files.first(where: { $0.path == path }) else { return }
        let isCached = switch contents[path] {
        case .loading, .loaded: true
        case .failed, nil: false
        }
        if !liftingCap, !reloading, isCached { return }
        nextLoadToken += 1
        let token = nextLoadToken
        let generation = listGeneration
        loadTokens[path] = token
        if liftingCap || !isCached { contents[path] = .loading }
        let lineCap = liftedCaps.contains(path) ? nil : GitDiffEngine.defaultLineCap
        let language = (path as NSString).pathExtension
        Task {
            let signpost = Log.reviewSignposter.beginInterval("ReviewFile")
            let started = ContinuousClock.now
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws -> (DiffFileContent, [ReviewDiffRow], Int) in
                    let content = try GitDiffEngine.content(for: file, in: range, lineCap: lineCap)
                    let rows = ReviewDiffRow.rows(for: content, language: language, palette: palette)
                    return (content, rows, ReviewDiffRow.columns(of: rows))
                }
            }.value
            let elapsed = ContinuousClock.now - started
            Log.reviewSignposter.endInterval("ReviewFile", signpost)
            guard loadTokens[path] == token, generation == listGeneration else { return }
            loadTokens[path] = nil
            switch result {
            case .success(let (content, rows, columns)):
                lastContentDuration = elapsed
                Log.review.info("Loaded \(rows.count) rows of \(path, privacy: .public) in \(String(describing: elapsed), privacy: .public)")
                contents[path] = .loaded(content, rows: rows, columns: columns)
            case .failure(let error):
                contents[path] = .failed(error.localizedDescription)
            }
        }
    }
}

/// One `ReviewModel` per folder, created on first use and kept for the
/// session. Deliberately not observable: creating a model from a view's body
/// must not invalidate that view.
@MainActor
final class ReviewStore {
    static let shared = ReviewStore()

    private var models: [String: ReviewModel] = [:]

    func model(for directory: String) -> ReviewModel {
        if let model = models[directory] { return model }
        let model = ReviewModel(directory: directory)
        models[directory] = model
        return model
    }
}
#endif
