import Foundation

/// The one handler the composer's text view holds, so it never swaps between
/// updates. Each key goes to whichever list has rows, and Esc also to a
/// mention panel still loading; the slash list wins if both somehow qualify.
final class ComposerAutocompleteRouter: ComposerAutocompleteHandler {
    let slash: ComposerAutocompleteController
    let mention: MentionAutocompleteController

    init(
        slash: ComposerAutocompleteController = ComposerAutocompleteController(),
        mention: MentionAutocompleteController = MentionAutocompleteController()
    ) {
        self.slash = slash
        self.mention = mention
    }

    private var active: ComposerAutocompleteHandler? {
        if slash.isShowing { return slash }
        if mention.isShowing { return mention }
        return nil
    }

    var isShowing: Bool { active != nil }
    var claimsEscape: Bool { slash.claimsEscape || mention.claimsEscape }

    func moveSelection(by delta: Int) { active?.moveSelection(by: delta) }
    func acceptSelection() { active?.acceptSelection() }

    func dismiss() {
        if slash.claimsEscape {
            slash.dismiss()
        } else if mention.claimsEscape {
            mention.dismiss()
        }
    }
}
