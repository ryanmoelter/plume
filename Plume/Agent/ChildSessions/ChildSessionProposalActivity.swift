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

    private var starting: Set<Key> = []
    private var failures: [Key: String] = [:]

    func isStarting(_ proposalID: String, in tabID: UUID) -> Bool {
        starting.contains(Key(tabID: tabID, proposalID: proposalID))
    }

    func failure(of proposalID: String, in tabID: UUID) -> String? {
        failures[Key(tabID: tabID, proposalID: proposalID)]
    }

    func begin(_ proposalID: String, in tabID: UUID) {
        let key = Key(tabID: tabID, proposalID: proposalID)
        starting.insert(key)
        failures.removeValue(forKey: key)
    }

    func end(_ proposalID: String, in tabID: UUID, failure: String?) {
        let key = Key(tabID: tabID, proposalID: proposalID)
        starting.remove(key)
        failures[key] = failure
    }

    func fail(_ proposalID: String, in tabID: UUID, reason: String) {
        failures[Key(tabID: tabID, proposalID: proposalID)] = reason
    }

    func clearFailure(of proposalID: String, in tabID: UUID) {
        failures.removeValue(forKey: Key(tabID: tabID, proposalID: proposalID))
    }

    func forget(_ tabID: UUID) {
        starting = starting.filter { $0.tabID != tabID }
        failures = failures.filter { $0.key.tabID != tabID }
    }
}
