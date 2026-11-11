import Testing
import Foundation
@testable import Plume

/// Times a store read after one subagent of hundreds appends a line. Opt-in:
/// set `TEST_RUNNER_PLUME_SUBAGENT_BENCH` to a file path to write results to.
@MainActor
struct SubagentReparseBenchmarkTests {
    private static let output = ProcessInfo.processInfo.environment["PLUME_SUBAGENT_BENCH"]

    @Test(.enabled(if: output != nil))
    func appendingToOneSubagentOfHundreds() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = SubagentFixture(directory: dir, subagentCount: 400, linesPerSubagent: 150, parentLines: 4000)
        try fixture.write()

        let store = TranscriptStore(debounce: .milliseconds(10), isTabLive: { _ in true })
        let tab = UUID()
        let firstStart = ContinuousClock.now
        store.watch(tabID: tab, transcriptPath: fixture.parentPath.path)
        await waitUntil(store) { store.subagents(forTab: tab).count == fixture.subagentCount }
        let firstRead = ContinuousClock.now - firstStart

        var samples: [Duration] = []
        for round in 0..<8 {
            let target = fixture.subagentPath(round * 37 % fixture.subagentCount)
            let marker = "bench-\(round)"
            let start = ContinuousClock.now
            try fixture.append(SubagentFixture.assistantText(marker), to: target)
            await waitUntil(store) {
                store.subagents(forTab: tab).contains { sub in
                    sub.transcript.messages.last?.blocks.contains { block in
                        if case .markdown(let text) = block { return text == marker }
                        return false
                    } ?? false
                }
            }
            samples.append(ContinuousClock.now - start)
        }

        let sorted = samples.sorted()
        let report = """
            subagents=\(fixture.subagentCount) bytes=\(fixture.totalSubagentBytes()) parentBytes=\(fixture.parentBytes())
            firstRead=\(firstRead)
            appendRead median=\(sorted[sorted.count / 2]) min=\(sorted.first!) max=\(sorted.last!)
            """
        if let output = Self.output {
            try report.write(toFile: output, atomically: true, encoding: .utf8)
        }
        store.stopAll()
    }

    private func waitUntil(_ store: TranscriptStore, _ condition: @escaping () -> Bool) async {
        guard !condition() else { return }
        await withCheckedContinuation { continuation in
            var resumed = false
            store.didRead = { _ in
                guard !resumed, condition() else { return }
                resumed = true
                continuation.resume()
            }
        }
        store.didRead = nil
    }
}

/// A session with a parent transcript and many subagent transcripts shaped
/// like real ones: tool calls, multi-kilobyte tool results, and prose.
struct SubagentFixture {
    let directory: URL
    let subagentCount: Int
    let linesPerSubagent: Int
    let parentLines: Int

    var parentPath: URL { directory.appending(path: "session.jsonl") }
    var subagentsDirectory: URL { directory.appending(path: "session/subagents") }

    func subagentPath(_ index: Int) -> URL {
        subagentsDirectory.appending(path: "agent-\(String(format: "a%05d", index)).jsonl")
    }

    func write() throws {
        try FileManager.default.createDirectory(at: subagentsDirectory, withIntermediateDirectories: true)
        try Self.conversation(lines: parentLines, sidechain: false).write(to: parentPath, atomically: true, encoding: .utf8)
        for index in 0..<subagentCount {
            try Self.conversation(lines: linesPerSubagent, sidechain: true)
                .write(to: subagentPath(index), atomically: true, encoding: .utf8)
        }
    }

    func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func totalSubagentBytes() -> Int {
        (0..<subagentCount).reduce(0) { total, index in
            total + ((try? FileManager.default.attributesOfItem(atPath: subagentPath(index).path)[.size] as? Int) ?? 0)
        }
    }

    func parentBytes() -> Int {
        (try? FileManager.default.attributesOfItem(atPath: parentPath.path)[.size] as? Int) ?? 0
    }

    static func conversation(lines: Int, sidechain: Bool) -> String {
        var text = ""
        var parent = "null"
        let payload = String(repeating: "lorem ipsum dolor sit amet ", count: 60)
        for index in 0..<lines {
            let uuid = UUID().uuidString
            let line: String
            switch index % 3 {
            case 0:
                line = "{\"type\":\"assistant\",\"uuid\":\"\(uuid)\",\"parentUuid\":\(parent),\"isSidechain\":\(sidechain),\"timestamp\":\"2026-11-11T10:00:00.000Z\",\"message\":{\"id\":\"msg_\(uuid)\",\"role\":\"assistant\",\"model\":\"claude\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_\(index)\",\"name\":\"Bash\",\"input\":{\"command\":\"grep -rn something Plume/\(index)\",\"description\":\"Search \(index)\"}}]}}"
            case 1:
                line = "{\"type\":\"user\",\"uuid\":\"\(uuid)\",\"parentUuid\":\(parent),\"isSidechain\":\(sidechain),\"timestamp\":\"2026-11-11T10:00:01.000Z\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_\(index - 1)\",\"content\":\"\(payload)\"}]}}"
            default:
                line = "{\"type\":\"assistant\",\"uuid\":\"\(uuid)\",\"parentUuid\":\(parent),\"isSidechain\":\(sidechain),\"timestamp\":\"2026-11-11T10:00:02.000Z\",\"message\":{\"id\":\"msg_\(uuid)\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Looked at \(index). \(payload.prefix(200))\"}]}}"
            }
            text += line + "\n"
            parent = "\"\(uuid)\""
        }
        return text
    }

    static func assistantText(_ text: String) -> String {
        let uuid = UUID().uuidString
        return "{\"type\":\"assistant\",\"uuid\":\"\(uuid)\",\"isSidechain\":true,\"message\":{\"id\":\"msg_\(uuid)\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"\(text)\"}]}}\n"
    }
}
