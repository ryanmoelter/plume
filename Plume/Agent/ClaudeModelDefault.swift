import Foundation

/// The model a new Claude tab starts on. `.followClaudeCode` passes no
/// `--model`, so the CLI resolves its own default from `~/.claude/settings.json`;
/// `.model` pins one.
nonisolated enum ClaudeModelDefault: Hashable, Identifiable, Sendable {
    case followClaudeCode
    case model(AgentModel)

    private static let followClaudeCodeRaw = "followClaudeCode"

    /// Any other raw value is a model ID, recognized the same way a tab's
    /// stored model is, so an ID this build has never heard of still pins.
    init(rawValue: String) {
        if rawValue == Self.followClaudeCodeRaw {
            self = .followClaudeCode
        } else if let model = AgentModel.recognizing(rawValue) {
            self = .model(model)
        } else {
            self = .followClaudeCode
        }
    }

    var rawValue: String {
        switch self {
        case .followClaudeCode: return Self.followClaudeCodeRaw
        case .model(let model): return model.id
        }
    }

    var id: String { rawValue }

    var pinnedModel: AgentModel? {
        switch self {
        case .followClaudeCode: return nil
        case .model(let model): return model
        }
    }

    /// Follow first, then every Claude preset. A stored model outside the
    /// presets is kept at the end so the picker still shows the selection.
    static func offered(including current: ClaudeModelDefault) -> [ClaudeModelDefault] {
        let options = [.followClaudeCode] + AgentModel.selectable.map(ClaudeModelDefault.model)
        return options.contains(current) ? options : options + [current]
    }
}
