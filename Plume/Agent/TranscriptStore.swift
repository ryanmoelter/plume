import Foundation
import Observation

/// A subagent's parsed transcript, keyed by the id in its filename
/// (`agent-<id>.jsonl`).
struct SubagentTranscript: Identifiable, Equatable {
    let id: String
    let transcript: Transcript
    let modifiedAt: Date?
    /// What the subagent was asked to do, from its `.meta.json` sidecar or
    /// the parent's spawning tool call. Nil when neither names it.
    var descriptor: SubagentDescriptor?
    var status: TaskStatus = .unset

    /// What to call this subagent in the list. Falls back to the raw id only
    /// when nothing describes it.
    var title: String {
        descriptor?.label(fallback: id) ?? id
    }
}

/// Watches agent transcripts and republishes their parsed content live.
///
/// One watcher per agent tab, mirroring `AgentTitleMonitor`. Each change
/// re-reads and re-parses the whole file rather than tracking offsets, which
/// costs tens of milliseconds on a multi-megabyte transcript — so the read
/// runs off the main actor and only the result is published on it. If whole-
/// file parsing stops being affordable at all, `HookEventIngester`'s
/// offset-based reads are the model to copy.
@MainActor
@Observable
final class TranscriptStore {
    static let shared = TranscriptStore()

    private(set) var transcripts: [UUID: Transcript] = [:]
    private(set) var subagentTranscripts: [UUID: [SubagentTranscript]] = [:]

    private var watchers: [UUID: FileWatcher] = [:]
    /// One watcher per subagent transcript, keyed by tab then by file path.
    private var subagentWatchers: [UUID: [String: FileWatcher]] = [:]
    private var paths: [UUID: String] = [:]
    private var pending: [UUID: Task<Void, Never>] = [:]
    /// Tabs with a parse in flight, so a burst of writes cannot stack reads.
    private var inFlight: Set<UUID> = []

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
        // Already watching this exact file, so the watcher is what reports
        // changes. Re-reading here would bypass the debounce, and this is
        // called again on every hook event for the tab — enough to keep a
        // core busy re-parsing a file nothing has written to.
        guard paths[tabID] != transcriptPath else { return }

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
        stopSubagentWatchers(tabID: tabID)
        pending.removeValue(forKey: tabID)?.cancel()
        inFlight.remove(tabID)
        paths.removeValue(forKey: tabID)
        transcripts.removeValue(forKey: tabID)
        subagentTranscripts.removeValue(forKey: tabID)
    }

    func stopAll() {
        for watcher in watchers.values { watcher.stop() }
        for tabWatchers in subagentWatchers.values {
            for watcher in tabWatchers.values { watcher.stop() }
        }
        for task in pending.values { task.cancel() }
        watchers.removeAll()
        subagentWatchers.removeAll()
        pending.removeAll()
        inFlight.removeAll()
        paths.removeAll()
        transcripts.removeAll()
        subagentTranscripts.removeAll()
    }

    func transcript(forTab tabID: UUID) -> Transcript? {
        transcripts[tabID]
    }

    /// Subagents spawned by a tab's transcript.
    ///
    /// Read from the cache filled on each transcript read, never from disk: a
    /// SwiftUI view calls this from `body`, which re-evaluates far more often
    /// than the file changes — scrolling alone would otherwise re-parse every
    /// subagent file per frame.
    func subagents(forTab tabID: UUID) -> [SubagentTranscript] {
        subagentTranscripts[tabID] ?? []
    }

    /// Parses every subagent transcript for a session, describing and scoring
    /// each against the parent's own bytes.
    ///
    /// `parentData` is passed in rather than re-read: the caller has just read
    /// it to parse the main transcript, and the spawn scan is a fallback that
    /// only runs when a subagent has no sidecar.
    private nonisolated static func readSubagents(transcriptPath: String, parentData: Data) -> [SubagentTranscript] {
        let paths = SessionJSONLReader.subagentTranscriptPaths(forTranscriptPath: transcriptPath)
        guard !paths.isEmpty else { return [] }

        let results = SubagentSpawnResults(parentData: parentData)
        // Scanning the parent for spawn calls costs a second full pass, so it
        // only happens when a sidecar is actually missing.
        var scanned: [String: SubagentDescriptor]?

        return paths.map { subagentPath in
            let id = Self.subagentID(forPath: subagentPath)
            let data = FileManager.default.contents(atPath: subagentPath) ?? Data()
            let transcript = TranscriptParser.parse(data, includeSidechain: true)

            var descriptor = SubagentMetadataReader.read(forSubagentPath: subagentPath)
            if descriptor == nil {
                let table = scanned ?? SubagentSpawnScanner.descriptors(in: parentData)
                scanned = table
                descriptor = table[id]
            }

            let result = descriptor?.toolUseID.flatMap { results.result(forToolUseID: $0) }
            return SubagentTranscript(
                id: id,
                transcript: transcript,
                modifiedAt: SessionJSONLReader.lastModified(atPath: subagentPath),
                descriptor: descriptor,
                status: SubagentStatusDeriver.derive(
                    transcript: transcript,
                    parentResult: result
                )
            )
        }
    }

    private nonisolated static func subagentID(forPath path: String) -> String {
        (path as NSString)
            .lastPathComponent
            .replacingOccurrences(of: "agent-", with: "")
            .replacingOccurrences(of: ".jsonl", with: "")
    }

    private func scheduleRead(tabID: UUID) {
        pending[tabID]?.cancel()
        pending[tabID] = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            read(tabID: tabID)
        }
    }

    /// Reads and parses off the main actor, then publishes on it.
    ///
    /// A live transcript is megabytes of JSONL and the debounce fires several
    /// times a second while a turn streams, so parsing here would stutter the
    /// window. One read per tab at a time: the parse can outlast the debounce,
    /// and queuing them would spend the whole gain re-parsing stale bytes.
    private func read(tabID: UUID) {
        guard let path = paths[tabID], !inFlight.contains(tabID) else { return }
        inFlight.insert(tabID)
        Task.detached(priority: .utility) {
            let parsed = FileManager.default.contents(atPath: path).map {
                (
                    TranscriptParser.parse($0),
                    Self.readSubagents(transcriptPath: path, parentData: $0)
                )
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.inFlight.remove(tabID)
                // The tab may have been dropped, or re-pointed at a different
                // session file, while this parse was in flight.
                guard let parsed, self.paths[tabID] == path else { return }
                self.transcripts[tabID] = parsed.0
                self.subagentTranscripts[tabID] = parsed.1
                self.syncSubagentWatchers(tabID: tabID, transcriptPath: path)
            }
        }
    }

    /// A subagent writes only its own file, so the parent's watcher never
    /// fires for it. Without a watch per subagent the list would refresh only
    /// when the main transcript happened to change.
    ///
    /// The set is reconciled after each read rather than on a timer, because a
    /// new subagent's file appearing is itself preceded by a parent write —
    /// the spawning tool call.
    private func syncSubagentWatchers(tabID: UUID, transcriptPath: String) {
        let paths = Set(SessionJSONLReader.subagentTranscriptPaths(forTranscriptPath: transcriptPath))
        var watchers = subagentWatchers[tabID] ?? [:]

        for (path, watcher) in watchers where !paths.contains(path) {
            watcher.stop()
            watchers.removeValue(forKey: path)
        }
        for path in paths where watchers[path] == nil {
            let watcher = FileWatcher(url: URL(fileURLWithPath: path)) { [weak self] in
                self?.scheduleRead(tabID: tabID)
            }
            watcher.start()
            watchers[path] = watcher
        }

        subagentWatchers[tabID] = watchers.isEmpty ? nil : watchers
    }

    private func stopSubagentWatchers(tabID: UUID) {
        subagentWatchers.removeValue(forKey: tabID)?.values.forEach { $0.stop() }
    }
}
