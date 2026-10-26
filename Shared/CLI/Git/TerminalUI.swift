import Foundation

/// A rendered fragment and how many columns it occupies on screen. The width
/// ignores ANSI and OSC 8 escapes, so tables align on it rather than on the
/// string's length.
nonisolated struct Chip: Equatable, Sendable {
    var text: String
    var width: Int
}

/// One row of the help page's symbol key. `color` is an escape from the
/// `TerminalUI` that renders the key, or empty for an uncolored glyph.
nonisolated struct GlyphKeyEntry: Equatable, Sendable {
    var glyph: String
    var color: String
    var meaning: String

    init(_ glyph: String, color: String = "", _ meaning: String) {
        self.glyph = glyph
        self.color = color
        self.meaning = meaning
    }
}

/// The terminal vocabulary `wt` and `stack` share: colors, the PR glyphs, PR
/// chips, the symbol key and the picker. A value rather than globals, so a
/// command renders with whatever settings it was handed.
nonisolated struct TerminalUI: Equatable, Sendable {
    enum Palette: Sendable, Equatable {
        /// No escapes at all: piped output, `NO_COLOR`, tests.
        case plain
        /// ANSI colors plus OSC 8 hyperlinks.
        case ansi
    }

    enum GlyphSet: Sendable, Equatable {
        /// Unicode that every font has. The default.
        case plain
        /// Nerd Font private-use codepoints.
        case nerd
    }

    var palette: Palette
    var glyphSet: GlyphSet
    /// Checks whose pending state is ignored when folding the checks glyph.
    var ignoredPendingChecks: Set<String>

    init(palette: Palette = .plain, glyphSet: GlyphSet = .plain, ignoredPendingChecks: Set<String> = []) {
        self.palette = palette
        self.glyphSet = glyphSet
        self.ignoredPendingChecks = ignoredPendingChecks
    }

    static let plain = TerminalUI()

    // MARK: Colors

    var green: String { escape("32") }
    var red: String { escape("31") }
    var yellow: String { escape("33") }
    var magenta: String { escape("35") }
    var cyan: String { escape("36") }
    var dim: String { escape("2") }
    var bold: String { escape("1") }
    var reset: String { escape("0") }

    /// Whether `hyperlink` emits OSC 8 links. Follows the palette: links only
    /// make sense on an interactive terminal.
    var linksEnabled: Bool {
        // TODO(PLUME-316 group A)
        false
    }

    private func escape(_ code: String) -> String {
        // TODO(PLUME-316 group A)
        ""
    }

    // MARK: Glyphs that follow the glyph set

    var checksPass: String {
        // TODO(PLUME-316 group A)
        ""
    }
    var checksFail: String {
        // TODO(PLUME-316 group A)
        ""
    }
    var checksPending: String {
        // TODO(PLUME-316 group A)
        ""
    }
    var merged: String {
        // TODO(PLUME-316 group A)
        ""
    }
    /// Empty in the plain set: the number prefix already names the forge.
    var github: String {
        // TODO(PLUME-316 group A)
        ""
    }
    /// Empty in the plain set: the number prefix already names the forge.
    var gitlab: String {
        // TODO(PLUME-316 group A)
        ""
    }
    var netOff: String {
        // TODO(PLUME-316 group A)
        ""
    }

    /// The forge's icon in this glyph set, empty for `.none`.
    func forgeIcon(for kind: ForgeKind) -> String {
        // TODO(PLUME-316 group A)
        ""
    }

    // MARK: Glyphs that never change

    static let closed = "⊘"
    static let open = "◉"
    static let draft = "◌"
    static let approved = "✓"
    static let changesRequested = "±"
    static let loading = "…"
    /// Pushed, with no pull request yet.
    static let noPullRequest = "–"
    /// Commits not on the parent branch.
    static let ahead = "↗"
    /// Commits not pushed.
    static let up = "↑"
    /// Commits on the remote, not local.
    static let down = "↓"
    /// Spelled out beside `netOff` when the forge was unreachable, which the
    /// bare glyph doesn't say on its own.
    static let netOffLabel = "not connected"

    // MARK: Rendering

    /// `text` wrapped in an OSC 8 hyperlink, or unchanged when links are off
    /// or there is no URL.
    func hyperlink(_ text: String, url: String?) -> String {
        // TODO(PLUME-316 group A)
        text
    }

    /// An optional dim forge icon, then `<prefix><number>`, a leading draft
    /// marker, then the checks and review glyphs, or the open marker when an
    /// open, non-draft PR has neither. `(no PR)` when `pr` is nil.
    func prChip(_ pr: PullRequest?, numberPrefix: String = "#", forgeIcon: String? = nil) -> Chip {
        // TODO(PLUME-316 group A)
        Chip(text: "", width: 0)
    }

    /// The forge icon and an ellipsis, while the fetch is in flight.
    func loadingChip(forgeIcon: String?) -> Chip {
        // TODO(PLUME-316 group A)
        Chip(text: "", width: 0)
    }

    /// The forge icon, `netOff` and `netOffLabel`: red when the fetch failed,
    /// dim when it timed out.
    func netOffChip(forgeIcon: String?, failed: Bool) -> Chip {
        // TODO(PLUME-316 group A)
        Chip(text: "", width: 0)
    }

    /// A branch's PR column once the fetch succeeded: the PR chip, a dim dash
    /// when pushed with no PR, or a bare dim `netOff` when never pushed.
    func branchPRChip(_ pr: PullRequest?, hasUpstream: Bool, forgeIcon: String?, numberPrefix: String = "#") -> Chip {
        // TODO(PLUME-316 group A)
        Chip(text: "", width: 0)
    }

    /// The help page's symbol legend, as lines, in this glyph set and palette.
    /// `forgeIcon` is listed only when non-empty; `extra` adds a "stack graph"
    /// section.
    func glyphKey(forgeIcon: String? = nil, numberPrefix: String = "#", extra: [GlyphKeyEntry] = []) -> [String] {
        // TODO(PLUME-316 group A)
        []
    }

    /// Rewinds over an `lines`-tall block already printed: cursor up, then
    /// clear to the end of the screen.
    static func redrawPrefix(lines: Int) -> String {
        // TODO(PLUME-316 group A)
        ""
    }

    /// Asks the user to pick one of `candidates` (value, display). Off a
    /// terminal it fails listing the values, so a script can correct itself.
    func pick(_ candidates: [(value: String, display: String)], what: String, console: any CLIConsole) throws -> String {
        // TODO(PLUME-316 group A)
        throw CLIFailure("cancelled")
    }
}
