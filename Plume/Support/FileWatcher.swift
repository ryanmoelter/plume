import Foundation

/// Watches one file for writes, via a DispatchSource on its descriptor.
///
/// Hooks append while Plume may be closed, so this is only the live signal;
/// correctness on startup comes from the ingester's offsets, not from here.
final class FileWatcher {
    private let url: URL
    private let createsFile: Bool
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var appearance: DispatchSourceTimer?
    private var descriptor: CInt = -1

    /// `createsFile` decides who owns the path. Pass true when Plume names a
    /// file something else appends to, as hook events are. Pass false when the
    /// writer creates it and treats its prior existence as meaningful:
    /// `claude --session-id` refuses to start at all — "Session ID is already
    /// in use" — if a transcript is already sitting at the session's path, so
    /// creating one to watch would kill the process we are waiting on.
    init(url: URL, createsFile: Bool = true, onChange: @escaping () -> Void) {
        self.url = url
        self.createsFile = createsFile
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    /// Creates the file if absent, when this watcher owns it: a watch can be
    /// requested before the first hook writes anything.
    ///
    /// When it does not own the file, an absent one is watched by polling for
    /// it instead. There is nothing to open a descriptor on until the writer
    /// creates it, and returning quietly would leave a watch that never fires.
    func start() {
        guard source == nil else { return }

        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            guard createsFile else { return waitForFile() }
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
        appearance?.cancel()
        appearance = nil
        source?.cancel()
        source = nil
        descriptor = -1
    }

    /// Polls until the writer creates the file, then watches it for real and
    /// reports the contents that arrived with it.
    ///
    /// A kqueue on the parent directory would be the tighter mechanism, but it
    /// fires for every sibling in a directory holding every transcript of a
    /// project; a one-second poll on a file that appears once is cheaper.
    private func waitForFile() {
        guard appearance == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.appearanceInterval, repeating: Self.appearanceInterval)
        timer.setEventHandler { [weak self] in
            guard let self, FileManager.default.fileExists(atPath: url.path) else { return }
            appearance?.cancel()
            appearance = nil
            start()
            onChange()
        }
        timer.resume()
        appearance = timer
    }

    private static let appearanceInterval: DispatchTimeInterval = .seconds(1)

    private func restart() {
        stop()
        start()
    }
}
