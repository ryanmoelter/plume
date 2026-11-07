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
    case loaded(DiffFileContent, rows: [ReviewDiffRow])
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
    private(set) var baseRef: GitDiffEngine.BaseRef?
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

    init(directory: String) {
        self.directory = directory
    }

    var selectedFile: DiffFileSummary? {
        files.first { $0.path == selectedPath }
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
        }
    }

    private func handle(_ batch: DirectoryTreeWatcher.Batch) {
        guard let scope, !batch.mustRescan else {
            baseRefIsStale = true
            headRefIsStale = true
            refresh()
            return
        }
        let outcome = triage.triage(batch.paths.map(scope.classify))
        pendingTouched.formUnion(outcome.touched)
        if outcome.headMoved { headRefIsStale = true }
        if outcome.baseRefChanged { baseRefIsStale = true }
        if outcome.relists {
            refresh(reloadingSelection: outcome.headMoved || outcome.baseRefChanged)
            return
        }
        let unknown = outcome.unknown
        guard !unknown.isEmpty else { return }
        // Anything not ignored is a new file, or a directory holding some.
        let root = scope.root
        Task {
            let relevant = await Task.detached(priority: .utility) {
                (try? GitDiffEngine.unignoredPaths(unknown, in: root)) ?? unknown
            }.value
            if !relevant.isEmpty { refresh(reloadingSelection: false) }
        }
    }

    private struct Listing: Sendable {
        let root: String
        let baseRef: GitDiffEngine.BaseRef
        let headRef: String?
        let range: ResolvedDiffRange
        let files: [DiffFileSummary]
        let tree: ReviewFileTree
        let changedTree: ReviewFileTree
        let knownPaths: Set<String>
        let nestedRepositories: Set<String>
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
        if files.isEmpty { phase = .loading }
        let directory = directory
        let untrackedCounts = untrackedCounts
        let cachedRoot = repositoryRoot
        let cachedBaseRef = baseRefIsStale ? nil : baseRef
        let cachedHeadRef: String?? = headRefIsStale ? nil : .some(headRef)
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
                    let baseRef = cachedBaseRef ?? GitDiffEngine.defaultBaseRef(in: root)
                    // Exit 1 means a detached `HEAD`.
                    let headRef = cachedHeadRef ?? (try? GitRunner.run(["symbolic-ref", "-q", "HEAD"], in: root))
                    let range = try GitDiffEngine.resolveWorkingTree(baseRef: baseRef.ref, root: root)
                    let snapshot = try GitDiffEngine.snapshot(in: range, cache: untrackedCounts)
                    let files = snapshot.files
                    return Listing(
                        root: root,
                        baseRef: baseRef,
                        headRef: headRef,
                        range: range,
                        files: files,
                        tree: ReviewFileTree(paths: snapshot.listedPaths, files: files),
                        changedTree: ReviewFileTree(paths: [], files: files),
                        knownPaths: Set(snapshot.listedPaths + files.flatMap { [$0.path, $0.oldPath].compactMap { $0 } }),
                        nestedRepositories: snapshot.nestedRepositories
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
            baseRef = listing.baseRef
            headRef = listing.headRef
            range = listing.range
            triage = ReviewChangeTriage(
                knownPaths: listing.knownPaths,
                nestedRepositories: listing.nestedRepositories,
                headRef: listing.headRef,
                baseRef: listing.baseRef.ref
            )
            if files != listing.files { files = listing.files }
            if tree != listing.tree { tree = listing.tree }
            if changedTree != listing.changedTree { changedTree = listing.changedTree }
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
                Result { () throws -> (DiffFileContent, [ReviewDiffRow]) in
                    let content = try GitDiffEngine.content(for: file, in: range, lineCap: lineCap)
                    return (content, ReviewDiffRow.rows(for: content, language: language, palette: palette))
                }
            }.value
            let elapsed = ContinuousClock.now - started
            Log.reviewSignposter.endInterval("ReviewFile", signpost)
            guard loadTokens[path] == token, generation == listGeneration else { return }
            loadTokens[path] = nil
            switch result {
            case .success(let (content, rows)):
                lastContentDuration = elapsed
                Log.review.info("Loaded \(rows.count) rows of \(path, privacy: .public) in \(String(describing: elapsed), privacy: .public)")
                contents[path] = .loaded(content, rows: rows)
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
