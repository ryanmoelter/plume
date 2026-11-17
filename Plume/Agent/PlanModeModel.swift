import Foundation

/// The model a Claude Code session plans on, when that differs from the one
/// it runs on.
///
/// The CLI swaps some aliases in plan mode — `haiku` plans on Sonnet,
/// `opusplan` on Opus — while `init` reports only the alias's normal model.
/// A reply's `message.model` is the evidence, so an observed plan model
/// overrides the prediction from the alias. "Model aliases" in
/// `docs/headless-protocol.md` has the measurements.
nonisolated enum PlanModeModel {
    struct Observation: Equatable, Sendable {
        /// A different run model makes the observation stale.
        let runModelID: String
        let planModel: AgentModel
    }

    /// Only the bare aliases swap; a full ID such as `claude-haiku-5-5`
    /// plans on itself.
    static func predicted(forRequestedID id: String?) -> AgentModel? {
        switch id?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "haiku": .sonnet
        case "opusplan": .opus
        default: nil
        }
    }

    /// Nil for a placeholder such as `<synthetic>`, which the CLI stamps on
    /// rows no model wrote.
    static func observation(replyModel reported: String?, runs: AgentModel) -> Observation? {
        guard let reported, !reported.isEmpty, !reported.hasPrefix("<"),
              let plans = AgentModel.recognizing(reported)
        else { return nil }
        return Observation(runModelID: runs.id, planModel: plans)
    }

    /// Nil when plan mode runs `runs` itself.
    static func differing(runs: AgentModel, requestedID: String?, observed: Observation?) -> AgentModel? {
        let current = observed.flatMap { $0.runModelID == runs.id ? $0.planModel : nil }
        guard let plans = current ?? predicted(forRequestedID: requestedID) else { return nil }
        return isSameModel(plans, runs) ? nil : plans
    }

    /// A bare family label ("Sonnet") matches any version of that family,
    /// since an alias names no version.
    static func isSameModel(_ lhs: AgentModel, _ rhs: AgentModel) -> Bool {
        if lhs.id.caseInsensitiveCompare(rhs.id) == .orderedSame { return true }
        let left = lhs.label.lowercased().split(separator: " ", maxSplits: 1)
        let right = rhs.label.lowercased().split(separator: " ", maxSplits: 1)
        guard left.first == right.first else { return false }
        guard left.count > 1, right.count > 1 else { return true }
        return left[1] == right[1]
    }
}
