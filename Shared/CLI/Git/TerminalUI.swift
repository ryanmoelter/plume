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

/// A color `wt` paints a glyph in.
nonisolated enum TerminalColor: Sendable, Equatable {
    case foreground
    case dim
    case green
    case red
    case yellow
    case magenta
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
    var linksEnabled: Bool { palette == .ansi }

    private func escape(_ code: String) -> String {
        palette == .ansi ? "\u{1B}[\(code)m" : ""
    }

    // MARK: Glyphs that follow the glyph set

    // Every Nerd Font replacement is one narrow codepoint, so chip widths
    // hold in either set.
    var checksPass: String { glyphSet == .nerd ? "\u{F058}" : "✔" }
    var checksFail: String { glyphSet == .nerd ? "\u{F057}" : "✘" }
    var checksPending: String { glyphSet == .nerd ? "\u{F111}" : "•" }
    var merged: String { glyphSet == .nerd ? "\u{F419}" : "⑃" }
    /// Empty in the plain set: the number prefix already names the forge.
    var github: String { glyphSet == .nerd ? "\u{F09B}" : "" }
    /// Empty in the plain set: the number prefix already names the forge.
    var gitlab: String { glyphSet == .nerd ? "\u{F296}" : "" }
    var netOff: String { glyphSet == .nerd ? "\u{F0A8E}" : "∅" }

    /// The forge's icon in this glyph set, empty for `.none`.
    func forgeIcon(for kind: ForgeKind) -> String {
        switch kind {
        case .github: github
        case .gitlab: gitlab
        case .none: ""
        }
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
        guard linksEnabled, let url, !url.isEmpty else { return text }
        return "\u{1B}]8;;\(url)\u{1B}\\\(text)\u{1B}]8;;\u{1B}\\"
    }

    /// An optional dim forge icon, then `<prefix><number>`, a leading draft
    /// marker, then the checks and review glyphs, or the open marker when an
    /// open, non-draft PR has neither. `(no PR)` when `pr` is nil.
    func prChip(_ pr: PullRequest?, numberPrefix: String = "#", forgeIcon: String? = nil) -> Chip {
        guard let pr else { return Chip(text: "\(dim)(no PR)\(reset)", width: "(no PR)".count) }
        let (lead, leadWidth) = forgeIcon.map { !$0.isEmpty ? ("\(dim)\($0)\(reset) ", 2) : ("", 0) } ?? ("", 0)
        let prefix = "\(numberPrefix)\(pr.number) "

        let glyphs: String
        let width: Int
        switch pr.state {
        case .merged:
            (glyphs, width) = ("\(magenta)\(merged)\(reset)", 1)
        case .closed:
            (glyphs, width) = ("\(red)\(Self.closed)\(reset)", 1)
        case .open:
            var parts: [String] = []
            switch pr.checkRollup(ignoredWhenPending: ignoredPendingChecks) {
            case .success: parts.append("\(green)\(checksPass)\(reset)")
            case .failure: parts.append("\(red)\(checksFail)\(reset)")
            case .pending: parts.append("\(yellow)\(checksPending)\(reset)")
            case .none: break
            }
            switch pr.reviewDecision {
            case .approved: parts.append("\(green)\(Self.approved)\(reset)")
            case .changesRequested: parts.append("\(red)\(Self.changesRequested)\(reset)")
            case .none: break
            }
            if pr.isDraft {
                let separator = parts.isEmpty ? "" : " "
                glyphs = Self.draft + separator + parts.joined()
                width = parts.count + 1 + separator.count
            } else if !parts.isEmpty {
                (glyphs, width) = (parts.joined(), parts.count)
            } else {
                (glyphs, width) = (Self.open, 1)
            }
        }
        return Chip(text: hyperlink(lead + prefix + glyphs, url: pr.url), width: leadWidth + prefix.count + width)
    }

    /// A chip's optional forge icon, which collapses away entirely when empty.
    private func forgeLead(_ forgeIcon: String?) -> (text: String, width: Int) {
        guard let forgeIcon, !forgeIcon.isEmpty else { return ("", 0) }
        return ("\(forgeIcon) ", 2)
    }

    /// The forge icon and an ellipsis, while the fetch is in flight.
    func loadingChip(forgeIcon: String?) -> Chip {
        let lead = forgeLead(forgeIcon)
        return Chip(text: "\(dim)\(lead.text)\(Self.loading)\(reset)", width: lead.width + 1)
    }

    /// The forge icon, `netOff` and `netOffLabel`: red when the fetch failed,
    /// dim when it timed out.
    func netOffChip(forgeIcon: String?, failed: Bool) -> Chip {
        let lead = forgeLead(forgeIcon)
        let color = failed ? red : dim
        return Chip(
            text: "\(color)\(lead.text)\(netOff) \(Self.netOffLabel)\(reset)",
            width: lead.width + 1 + 1 + Self.netOffLabel.count
        )
    }

    /// A branch's PR column once the fetch succeeded: the PR chip, a dim dash
    /// when pushed with no PR, or a bare dim `netOff` when never pushed.
    func branchPRChip(_ pr: PullRequest?, hasUpstream: Bool, forgeIcon: String?, numberPrefix: String = "#") -> Chip {
        if let pr { return prChip(pr, numberPrefix: numberPrefix, forgeIcon: forgeIcon) }
        if hasUpstream {
            let lead = forgeLead(forgeIcon)
            return Chip(text: "\(dim)\(lead.text)\(Self.noPullRequest)\(reset)", width: lead.width + 1)
        }
        return Chip(text: "\(dim)\(netOff)\(reset)", width: 1)
    }

    /// The help page's symbol legend, as lines, in this glyph set and palette.
    /// `forgeIcon` is listed only when non-empty; `extra` adds a "stack graph"
    /// section.
    func glyphKey(forgeIcon: String? = nil, numberPrefix: String = "#", extra: [GlyphKeyEntry] = []) -> [String] {
        // Each glyph is painted the color it renders in, so the key reads as
        // a sample of the output.
        var prColumn = [
            GlyphKeyEntry(Self.open, "open, no checks or review yet"),
            GlyphKeyEntry(Self.draft, "draft"),
            GlyphKeyEntry(checksPass, color: green, "checks passing"),
            GlyphKeyEntry(checksFail, color: red, "checks failing"),
            GlyphKeyEntry(checksPending, color: yellow, "checks running"),
            GlyphKeyEntry(Self.approved, color: green, "approved"),
            GlyphKeyEntry(Self.changesRequested, color: red, "changes requested"),
            GlyphKeyEntry(merged, color: magenta, "merged"),
            GlyphKeyEntry(Self.closed, color: red, "closed without merging"),
            GlyphKeyEntry(Self.noPullRequest, color: dim, "pushed, no PR/MR yet"),
            GlyphKeyEntry(Self.loading, color: dim, "fetching from the forge"),
            GlyphKeyEntry("\(netOff) \(Self.netOffLabel)", color: red, "forge unreachable"),
            GlyphKeyEntry(netOff, color: dim, "local-only branch, never pushed"),
        ]
        let local = [
            GlyphKeyEntry(Self.ahead, color: dim, "commits not on the parent branch"),
            GlyphKeyEntry(Self.up, color: green, "commits not pushed"),
            GlyphKeyEntry(Self.down, color: green, "commits on the remote, not local"),
            GlyphKeyEntry("+", color: green, "uncommitted changes"),
        ]
        prColumn.insert(GlyphKeyEntry("\(numberPrefix)12", "PR/MR number (# GitHub, ! GitLab)"), at: 0)
        if let forgeIcon, !forgeIcon.isEmpty {
            prColumn.insert(GlyphKeyEntry(forgeIcon, color: dim, "the forge the PR/MR lives on"), at: 0)
        }

        // The net-off row's trailing label may overhang rather than push
        // every meaning past it.
        let width = (prColumn + local + extra)
            .filter { !$0.glyph.contains(Self.netOffLabel) }
            .map(\.glyph.count)
            .max() ?? 0

        func section(_ title: String, _ entries: [GlyphKeyEntry]) -> [String] {
            ["  \(title)"] + entries.map { entry in
                // Pad on the bare glyph: the escapes are zero-width.
                let pad = String(repeating: " ", count: max(0, width - entry.glyph.count))
                let close = entry.color.isEmpty ? "" : reset
                return "    \(entry.color)\(entry.glyph)\(close)\(pad)  \(dim)\(entry.meaning)\(reset)"
            }
        }

        var lines = ["Symbols:"]
        lines += section("PR/MR column", prColumn)
        lines.append("")
        lines += section("local status", local)
        if !extra.isEmpty {
            lines.append("")
            lines += section("stack graph", extra)
        }
        return lines
    }

    /// Every glyph a `wt list` row can print, each in the color it prints in,
    /// so Settings can preview them against the terminal theme. A glyph this
    /// set leaves empty drops out.
    var listGlyphs: [(glyph: String, color: TerminalColor)] {
        listGlyphSlots.filter { !$0.glyph.isEmpty }
    }

    /// `listGlyphs` with the empty glyphs kept in place, so two sets line up
    /// slot for slot.
    var listGlyphSlots: [(glyph: String, color: TerminalColor)] {
        [
            (github, .dim),
            (gitlab, .dim),
            (Self.open, .foreground),
            (Self.draft, .foreground),
            (checksPass, .green),
            (checksFail, .red),
            (checksPending, .yellow),
            (Self.approved, .green),
            (Self.changesRequested, .red),
            (merged, .magenta),
            (Self.closed, .red),
            (Self.noPullRequest, .dim),
            (Self.loading, .dim),
            (netOff, .red),
            (netOff, .dim),
            (Self.ahead, .dim),
            (Self.up, .green),
            (Self.down, .green),
            ("+", .green),
        ]
    }

    /// The escape that paints `color`, empty for the default foreground.
    func escape(for color: TerminalColor) -> String {
        switch color {
        case .foreground: ""
        case .dim: dim
        case .green: green
        case .red: red
        case .yellow: yellow
        case .magenta: magenta
        }
    }

    /// Rewinds over an `lines`-tall block already printed: cursor up, then
    /// clear to the end of the screen.
    static func redrawPrefix(lines: Int) -> String {
        "\u{1B}[\(lines)A\u{1B}[J"
    }
}
