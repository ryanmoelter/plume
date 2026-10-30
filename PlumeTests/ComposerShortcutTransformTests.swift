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

    @Test func shiftTabYieldsToAutocompleteThenListThenCyclesMode() {
        #expect(ComposerShiftTab.decide(autocompleteShowing: true, outdent: sample, canCycleMode: true) == .autocomplete)
        #expect(ComposerShiftTab.decide(autocompleteShowing: false, outdent: sample, canCycleMode: true) == .outdent(sample))
        #expect(ComposerShiftTab.decide(autocompleteShowing: false, outdent: nil, canCycleMode: true) == .cycleMode)
        #expect(ComposerShiftTab.decide(autocompleteShowing: false, outdent: nil, canCycleMode: false) == .ordinary)
    }

    @Test func nextOptionWraps() {
        #expect(ComposerShiftTab.next(after: "b", in: ["a", "b", "c"]) == "c")
        #expect(ComposerShiftTab.next(after: "c", in: ["a", "b", "c"]) == "a")
        #expect(ComposerShiftTab.next(after: "z", in: ["a", "b"]) == "a")
        #expect(ComposerShiftTab.next(after: "a", in: ["a"]) == nil)
        #expect(ComposerShiftTab.next(after: "a", in: [String]()) == nil)
    }
}
