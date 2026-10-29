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
    /// What the parent recorded about this agent's outcome, kept so a status
    /// can be re-derived without re-reading the parent.
    var parentSignal: SubagentParentSignal?
    var status: TaskStatus = .notStarted
    var provider: AgentProviderKind = .claudeCode

    /// What to call this subagent in the list. Falls back to the raw id only
    /// when nothing describes it.
    nonisolated var title: String {
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
    /// The token of each tab's parse in flight, so a burst of writes cannot
    /// stack reads. A read that finishes after its tab's watch was torn down
    /// finds a different token, or none, and leaves the newer read's alone.
    private var inFlight: [UUID: UUID] = [:]
    /// Tabs that asked for a read while one was in flight. That parse may have
    /// taken its bytes before the change that asked, so it reads again once it
    /// lands — otherwise a write, or a move, could go unseen until the next one.
    private var rereadRequested: Set<UUID> = []
    /// Tabs whose last read found their `subagents/` missing or partly gone,
    /// with a watch on the directory for its return. Claude Code moves that
    /// directory separately from the transcript, before or after it, and until
    /// it lands the tab keeps the subagents it last published rather than
    /// dropping them.
    private var awaitingSubagents: [UUID: (directory: String, watcher: FileWatcher)] = [:]
    /// The part of each tab's Linear evidence that came from its subagents,
    /// kept so carried subagents keep contributing.
    private var subagentLinearEvidence: [UUID: [LinearEvidence]] = [:]
    private let projectsDirectory: URL

    /// Awaited by every read between loading a file and parsing it, with the
    /// path it loaded, so a test can hold a read in flight.
    var afterLoadingTranscript: (@Sendable (String) async -> Void)?

    /// Fires when a read is requested while one is in flight, so a test can
    /// tell the request landed before releasing a held read.
    var didDeferRead: ((UUID) -> Void)?

    // This drives visible chat content rather than a sidebar label, so it
    // needs to feel live — much shorter than AgentTitleMonitor's 1s.
    private let debounce: Duration
    private let statusEngine: StatusEngine
    private let backgroundTasks: BackgroundTaskTracker
    private let linearActivity: LinearActivitySink
    private let linkedPullRequests: LinkedPullRequestStore
    /// Per tab, so a read rescans only the messages that changed.
    private var referenceCaches: [UUID: ConversationReferenceScanner.Cache] = [:]
    private let completionTracker: SubagentCompletionTracker
    private let statusOverrides: SubagentStatusOverrides
    /// Whether a live process backs a tab, checked across both transports. A
    /// tab that ran this session and then lost its process (sleep, a quit
    /// mid-turn) is not dormant — it was never restored from disk — so
    /// `settlingDormant` needs this in addition to `StatusEngine.isDormant`
    /// to catch a subagent left reading `working` with nothing behind it.
    private let isTabLive: (UUID) -> Bool

    /// Fires after every read settles, whether or not it published anything.
    /// Tests await this instead of polling a clock, which a parallel run's
    /// CPU-bound suites can outlast.
    var didRead: ((UUID) -> Void)?

    /// Reports each change in a tab's transcript `cwd`, which is where the
    /// agent's shell is now. It fires for a hidden tab too, since the watch
    /// outlives the chat view.
    var onWorkingDirectoryChanged: ((UUID, String) -> Void)?

    init(
        debounce: Duration = .milliseconds(250),
        statusEngine: StatusEngine = .shared,
        backgroundTasks: BackgroundTaskTracker = .shared,
        linearActivity: LinearActivitySink? = nil,
        linkedPullRequests: LinkedPullRequestStore? = nil,
        completionTracker: SubagentCompletionTracker = .shared,
        statusOverrides: SubagentStatusOverrides = .shared,
        projectsDirectory: URL = SessionJSONLReader.projectsDirectory,
        isTabLive: @escaping (UUID) -> Bool = TranscriptStore.hasLiveSession
    ) {
        self.debounce = debounce
        self.statusEngine = statusEngine
        self.backgroundTasks = backgroundTasks
        self.linearActivity = linearActivity ?? LinearStore.shared
        self.linkedPullRequests = linkedPullRequests ?? .shared
        self.completionTracker = completionTracker
        self.statusOverrides = statusOverrides
        self.projectsDirectory = projectsDirectory
        self.isTabLive = isTabLive
    }

    private static func hasLiveSession(tabID: UUID) -> Bool {
        SurfaceManager.shared.existingSession(for: tabID) != nil
            || AgentSessionManager.shared.existingSession(for: tabID) != nil
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
        // The same session file somewhere else. A caller still holding the
        // path it moved away from — a remount, a relaunch, an unarchive — is
        // ignored, and a hook reporting where it moved to re-points without
        // the teardown that would blank the chat.
        if let current = paths[tabID],
           (current as NSString).lastPathComponent == (transcriptPath as NSString).lastPathComponent {
            if SessionJSONLReader.hasContent(atPath: transcriptPath) {
                relocate(tabID: tabID, to: transcriptPath)
            }
            return
        }

        stopWatching(tabID: tabID)
        paths[tabID] = transcriptPath
        read(tabID: tabID)
        startWatcher(tabID: tabID, transcriptPath: transcriptPath)
    }

    private func startWatcher(tabID: UUID, transcriptPath: String) {
        let watcher = FileWatcher(url: URL(fileURLWithPath: transcriptPath), createsFile: false) { [weak self] in
            self?.scheduleRead(tabID: tabID)
        }
        watcher.start()
        watchers[tabID] = watcher
    }

    func stopWatching(tabID: UUID) {
        watchers.removeValue(forKey: tabID)?.stop()
        stopSubagentWatchers(tabID: tabID)
        pending.removeValue(forKey: tabID)?.cancel()
        inFlight.removeValue(forKey: tabID)
        rereadRequested.remove(tabID)
        awaitingSubagents.removeValue(forKey: tabID)?.watcher.stop()
        subagentLinearEvidence.removeValue(forKey: tabID)
        paths.removeValue(forKey: tabID)
        transcripts.removeValue(forKey: tabID)
        subagentTranscripts.removeValue(forKey: tabID)
        // A new session file, or a closed tab, so no finish recorded for the
        // old one should decide whether a subagent of the new one lingers.
        completionTracker.forget(tabID: tabID)
        // Nothing watches this tab now, so a subagent that was working when
        // the watch stopped would otherwise pin the task at working forever.
        statusEngine.setSubagentActivity(tabID: tabID, working: false)
        backgroundTasks.forget(tabID: tabID)
        linearActivity.forgetActivity(tabID: tabID)
        linkedPullRequests.forget(tabID: tabID)
        referenceCaches.removeValue(forKey: tabID)
    }

    func stopAll() {
        for watcher in watchers.values { watcher.stop() }
        for tabWatchers in subagentWatchers.values {
            for watcher in tabWatchers.values { watcher.stop() }
        }
        for task in pending.values { task.cancel() }
        for tabID in paths.keys {
            linearActivity.forgetActivity(tabID: tabID)
            linkedPullRequests.forget(tabID: tabID)
        }
        referenceCaches.removeAll()
        watchers.removeAll()
        subagentWatchers.removeAll()
        pending.removeAll()
        inFlight.removeAll()
        rereadRequested.removeAll()
        for awaiting in awaitingSubagents.values { awaiting.watcher.stop() }
        awaitingSubagents.removeAll()
        subagentLinearEvidence.removeAll()
        paths.removeAll()
        transcripts.removeAll()
        for tabID in subagentTranscripts.keys {
            statusEngine.setSubagentActivity(tabID: tabID, working: false)
        }
        subagentTranscripts.removeAll()
        backgroundTasks.reset()
    }

    func transcript(forTab tabID: UUID) -> Transcript? {
        transcripts[tabID]
    }

    /// The file a tab is watching, which is not always the path it was
    /// registered with — a relocated session gets re-pointed here. The owning
    /// view persists this back onto the tab.
    func watchedPath(forTab tabID: UUID) -> String? {
        paths[tabID]
    }

    /// `EnterWorktree` moves a live transcript into a project directory keyed
    /// by the worktree, keeping the session id. A read that finds nothing —
    /// whether the file is gone or sitting there empty — is the signal to go
    /// find where the session went.
    ///
    /// A session that has genuinely written nothing yet finds nothing and
    /// keeps its current path, so it still reads as waiting rather than lost.
    ///
    /// It is the same session, so everything published for the tab stays up
    /// until the new file's read replaces it. Tearing it down would blank the
    /// chat, and briefly drop subagents whose directory has not moved yet.
    @discardableResult
    private func repointIfRelocated(tabID: UUID, from path: String) -> Bool {
        let sessionID = (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
        let found = SessionJSONLReader.locateTranscript(sessionID: sessionID, inProjectsDirectory: projectsDirectory)
        guard let relocated = found, relocated != path else { return false }
        relocate(tabID: tabID, to: relocated)
        return true
    }

    private func relocate(tabID: UUID, to path: String) {
        watchers.removeValue(forKey: tabID)?.stop()
        stopSubagentWatchers(tabID: tabID)
        awaitingSubagents.removeValue(forKey: tabID)?.watcher.stop()
        pending.removeValue(forKey: tabID)?.cancel()
        paths[tabID] = path
        startWatcher(tabID: tabID, transcriptPath: path)
        read(tabID: tabID)
    }

    private func awaitSubagents(tabID: UUID, transcriptPath: String) {
        let directory = SessionJSONLReader.subagentsDirectory(forTranscriptPath: transcriptPath)
        guard awaitingSubagents[tabID]?.directory != directory else { return }
        awaitingSubagents.removeValue(forKey: tabID)?.watcher.stop()
        let watcher = FileWatcher(url: URL(fileURLWithPath: directory), createsFile: false) { [weak self] in
            self?.scheduleRead(tabID: tabID)
        }
        watcher.start()
        awaitingSubagents[tabID] = (directory, watcher)
        // Back already, between the read that missed it and this watch, which
        // only reports an arrival it waits for.
        if FileManager.default.fileExists(atPath: directory) { scheduleRead(tabID: tabID) }
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
    /// `intact` is false when `subagents/` could not be listed, or a listed
    /// file was gone by the time it was read — what a move of the directory
    /// looks like from either side of it.
    private nonisolated static func readSubagents(
        transcriptPath: String,
        parentData: Data
    ) -> (subagents: [SubagentTranscript], intact: Bool) {
        guard let paths = SessionJSONLReader.listedSubagentTranscriptPaths(forTranscriptPath: transcriptPath)
        else { return ([], false) }
        guard !paths.isEmpty else { return ([], true) }

        let results = SubagentSpawnResults(parentData: parentData)
        // Scanning the parent for spawn calls costs a second full pass, so it
        // only happens when a sidecar is actually missing.
        var scanned: [String: SubagentDescriptor]?

        let subagents = paths.compactMap { subagentPath -> SubagentTranscript? in
            // Parsing nothing would show it as not started.
            guard let data = FileManager.default.contents(atPath: subagentPath) else { return nil }
            let id = Self.subagentID(forPath: subagentPath)
            let transcript = TranscriptParser.parse(data, includeSidechain: true)

            var descriptor = SubagentMetadataReader.read(forSubagentPath: subagentPath)
            if descriptor == nil {
                let table = scanned ?? SubagentSpawnScanner.descriptors(in: parentData)
                scanned = table
                descriptor = table[id]
            }

            let parentSignal = results.signal(forAgentID: id)
            return SubagentTranscript(
                id: id,
                transcript: transcript,
                modifiedAt: SessionJSONLReader.lastModified(atPath: subagentPath),
                descriptor: descriptor,
                parentSignal: parentSignal,
                status: SubagentStatusDeriver.derive(
                    transcript: transcript,
                    parentSignal: parentSignal,
                    stoppedByUser: descriptor?.stoppedByUser ?? false
                )
            )
        }
        return (subagents, subagents.count == paths.count)
    }

    private nonisolated static func linearEvidence(subagents: [SubagentTranscript]) -> [LinearEvidence] {
        subagents.flatMap { sub in
            LinearActivityScanner.scan(
                sub.transcript.messages,
                subagent: LinearSubagentRef(id: sub.id, label: sub.title)
            )
        }
    }

    private nonisolated struct ParsedRead {
        let transcript: Transcript
        let subagents: [SubagentTranscript]
        /// Whether `subagents/` was there and every file it listed was read.
        let subagentsIntact: Bool
        let backgroundTasks: [BackgroundTaskTracker.Entry]
        let transcriptEvidence: [LinearEvidence]
        let subagentEvidence: [LinearEvidence]
        let references: ConversationReferences
        let referenceCache: ConversationReferenceScanner.Cache
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
        guard let path = paths[tabID] else { return }
        guard inFlight[tabID] == nil else {
            rereadRequested.insert(tabID)
            didDeferRead?(tabID)
            return
        }
        let token = UUID()
        inFlight[tabID] = token
        let referenceCache = referenceCaches[tabID] ?? ConversationReferenceScanner.Cache()
        let afterLoading = afterLoadingTranscript
        Task.detached(priority: .utility) {
            let data = FileManager.default.contents(atPath: path)
            await afterLoading?(path)
            let parsed = data.map { data in
                let transcript = TranscriptParser.parse(data)
                let (subagents, intact) = Self.readSubagents(transcriptPath: path, parentData: data)
                var referenceCache = referenceCache
                let references = ConversationReferenceScanner.scan(transcript.messages, cache: &referenceCache)
                return ParsedRead(
                    transcript: transcript,
                    subagents: subagents,
                    subagentsIntact: intact,
                    backgroundTasks: BackgroundTaskScanner.inFlight(parentData: data),
                    transcriptEvidence: LinearActivityScanner.scan(transcript.messages, subagent: nil),
                    subagentEvidence: Self.linearEvidence(subagents: subagents),
                    references: references,
                    referenceCache: referenceCache
                )
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                defer { self.didRead?(tabID) }
                guard self.inFlight[tabID] == token else { return }
                self.inFlight.removeValue(forKey: tabID)
                let reread = self.rereadRequested.remove(tabID) != nil
                // A re-point below may already have started the next read.
                defer { if reread, self.inFlight[tabID] == nil { self.read(tabID: tabID) } }
                guard let parsed else {
                    self.repointIfRelocated(tabID: tabID, from: path)
                    return
                }
                // An empty file is often the stub a move leaves behind, so the
                // file it moved to replaces the chat rather than a blank one.
                if parsed.transcript.messages.isEmpty, self.repointIfRelocated(tabID: tabID, from: path) {
                    return
                }
                let previousDirectory = self.transcripts[tabID]?.cwd
                self.transcripts[tabID] = parsed.transcript
                if let cwd = parsed.transcript.cwd, cwd != previousDirectory {
                    self.onWorkingDirectoryChanged?(tabID, cwd)
                }
                let previousSubagents = self.subagentTranscripts[tabID] ?? []
                if !parsed.subagentsIntact, !previousSubagents.isEmpty {
                    self.subagentTranscripts[tabID] = self.settled(
                        Self.rederived(previousSubagents), tabID: tabID
                    )
                    self.awaitSubagents(tabID: tabID, transcriptPath: path)
                } else {
                    self.awaitingSubagents.removeValue(forKey: tabID)?.watcher.stop()
                    self.subagentTranscripts[tabID] = self.settled(parsed.subagents, tabID: tabID)
                    self.subagentLinearEvidence[tabID] = parsed.subagentEvidence
                }
                self.publishSubagentActivity(tabID: tabID, subagents: self.subagentTranscripts[tabID] ?? [])
                // A tab with nothing behind it has a transcript that is a
                // record, not a running process, so its tasks stopped with it.
                self.backgroundTasks.replace(
                    tabID: tabID,
                    entries: self.isTabLive(tabID) ? parsed.backgroundTasks : []
                )
                self.linearActivity.replaceActivity(
                    tabID: tabID,
                    evidence: parsed.transcriptEvidence + (self.subagentLinearEvidence[tabID] ?? [])
                )
                self.linearActivity.replaceMentions(tabID: tabID, identifiers: parsed.references.linearIdentifiers)
                self.linkedPullRequests.replace(tabID: tabID, references: parsed.references.pullRequests)
                self.referenceCaches[tabID] = parsed.referenceCache
                self.syncSubagentWatchers(tabID: tabID, transcriptPath: path)
            }
        }
    }

    /// The corrections a freshly derived list needs, both of which depend on
    /// state the deriver cannot see from the file it parses.
    private func settled(_ subagents: [SubagentTranscript], tabID: UUID) -> [SubagentTranscript] {
        statusOverrides.applying(settlingDormant(subagents, tabID: tabID), tabID: tabID)
    }

    /// Records a status the user set by hand on a subagent row, and republishes
    /// the tab's rows so the change lands without waiting for a file write.
    func setOverride(
        _ override: SubagentStatusOverrides.Override?,
        tabID: UUID,
        subagentID: String
    ) {
        statusOverrides.set(override, tabID: tabID, subagentID: subagentID)
        guard let subagents = subagentTranscripts[tabID] else { return }
        subagentTranscripts[tabID] = settled(Self.rederived(subagents), tabID: tabID)
        publishSubagentActivity(tabID: tabID, subagents: subagentTranscripts[tabID] ?? [])
    }

    /// Statuses re-derived from the parsed transcripts rather than taken from a
    /// corrected list, so a cleared override or a revived process restores the
    /// real status.
    private static func rederived(_ subagents: [SubagentTranscript]) -> [SubagentTranscript] {
        subagents.map { subagent in
            var reset = subagent
            reset.status = SubagentStatusDeriver.derive(
                transcript: subagent.transcript,
                parentSignal: subagent.parentSignal,
                stoppedByUser: subagent.descriptor?.stoppedByUser ?? false
            )
            return reset
        }
    }

    /// A tab with no process behind it — restored from disk and never
    /// resumed, or one whose process died mid-turn (sleep, a quit) — has a
    /// transcript that is a record, not a running process, so a subagent left
    /// mid-step reads as interrupted rather than working. The deriver cannot
    /// tell the difference — it parses files off the main actor with no idea
    /// whether anything is alive — so the correction happens here, where
    /// liveness is known.
    private func settlingDormant(_ subagents: [SubagentTranscript], tabID: UUID) -> [SubagentTranscript] {
        guard statusEngine.isDormant(tabID: tabID) || !isTabLive(tabID) else { return subagents }
        return subagents.map { subagent in
            guard subagent.status == .working else { return subagent }
            var settled = subagent
            settled.status = .interrupted
            return settled
        }
    }

    /// This is the only place that sees every subagent's status per tab, so it
    /// is what tells `StatusEngine` a finished turn is still not done, and what
    /// starts a finished subagent's linger.
    ///
    /// The linger is driven from here rather than from the chat's list because
    /// this store watches every tab whether or not a view is mounted. Driven
    /// from a view, a subagent that finished while the user was looking
    /// elsewhere would never start its clock, and would sit in the sidebar
    /// forever.
    private func publishSubagentActivity(tabID: UUID, subagents: [SubagentTranscript]) {
        completionTracker.observe(subagents, tabID: tabID)
        statusEngine.setSubagentActivity(
            tabID: tabID,
            working: subagents.contains { $0.status == .working }
        )
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
            let watcher = FileWatcher(url: URL(fileURLWithPath: path), createsFile: false) { [weak self] in
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
