import Foundation
import Observation

/// The pull requests each agent tab's conversation links to, from
/// `TranscriptStore`'s scan, and what GitHub says about each one.
///
/// Details are fetched by owner and name rather than through the tab's
/// repository, since a conversation can link a pull request anywhere. An
/// answer stands for `cacheLifetime`; a failed `gh` call keeps the last one
/// and waits longer before asking again with each consecutive failure. A
/// repository `gh` cannot see answers `.unavailable`.
@MainActor
@Observable
final class LinkedPullRequestStore {
    static let shared = LinkedPullRequestStore()

    static let cacheLifetime: TimeInterval = 120
    static let failureBackoff: TimeInterval = 30
    static let maxFailureBackoff: TimeInterval = 600
    static let maxConcurrentRepositories = 2

    nonisolated enum Detail: Equatable, Sendable {
        case pullRequest(MentionCandidate.PullRequestEntry)
        /// GitHub answered and has no such pull request, or `gh` cannot see it.
        case unavailable
    }

    typealias Runner = @Sendable (_ arguments: [String]) async throws -> Data

    private var referencesByTab: [UUID: [PullRequestReference]] = [:]
    /// Pinned references a task's sidebar row shows, kept alive when no tab
    /// names them.
    @ObservationIgnored private var retainedByTask: [UUID: [PullRequestReference]] = [:]
    private var details: [PullRequestReference: Detail] = [:]
    @ObservationIgnored private var askedAt: [PullRequestReference: Date] = [:]
    @ObservationIgnored private var inFlight: Set<PullRequestReference> = []
    @ObservationIgnored private var failures: [PullRequestReference: Int] = [:]
    @ObservationIgnored private var pending: [(RepositoryKey, [Int])] = []
    @ObservationIgnored private var activeWorkers = 0

    @ObservationIgnored private let run: Runner
    @ObservationIgnored private let now: () -> Date

    init(
        run: @escaping Runner = { try await GHCommand.run(arguments: $0, in: NSHomeDirectory(), timeout: .seconds(10)) },
        now: @escaping () -> Date = Date.init
    ) {
        self.run = run
        self.now = now
    }

    func replace(tabID: UUID, references: [PullRequestReference]) {
        if (referencesByTab[tabID] ?? []) != references {
            referencesByTab[tabID] = references.isEmpty ? nil : references
        }
    }

    func forget(tabID: UUID) {
        guard referencesByTab[tabID] != nil else { return }
        referencesByTab[tabID] = nil
        prune()
    }

    /// Holds a task's pinned references and fetches any that are due.
    func retain(_ references: [PullRequestReference], forTask taskID: UUID) {
        let before = retainedByTask[taskID] ?? []
        retainedByTask[taskID] = references.isEmpty ? nil : references
        if !Set(before).isSubset(of: Set(references)) { prune() }
        refresh(references)
    }

    func forget(taskID: UUID) {
        guard retainedByTask.removeValue(forKey: taskID) != nil else { return }
        prune()
    }

    private func prune() {
        let live = Set(referencesByTab.values.joined()).union(retainedByTask.values.joined())
        for reference in details.keys where !live.contains(reference) { details[reference] = nil }
        askedAt = askedAt.filter { live.contains($0.key) || inFlight.contains($0.key) }
        failures = failures.filter { live.contains($0.key) }
    }

    /// Every pull request the task's agent tabs link to, in tab order.
    func references(for task: WorkTask) -> [PullRequestReference] {
        var result: [PullRequestReference] = []
        for tab in task.orderedTabs where tab.kind == .agent {
            for reference in referencesByTab[tab.id] ?? [] where !result.contains(reference) {
                result.append(reference)
            }
        }
        return result
    }

    func detail(for reference: PullRequestReference) -> Detail? {
        details[reference]
    }

    /// Fetches every reference with no answer yet, or one older than its
    /// lifetime. References share one request per repository, and only
    /// `maxConcurrentRepositories` requests run at once.
    func refresh(_ references: [PullRequestReference]) {
        let date = now()
        var due: [RepositoryKey: [Int]] = [:]
        for reference in references where !inFlight.contains(reference) {
            if let asked = askedAt[reference], date.timeIntervalSince(asked) < Self.cacheLifetime { continue }
            inFlight.insert(reference)
            askedAt[reference] = date
            due[RepositoryKey(owner: reference.owner, repo: reference.repo), default: []].append(reference.number)
        }
        for key in due.keys.sorted(by: { ($0.owner, $0.repo) < ($1.owner, $1.repo) }) {
            let numbers = due[key]!.sorted()
            for start in stride(from: 0, to: numbers.count, by: PullRequestLinkSource.batchLimit) {
                let slice = Array(numbers[start..<min(start + PullRequestLinkSource.batchLimit, numbers.count)])
                pending.append((key, slice))
            }
        }
        while activeWorkers < Self.maxConcurrentRepositories, !pending.isEmpty {
            activeWorkers += 1
            Task {
                while !pending.isEmpty {
                    let (key, numbers) = pending.removeFirst()
                    await fetch(key, numbers: numbers)
                }
                activeWorkers -= 1
            }
        }
    }

    struct RepositoryKey: Hashable, Sendable {
        let owner: String
        let repo: String
    }

    /// How a failed `gh` call reads.
    nonisolated enum Failure: Equatable, Sendable {
        case repositoryMissing
        case missingPullRequests(Set<Int>)
        case transient
    }

    nonisolated static func classify(_ error: Error) -> Failure {
        guard let message = (error as? ForgeError)?.message else { return .transient }
        if PullRequestLinkSource.namesMissingRepository(message) { return .repositoryMissing }
        let missing = PullRequestLinkSource.missingNumbers(in: message)
        return missing.isEmpty ? .transient : .missingPullRequests(missing)
    }

    /// Doubles with each consecutive failure, up to `maxFailureBackoff`.
    nonisolated static func backoff(afterFailures count: Int) -> TimeInterval {
        guard count > 0 else { return 0 }
        return min(failureBackoff * pow(2, Double(min(count, 16) - 1)), maxFailureBackoff)
    }

    private func fetch(_ key: RepositoryKey, numbers: [Int]) async {
        var remaining = numbers
        var answers: [Int: Detail] = [:]
        while !remaining.isEmpty {
            let request = GitHubMentionQuery.pullRequests(numbers: remaining, owner: key.owner, name: key.repo)
            do {
                let data = try await run(request.arguments)
                guard let entries = try? GitHubMentionQuery.decodePullRequests(data, numbers: remaining) else { break }
                for number in remaining { answers[number] = entries[number].map(Detail.pullRequest) ?? .unavailable }
                break
            } catch {
                switch Self.classify(error) {
                case .repositoryMissing:
                    for number in remaining { answers[number] = .unavailable }
                    remaining = []
                case .missingPullRequests(let missing) where !missing.isDisjoint(with: remaining):
                    for number in remaining where missing.contains(number) { answers[number] = .unavailable }
                    remaining.removeAll { missing.contains($0) }
                case .missingPullRequests, .transient:
                    remaining = []
                }
            }
        }
        for number in numbers {
            let reference = PullRequestReference(owner: key.owner, repo: key.repo, number: number)
            inFlight.remove(reference)
            if let answer = answers[number] {
                failures[reference] = nil
                if details[reference] != answer { details[reference] = answer }
            } else {
                let count = (failures[reference] ?? 0) + 1
                failures[reference] = count
                askedAt[reference] = now().addingTimeInterval(Self.backoff(afterFailures: count) - Self.cacheLifetime)
            }
        }
    }
}
