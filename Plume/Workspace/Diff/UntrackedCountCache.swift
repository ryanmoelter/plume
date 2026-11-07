import Foundation
import Synchronization

/// Untracked files' summaries from earlier listings, so a relist reads only
/// the files whose size or modification time moved.
nonisolated final class UntrackedCountCache: Sendable {
    struct Stamp: Hashable, Sendable {
        let size: Int64
        let seconds: Int
        let nanoseconds: Int

        init(_ info: stat) {
            size = Int64(info.st_size)
            seconds = info.st_mtimespec.tv_sec
            nanoseconds = info.st_mtimespec.tv_nsec
        }
    }

    private struct Entry {
        let stamp: Stamp
        let summary: DiffFileSummary
    }

    private let entries = Mutex<[String: Entry]>([:])

    func summary(for path: String, stamp: Stamp) -> DiffFileSummary? {
        entries.withLock { entries in
            guard let entry = entries[path], entry.stamp == stamp else { return nil }
            return entry.summary
        }
    }

    func store(_ summary: DiffFileSummary, for path: String, stamp: Stamp) {
        entries.withLock { $0[path] = Entry(stamp: stamp, summary: summary) }
    }

    /// Forgets files no longer untracked.
    func keepOnly(_ paths: Set<String>) {
        entries.withLock { entries in entries = entries.filter { paths.contains($0.key) } }
    }
}
