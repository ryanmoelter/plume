import Testing
import Foundation
@testable import Plume

@MainActor
struct MarkdownFileStoreTests {
    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func append(_ text: String, to url: URL) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(text.data(using: .utf8) ?? Data())
    }

    /// Waits on the store's own read signal rather than a wall clock. The
    /// corpus suites saturate every core for tens of seconds, so any deadline
    /// short enough to be useful is one a parallel run can blow through.
    private func waitUntil(
        _ store: MarkdownFileStore,
        _ condition: @escaping () -> Bool
    ) async {
        guard !condition() else { return }
        await withCheckedContinuation { continuation in
            var resumed = false
            store.didRead = {
                guard !resumed, condition() else { return }
                resumed = true
                continuation.resume()
            }
        }
        store.didRead = nil
    }

    @Test func watchingAFileReadsItsContent() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "plan.md")
        write("# First plan", to: path)

        let store = MarkdownFileStore(debounce: .milliseconds(10))
        store.watch(path: path.path)

        #expect(store.content == "# First plan")
    }

    @Test func appendingToTheFileUpdatesContentAfterTheDebounce() async {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "plan.md")
        write("# First plan", to: path)

        let store = MarkdownFileStore(debounce: .milliseconds(10))
        store.watch(path: path.path)
        #expect(store.content == "# First plan")

        append("\n\nMore detail.", to: path)

        await waitUntil(store) { store.content == "# First plan\n\nMore detail." }
        #expect(store.content == "# First plan\n\nMore detail.")
    }

    @Test func stoppingClearsTheContent() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "plan.md")
        write("# First plan", to: path)

        let store = MarkdownFileStore(debounce: .milliseconds(10))
        store.watch(path: path.path)
        #expect(store.content != nil)

        store.stop()
        #expect(store.content == nil)
    }

    @Test func aMissingFileHasNilContent() {
        let store = MarkdownFileStore(debounce: .milliseconds(10))
        store.watch(path: "/nonexistent/plan-\(UUID().uuidString).md")

        #expect(store.content == nil)
    }
}
