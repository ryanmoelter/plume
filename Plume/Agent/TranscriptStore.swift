import Foundation
import Observation

/// A subagent's parsed transcript, keyed by the id in its filename
/// (`agent-<id>.jsonl`).
struct SubagentTranscript: Identifiable {
    let id: String
    let transcript: Transcript
    let modifiedAt: Date?
}

/// Watches agent transcripts and republishes their parsed content live.
///
/// One watcher per agent tab, mirroring `AgentTitleMonitor`. Transcripts are
/// small (largest seen locally is ~500KB), so each change re-reads and
/// re-parses the whole file rather than tracking offsets. If that stops being
/// cheap enough, `HookEventIngester`'s offset-based reads are the model to
/// copy.
@MainActor
@Observable
final class TranscriptStore {
    static let shared = TranscriptStore()

    private(set) var transcripts: [UUID: Transcript] = [:]

    private var watchers: [UUID: FileWatcher] = [:]
    private var paths: [UUID: String] = [:]
    private var pending: [UUID: Task<Void, Never>] = [:]

    // This drives visible chat content rather than a sidebar label, so it
    // needs to feel live — much shorter than AgentTitleMonitor's 1s.
    private let debounce: Duration

    init(debounce: Duration = .milliseconds(250)) {
        self.debounce = debounce
    }

    /// Starts watching a tab's transcript and parses whatever it already
    /// holds. Re-pointing a tab at a different transcript (a `/clear` gives
    /// it a new session file) replaces the watch.
    func watch(tabID: UUID, transcriptPath: String) {
        guard paths[tabID] != transcriptPath else {
            read(tabID: tabID)
            return
        }

        stopWatching(tabID: tabID)
        paths[tabID] = transcriptPath
        read(tabID: tabID)

        let watcher = FileWatcher(url: URL(fileURLWithPath: transcriptPath)) { [weak self] in
            self?.scheduleRead(tabID: tabID)
        }
        watcher.start()
        watchers[tabID] = watcher
    }

    func stopWatching(tabID: UUID) {
        watchers.removeValue(forKey: tabID)?.stop()
        pending.removeValue(forKey: tabID)?.cancel()
        paths.removeValue(forKey: tabID)
        transcripts.removeValue(forKey: tabID)
    }

    func stopAll() {
        for watcher in watchers.values { watcher.stop() }
        for task in pending.values { task.cancel() }
        watchers.removeAll()
        pending.removeAll()
        paths.removeAll()
        transcripts.removeAll()
    }

    func transcript(forTab tabID: UUID) -> Transcript? {
        transcripts[tabID]
    }

    /// Subagents spawned by a tab's transcript. Re-scanned from disk on every
    /// call, since a subagent file's own writes do not trigger the main
    /// transcript's watcher — freshness here is best-effort, bounded by how
    /// often the main transcript changes, not by subagent activity itself.
    func subagents(forTab tabID: UUID) -> [SubagentTranscript] {
        guard let path = paths[tabID] else { return [] }
        return SessionJSONLReader.subagentTranscriptPaths(forTranscriptPath: path).map { subagentPath in
            let id = (subagentPath as NSString)
                .lastPathComponent
                .replacingOccurrences(of: "agent-", with: "")
                .replacingOccurrences(of: ".jsonl", with: "")
            let data = FileManager.default.contents(atPath: subagentPath) ?? Data()
            return SubagentTranscript(
                id: id,
                transcript: TranscriptParser.parse(data),
                modifiedAt: SessionJSONLReader.lastModified(atPath: subagentPath)
            )
        }
    }

    private func scheduleRead(tabID: UUID) {
        pending[tabID]?.cancel()
        pending[tabID] = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            read(tabID: tabID)
        }
    }

    private func read(tabID: UUID) {
        guard let path = paths[tabID],
              let data = FileManager.default.contents(atPath: path)
        else { return }
        transcripts[tabID] = TranscriptParser.parse(data)
    }
}
