import Foundation

/// A model this UI can switch a running session to.
///
/// A struct rather than an enum because the set of models is open: the CLI
/// accepts any ID its backend knows, and the menu offers an "Other…" field for
/// one this build has never heard of. `id` is what `--model` and the
/// `set_model` control request carry; `label` is what the menu shows.
nonisolated struct AgentModel: Identifiable, Hashable, Sendable {
    let id: String
    let label: String

    init(id: String, label: String) {
        self.id = id
        self.label = label
    }

    /// A model named only by its CLI ID, for one that isn't in `selectable`.
    init(unrecognizedID id: String) {
        self.init(id: id, label: AgentModel.shortenedLabel(for: id))
    }

    var token: String { id }

    // MARK: - Presets

    /// The 1M-context variants, which is what the composer's top-level menu
    /// offers. The bare `opus`/`sonnet`/`fable` aliases resolve to the 256K
    /// models instead — see "Model aliases" in docs/headless-protocol.md — so
    /// these send the explicit `[1m]` IDs.
    static let fable = AgentModel(id: "claude-fable-5-1[1m]", label: "Fable 1M")
    static let opus = AgentModel(id: "claude-opus-5[1m]", label: "Opus 1M")
    static let sonnet = AgentModel(id: "claude-sonnet-5[1m]", label: "Sonnet 1M")

    /// The models the "More" submenu offers.
    ///
    /// There is no live source for this list: the `init` event reports only
    /// the model in use, and its `capabilities` array names protocol features,
    /// not models. So it is maintained by hand from `claude --help`'s aliases
    /// and the IDs the CLI accepted when probed.
    static let more: [AgentModel] = [
        AgentModel(id: "claude-fable-5-1", label: "Fable"),
        AgentModel(id: "claude-opus-5", label: "Opus"),
        AgentModel(id: "claude-sonnet-5", label: "Sonnet"),
        AgentModel(id: "claude-haiku-4-5-20251001", label: "Haiku 4.5")
    ]

    /// Everything the menu can offer, top-level items first.
    static let selectable: [AgentModel] = [fable, opus, sonnet] + more

    // MARK: - Recognition

    /// Maps a transcript- or statusline-reported model string onto a selection.
    ///
    /// An exact ID match wins. Otherwise the `[1m]` suffix is dropped and the
    /// remainder matched against the non-1M presets and their short aliases,
    /// so a reported name this build has no preset for still lands on the
    /// right family. An unfamiliar ID comes back as itself rather than nil, so
    /// the control can display what the session actually runs on.
    static func recognizing(_ reported: String) -> AgentModel? {
        let trimmed = reported.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let exact = selectable.first(where: { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return exact
        }
        if let alias = aliases[trimmed.lowercased()] {
            return alias
        }
        return AgentModel(unrecognizedID: trimmed)
    }

    /// Short names and display strings the CLI or a statusline may report in
    /// place of a full ID.
    private static let aliases: [String: AgentModel] = [
        "fable": .fable, "fable 5": .fable, "fable 5.1": .fable,
        "opus": .opus, "opus 5": .opus,
        "sonnet": .sonnet, "sonnet 5": .sonnet,
        "haiku": AgentModel(id: "claude-haiku-4-5-20251001", label: "Haiku 4.5"),
        "claude-fable-5": .fable
    ]

    /// Trims the `claude-` prefix and a dated suffix so an unknown ID reads as
    /// a name rather than a slug.
    private static func shortenedLabel(for id: String) -> String {
        var name = id
        if name.hasPrefix("claude-") { name.removeFirst("claude-".count) }
        return name
    }
}

/// An effort level this UI can switch a running session to, per
/// `claude --help`.
nonisolated enum AgentEffort: String, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }

    var token: String { rawValue }

    var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "X-High"
        case .max: return "Max"
        }
    }

    /// Maps a transcript- or statusline-reported effort string back to an
    /// option, or nil when it doesn't match one of the five levels.
    static func recognizing(_ reported: String) -> AgentEffort? {
        AgentEffort(rawValue: reported)
    }
}

/// Builds the slash-command lines `ChatComposer`/`TerminalSession.submit`
/// sends to change a running session's model or effort — both take effect
/// for that session only.
///
/// A model ID can now come from the menu's free-text "Other…" field, so
/// `setModel` runs its token through `sanitizedToken(_:)` rather than
/// trusting it.
nonisolated enum ModelEffortCommand {
    enum InvalidTokenError: Error, Equatable {
        case containsWhitespaceOrNewline(String)
    }

    static func setModel(_ model: AgentModel) -> String {
        guard let token = try? sanitizedToken(model.token) else { return "/model" }
        return "/model \(token)"
    }

    static func setEffort(_ effort: AgentEffort) -> String {
        "/effort \(effort.token)"
    }

    /// Rejects a token containing whitespace or a newline, which could
    /// otherwise inject a second line into the terminal after the command.
    static func sanitizedToken(_ token: String) throws -> String {
        guard token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw InvalidTokenError.containsWhitespaceOrNewline(token)
        }
        return token
    }
}
