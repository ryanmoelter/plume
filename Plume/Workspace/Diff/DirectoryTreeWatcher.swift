import CoreServices
import Foundation

/// Reports changes anywhere under a directory, through FSEvents.
///
/// Events inside any `.git` directory are dropped: an agent's `git status`
/// rewrites the index constantly, and none of it changes what a review shows.
nonisolated final class DirectoryTreeWatcher {
    private let path: String
    private let latency: TimeInterval
    private let onChange: @MainActor () -> Void
    private var stream: FSEventStreamRef?

    /// `onChange` runs on the main queue.
    init(path: String, latency: TimeInterval = 0.5, onChange: @escaping @MainActor () -> Void) {
        self.path = path
        self.latency = latency
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            nil,
            Self.callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(flags)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    nonisolated static func isRelevant(_ path: String) -> Bool {
        !path.contains("/.git/") && !path.hasSuffix("/.git")
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
        guard let info else { return }
        let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
        guard changed.prefix(count).contains(where: isRelevant) else { return }
        let onChange = Unmanaged<DirectoryTreeWatcher>.fromOpaque(info).takeUnretainedValue().onChange
        MainActor.assumeIsolated { onChange() }
    }
}
