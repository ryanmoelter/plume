import Foundation

/// Watches one file for writes, via a DispatchSource on its descriptor.
///
/// Hooks append while Plume may be closed, so this is only the live signal;
/// correctness on startup comes from the ingester's offsets, not from here.
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    /// Creates the file if absent: a watch can be requested before the first
    /// hook writes anything.
    func start() {
        guard source == nil else { return }

        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try? manager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            manager.createFile(atPath: url.path, contents: nil)
        }

        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            // A replaced file needs a fresh descriptor, or we would keep
            // watching the old inode forever.
            if events.contains(.delete) || events.contains(.rename) {
                restart()
            }
            onChange()
        }
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
    }

    private func restart() {
        stop()
        start()
    }
}
