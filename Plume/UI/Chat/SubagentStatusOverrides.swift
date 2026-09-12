import Foundation
import Observation

/// Statuses the user set by hand on a subagent row, applied after the
/// transcript is derived.
///
/// The escape hatch for a subagent nothing can settle automatically: an agent
/// that dies without writing a terminal line, and whose parent records no
/// outcome, reads as working forever. `SubagentStatusDeriver` cannot be told
/// about it, because status is re-derived from the transcript on every
/// re-parse and anything written onto the model would be overwritten by the
/// next file change. So the override is held here and applied afterwards, the
/// way `TranscriptStore.settlingDormant` corrects a dormant tab's rows.
///
/// Persisted, because the point of dismissing a stuck row is that it stays
/// dismissed. Held in memory it would come back on the next launch, in
/// exactly the state the user just cleared.
///
/// An override is a floor, not a verdict: it only ever replaces `working`, so
/// a subagent that turns out to be alive and goes on to report still says so.
@MainActor
@Observable
final class SubagentStatusOverrides {
    static let shared = SubagentStatusOverrides()

    /// What the user can declare a stuck subagent to be. Neither claims the
    /// agent reported — `done` says the user is satisfied it finished, and
    /// `interrupted` that it stopped without finishing.
    enum Override: String, CaseIterable {
        case done
        case interrupted

        var status: TaskStatus {
            switch self {
            case .done: .done
            case .interrupted: .interrupted
            }
        }
    }

    private static let defaultsKey = "subagentStatusOverrides"

    private let defaults: UserDefaults
    private var overrides: [String: Override]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        self.overrides = stored.compactMapValues(Override.init(rawValue:))
    }

    func override(tabID: UUID, subagentID: String) -> Override? {
        overrides[Self.key(tabID: tabID, subagentID: subagentID)]
    }

    func set(_ override: Override?, tabID: UUID, subagentID: String) {
        let key = Self.key(tabID: tabID, subagentID: subagentID)
        if let override {
            overrides[key] = override
        } else {
            overrides.removeValue(forKey: key)
        }
        save()
    }

    /// Applies each row's override, leaving anything already settled alone.
    func applying(_ subagents: [SubagentTranscript], tabID: UUID) -> [SubagentTranscript] {
        guard !overrides.isEmpty else { return subagents }
        return subagents.map { subagent in
            guard subagent.status == .working,
                  let override = override(tabID: tabID, subagentID: subagent.id)
            else { return subagent }
            var overridden = subagent
            overridden.status = override.status
            return overridden
        }
    }

    /// Drops a closed tab's overrides, alongside the other per-tab stores a
    /// delete clears.
    func forget(tabID: UUID) {
        let prefix = "\(tabID.uuidString)/"
        overrides = overrides.filter { !$0.key.hasPrefix(prefix) }
        save()
    }

    private func save() {
        defaults.set(overrides.mapValues(\.rawValue), forKey: Self.defaultsKey)
    }

    private static func key(tabID: UUID, subagentID: String) -> String {
        "\(tabID.uuidString)/\(subagentID)"
    }
}
