import Foundation
import Testing
@testable import Plume

/// Cases write the selection as `|` for a caret or `[...]` for a range, in
/// both input and expected output.
struct ComposerShortcutTransformTests {
    private func parse(_ marked: String) -> (String, NSRange) {
        let ns = marked as NSString
        let open = ns.range(of: "[")
        if open.location != NSNotFound {
            let close = ns.range(of: "]", options: .backwards)
            let plain = ns.replacingCharacters(in: close, with: "") as NSString
            let text = plain.replacingCharacters(in: open, with: "")
            return (text, NSRange(location: open.location, length: close.location - open.location - 1))
        }
        let caret = ns.range(of: "|")
        return (ns.replacingCharacters(in: caret, with: ""), NSRange(location: caret.location, length: 0))
    }

    private func render(_ result: ComposerMarkdownEditing.Result) -> String {
        let ns = result.text as NSString
        if result.selection.length == 0 {
            return ns.replacingCharacters(in: result.selection, with: "|")
        }
        let end = NSMaxRange(result.selection)
        let closed = ns.replacingCharacters(in: NSRange(location: end, length: 0), with: "]") as NSString
        return closed.replacingCharacters(in: NSRange(location: result.selection.location, length: 0), with: "[")
    }

    private func format(_ style: ComposerInlineFormatting.Style, _ marked: String) -> String? {
        let (text, selection) = parse(marked)
        return ComposerInlineFormatting.apply(style, in: text, selection: selection).map(render)
    }

    // MARK: - Formatting

    @Test func selectionIsWrapped() {
        #expect(format(.bold, "say [hello] now") == "say **[hello]** now")
        #expect(format(.italic, "say [hello] now") == "say *[hello]* now")
        #expect(format(.code, "say [hello] now") == "say `[hello]` now")
    }

    @Test func wrappedSelectionIsUnwrapped() {
        #expect(format(.bold, "say **[hello]** now") == "say [hello] now")
        #expect(format(.bold, "say [**hello**] now") == "say [hello] now")
        #expect(format(.code, "`[a b]`") == "[a b]")
    }

    @Test func caretAtEndOfWordWrapsTheWord() {
        #expect(format(.bold, "say hello| now") == "say **hello**| now")
        #expect(format(.code, "hello|") == "`hello`|")
    }

    @Test func caretInsideWordWrapsTheWord() {
        #expect(format(.italic, "hel|lo") == "*hello*|")
    }

    @Test func caretAtLeadingEdgeOrBetweenSpacesInsertsAPair() {
        #expect(format(.bold, "say |hello") == "say **|**hello")
        #expect(format(.bold, "say | now") == "say **|** now")
        #expect(format(.code, "|") == "`|`")
    }

    @Test func caretInsideAnEmptyPairRemovesIt() {
        #expect(format(.bold, "a **|** b") == "a | b")
        #expect(format(.code, "`|`") == "|")
    }

    @Test func italicDoesNotUnwrapHalfOfABoldPair() {
        #expect(format(.italic, "**[hi]**") == "***[hi]***")
    }

    @Test func boldAndItalicSkipCode() {
        #expect(format(.bold, "```\nco|de\n```") == nil)
        #expect(format(.code, "```\nco[de]\n```") != nil)
    }

    // MARK: - Caret toggles

    /// Caret cases use `^` so link brackets stay literal.
    private func caretFormat(_ style: ComposerInlineFormatting.Style, _ marked: String) -> String? {
        let ns = marked as NSString
        let caret = ns.range(of: "^")
        let text = ns.replacingCharacters(in: caret, with: "")
        return ComposerInlineFormatting.apply(style, in: text, selection: NSRange(location: caret.location, length: 0)).map {
            ($0.text as NSString).replacingCharacters(in: $0.selection, with: "^")
        }
    }

    @Test func caretInsideOrTouchingCodeSpanRemovesIt() {
        #expect(caretFormat(.code, "a `code^` b") == "a code^ b")
        #expect(caretFormat(.code, "a `^code` b") == "a ^code b")
        #expect(caretFormat(.code, "a `co^de` b") == "a co^de b")
        #expect(caretFormat(.code, "a `code`^ b") == "a code^ b")
        #expect(caretFormat(.code, "a ^`code` b") == "a ^code b")
    }

    @Test func caretInsideOrTouchingBoldSpanRemovesIt() {
        #expect(caretFormat(.bold, "a **bo^ld** b") == "a bo^ld b")
        #expect(caretFormat(.bold, "a **bold**^ b") == "a bold^ b")
        #expect(caretFormat(.bold, "a ^**bold** b") == "a ^bold b")
        #expect(caretFormat(.bold, "a **bold^** b") == "a bold^ b")
    }

    @Test func caretInsideOrTouchingItalicSpanRemovesIt() {
        #expect(caretFormat(.italic, "a *it^al* b") == "a it^al b")
        #expect(caretFormat(.italic, "a *ital*^ b") == "a ital^ b")
        #expect(caretFormat(.italic, "a ^*ital* b") == "a ^ital b")
    }

    @Test func caretToggleDisambiguatesBoldAndItalic() {
        #expect(caretFormat(.italic, "**bo^ld**") == "***bold*^**")
        #expect(caretFormat(.bold, "*it^al*") == "***ital**^*")
        #expect(caretFormat(.bold, "a *x* **bo^ld**") == "a *x* bo^ld")
        #expect(caretFormat(.italic, "a **b** *it^al*") == "a **b** it^al")
    }

    @Test func boldAndItalicDoNothingInsideInlineCode() {
        #expect(caretFormat(.bold, "`co^de`") == nil)
        #expect(caretFormat(.italic, "`**co^de**`") == nil)
    }

    @Test func linkCaretUnwrapsToItsLabel() {
        #expect(caretFormat(.link, "a [te^xt](http://x.y) b") == "a te^xt b")
        #expect(caretFormat(.link, "a [text](http://x.y)^ b") == "a text^ b")
        #expect(caretFormat(.link, "a ^[text](http://x.y) b") == "a ^text b")
        #expect(caretFormat(.link, "a [text](http://^x.y) b") == "a text^ b")
    }

    @Test func linkWrapsTheWordWithCaretInTheTarget() {
        #expect(format(.link, "see docs| now") == "see [docs](|) now")
        #expect(format(.link, "see [the docs] now") == "see [the docs](|) now")
    }

    @Test func linkOfAURLPutsTheCaretInTheLabel() {
        #expect(format(.link, "[https://a.dev]") == "[|](https://a.dev)")
    }

    @Test func linkWithNothingToWrapInsertsEmptyBrackets() {
        #expect(format(.link, "see | now") == "see [|]() now")
    }

    // MARK: - Paste link

    private func pasteLink(_ url: String, over marked: String) -> String? {
        let (text, selection) = parse(marked)
        return ComposerInlineFormatting.pasteLink(url, in: text, selection: selection).map(render)
    }

    @Test func pastingAURLOverASelectionLinksIt() {
        #expect(pasteLink("https://a.dev/x?y=1", over: "see [the docs] now") == "see [the docs](https://a.dev/x?y=1)| now")
        #expect(pasteLink("  mailto:me@a.dev\n", over: "[me]") == "[me](mailto:me@a.dev)|")
        #expect(pasteLink("https://a.dev", over: "- [item]") == "- [item](https://a.dev)|")
    }

    @Test func pastingAnythingElseIsOrdinary() {
        #expect(pasteLink("https://a.dev", over: "see the| docs") == nil)
        #expect(pasteLink("not a url", over: "[docs]") == nil)
        #expect(pasteLink("a.dev", over: "[docs]") == nil)
        #expect(pasteLink("https://a.dev more", over: "[docs]") == nil)
        #expect(pasteLink("https://b.dev", over: "[https://a.dev]") == nil)
        #expect(pasteLink("https://a.dev", over: "[two\nlines]") == nil)
        #expect(pasteLink("https://a.dev", over: "```\n[code]\n```") == nil)
    }

    // MARK: - Fence

    private func closeFence(_ marked: String) -> String? {
        let (text, selection) = parse(marked)
        return ComposerFenceClosing.closing(in: text, caret: selection.location).map(render)
    }

    @Test func openingFenceGetsAClosingFence() {
        #expect(closeFence("```|") == "```|\n```")
        #expect(closeFence("hi\n~~~|") == "hi\n~~~|\n~~~")
        #expect(closeFence("> ```|") == "> ```|\n> ```")
    }

    @Test func fenceThatIsAlreadyClosedAddsNothing() {
        #expect(closeFence("```\ncode\n```|") == nil)
        #expect(closeFence("```|\ncode\n```") == nil)
    }

    @Test func nonFenceTextAddsNothing() {
        #expect(closeFence("``|") == nil)
        #expect(closeFence("a ```|") == nil)
        #expect(closeFence("```swift|") == nil)
        #expect(closeFence("````|") == nil)
    }

    // MARK: - Shift-Tab

    private let sample = ComposerMarkdownEditing.Result(text: "x", selection: NSRange(location: 0, length: 0))

    @Test func shiftTabYieldsToAutocompleteThenListThenTogglesPlanMode() {
        #expect(ComposerShiftTab.decide(autocompleteShowing: true, outdent: sample, canTogglePlanMode: true) == .autocomplete)
        #expect(ComposerShiftTab.decide(autocompleteShowing: false, outdent: sample, canTogglePlanMode: true) == .outdent(sample))
        #expect(ComposerShiftTab.decide(autocompleteShowing: false, outdent: nil, canTogglePlanMode: true) == .togglePlanMode)
        #expect(ComposerShiftTab.decide(autocompleteShowing: false, outdent: nil, canTogglePlanMode: false) == .ordinary)
    }

    private func preset(_ mode: PermissionMode) -> AgentPermissionPreset {
        AgentPermissionPreset(id: mode.rawValue, label: mode.label)
    }

    private var presets: [AgentPermissionPreset] { PermissionMode.allCases.map(preset) }

    @Test func togglePlanEntersPlanFromAnyOtherMode() {
        let next = ComposerShiftTab.togglePlan(current: preset(.manual), lastNonPlan: preset(.auto), in: presets)
        #expect(next == preset(.plan))
    }

    @Test func togglePlanReturnsToTheRememberedMode() {
        let next = ComposerShiftTab.togglePlan(current: preset(.plan), lastNonPlan: preset(.acceptEdits), in: presets)
        #expect(next == preset(.acceptEdits))
    }

    @Test func togglePlanFallsBackToAutoWithNothingRemembered() {
        let next = ComposerShiftTab.togglePlan(current: preset(.plan), lastNonPlan: nil, in: presets)
        #expect(next == preset(.auto))
    }

    @Test func togglePlanIgnoresARememberedModeThePresetsNoLongerOffer() {
        let offered = presets.filter { $0.id != PermissionMode.bypassPermissions.rawValue }
        let next = ComposerShiftTab.togglePlan(current: preset(.plan), lastNonPlan: preset(.bypassPermissions), in: offered)
        #expect(next == preset(.auto))
    }

    @Test func togglePlanIsNilWithoutAPlanPreset() {
        #expect(ComposerShiftTab.togglePlan(current: nil, lastNonPlan: nil, in: [AgentPermissionPreset.codexReadOnly]) == nil)
    }
}
