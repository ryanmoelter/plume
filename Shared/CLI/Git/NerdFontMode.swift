import Foundation

/// Whether `wt` prints Nerd Font icons. One setting for every repository,
/// stored as its raw value under `userDefaultsKey`. Inside the retired
/// per-project field, a `Bool` from before the automatic mode still decodes,
/// as `on` or `off`.
nonisolated enum NerdFontMode: String, Codable, CaseIterable, Sendable {
    /// On inside a Plume tab whose terminal uses the bundled font, which has
    /// the icons; off anywhere else.
    case automatic
    case on
    case off

    /// Set to `1` in every tab when the user's ghostty config names its own
    /// `font-family`, which may lack the icons.
    static let customTerminalFontEnvironmentKey = "PLUME_CUSTOM_TERMINAL_FONT"

    /// The UserDefaults key, in the app's domain, holding the mode.
    static let userDefaultsKey = "nerdFontMode"

    /// The stored mode, else the Projects defaults row's from before the
    /// setting was global, else automatic. A stored value that names no mode
    /// reads as automatic.
    static func global(stored: String?, legacyDefault: NerdFontMode?) -> NerdFontMode {
        guard let stored else { return legacyDefault ?? .automatic }
        return NerdFontMode(rawValue: stored) ?? .automatic
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let legacy = try? container.decode(Bool.self) {
            self = legacy ? .on : .off
            return
        }
        // An unknown value reads as automatic rather than failing, which
        // would discard every project's settings with it.
        self = NerdFontMode(rawValue: try container.decode(String.self)) ?? .automatic
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Whether to use the icons. Nil means unset, which is `automatic`.
    static func usesNerdFont(_ mode: NerdFontMode?, environment: [String: String]) -> Bool {
        switch mode ?? .automatic {
        case .on: true
        case .off: false
        case .automatic:
            !(environment[CLISocket.tabIDEnvironmentKey] ?? "").isEmpty
                && environment[customTerminalFontEnvironmentKey] != "1"
        }
    }
}
