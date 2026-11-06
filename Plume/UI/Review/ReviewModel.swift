import Foundation
import Observation
import os

/// One row of a file's rendered diff: a hunk header or a line.
nonisolated struct ReviewDiffRow: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case hunk(String)
        case line(DiffLine)
    }

    let id: Int
    let kind: Kind

    static func rows(for content: DiffFileContent) -> [ReviewDiffRow] {
        guard case .text(let hunks) = content else { return [] }
        var rows: [ReviewDiffRow] = []
        rows.reserveCapacity(hunks.reduce(0) { $0 + $1.lines.count + 1 })
        for hunk in hunks {
            rows.append(ReviewDiffRow(id: rows.count, kind: .hunk(hunk.header)))
            for line in hunk.lines {
                rows.append(ReviewDiffRow(id: rows.count, kind: .line(line)))
            }
        }
        return rows
    }
}

enum ReviewContentState {
    case loading
    case loaded(DiffFileContent, rows: [ReviewDiffRow])
    case failed(String)
}

/// The review of one task folder: the working tree against its merge base
/// with the repository's default branch.
///
/// Shared by every view of that folder, so the detail pane and the review tab
/// agree on the selected file. All `git` work runs detached; only results land
/// here.
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
    private(set) var baseRef: String?
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
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var isListing = false
    @ObservationIgnored private var needsRelist = false
    @ObservationIgnored private var contentInFlight: Set<String> = []

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
        let watcher = DirectoryTreeWatcher(path: directory) { [weak self] in self?.refresh() }
        watcher.start()
        self.watcher = watcher
        refresh()
    }

    func release() {
        viewers -= 1
        guard viewers <= 0 else { return }
        viewers = 0
        watcher?.stop()
        watcher = nil
    }

    func selectFile(offset: Int) {
        guard !files.isEmpty else { return }
        let current = files.firstIndex { $0.path == selectedPath } ?? (offset > 0 ? -1 : files.count)
        let next = min(max(current + offset, 0), files.count - 1)
        selectedPath = files[next].path
    }

    private struct Listing: Sendable {
        let baseRef: String
        let range: ResolvedDiffRange
        let files: [DiffFileSummary]
        let tree: ReviewFileTree
        let changedTree: ReviewFileTree
    }

    func refresh() {
        guard !isListing else {
            needsRelist = true
            return
        }
        isListing = true
        if files.isEmpty { phase = .loading }
        let directory = directory
        Task {
            let signpost = Log.reviewSignposter.beginInterval("ReviewList")
            let started = ContinuousClock.now
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws -> Listing in
                    let baseRef = GitDiffEngine.defaultBaseRef(in: directory)
                    let range = try GitDiffEngine.resolve(.workingTree(baseRef: baseRef), in: directory)
                    let files = try GitDiffEngine.files(in: range)
                    let listed = (try? GitDiffEngine.listedPaths(in: range.repositoryRoot)) ?? []
                    return Listing(
                        baseRef: baseRef,
                        range: range,
                        files: files,
                        tree: ReviewFileTree(paths: listed, files: files),
                        changedTree: ReviewFileTree(paths: [], files: files)
                    )
                }
            }.value
            let elapsed = ContinuousClock.now - started
            Log.reviewSignposter.endInterval("ReviewList", signpost)
            apply(result, elapsed: elapsed)
            isListing = false
            if needsRelist {
                needsRelist = false
                refresh()
            }
        }
    }

    private func apply(_ result: Result<Listing, any Error>, elapsed: Duration) {
        switch result {
        case .failure(let error):
            phase = .failed(error.localizedDescription)
        case .success(let listing):
            lastListDuration = elapsed
            Log.review.info("Listed \(listing.files.count) files in \(String(describing: elapsed), privacy: .public)")
            baseRef = listing.baseRef
            range = listing.range
            if files != listing.files { files = listing.files }
            if tree != listing.tree { tree = listing.tree }
            if changedTree != listing.changedTree { changedTree = listing.changedTree }
            phase = .loaded
            // A file's lines can change without its counts changing, so every
            // cached diff is stale. The selected one reloads in place.
            contents = contents.filter { $0.key == selectedPath }
            if let selectedPath, files.contains(where: { $0.path == selectedPath }) {
                loadContent(for: selectedPath, reloading: true)
            } else {
                selectedPath = files.first?.path
            }
        }
    }

    func loadContent(for path: String, liftingCap: Bool = false, reloading: Bool = false) {
        guard let range, let file = files.first(where: { $0.path == path }) else { return }
        if !liftingCap, !reloading, contents[path] != nil { return }
        guard !contentInFlight.contains(path) else { return }
        contentInFlight.insert(path)
        if contents[path] == nil { contents[path] = .loading }
        let lineCap = liftingCap ? nil : GitDiffEngine.defaultLineCap
        Task {
            let signpost = Log.reviewSignposter.beginInterval("ReviewFile")
            let started = ContinuousClock.now
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws -> (DiffFileContent, [ReviewDiffRow]) in
                    let content = try GitDiffEngine.content(for: file, in: range, lineCap: lineCap)
                    return (content, ReviewDiffRow.rows(for: content))
                }
            }.value
            let elapsed = ContinuousClock.now - started
            Log.reviewSignposter.endInterval("ReviewFile", signpost)
            contentInFlight.remove(path)
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
