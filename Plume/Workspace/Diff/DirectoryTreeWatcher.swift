import CoreServices
import Foundation

/// Reports the files that change under a set of directories, through
/// FSEvents. Deciding which changes matter is the caller's job.
nonisolated final class DirectoryTreeWatcher {
    struct Batch: Sendable {
        let paths: [String]
        /// FSEvents dropped events, so `paths` is incomplete.
        let mustRescan: Bool
    }

    private let paths: [String]
    private let latency: TimeInterval
    private let onChange: @MainActor (Batch) -> Void
    private var stream: FSEventStreamRef?

    /// `onChange` runs on the main queue.
    init(paths: [String], latency: TimeInterval = 0.5, onChange: @escaping @MainActor (Batch) -> Void) {
        self.paths = paths
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
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents
        )
        guard let stream = FSEventStreamCreate(
            nil,
            Self.callback,
            &context,
            paths as CFArray,
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

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let changed = Array((unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []).prefix(count))
        let rescanFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
        )
        let mustRescan = (0 ..< count).contains { flags[$0] & rescanFlags != 0 }
        let onChange = Unmanaged<DirectoryTreeWatcher>.fromOpaque(info).takeUnretainedValue().onChange
        MainActor.assumeIsolated { onChange(Batch(paths: changed, mustRescan: mustRescan)) }
    }
}
