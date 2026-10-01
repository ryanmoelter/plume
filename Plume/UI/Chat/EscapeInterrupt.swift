import AppKit

/// Whether Esc in the chat composer stops the running turn, as a single
/// press does in Claude Code's TUI.
///
/// Esc reaches the composer only after everything that outranks it has
/// passed: a `.cancelAction` button (the plan panel, the subagent overlay)
/// answers from `performKeyEquivalent`, and the slash-command list takes it
/// first in `ComposerNSTextView.keyDown`. A chord with a modifier is left
/// alone, and so is Esc with no turn running, so `NSTextView` keeps its own
/// meaning for it.
enum EscapeInterrupt {
    static func shouldInterrupt(
        isEnabled: Bool,
        isTurnRunning: Bool,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        isEnabled && isTurnRunning && modifiers.isDisjoint(with: [.command, .option, .control, .shift])
    }
}
