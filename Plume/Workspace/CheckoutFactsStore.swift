import Foundation
import Observation

/// Which project each directory belongs to, resolved once and kept.
///
/// A checkout cannot change which repository it is part of without becoming a
/// different directory, so unlike `GitStateStore` this needs neither a poll
/// nor a watcher — one `rev-parse` per directory, cached for the run.
@MainActor
@Observable
final class CheckoutFactsStore {
    static let shared = CheckoutFactsStore()

    private var facts: [String: CheckoutFacts] = [:]
    /// Directories whose lookup found no repository, so a row that asks
    /// repeatedly does not spawn a `git` process every redraw.
    private var missing: Set<String> = []
    @ObservationIgnored private var inFlight: Set<String> = []

    var resolve: @Sendable (String) async -> CheckoutFacts? = { directory in
        await GitService.shared.checkoutFacts(containing: directory)
    }

    init() {}

    /// Reads cache only, so it is safe from a view's `body`. Writing there —
    /// even to start a lookup — makes the render invalidate itself.
    func facts(for directory: String?) -> CheckoutFacts? {
        guard let directory else { return nil }
        return facts[directory]
    }

    /// Call from a lifecycle event, never from `body`.
    func load(_ directory: String) {
        guard !directory.isEmpty, facts[directory] == nil, !missing.contains(directory) else { return }
        guard inFlight.insert(directory).inserted else { return }
        Task {
            let resolved = await resolve(directory)
            inFlight.remove(directory)
            if let resolved {
                facts[directory] = resolved
            } else {
                missing.insert(directory)
            }
        }
    }

    #if DEBUG
    /// Seeds a fake answer so a fixture row renders as a worktree without one
    /// existing on disk. Cached like a real answer, so nothing looks it up.
    func seedFixture(directory: String, facts: CheckoutFacts) {
        self.facts[directory] = facts
    }
    #endif

    /// Drops every cached answer. For tests.
    func reset() {
        facts.removeAll()
        missing.removeAll()
        inFlight.removeAll()
    }
}
