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

    /// Bounded poll instead of a fixed sleep, so the check isn't flaky on a
    /// loaded machine but also doesn't wait the full timeout when it's fast.
    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
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

        await waitUntil { store.content == "# First plan\n\nMore detail." }
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
