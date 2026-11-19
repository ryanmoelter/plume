import Foundation
import Observation

/// What a proposal card shows besides its stored state: a start under way,
/// and why the user's last start failed. In memory only.
@MainActor
@Observable
final class ChildSessionProposalActivity {
    static let shared = ChildSessionProposalActivity()

    private struct Key: Hashable {
        let tabID: UUID
        let proposalID: String
    }

    struct Failure: Equatable {
        let text: String
        /// What the card read when the start failed.
        let state: ChildSessionProposalCardState
    }

    private var starting: Set<Key> = []
    private var failures: [Key: Failure] = [:]

    func isStarting(_ proposalID: String, in tabID: UUID) -> Bool {
        starting.contains(Key(tabID: tabID, proposalID: proposalID))
    }

    /// The failure recorded while the card read `state`, only while it
    /// still does.
    func failure(of proposalID: String, in tabID: UUID, showing state: ChildSessionProposalCardState) -> String? {
        failures[Key(tabID: tabID, proposalID: proposalID)].flatMap { $0.state == state ? $0.text : nil }
    }

    func begin(_ proposalID: String, in tabID: UUID) {
        let key = Key(tabID: tabID, proposalID: proposalID)
        starting.insert(key)
        failures.removeValue(forKey: key)
    }

    func end(_ proposalID: String, in tabID: UUID, failure: Failure?) {
        let key = Key(tabID: tabID, proposalID: proposalID)
        starting.remove(key)
        failures[key] = failure
    }

    func fail(_ proposalID: String, in tabID: UUID, _ failure: Failure) {
        failures[Key(tabID: tabID, proposalID: proposalID)] = failure
    }

    func clearFailure(of proposalID: String, in tabID: UUID) {
        failures.removeValue(forKey: Key(tabID: tabID, proposalID: proposalID))
    }

    func forget(_ tabID: UUID) {
        starting = starting.filter { $0.tabID != tabID }
        failures = failures.filter { $0.key.tabID != tabID }
    }
}
