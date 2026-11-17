import Foundation
import Observation
#if DEBUG
import OSLog
import QuartzCore
#endif

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
/// One watcher per agent tab, mirroring `AgentTitleMonitor`. A change to the
/// main transcript that only appended to it decodes just the appended lines
/// (`TranscriptFold`); anything else, such as a rewrite or a replaced file,
/// re-reads the whole file, which takes seconds on a transcript of tens of
/// megabytes. Either way the read runs off the main actor and only the
/// result is published on it. Subagent files are parsed incrementally too
/// (`SubagentTranscriptCache`): a session can have hundreds, and re-parsing
/// every one on each write would hold a core busy for as long as they run.
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
    /// Each tab's open debounce window. The change that opens one reads at
    /// once; changes inside it wait for it to close.
    private var debounceWindows: [UUID: Task<Void, Never>] = [:]
    private var changedDuringWindow: Set<UUID> = []
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
    private var awaitingSubagents: [UUID: (directory: String, watcher: FileWatcher, expiry: Task<Void, Never>)] = [:]
    /// The subagents each tab shows only because an earlier read had them: the
    /// latest read could not read their files.
    private var carriedSubagentIDs: [UUID: Set<String>] = [:]
    /// The part of each tab's Linear evidence that came from its subagents,
    /// kept so carried subagents keep contributing.
    private var subagentLinearEvidence: [UUID: [LinearEvidence]] = [:]
    private let projectsDirectory: URL
    /// How long carried subagents wait for their directory before they go.
    private let carriedSubagentExpiry: Duration

    #if DEBUG
    /// Awaited by every read between loading a file and parsing it, with the
    /// path it loaded, so a test can hold a read in flight.
    var afterLoadingTranscript: (@Sendable (String) async -> Void)?

    /// Fires when a change waits for its tab's debounce window to close.
    var didDeferToWindowEnd: ((UUID) -> Void)?

    /// Fires when a read is requested while one is in flight, so a test can
    /// tell the request landed before releasing a held read.
    var didDeferRead: ((UUID) -> Void)?

    /// Fires after carried subagents expire.
    var didExpireCarriedSubagents: ((UUID) -> Void)?

    /// Reports how each settled read reached its subagent transcripts, and
    /// whether it reused the parent's parse.
    var didParseSubagents: ((UUID, SubagentTranscriptCache.Stats, _ reusedParent: Bool) -> Void)?

    /// Reports how each settled read reached the main transcript's parse.
    var didReadParent: ((UUID, ParentReadPath) -> Void)?
    #endif

    // This drives visible chat content rather than a sidebar label, so it
    // needs to feel live — much shorter than AgentTitleMonitor's 1s.
    private let debounce: Duration
    private let sleep: @Sendable (Duration) async -> Void
    private let statusEngine: StatusEngine
    private let backgroundTasks: BackgroundTaskTracker
    private let linearActivity: LinearActivitySink
    private let linkedPullRequests: LinkedPullRequestStore
    /// Per tab, so a read rescans only the messages that changed.
    private var referenceCaches: [UUID: ConversationReferenceScanner.Cache] = [:]
    /// Per tab, so a read re-parses only the subagent files that changed.
    private var subagentCaches: [UUID: SubagentTranscriptCache] = [:]
    /// Per tab: the last parse of the main transcript, reused while the file
    /// is unchanged so a subagent's write never re-parses the parent, and
    /// continued from where it stopped when the file only grew.
    private var parentParses: [UUID: ParentParse] = [:]
    private let completionTracker: SubagentCompletionTracker
    private let statusOverrides: SubagentStatusOverrides
    /// Whether a live process backs a tab, checked across both transports. A
    /// tab that ran this session and then lost its process (sleep, a quit
    /// mid-turn) is not dormant — it was never restored from disk — so
    /// `settlingDormant` needs this in addition to `StatusEngine.isDormant`
    /// to catch a subagent left reading `working` with nothing behind it.
    private let isTabLive: @MainActor (UUID) -> Bool

    /// Fires after every read settles, whether or not it published anything.
    /// Tests await this instead of polling a clock, which a parallel run's
    /// CPU-bound suites can outlast.
    var didRead: ((UUID) -> Void)?

    /// Reports each change in a tab's transcript `cwd`, which is where the
    /// agent's shell is now. It fires for a hidden tab too, since the watch
    /// outlives the chat view.
    var onWorkingDirectoryChanged: ((UUID, String) -> Void)?

    /// Reports the ID of a tab's last message on its first read and whenever
    /// it changes. A transcript that is not there reports nil.
    var onLatestMessageChanged: ((UUID, String?) -> Void)?
    @ObservationIgnored private var reportedLatestMessageIDs: [UUID: String?] = [:]

    init(
        debounce: Duration = .milliseconds(250),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        statusEngine: StatusEngine = .shared,
        backgroundTasks: BackgroundTaskTracker = .shared,
        linearActivity: LinearActivitySink? = nil,
        linkedPullRequests: LinkedPullRequestStore? = nil,
        completionTracker: SubagentCompletionTracker = .shared,
        statusOverrides: SubagentStatusOverrides = .shared,
        projectsDirectory: URL = SessionJSONLReader.projectsDirectory,
        carriedSubagentExpiry: Duration = .seconds(60),
        isTabLive: @escaping @MainActor (UUID) -> Bool = TranscriptStore.hasLiveSession
    ) {
        self.debounce = debounce
        self.sleep = sleep
        self.statusEngine = statusEngine
        self.backgroundTasks = backgroundTasks
        self.linearActivity = linearActivity ?? LinearStore.shared
        self.linkedPullRequests = linkedPullRequests ?? .shared
        self.completionTracker = completionTracker
        self.statusOverrides = statusOverrides
        self.projectsDirectory = projectsDirectory
        self.carriedSubagentExpiry = carriedSubagentExpiry
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
        closeDebounceWindow(tabID: tabID)
        inFlight.removeValue(forKey: tabID)
        rereadRequested.remove(tabID)
        stopAwaitingSubagents(tabID: tabID)
        carriedSubagentIDs.removeValue(forKey: tabID)
        subagentLinearEvidence.removeValue(forKey: tabID)
        paths.removeValue(forKey: tabID)
        transcripts.removeValue(forKey: tabID)
        reportedLatestMessageIDs.removeValue(forKey: tabID)
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
        subagentCaches.removeValue(forKey: tabID)
        parentParses.removeValue(forKey: tabID)
    }

    func stopAll() {
        for watcher in watchers.values { watcher.stop() }
        for tabWatchers in subagentWatchers.values {
            for watcher in tabWatchers.values { watcher.stop() }
        }
        for window in debounceWindows.values { window.cancel() }
        for tabID in paths.keys {
            linearActivity.forgetActivity(tabID: tabID)
            linkedPullRequests.forget(tabID: tabID)
        }
        referenceCaches.removeAll()
        subagentCaches.removeAll()
        parentParses.removeAll()
        watchers.removeAll()
        subagentWatchers.removeAll()
        debounceWindows.removeAll()
        changedDuringWindow.removeAll()
        inFlight.removeAll()
        rereadRequested.removeAll()
        for awaiting in awaitingSubagents.values {
            awaiting.watcher.stop()
            awaiting.expiry.cancel()
        }
        awaitingSubagents.removeAll()
        carriedSubagentIDs.removeAll()
        subagentLinearEvidence.removeAll()
        paths.removeAll()
        transcripts.removeAll()
        reportedLatestMessageIDs.removeAll()
        for tabID in subagentTranscripts.keys {
            statusEngine.setSubagentActivity(tabID: tabID, working: false)
        }
        subagentTranscripts.removeAll()
        backgroundTasks.reset()
    }

    /// The live stream's ID for the tab's newest message, ahead of the read
    /// that will confirm or correct it.
    func streamReportedLatestMessage(tabID: UUID, messageID: String) {
        reportLatestMessage(messageID, tabID: tabID)
    }

    private func reportLatestMessage(_ messageID: String?, tabID: UUID) {
        if let reported = reportedLatestMessageIDs[tabID], reported == messageID { return }
        reportedLatestMessageIDs[tabID] = .some(messageID)
        onLatestMessageChanged?(tabID, messageID)
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
    private func repointIfRelocated(tabID: UUID, from path: String, locatedAt found: String?) -> Bool {
        guard let relocated = found, relocated != path else { return false }
        relocate(tabID: tabID, to: relocated)
        return true
    }

    private func relocate(tabID: UUID, to path: String) {
        watchers.removeValue(forKey: tabID)?.stop()
        stopSubagentWatchers(tabID: tabID)
        stopAwaitingSubagents(tabID: tabID)
        closeDebounceWindow(tabID: tabID)
        paths[tabID] = path
        startWatcher(tabID: tabID, transcriptPath: path)
        read(tabID: tabID)
    }

    private func awaitSubagents(tabID: UUID, transcriptPath: String) {
        let directory = SessionJSONLReader.subagentsDirectory(forTranscriptPath: transcriptPath)
        guard awaitingSubagents[tabID]?.directory != directory else { return }
        stopAwaitingSubagents(tabID: tabID)
        let watcher = FileWatcher(url: URL(fileURLWithPath: directory), createsFile: false) { [weak self] in
            self?.scheduleRead(tabID: tabID)
        }
        watcher.start()
        let expiry = Task { [weak self, carriedSubagentExpiry] in
            try? await Task.sleep(for: carriedSubagentExpiry)
            guard !Task.isCancelled else { return }
            self?.expireCarriedSubagents(tabID: tabID)
        }
        awaitingSubagents[tabID] = (directory, watcher, expiry)
        // Back already, between the read that missed it and this watch, which
        // only reports an arrival it waits for. This runs while a read is
        // publishing, so the next read starts after that finishes.
        if FileManager.default.fileExists(atPath: directory) {
            Task { [weak self] in self?.scheduleRead(tabID: tabID) }
        }
    }

    private func stopAwaitingSubagents(tabID: UUID) {
        guard let awaiting = awaitingSubagents.removeValue(forKey: tabID) else { return }
        awaiting.watcher.stop()
        awaiting.expiry.cancel()
    }

    /// The directory never came, so the carried rows describe agents nothing
    /// can read any more. The read this schedules republishes the Linear
    /// evidence without them.
    private func expireCarriedSubagents(tabID: UUID) {
        stopAwaitingSubagents(tabID: tabID)
        guard let carried = carriedSubagentIDs.removeValue(forKey: tabID), !carried.isEmpty,
              let current = subagentTranscripts[tabID]
        else { return }
        subagentTranscripts[tabID] = current.filter { !carried.contains($0.id) }
        subagentLinearEvidence[tabID]?.removeAll { evidence in
            evidence.subagent.map { carried.contains($0.id) } ?? false
        }
        publishSubagentActivity(tabID: tabID, subagents: subagentTranscripts[tabID] ?? [])
        scheduleRead(tabID: tabID)
        #if DEBUG
        didExpireCarriedSubagents?(tabID)
        #endif
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
    /// each against the parent's parse. `cache` keeps each file's parse, so
    /// only the files that changed since the last read are parsed again.
    ///
    /// `intact` is false when `subagents/` could not be listed, or a listed
    /// file was gone by the time it was read — what a move of the directory
    /// looks like from either side of it.
    private nonisolated static func readSubagents(
        transcriptPath: String,
        parent: ParentParse,
        cache: inout SubagentTranscriptCache
    ) -> (subagents: [SubagentTranscript], evidence: [LinearEvidence], intact: Bool) {
        let listed = SessionJSONLReader.listedSubagentTranscriptPaths(forTranscriptPath: transcriptPath)
        cache.beginRead(paths: listed)
        defer { cache.endRead() }
        guard let paths = listed else { return ([], [], false) }
        guard !paths.isEmpty else { return ([], [], true) }

        var subagents: [SubagentTranscript] = []
        var evidence: [LinearEvidence] = []
        for subagentPath in paths {
            // Parsing nothing would show it as not started.
            guard let (transcript, modifiedAt) = cache.transcript(atPath: subagentPath) else { continue }
            let id = Self.subagentID(forPath: subagentPath)

            let descriptor = cache.descriptor(forSubagentPath: subagentPath) ?? parent.spawnDescriptors[id]

            let parentSignal = parent.spawnResults.signal(forAgentID: id)
            let subagent = SubagentTranscript(
                id: id,
                transcript: transcript,
                modifiedAt: modifiedAt,
                descriptor: descriptor,
                parentSignal: parentSignal,
                status: SubagentStatusDeriver.derive(
                    transcript: transcript,
                    parentSignal: parentSignal,
                    stoppedByUser: descriptor?.stoppedByUser ?? false
                )
            )
            subagents.append(subagent)
            evidence += cache.linearEvidence(
                atPath: subagentPath,
                subagent: LinearSubagentRef(id: id, label: subagent.title)
            )
        }
        return (subagents, evidence, subagents.count == paths.count)
    }

    nonisolated enum ParentReadPath: Sendable, Equatable {
        /// The file was unchanged, so the last parse stood.
        case reused
        /// Only the bytes after the last parse's end were read.
        case appended
        case full
    }

    /// The main transcript's new bytes, and the parse they continue.
    private nonisolated enum ParentBytes {
        case appended(Data, to: TranscriptFold)
        case whole(Data)

        var count: Int {
            switch self {
            case .appended(let data, _), .whole(let data): data.count
            }
        }

        /// Only the bytes past the last parse when the file is the same one,
        /// no shorter, and unchanged up to where that parse stopped.
        static func load(path: String, fingerprint: FileFingerprint?, previous: ParentParse?) -> ParentBytes? {
            if let previous, let fingerprint,
               previous.fingerprint?.fileNumber == fingerprint.fileNumber,
               fingerprint.size >= previous.fold.consumed,
               let appended = previous.fold.cursor.appendedBytes(atPath: path) {
                return .appended(appended, to: previous.fold)
            }
            return FileManager.default.contents(atPath: path).map(ParentBytes.whole)
        }
    }

    /// Everything a read derives from the main transcript's bytes alone.
    private nonisolated struct ParentParse: Sendable {
        let fingerprint: FileFingerprint?
        /// The parser's and scans' state, which the next read continues when
        /// the file only grew. It keeps no raw bytes and no decoded lines.
        let fold: TranscriptFold
        let transcript: Transcript
        let backgroundTasks: [BackgroundTaskTracker.Entry]
        let transcriptEvidence: [LinearEvidence]
        let references: ConversationReferences
        let referenceCache: ConversationReferenceScanner.Cache
        let spawnResults: SubagentSpawnResults
        /// What each spawning call asked for, for a subagent with no sidecar.
        let spawnDescriptors: [String: SubagentDescriptor]
        let path: ParentReadPath

        init(
            bytes: ParentBytes,
            fingerprint: FileFingerprint?,
            referenceCache: ConversationReferenceScanner.Cache,
            timings: inout ReadTimings
        ) {
            var fold: TranscriptFold
            let newBytes: Data
            switch bytes {
            case .appended(let appended, let previous):
                fold = previous
                newBytes = appended
                path = .appended
            case .whole(let whole):
                fold = TranscriptFold()
                newBytes = whole
                path = .full
            }
            let snapshot = fold.append(newBytes)
            timings.fold = snapshot.timings
            let transcript = snapshot.transcript
            var referenceCache = referenceCache
            self.fingerprint = fingerprint
            self.fold = fold
            self.transcript = transcript
            backgroundTasks = snapshot.backgroundTasks
            transcriptEvidence = timings.time(\.linear) { LinearActivityScanner.scan(transcript.messages, subagent: nil) }
            references = timings.time(\.references) {
                ConversationReferenceScanner.scan(transcript.messages, cache: &referenceCache)
            }
            self.referenceCache = referenceCache
            spawnResults = snapshot.spawnResults
            spawnDescriptors = snapshot.spawnDescriptors
        }
    }

    /// Milliseconds per stage of a read, measured and logged only in a Debug
    /// build.
    private nonisolated struct ReadTimings: Sendable {
        var load = 0.0
        var fold = TranscriptFold.Timings()
        var linear = 0.0
        var references = 0.0
        var subagents = 0.0

        static func now() -> Double {
            #if DEBUG
            CACurrentMediaTime()
            #else
            0
            #endif
        }

        mutating func time<T>(_ slot: WritableKeyPath<Self, Double>, _ body: () -> T) -> T {
            #if DEBUG
            let began = Self.now()
            defer { self[keyPath: slot] += (Self.now() - began) * 1000 }
            #endif
            return body()
        }

        func log(since began: Double, bytes: UInt64, bytesRead: Int, path: ParentReadPath) {
            #if DEBUG
            let ms = { (value: Double) in "\(Int(value.rounded()))ms" }
            let line = "transcript-read load=\(ms(load)) decode=\(ms(fold.decode)) parse=\(ms(fold.parse)) "
                + "bgTasks=\(ms(fold.backgroundTasks)) linear=\(ms(linear)) references=\(ms(references)) "
                + "spawnResults=\(ms(fold.spawnResults)) subagents=\(ms(subagents)) "
                + "total=\(ms((Self.now() - began) * 1000)) "
                + "bytes=\(bytes) bytesRead=\(bytesRead) tail=\(path == .appended) reusedParent=\(path == .reused)"
            Log.app.info("\(line, privacy: .public)")
            #endif
        }
    }

    private nonisolated struct ParsedRead: Sendable {
        let parent: ParentParse
        var transcript: Transcript { parent.transcript }
        let subagents: [SubagentTranscript]
        /// Whether `subagents/` was there and every file it listed was read.
        let subagentsIntact: Bool
        let subagentEvidence: [LinearEvidence]
        let subagentCache: SubagentTranscriptCache
        let parentPath: ParentReadPath
        var reusedParent: Bool { parentPath == .reused }
    }

    private nonisolated static func sessionID(forPath path: String) -> String {
        (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
    }

    private nonisolated static func subagentID(forPath path: String) -> String {
        (path as NSString)
            .lastPathComponent
            .replacingOccurrences(of: "agent-", with: "")
            .replacingOccurrences(of: ".jsonl", with: "")
    }

    /// Reads at once on the first change of a burst, so a sent message shows
    /// without waiting out the debounce. Later changes wait for the window to
    /// close and share one read, and that read opens a new window. A window
    /// never restarts, so a transcript that streams without pause still reads
    /// once per `debounce` rather than not at all.
    private func scheduleRead(tabID: UUID) {
        guard debounceWindows[tabID] == nil else {
            changedDuringWindow.insert(tabID)
            #if DEBUG
            didDeferToWindowEnd?(tabID)
            #endif
            return
        }
        read(tabID: tabID)
        openDebounceWindow(tabID: tabID)
    }

    private func openDebounceWindow(tabID: UUID) {
        debounceWindows[tabID] = Task { [sleep, debounce] in
            await sleep(debounce)
            guard !Task.isCancelled else { return }
            debounceWindows.removeValue(forKey: tabID)
            guard changedDuringWindow.remove(tabID) != nil else { return }
            read(tabID: tabID)
            openDebounceWindow(tabID: tabID)
        }
    }

    private func closeDebounceWindow(tabID: UUID) {
        debounceWindows.removeValue(forKey: tabID)?.cancel()
        changedDuringWindow.remove(tabID)
    }

    /// Reads and parses off the main actor, then publishes on it.
    ///
    /// A live transcript is megabytes of JSONL and reads come several times a
    /// second while a turn streams, so parsing here would stutter the window.
    /// One read per tab at a time: the parse can outlast the debounce,
    /// and queuing them would spend the whole gain re-parsing stale bytes.
    private func read(tabID: UUID) {
        guard let path = paths[tabID] else { return }
        guard inFlight[tabID] == nil else {
            rereadRequested.insert(tabID)
            #if DEBUG
            didDeferRead?(tabID)
            #endif
            return
        }
        let token = UUID()
        inFlight[tabID] = token
        let referenceCache = referenceCaches[tabID] ?? ConversationReferenceScanner.Cache()
        let previousParent = parentParses[tabID]
        let subagentCache = subagentCaches[tabID] ?? SubagentTranscriptCache()
        let projectsDirectory = projectsDirectory
        #if DEBUG
        let afterLoading = afterLoadingTranscript
        #endif
        Task.detached(priority: .utility) {
            var timings = ReadTimings()
            let readBegan = ReadTimings.now()
            let fingerprint = FileFingerprint(path: path)
            let reusable = previousParent.flatMap { previous in
                fingerprint != nil && previous.fingerprint == fingerprint ? previous : nil
            }
            let bytes = reusable == nil ? timings.time(\.load) {
                ParentBytes.load(path: path, fingerprint: fingerprint, previous: previousParent)
            } : nil
            #if DEBUG
            await afterLoading?(path)
            #endif
            let parentParse = reusable ?? bytes.map {
                ParentParse(bytes: $0, fingerprint: fingerprint, referenceCache: referenceCache, timings: &timings)
            }
            let parentPath = reusable != nil ? ParentReadPath.reused : parentParse?.path ?? .full
            let parsed = parentParse.map { parent in
                var subagentCache = subagentCache
                let (subagents, evidence, intact) = timings.time(\.subagents) {
                    Self.readSubagents(transcriptPath: path, parent: parent, cache: &subagentCache)
                }
                timings.log(
                    since: readBegan,
                    bytes: fingerprint?.size ?? 0,
                    bytesRead: bytes?.count ?? 0,
                    path: parentPath
                )
                return ParsedRead(
                    parent: parent,
                    subagents: subagents,
                    subagentsIntact: intact,
                    subagentEvidence: evidence,
                    subagentCache: subagentCache,
                    parentPath: parentPath
                )
            }
            // A missing or empty file is the sign of a move, so look for the
            // session elsewhere, off the main actor.
            let located = parsed?.transcript.messages.isEmpty ?? true
                ? SessionJSONLReader.locateTranscript(
                    sessionID: Self.sessionID(forPath: path), inProjectsDirectory: projectsDirectory
                )
                : nil
            await MainActor.run { [weak self] in
                Self.publishing {
                    guard let self else { return }
                    defer { self.didRead?(tabID) }
                    guard self.inFlight[tabID] == token else { return }
                    self.inFlight.removeValue(forKey: tabID)
                    let reread = self.rereadRequested.remove(tabID) != nil
                    // A re-point below may already have started the next read.
                    defer { if reread, self.inFlight[tabID] == nil { self.read(tabID: tabID) } }
                    guard let parsed else {
                        if !self.repointIfRelocated(tabID: tabID, from: path, locatedAt: located), self.transcripts[tabID] == nil {
                            self.reportLatestMessage(nil, tabID: tabID)
                        }
                        return
                    }
                    // An empty file is often the stub a move leaves behind, so the
                    // file it moved to replaces the chat rather than a blank one.
                    if parsed.transcript.messages.isEmpty, self.repointIfRelocated(tabID: tabID, from: path, locatedAt: located) {
                        return
                    }
                    self.parentParses[tabID] = parsed.parent
                    self.subagentCaches[tabID] = parsed.subagentCache
                    #if DEBUG
                    self.didParseSubagents?(tabID, parsed.subagentCache.stats, parsed.reusedParent)
                    self.didReadParent?(tabID, parsed.parentPath)
                    #endif
                    let previousDirectory = self.transcripts[tabID]?.cwd
                    self.transcripts[tabID] = parsed.transcript
                    self.reportLatestMessage(parsed.transcript.messages.last?.id, tabID: tabID)
                    if let cwd = parsed.transcript.cwd, cwd != previousDirectory {
                        self.onWorkingDirectoryChanged?(tabID, cwd)
                    }
                    let merge = Self.merging(
                        parsed,
                        into: self.subagentTranscripts[tabID] ?? [],
                        evidence: self.subagentLinearEvidence[tabID] ?? []
                    )
                    self.subagentTranscripts[tabID] = self.settled(merge.subagents, tabID: tabID)
                    self.subagentLinearEvidence[tabID] = merge.evidence
                    if merge.carried.isEmpty {
                        self.carriedSubagentIDs.removeValue(forKey: tabID)
                        self.stopAwaitingSubagents(tabID: tabID)
                    } else {
                        self.carriedSubagentIDs[tabID] = merge.carried
                        self.awaitSubagents(tabID: tabID, transcriptPath: path)
                    }
                    self.publishSubagentActivity(tabID: tabID, subagents: self.subagentTranscripts[tabID] ?? [])
                    // A tab with nothing behind it has a transcript that is a
                    // record, not a running process, so its tasks stopped with it.
                    self.backgroundTasks.replace(
                        tabID: tabID,
                        entries: self.isTabLive(tabID) ? parsed.parent.backgroundTasks : []
                    )
                    self.linearActivity.replaceActivity(
                        tabID: tabID,
                        evidence: parsed.parent.transcriptEvidence + (self.subagentLinearEvidence[tabID] ?? [])
                    )
                    self.linearActivity.replaceMentions(tabID: tabID, identifiers: parsed.parent.references.linearIdentifiers)
                    self.linkedPullRequests.replace(tabID: tabID, references: parsed.parent.references.pullRequests)
                    self.referenceCaches[tabID] = parsed.parent.referenceCache
                    self.syncSubagentWatchers(tabID: tabID, transcriptPath: path)
                }
            }
        }
    }

    @MainActor
    private static func publishing(_ body: () -> Void) {
        #if DEBUG
        SwitchLatencyProbe.time("storePublish", body)
        #else
        body()
        #endif
    }

    /// A read that could not read every listed subagent file updates the ones
    /// it did read and carries the rest over by ID from the previous list.
    private static func merging(
        _ parsed: ParsedRead,
        into previous: [SubagentTranscript],
        evidence previousEvidence: [LinearEvidence]
    ) -> (subagents: [SubagentTranscript], evidence: [LinearEvidence], carried: Set<String>) {
        guard !parsed.subagentsIntact, !previous.isEmpty else {
            return (parsed.subagents, parsed.subagentEvidence, [])
        }
        let fresh = Dictionary(parsed.subagents.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let previousIDs = Set(previous.map(\.id))
        let carried = previousIDs.subtracting(fresh.keys)
        let carriedRows = rederived(previous.filter { carried.contains($0.id) })
        let carriedByID = Dictionary(uniqueKeysWithValues: carriedRows.map { ($0.id, $0) })
        let merged = previous.compactMap { fresh[$0.id] ?? carriedByID[$0.id] }
            + parsed.subagents.filter { !previousIDs.contains($0.id) }
        let kept = previousEvidence.filter { evidence in
            evidence.subagent.map { carried.contains($0.id) } ?? false
        }
        return (merged, parsed.subagentEvidence + kept, carried)
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
