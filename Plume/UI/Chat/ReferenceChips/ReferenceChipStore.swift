import Foundation
import Observation

/// What each reference chip in the chat shows: its title and its icon.
///
/// A chat list says which targets its pieces link to with `want(_:owner:)`.
/// The store looks them up (Linear through `LinearStore`, pull requests
/// through `PullRequestLinkSource`, files on disk) and bumps the owner's
/// `revision(for:)` when a wanted target's title arrives or changes, which is
/// the list's cue to rebuild its pieces. An icon change alone re-renders only
/// the text drawing it, since `icon(for:)` reads a per-target box.
@MainActor @Observable
final class ReferenceChipStore {
    static let shared = ReferenceChipStore()

    struct Resolution: Equatable {
        let title: String
        let icon: ReferenceChipIcon
    }

    struct Dependencies {
        var linearIssue: @MainActor (String) -> LinearIssue?
        var wantLinear: @MainActor (Set<String>, UUID) -> Void
        var pullRequests: @Sendable (Set<PullRequestLinkSource.Key>) async -> [PullRequestLinkSource.Key: PullRequestLinkSource.Lookup]
        /// Whether each path is a directory, for the paths that exist.
        var fileKinds: @Sendable ([String]) async -> [String: Bool]
        var sleep: @Sendable (Duration) async -> Void
        var now: @Sendable () -> Date

        static let live = Dependencies(
            linearIssue: { LinearStore.shared.state(for: $0)?.issue },
            wantLinear: { LinearStore.shared.setWanted($0, owner: $1) },
            pullRequests: { await PullRequestLinkSource.shared.lookUp($0) },
            fileKinds: { paths in
                await Task.detached(priority: .utility) { ReferenceChipStore.fileKinds(paths) }.value
            },
            sleep: { try? await Task.sleep(for: $0) },
            now: { Date() }
        )
    }

    /// How long a missing file or a failed pull request lookup waits before
    /// it is asked about again.
    static let retryInterval: TimeInterval = 30
    static let coalescing: Duration = .milliseconds(250)
    static let pullRequestDebounce: Duration = .milliseconds(100)

    @Observable
    final class Box {
        var resolution: Resolution?
    }

    @Observable
    final class Revision {
        var value = 0
    }

    @ObservationIgnored private var boxes: [ReferenceTarget: Box] = [:]
    @ObservationIgnored private var revisions: [UUID: Revision] = [:]
    @ObservationIgnored private var wants: [UUID: Set<ReferenceTarget>] = [:]
    @ObservationIgnored private var linearOwners: [UUID: UUID] = [:]
    /// When each target looked up is next worth asking about.
    @ObservationIgnored private var nextLookups: [ReferenceTarget: Date] = [:]
    @ObservationIgnored private var inFlight: Set<ReferenceTarget> = []
    @ObservationIgnored private var pendingPullRequests: Set<ReferenceTarget> = []
    @ObservationIgnored private var pendingOwners: Set<UUID> = []
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pullRequestTask: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var linearTrackingGeneration = 0
    @ObservationIgnored private let dependencies: Dependencies

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    // MARK: - Reading

    func title(for target: ReferenceTarget) -> String? {
        box(for: target).resolution?.title
    }

    /// Nil for a target nothing has vouched for yet.
    func icon(for target: ReferenceTarget) -> ReferenceChipIcon? {
        box(for: target).resolution?.icon
    }

    func revision(for owner: UUID) -> Int {
        revisionBox(for: owner).value
    }

    // MARK: - Wants

    /// Replaces the targets `owner` shows. An empty set releases them.
    func want(_ targets: Set<ReferenceTarget>, owner: UUID) {
        let previous = wants[owner] ?? []
        if targets.isEmpty { wants[owner] = nil } else { wants[owner] = targets }

        let identifiers = Set(targets.compactMap { if case .linear(let identifier) = $0 { identifier } else { nil } })
        let previousIdentifiers = Set(previous.compactMap { if case .linear(let identifier) = $0 { identifier } else { nil } })
        if identifiers != previousIdentifiers {
            let linearOwner = linearOwners[owner] ?? UUID()
            linearOwners[owner] = identifiers.isEmpty ? nil : linearOwner
            dependencies.wantLinear(identifiers, linearOwner)
            refreshLinear()
        }
        if targets.isEmpty {
            revisions[owner] = nil
            return
        }

        let now = dependencies.now()
        var files: [String] = []
        for target in targets where !inFlight.contains(target) && nextLookups[target].map({ now >= $0 }) ?? true {
            switch target {
            case .linear: continue
            case .pullRequest: pendingPullRequests.insert(target)
            case .file(let path): files.append(path)
            }
            inFlight.insert(target)
        }
        if !files.isEmpty { checkFiles(files) }
        if !pendingPullRequests.isEmpty, pullRequestTask == nil { schedulePullRequests() }
    }

    func release(owner: UUID) {
        want([], owner: owner)
    }

    /// Returns once every lookup started so far has finished and its
    /// revisions are bumped. For tests.
    func settled() async {
        await lookupsSettled()
        while let flushTask { await flushTask.value }
    }

    /// Returns once every lookup started so far has finished, without
    /// waiting for the revisions it bumps. For tests.
    func lookupsSettled() async {
        while true {
            let running = Array(tasks.values) + [pullRequestTask].compactMap { $0 }
            guard !running.isEmpty else { return }
            for task in running { await task.value }
        }
    }

    // MARK: - Lookups

    private func checkFiles(_ paths: [String]) {
        let id = UUID()
        let fileKinds = dependencies.fileKinds
        tasks[id] = Task { [weak self] in
            let kinds = await fileKinds(paths)
            guard let self else { return }
            let now = dependencies.now()
            for path in paths {
                let target = ReferenceTarget.file(path: path)
                inFlight.remove(target)
                if let isDirectory = kinds[path] {
                    nextLookups[target] = .distantFuture
                    publish(Resolution(title: target.canonicalLabel, icon: .file(isDirectory: isDirectory)), for: target)
                } else {
                    nextLookups[target] = now.addingTimeInterval(Self.retryInterval)
                    publish(nil, for: target)
                }
            }
            tasks[id] = nil
        }
    }

    private func schedulePullRequests() {
        let dependencies = dependencies
        pullRequestTask = Task { [weak self] in
            await dependencies.sleep(Self.pullRequestDebounce)
            guard let self else { return }
            let targets = pendingPullRequests
            pendingPullRequests = []
            var keys: [PullRequestLinkSource.Key: ReferenceTarget] = [:]
            for target in targets {
                if case let .pullRequest(owner, repo, number) = target {
                    keys[PullRequestLinkSource.Key(owner: owner, repo: repo, number: number)] = target
                }
            }
            let answers = await dependencies.pullRequests(Set(keys.keys))
            let now = dependencies.now()
            for (key, target) in keys {
                inFlight.remove(target)
                switch answers[key] {
                case .found(let entry):
                    let lifetime = entry.state == .open ? PullRequestLinkSource.openLifetime : PullRequestLinkSource.settledLifetime
                    nextLookups[target] = now.addingTimeInterval(lifetime)
                    publish(Resolution(
                        title: entry.title,
                        icon: .pullRequest(number: entry.number, state: entry.state, isDraft: entry.isDraft)
                    ), for: target)
                case .missing:
                    nextLookups[target] = now.addingTimeInterval(PullRequestLinkSource.missLifetime)
                    publish(nil, for: target)
                case nil:
                    nextLookups[target] = now.addingTimeInterval(Self.retryInterval)
                }
            }
            pullRequestTask = nil
            if !pendingPullRequests.isEmpty { schedulePullRequests() }
        }
    }

    /// Reads every wanted Linear issue, and re-arms itself to run again when
    /// any of them changes.
    private func refreshLinear() {
        linearTrackingGeneration += 1
        let generation = linearTrackingGeneration
        let identifiers = Set(wants.values.joined().compactMap { if case .linear(let identifier) = $0 { identifier } else { nil } })
        guard !identifiers.isEmpty else { return }
        let issues = withObservationTracking {
            identifiers.map { ($0, dependencies.linearIssue($0)) }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, linearTrackingGeneration == generation else { return }
                refreshLinear()
            }
        }
        for (identifier, issue) in issues {
            let resolution = issue.map {
                Resolution(title: $0.title, icon: .linear($0.stateType, colorHex: $0.stateColor))
            }
            publish(resolution, for: .linear(identifier: identifier))
        }
    }

    private func publish(_ resolution: Resolution?, for target: ReferenceTarget) {
        let box = box(for: target)
        guard box.resolution != resolution else { return }
        let titleChanged = box.resolution?.title != resolution?.title
        box.resolution = resolution
        guard titleChanged else { return }
        for (owner, targets) in wants where targets.contains(target) { pendingOwners.insert(owner) }
        if !pendingOwners.isEmpty, flushTask == nil { scheduleFlush() }
    }

    private func scheduleFlush() {
        let sleep = dependencies.sleep
        flushTask = Task { [weak self] in
            await sleep(Self.coalescing)
            guard let self else { return }
            let owners = pendingOwners
            pendingOwners = []
            for owner in owners where wants[owner] != nil { revisionBox(for: owner).value += 1 }
            flushTask = nil
        }
    }

    // MARK: - Boxes

    private func box(for target: ReferenceTarget) -> Box {
        if let box = boxes[target] { return box }
        let box = Box()
        boxes[target] = box
        return box
    }

    private func revisionBox(for owner: UUID) -> Revision {
        if let box = revisions[owner] { return box }
        let box = Revision()
        revisions[owner] = box
        return box
    }

    nonisolated static func fileKinds(_ paths: [String]) -> [String: Bool] {
        var kinds: [String: Bool] = [:]
        for path in paths {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) { kinds[path] = isDirectory.boolValue }
        }
        return kinds
    }
}
