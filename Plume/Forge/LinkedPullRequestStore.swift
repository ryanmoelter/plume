import Foundation
import Observation

/// The pull requests each agent tab's conversation links to, from
/// `TranscriptStore`'s scan, and what GitHub says about each one.
///
/// Details are fetched by owner and name rather than through the tab's
/// repository, since a conversation can link a pull request anywhere. An
/// answer stands for `cacheLifetime`; a failed `gh` call keeps the last one
/// and waits `failureBackoff` before asking again.
@MainActor
@Observable
final class LinkedPullRequestStore {
    static let shared = LinkedPullRequestStore()

    static let cacheLifetime: TimeInterval = 120
    static let failureBackoff: TimeInterval = 30

    nonisolated enum Detail: Equatable, Sendable {
        case pullRequest(MentionCandidate.PullRequestEntry)
        /// GitHub answered and has no such pull request, or `gh` cannot see it.
        case unavailable
    }

    typealias Runner = @Sendable (_ arguments: [String]) async throws -> Data

    private var referencesByTab: [UUID: [PullRequestReference]] = [:]
    private var details: [PullRequestReference: Detail] = [:]
    @ObservationIgnored private var askedAt: [PullRequestReference: Date] = [:]
    @ObservationIgnored private var inFlight: Set<PullRequestReference> = []

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
        if referencesByTab[tabID] != nil { referencesByTab[tabID] = nil }
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
    /// lifetime.
    func refresh(_ references: [PullRequestReference]) {
        let date = now()
        for reference in references where !inFlight.contains(reference) {
            if let asked = askedAt[reference], date.timeIntervalSince(asked) < Self.cacheLifetime { continue }
            inFlight.insert(reference)
            askedAt[reference] = date
            let request = GitHubMentionQuery.pullRequest(
                number: reference.number,
                owner: reference.owner,
                name: reference.repo
            )
            let run = run
            Task {
                let answer: Detail?
                do {
                    let data = try await run(request.arguments)
                    answer = (try? GitHubMentionQuery.decodePullRequest(data)).flatMap { $0.map(Detail.pullRequest) }
                        ?? .unavailable
                } catch let error as ForgeError where !PullRequestLinkSource.missingNumbers(in: error.message).isEmpty {
                    answer = .unavailable
                } catch {
                    answer = nil
                }
                inFlight.remove(reference)
                if let answer {
                    if details[reference] != answer { details[reference] = answer }
                } else {
                    askedAt[reference] = now().addingTimeInterval(Self.failureBackoff - Self.cacheLifetime)
                }
            }
        }
    }
}
