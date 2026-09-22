import Foundation

/// Parses a model ID into a display label, so an ID this build has never
/// hardcoded — one only the CLI reports, in a stream event or `system/init`
/// — still gets a readable name instead of falling back to the raw string
/// everywhere it's shown.
nonisolated enum ModelDisplayName {
    /// `claude-opus-5-5[1m]` → `"Opus 5.5"`, `claude-haiku-4-5-20251001` →
    /// `"Haiku 4.5"`. Returns `id` unchanged when it doesn't fit the pattern:
    /// a family word followed by digit-only version components, optionally
    /// a trailing date stamp, optionally a bracketed suffix.
    static func parse(_ id: String) -> String {
        var body = id
        if let bracketStart = body.firstIndex(of: "[") {
            body = String(body[..<bracketStart])
        }

        var parts = body.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return id }

        if parts.first == "claude" { parts.removeFirst() }
        guard let family = parts.first, family.allSatisfy(\.isLetter) else { return id }
        parts.removeFirst()

        // A trailing run of 8+ digits is a date stamp (YYYYMMDD), not a version.
        if let last = parts.last, last.count >= 8, last.allSatisfy(\.isNumber) {
            parts.removeLast()
        }

        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return id }

        let familyLabel = family.prefix(1).uppercased() + family.dropFirst().lowercased()
        let versionLabel = parts.joined(separator: ".")
        return versionLabel.isEmpty ? familyLabel : "\(familyLabel) \(versionLabel)"
    }
}

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
    /// The label is parsed from the ID rather than hardcoded, so an ID this
    /// build has never seen still gets a readable name.
    init(unrecognizedID id: String) {
        self.init(id: id, label: ModelDisplayName.parse(id))
    }

    /// A preset whose label is derived from its own ID, with an optional
    /// context-window suffix appended.
    private init(id: String, contextSuffix: String? = nil) {
        let parsed = ModelDisplayName.parse(id)
        self.init(id: id, label: contextSuffix.map { "\(parsed) \($0)" } ?? parsed)
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
    static let fable = AgentModel(id: "claude-fable-5-1")
    static let opus = AgentModel(id: "claude-opus-5-5[1m]")
    static let sonnet = AgentModel(id: "claude-sonnet-5[1m]")
    static let haiku = AgentModel(id: "claude-haiku-4-5-20251001[1m]")

    /// The 200K sibling of each model the "More" submenu offers, named so the
    /// alias map can reference them individually. `opus5At200K` is the prior
    /// generation's Opus, kept reachable after Opus 5.5 took the top-level
    /// slot.
    static let opus5dot5At200K = AgentModel(id: "claude-opus-5-5", contextSuffix: "200K")
    static let opus5At200K = AgentModel(id: "claude-opus-5", contextSuffix: "200K")
    static let sonnetAt200K = AgentModel(id: "claude-sonnet-5", contextSuffix: "200K")
    static let haikuAt200K = AgentModel(id: "claude-haiku-4-5-20251001", contextSuffix: "200K")

    /// The models the "More" submenu offers.
    ///
    /// There is no live source for this list: the `init` event reports only
    /// the model in use, and its `capabilities` array names protocol features,
    /// not models. So it is maintained by hand from `claude --help`'s aliases
    /// and the IDs the CLI accepted when probed.
    static let more: [AgentModel] = [opus5dot5At200K, opus5At200K, sonnetAt200K, haikuAt200K]

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
        "opus": .opus5dot5At200K, "opus 5.5": .opus5dot5At200K, "claude-opus-5-5": .opus5dot5At200K,
        "opus 5": .opus5At200K,
        "sonnet": .sonnetAt200K, "sonnet 5": .sonnetAt200K,
        "haiku": .haikuAt200K, "haiku 4.5": .haikuAt200K
    ]

    private static let contextSuffix = "[1m]"

    /// The 1M-context sibling of this model, or the model itself when it has
    /// no 1M form — Fable, whose suffixed ID the CLI reports back plain.
    private var oneMillionVariant: AgentModel {
        let suffixed = id + AgentModel.contextSuffix
        return AgentModel.selectable.first { $0.id == suffixed } ?? self
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
