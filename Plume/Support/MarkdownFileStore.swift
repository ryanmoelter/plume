import Foundation
import Observation

/// Watches one markdown file on disk and republishes its content live, for
/// `MarkdownFileView`. Mirrors `TranscriptStore`'s shape but keyed by nothing
/// — a single file at a time is all any one viewer needs.
@MainActor
@Observable
final class MarkdownFileStore {
    private(set) var content: String?

    private var watcher: FileWatcher?
    private var path: String?
    private var pending: Task<Void, Never>?

    private let debounce: Duration

    init(debounce: Duration = .milliseconds(250)) {
        self.debounce = debounce
    }

    func watch(path: String) {
        guard self.path != path else {
            read()
            return
        }

        stop()
        self.path = path
        read()

        let watcher = FileWatcher(url: URL(fileURLWithPath: path)) { [weak self] in
            self?.scheduleRead()
        }
        watcher.start()
        self.watcher = watcher
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        pending?.cancel()
        pending = nil
        path = nil
        content = nil
    }

    private func scheduleRead() {
        pending?.cancel()
        pending = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            read()
        }
    }

    private func read() {
        guard let path else { return }
        content = try? String(contentsOfFile: path, encoding: .utf8)
    }
}
