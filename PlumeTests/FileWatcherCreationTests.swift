import Foundation
import Testing
@testable import Plume

/// Who owns the watched path. Creating a file to watch is right for hook
/// events, which Plume names and something else appends to, and wrong for a
/// transcript: `claude --session-id` reads a file already at the session's
/// path as proof the id is taken and refuses to start.
struct FileWatcherCreationTests {
    private func scratchPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("plume-watcher-\(UUID().uuidString)")
            .appendingPathComponent("transcript.jsonl")
            .path
    }

    /// The bug this guards: a forked tab derived its transcript path and
    /// started watching before the CLI launched, the watcher created the file,
    /// and every fork then died with "Session ID is already in use".
    @Test func aWatchOnSomeoneElsesFileDoesNotCreateIt() {
        let path = scratchPath()
        let watcher = FileWatcher(url: URL(fileURLWithPath: path), createsFile: false) {}
        watcher.start()
        defer { watcher.stop() }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func aWatchOnItsOwnFileCreatesIt() throws {
        let path = scratchPath()
        let watcher = FileWatcher(url: URL(fileURLWithPath: path)) {}
        watcher.start()
        defer {
            watcher.stop()
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: path).deletingLastPathComponent())
        }
        #expect(FileManager.default.fileExists(atPath: path))
    }

    /// Not creating the file must not mean never reporting it. The writer
    /// creates it later, and the watch has to pick it up then.
    @Test func aFileThatAppearsLaterIsStillReported() async throws {
        let path = scratchPath()
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let reported = Reported()
        let watcher = FileWatcher(url: URL(fileURLWithPath: path), createsFile: false) {
            Task { await reported.mark() }
        }
        watcher.start()
        defer {
            watcher.stop()
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: path).deletingLastPathComponent())
        }
        #expect(!FileManager.default.fileExists(atPath: path))

        FileManager.default.createFile(atPath: path, contents: Data("{}\n".utf8))
        try await reported.waitForMark()
    }

    private actor Reported {
        private var marked = false
        func mark() { marked = true }

        /// Polls the flag rather than sleeping a fixed span: the watcher's own
        /// appearance poll is on a one-second timer, so a single wait long
        /// enough to be safe would be long enough to slow the suite.
        func waitForMark() async throws {
            for _ in 0..<60 {
                if marked { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            Issue.record("the watcher never reported the file appearing")
        }
    }
}
