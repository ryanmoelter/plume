import Foundation
import SwiftUI

/// A menu command whose chord the user can reassign.
///
/// The four cycling commands, Send Now, Home and the composer's formatting
/// keys are rebindable. Every other chord
/// `PlumeCommands` binds stays fixed, because it either matches a macOS-wide
/// convention (⌘N, ⌘T, ⌘W) or is positional (⌘1…⌘9).
nonisolated enum ShortcutAction: String, CaseIterable, Identifiable, Codable {
    case nextTab
    case previousTab
    case nextTask
    case previousTask
    case sendNow
    case showHome
    case formatBold
    case formatItalic
    case formatCode
    case formatLink

    var id: String { rawValue }

    var label: String {
        switch self {
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        case .nextTask: "Next Task"
        case .previousTask: "Previous Task"
        case .sendNow: "Send Now"
        case .showHome: "Home"
        case .formatBold: "Bold"
        case .formatItalic: "Italic"
        case .formatCode: "Code"
        case .formatLink: "Link"
        }
    }

    /// The composer's text view handles these chords itself. They have no
    /// menu item, and a terminal must never be made to give them up.
    var isComposerFormatting: Bool { composerStyle != nil }

    var composerStyle: ComposerInlineFormatting.Style? {
        switch self {
        case .formatBold: .bold
        case .formatItalic: .italic
        case .formatCode: .code
        case .formatLink: .link
        default: nil
        }
    }

    static var menuActions: [ShortcutAction] { allCases.filter { !$0.isComposerFormatting } }
    static var composerFormattingActions: [ShortcutAction] { allCases.filter(\.isComposerFormatting) }

    /// Nil for an action that ships unbound and gets a chord only when the
    /// user records one.
    var defaultShortcut: MenuShortcut? {
        switch self {
        case .nextTab: MenuShortcut("]", modifiers: [.command, .shift])
        case .previousTab: MenuShortcut("[", modifiers: [.command, .shift])
        case .nextTask: MenuShortcut("]")
        case .previousTask: MenuShortcut("[")
        case .sendNow: nil
        case .showHome: MenuShortcut("h", modifiers: [.command, .shift])
        case .formatBold: MenuShortcut("b")
        case .formatItalic: MenuShortcut("i")
        case .formatCode: MenuShortcut("e")
        case .formatLink: MenuShortcut("k")
        }
    }
}

/// The user's chord for every rebindable action, with unbound actions falling
/// back to their default.
///
/// `PlumeShortcuts` reads from here and `TerminalShortcutMonitor` claims from
/// the same values, so rebinding a chord moves both at once. Persisted whole,
/// as one JSON blob, rather than a key per action: the set is small and always
/// read together, and one blob keeps a partial write from leaving half the
/// bindings stale.
nonisolated struct ShortcutBindings: Equatable, Codable {
    /// An action present here with a nil value is deliberately unbound: its
    /// chord went to another action, and falling back to its default would
    /// hand it a chord that action now owns.
    private var overrides: [ShortcutAction: MenuShortcut?]

    init(overrides: [ShortcutAction: MenuShortcut?] = [:]) {
        self.overrides = overrides
    }

    /// The chord bound to `action`, or nil when it has none.
    subscript(action: ShortcutAction) -> MenuShortcut? {
        overrides[action] ?? action.defaultShortcut
    }

    /// The menu actions' chords, which is what a terminal may be asked to give
    /// up. Composer formatting chords stay out.
    var all: [MenuShortcut] { ShortcutAction.menuActions.compactMap { self[$0] } }

    func isCustomized(_ action: ShortcutAction) -> Bool { overrides[action] != nil }

    /// Assigns `shortcut` to `action`, unbinding any other action that already
    /// held it. Two menu items sharing a chord leaves AppKit to pick one, so
    /// the loser would silently stop working.
    mutating func assign(_ shortcut: MenuShortcut, to action: ShortcutAction) {
        for other in ShortcutAction.allCases where other != action && self[other] == shortcut {
            overrides[other] = .some(nil)
        }
        overrides[action] = shortcut
    }

    mutating func reset(_ action: ShortcutAction) {
        overrides[action] = nil
    }

    mutating func resetAll() {
        overrides = [:]
    }

    /// The conflicting action, if `shortcut` is already bound elsewhere.
    func conflict(for shortcut: MenuShortcut, excluding action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && self[$0] == shortcut }
    }
}

/// Encoded as an object keyed by action, whose value is the chord or `null`
/// for a deliberately unbound action. Written by hand because a dictionary of
/// optionals keyed by a non-`String` type encodes as a flat array otherwise.
nonisolated extension ShortcutBindings {
    private struct ActionKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
        init(_ action: ShortcutAction) { stringValue = action.rawValue }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ActionKey.self)
        var overrides: [ShortcutAction: MenuShortcut?] = [:]
        for action in ShortcutAction.allCases {
            let key = ActionKey(action)
            guard container.contains(key) else { continue }
            overrides[action] = try container.decodeIfPresent(MenuShortcut.self, forKey: key)
        }
        self.init(overrides: overrides)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ActionKey.self)
        for action in ShortcutAction.allCases where isCustomized(action) {
            let key = ActionKey(action)
            if let shortcut = self[action] {
                try container.encode(shortcut, forKey: key)
            } else {
                try container.encodeNil(forKey: key)
            }
        }
    }
}
