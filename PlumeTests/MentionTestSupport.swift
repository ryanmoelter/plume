import Foundation
@testable import Plume

/// Mention sources a test answers by hand. A source with `holds` set parks
/// every call until the test releases it, so a test can see the controller
/// mid-load and hand back results in any order.
@MainActor
final class FakeMentionSources: MentionSources {
    /// Answers once; a second release, from `releaseAll`, does nothing.
    final class Call {
        let query: MentionQuery
        private var continuation: CheckedContinuation<[RankedMention], Never>?

        init(query: MentionQuery, continuation: CheckedContinuation<[RankedMention], Never>) {
            self.query = query
            self.continuation = continuation
        }

        func release(_ results: [RankedMention]) {
            continuation?.resume(returning: results)
            continuation = nil
        }
    }

    var holdsFiles = false
    var holdsPullRequests = false
    var fileAnswer: (MentionQuery) -> [RankedMention] = { _ in [] }
    var pullRequestAnswer: (MentionQuery) -> [RankedMention] = { _ in [] }
    var linearAnswer: (String) -> [RankedMention] = { _ in [] }

    private(set) var fileQueries: [String] = []
    private(set) var pullRequestQueries: [String] = []
    /// The queries asked with `includingLookups`.
    private(set) var pullRequestLookups: [String] = []
    private(set) var linearSearches: [String] = []
    private(set) var heldFiles: [Call] = []
    private(set) var heldPullRequests: [Call] = []
    /// Called whenever a call parks, so a test can wait for it.
    var didHold: (() -> Void)?

    func files(for query: MentionQuery, in directory: String?) async -> [RankedMention] {
        fileQueries.append(query.text)
        guard holdsFiles else { return fileAnswer(query) }
        return await withCheckedContinuation { continuation in
            heldFiles.append(Call(query: query, continuation: continuation))
            didHold?()
        }
    }

    func pullRequests(for query: MentionQuery, in directory: String?, includingLookups: Bool) async -> [RankedMention] {
        pullRequestQueries.append(query.text)
        if includingLookups { pullRequestLookups.append(query.text) }
        guard holdsPullRequests else { return pullRequestAnswer(query) }
        return await withCheckedContinuation { continuation in
            heldPullRequests.append(Call(query: query, continuation: continuation))
            didHold?()
        }
    }

    func cachedLinearIssues(matching text: String) async -> [RankedMention] {
        linearAnswer(text)
    }

    func searchLinear(_ text: String) async {
        linearSearches.append(text)
    }

    /// Answers every parked call with nothing, so no continuation leaks.
    func releaseAll() {
        let calls = heldFiles + heldPullRequests
        heldFiles = []
        heldPullRequests = []
        for call in calls { call.release([]) }
    }

    func waitForHeldFiles(_ count: Int) async {
        await waitUntil { self.heldFiles.count >= count }
    }

    func waitForHeldPullRequests(_ count: Int) async {
        await waitUntil { self.heldPullRequests.count >= count }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        while !condition() {
            await withCheckedContinuation { continuation in
                didHold = {
                    self.didHold = nil
                    continuation.resume()
                }
            }
        }
    }
}

/// Records the debounce a source waited out, and returns at once.
@MainActor
final class RecordingSleep {
    private(set) var durations: [Duration] = []

    var sleep: MentionAutocompleteController.Sleep {
        { [self] duration in
            durations.append(duration)
            try Task.checkCancellation()
        }
    }
}

enum MentionFixtures {
    static func issue(_ identifier: String, _ title: String) -> MentionCandidate.LinearIssue {
        MentionCandidate.LinearIssue(
            identifier: identifier,
            title: title,
            url: "https://linear.app/acme/issue/\(identifier.lowercased())",
            stateType: .started,
            stateColor: "#f2c94c",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    static func file(_ path: String, isDirectory: Bool = false) -> MentionCandidate.FileEntry {
        MentionCandidate.FileEntry(path: path, isDirectory: isDirectory)
    }

    static func pull(_ number: Int, _ title: String) -> MentionCandidate.PullRequestEntry {
        MentionCandidate.PullRequestEntry(
            number: number,
            title: title,
            url: "https://github.com/acme/app/pull/\(number)",
            state: .open,
            isDraft: false,
            updatedAt: nil
        )
    }

    static func ranked(_ candidate: MentionCandidate, _ quality: MentionMatchQuality = .prefix) -> RankedMention {
        RankedMention(candidate: candidate, quality: quality)
    }
}

extension MentionAutocompleteController {
    /// Returns once the current query has every source's answer, or at once
    /// if it already has.
    func settled() async {
        while query != nil, isLoading {
            await withCheckedContinuation { continuation in
                didSettle = {
                    self.didSettle = nil
                    continuation.resume()
                }
            }
        }
    }

    func discarded() async {
        await withCheckedContinuation { continuation in
            didDiscard = {
                self.didDiscard = nil
                continuation.resume()
            }
        }
    }
}
