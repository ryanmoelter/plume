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

    /// The context window this model implies before any turn has reported
    /// the real one — `more`'s bare IDs report 200,000, everything else in
    /// `selectable` is the 1M variant. Nil
    /// outside `selectable`: a model this build has never heard of assumes
    /// nothing.
    var nominalContextWindow: Int? {
        if AgentModel.more.contains(where: { $0.id == id }) { return 200_000 }
        if AgentModel.selectable.contains(where: { $0.id == id }) { return 1_000_000 }
        return nil
    }

    // MARK: - Presets

    /// The composer's top-level menu. The bare `opus`/`sonnet`/`fable`/`haiku`
    /// aliases resolve to the 200K models, so these send the explicit `[1m]`
    /// IDs. Fable has no 1M variant — passing the suffix gets
    /// `claude-fable-5-1` back — so it sends the plain ID. An unspecified
    /// context window means 1M, so only the 200K variants carry a suffix; see
    /// "Model aliases" in docs/headless-protocol.md.
    static let fable = AgentModel(id: "claude-fable-5-1", label: "Fable")
    static let opus = AgentModel(id: "claude-opus-5[1m]", label: "Opus")
    static let sonnet = AgentModel(id: "claude-sonnet-5[1m]", label: "Sonnet")
    static let haiku = AgentModel(id: "claude-haiku-4-5-20251001[1m]", label: "Haiku 4.5")

    /// The models the "More" submenu offers.
    ///
    /// There is no live source for this list: the `init` event reports only
    /// the model in use, and its `capabilities` array names protocol features,
    /// not models. So it is maintained by hand from `claude --help`'s aliases
    /// and the IDs the CLI accepted when probed.
    static let more: [AgentModel] = [
        AgentModel(id: "claude-opus-5", label: "Opus 200K"),
        AgentModel(id: "claude-sonnet-5", label: "Sonnet 200K"),
        AgentModel(id: "claude-haiku-4-5-20251001", label: "Haiku 4.5 200K")
    ]

    /// Everything the menu can offer, top-level items first.
    static let selectable: [AgentModel] = [fable, opus, sonnet, haiku] + more

    // MARK: - Recognition

    /// Maps a transcript- or statusline-reported model string onto a selection.
    ///
    /// An exact ID match wins. Otherwise a short alias matches, with a `[1m]`
    /// suffix promoting the result to that model's 1M variant. An unfamiliar
    /// ID comes back as itself rather than nil, so the control can display
    /// what the session actually runs on.
    static func recognizing(_ reported: String) -> AgentModel? {
        let trimmed = reported.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let exact = selectable.first(where: { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return exact
        }
        let isOneMillion = trimmed.hasSuffix(contextSuffix)
        let bare = String(trimmed.dropLast(isOneMillion ? contextSuffix.count : 0))
        if let alias = aliases[bare.lowercased()] {
            return isOneMillion ? alias.oneMillionVariant : alias
        }
        return AgentModel(unrecognizedID: trimmed)
    }

    /// Short names and display strings the CLI or a statusline may report in
    /// place of a full ID, each mapped to its 200K form. A `[1m]` suffix on
    /// the reported string promotes the result to the 1M variant.
    private static let aliases: [String: AgentModel] = [
        "fable": .fable, "fable 5": .fable, "fable 5.1": .fable, "claude-fable-5": .fable,
        "opus": more[0], "opus 5": more[0],
        "sonnet": more[1], "sonnet 5": more[1],
        "haiku": more[2], "haiku 4.5": more[2]
    ]

    private static let contextSuffix = "[1m]"

    /// The 1M-context sibling of this model, or the model itself when it has
    /// no 1M form — Fable, whose suffixed ID the CLI reports back plain.
    private var oneMillionVariant: AgentModel {
        let suffixed = id + AgentModel.contextSuffix
        return AgentModel.selectable.first { $0.id == suffixed } ?? self
    }

    /// Trims the `claude-` prefix so an unknown ID reads as a name rather
    /// than a slug. The rest is kept verbatim — a wrong-but-pretty label
    /// would be worse than an ugly true one.
    private static func shortenedLabel(for id: String) -> String {
        id.hasPrefix("claude-") ? String(id.dropFirst("claude-".count)) : id
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
/// A model ID can come from the menu's free-text "Other…" field, which
/// rejects a whitespace-bearing one through `sanitizedToken(_:)` before it
/// ever becomes an `AgentModel`. `setModel` re-checks anyway, since a line
/// pasted into a terminal is the one place an injected newline would matter.
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
