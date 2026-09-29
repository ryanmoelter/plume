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

    /// A top-level menu entry: sends the CLI's own alias and shows the bare
    /// family name, letting the CLI resolve the current version.
    private init(alias: String, label: String) {
        self.init(id: alias, label: label)
    }

    var token: String { id }

    /// The context window this model implies before any turn has reported
    /// the real one. A bare ID whose `[1m]` sibling is also offered means
    /// 200K; every other preset means 1M. Nil outside `selectable`: a model
    /// this build has never heard of assumes nothing.
    var nominalContextWindow: Int? {
        guard AgentModel.selectable.contains(where: { $0.id == id }) else { return nil }
        return hasOneMillionVariant ? 200_000 : 1_000_000
    }

    // MARK: - Presets

    /// The composer's top-level menu. Each sends the CLI's own alias — the
    /// 1M form where one exists — and shows the bare family name; the CLI
    /// picks the current version, so Plume tracks no version for this path.
    /// Fable has no `[1m]` form, so it sends the plain alias. See "Model
    /// aliases" in docs/headless-protocol.md.
    static let fable = AgentModel(alias: "fable", label: "Fable")
    static let opus = AgentModel(alias: "opus[1m]", label: "Opus")
    static let sonnet = AgentModel(alias: "sonnet[1m]", label: "Sonnet")
    static let haiku = AgentModel(alias: "haiku[1m]", label: "Haiku")

    /// Explicit versioned IDs the "More" submenu offers. The current Opus,
    /// Sonnet and Fable models are 1M at their bare ID, with no 200K form, so
    /// they carry no suffix. Haiku 4.5 is 200K bare and 1M only with `[1m]`.
    static let opus5dot5 = AgentModel(id: "claude-opus-5-5")
    static let opus5 = AgentModel(id: "claude-opus-5")
    static let sonnet5 = AgentModel(id: "claude-sonnet-5")
    static let fable5dot1 = AgentModel(id: "claude-fable-5-1")
    static let haiku4dot5 = AgentModel(id: "claude-haiku-4-5-20251001[1m]")
    static let haiku4dot5At200K = AgentModel(id: "claude-haiku-4-5-20251001", contextSuffix: "200K")

    /// The models the "More" submenu offers.
    ///
    /// There is no live source for this list: the `init` event reports only
    /// the model in use, and its `capabilities` array names protocol features,
    /// not models. So it is maintained by hand from `claude --help`'s aliases
    /// and the IDs the CLI accepted when probed.
    static let more: [AgentModel] = [
        opus5dot5,
        opus5,
        sonnet5,
        fable5dot1,
        haiku4dot5, haiku4dot5At200K
    ]

    /// Everything the menu can offer, top-level items first.
    static let selectable: [AgentModel] = [fable, opus, sonnet, haiku] + more

    static let codexSelectable: [AgentModel] = [
        AgentModel(id: "gpt-6-astra", label: "Astra"),
        AgentModel(id: "gpt-5.6-sol", label: "Sol"),
        AgentModel(id: "gpt-5.6-terra", label: "Terra"),
        AgentModel(id: "gpt-5.6-luna", label: "Luna"),
        AgentModel(id: "gpt-5.5", label: "GPT-5.5"),
        AgentModel(id: "gpt-5.4-mini", label: "GPT-5.4 mini")
    ]

    // MARK: - Recognition

    /// Maps a transcript- or statusline-reported model string onto a
    /// selection, so the composer can show the resolved version once a
    /// session reports it rather than the bare alias it was launched with.
    ///
    /// An exact ID match wins. Otherwise a short alias or a bare ID matches a
    /// versioned "More" entry, with a `[1m]` suffix promoting the result to
    /// that model's 1M variant where it has a distinct one. An unfamiliar ID
    /// comes back as itself rather than nil, so the control can display what
    /// the session actually runs on.
    static func recognizing(_ reported: String) -> AgentModel? {
        let trimmed = reported.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let exact = preset(withID: trimmed) {
            return exact
        }
        let isOneMillion = trimmed.hasSuffix(contextSuffix)
        let bare = String(trimmed.dropLast(isOneMillion ? contextSuffix.count : 0))
        if let base = aliases[bare.lowercased()] ?? preset(withID: bare) {
            return isOneMillion ? base.oneMillionVariant : base
        }
        return AgentModel(unrecognizedID: trimmed)
    }

    static func recognizing(_ reported: String, provider: AgentProviderKind) -> AgentModel? {
        let trimmed = reported.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if provider == .codex {
            return codexSelectable.first { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }
                ?? AgentModel(unrecognizedID: trimmed)
        }
        return recognizing(trimmed)
    }

    /// Short names and display strings the CLI or a statusline may report in
    /// place of a full ID, each mapped to the model a bare `--model` of that
    /// name runs on. A `[1m]` suffix on the reported string promotes the
    /// result to its 1M variant, which only Haiku has.
    private static let aliases: [String: AgentModel] = [
        "fable": .fable5dot1, "fable 5": .fable5dot1, "fable 5.1": .fable5dot1, "claude-fable-5": .fable5dot1,
        "opus": .opus5dot5, "opus 5.5": .opus5dot5,
        "opus 5": .opus5,
        "sonnet": .sonnet5, "sonnet 5": .sonnet5,
        "haiku": .haiku4dot5At200K, "haiku 4.5": .haiku4dot5At200K
    ]

    private static let contextSuffix = "[1m]"

    private static func preset(withID id: String) -> AgentModel? {
        selectable.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    private var hasOneMillionVariant: Bool {
        oneMillionVariant != self
    }

    /// The 1M-context sibling of this model, or the model itself when its
    /// bare ID is already 1M.
    private var oneMillionVariant: AgentModel {
        let suffixed = id + AgentModel.contextSuffix
        return AgentModel.selectable.first { $0.id == suffixed } ?? self
    }
}

/// A reasoning effort value advertised by an agent.
///
/// Claude currently uses the six values in `allCases`, while Codex's schema
/// deliberately leaves the vocabulary open and advertises values per model.
/// Keep the familiar static presets for Claude and let a live provider carry
/// a value this build has never seen without dropping it or substituting a
/// different effort.
nonisolated struct AgentEffort: RawRepresentable, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let low = AgentEffort(rawValue: "low")
    static let medium = AgentEffort(rawValue: "medium")
    static let high = AgentEffort(rawValue: "high")
    static let xhigh = AgentEffort(rawValue: "xhigh")
    static let max = AgentEffort(rawValue: "max")
    static let ultra = AgentEffort(rawValue: "ultra")

    static let allCases: [AgentEffort] = [.low, .medium, .high, .xhigh, .max, .ultra]

    var id: String { rawValue }

    var token: String { rawValue }

    var label: String {
        switch rawValue {
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "X-High"
        case "max": return "Max"
        case "ultra": return "Ultra"
        default: return rawValue
        }
    }

    /// Raw-string Codable keeps persistence compatible with a raw enum.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Maps a transcript- or statusline-reported effort string back to an
    /// option. Codex may report a value outside Claude's known presets, so an
    /// unfamiliar non-empty value remains selectable instead of becoming nil.
    static func recognizing(_ reported: String) -> AgentEffort? {
        let value = reported.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return AgentEffort(rawValue: value)
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
