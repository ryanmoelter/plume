import Foundation
import Testing
@testable import Plume

/// Each case writes the caret as `|` in both the input and the expected
/// output, so a test reads as before and after.
struct ComposerMarkdownEditingTests {
    private typealias Operation = (String, NSRange) -> ComposerMarkdownEditing.Result?

    private func run(_ operation: Operation, _ marked: String) -> String? {
        let caret = (marked as NSString).range(of: "|")
        let text = (marked as NSString).replacingCharacters(in: caret, with: "")
        guard let result = operation(text, NSRange(location: caret.location, length: 0)) else { return nil }
        #expect(result.selection.length == 0)
        return (result.text as NSString).replacingCharacters(in: result.selection, with: "|")
    }

    // MARK: - Return

    @Test func returnContinuesABullet() {
        #expect(run(ComposerMarkdownEditing.newline, "- one|") == "- one\n- |")
        #expect(run(ComposerMarkdownEditing.newline, "  * one|") == "  * one\n  * |")
    }

    @Test func returnMidItemCarriesTheRestDown() {
        #expect(run(ComposerMarkdownEditing.newline, "- on|e") == "- on\n- |e")
    }

    @Test func returnIncrementsAndRenumbers() {
        #expect(run(ComposerMarkdownEditing.newline, "1. a|\n2. b\n3. c") == "1. a\n2. |\n3. b\n4. c")
    }

    @Test func returnKeepsTheDelimiter() {
        #expect(run(ComposerMarkdownEditing.newline, "1) a|") == "1) a\n2) |")
    }

    @Test func returnContinuesATaskUnchecked() {
        #expect(run(ComposerMarkdownEditing.newline, "- [x] done|") == "- [x] done\n- [ ] |")
    }

    @Test func returnOnAnEmptyItemEndsTheList() {
        #expect(run(ComposerMarkdownEditing.newline, "- a\n- |") == "- a\n|")
    }

    @Test func returnOnAnEmptyNestedItemOutdents() {
        #expect(run(ComposerMarkdownEditing.newline, "- a\n  - |") == "- a\n- |")
    }

    @Test func returnContinuesAQuote() {
        #expect(run(ComposerMarkdownEditing.newline, "> > deep|") == "> > deep\n> > |")
        #expect(run(ComposerMarkdownEditing.newline, "> - item|") == "> - item\n> - |")
    }

    @Test func returnOnAnEmptyQuoteLineLeavesALevel() {
        #expect(run(ComposerMarkdownEditing.newline, "> > |") == "> |")
    }

    @Test func returnIsOrdinaryElsewhere() {
        #expect(run(ComposerMarkdownEditing.newline, "plain|") == nil)
        #expect(run(ComposerMarkdownEditing.newline, "# Title|") == nil)
        #expect(run(ComposerMarkdownEditing.newline, "```\n- code|") == nil)
    }

    // MARK: - Tab

    @Test func tabIndentsToTheItemAbove() {
        #expect(run(ComposerMarkdownEditing.indent, "- a\n- |b") == "- a\n  - |b")
        #expect(run(ComposerMarkdownEditing.indent, "1. a\n2. |b") == "1. a\n   1. |b")
    }

    @Test func tabCarriesNestedLines() {
        #expect(run(ComposerMarkdownEditing.indent, "- a\n- |b\n  - c\n- d") == "- a\n  - |b\n    - c\n- d")
    }

    @Test func tabOnTheFirstItemIsSwallowed() {
        #expect(run(ComposerMarkdownEditing.indent, "- |a") == "- |a")
    }

    @Test func tabOutsideAListIsOrdinary() {
        #expect(run(ComposerMarkdownEditing.indent, "text|") == nil)
        #expect(run(ComposerMarkdownEditing.indent, "- a\n- b|") == nil)
    }

    @Test func tabRenumbersBothLists() {
        #expect(run(ComposerMarkdownEditing.indent, "1. a\n2. |b\n3. c") == "1. a\n   1. |b\n2. c")
    }

    // MARK: - Shift-Tab

    @Test func shiftTabOutdentsToTheParent() {
        #expect(run(ComposerMarkdownEditing.outdent, "- a\n  - |b") == "- a\n- |b")
        #expect(run(ComposerMarkdownEditing.outdent, "- a\n  - b\n    - c|") == "- a\n  - b\n  - c|")
    }

    @Test func shiftTabAtTheTopLevelIsSwallowed() {
        #expect(run(ComposerMarkdownEditing.outdent, "- a|") == "- a|")
    }

    // MARK: - Delete

    @Test func deleteAtTheTextStartRemovesTheMarker() {
        #expect(run(ComposerMarkdownEditing.deleteBackward, "- |item") == "|item")
        #expect(run(ComposerMarkdownEditing.deleteBackward, "- [ ] |task") == "|task")
        #expect(run(ComposerMarkdownEditing.deleteBackward, "1. |one") == "|one")
    }

    @Test func deleteOutdentsANestedItem() {
        #expect(run(ComposerMarkdownEditing.deleteBackward, "- a\n  - |b") == "- a\n- |b")
    }

    @Test func deleteRemovesOneQuoteLevel() {
        #expect(run(ComposerMarkdownEditing.deleteBackward, "> > |deep") == "> |deep")
    }

    @Test func deleteKeepsTheQuoteAroundAListItem() {
        #expect(run(ComposerMarkdownEditing.deleteBackward, "> - |item") == "> |item")
    }

    @Test func deleteAfterARuleBreaksIt() {
        #expect(run(ComposerMarkdownEditing.deleteBackward, "---\n|after") == "--\n|after")
    }

    @Test func deleteRenumbersTheRest() {
        #expect(run(ComposerMarkdownEditing.deleteBackward, "1. a\n2. |b\n3. c\n4. d") == "1. a\n|b\n3. c\n4. d")
    }

    @Test func deleteIsOrdinaryElsewhere() {
        #expect(run(ComposerMarkdownEditing.deleteBackward, "- it|em") == nil)
        #expect(run(ComposerMarkdownEditing.deleteBackward, "# |Title") == nil)
        #expect(run(ComposerMarkdownEditing.deleteBackward, "plain\n|next") == nil)
    }

    // MARK: - Space

    @Test func aMarkerTypedInAnItemConvertsItsLevel() {
        #expect(run(ComposerMarkdownEditing.insertSpace, "1. a\n2. -|b\n3. c") == "- a\n- |b\n- c")
        #expect(run(ComposerMarkdownEditing.insertSpace, "- a\n- 1.|b") == "1. a\n2. |b")
        #expect(run(ComposerMarkdownEditing.insertSpace, "- 3)|a\n- b") == "3) |a\n4) b")
        #expect(run(ComposerMarkdownEditing.insertSpace, "- a\n- x|b") == "- [ ] a\n- [ ] |b")
        #expect(run(ComposerMarkdownEditing.insertSpace, "- [x] a\n- [ ] -|b") == "- a\n- |b")
        #expect(run(ComposerMarkdownEditing.insertSpace, "> 1. -|a") == "> - |a")
    }

    @Test func convertingALevelLeavesOtherLevelsAlone() {
        #expect(
            run(ComposerMarkdownEditing.insertSpace, "- a\n  - b\n  - 1.|c\n- d")
                == "- a\n  1. b\n  2. |c\n- d"
        )
    }

    @Test func nestedLinesFollowTheNewMarkerWidth() {
        #expect(
            run(ComposerMarkdownEditing.insertSpace, "- 1.|a\n  - b\n  more\n- c")
                == "1. |a\n   - b\n   more\n2. c"
        )
        #expect(run(ComposerMarkdownEditing.insertSpace, "1. -|a\n   - b") == "- |a\n  - b")
    }

    @Test func xStartsATask() {
        #expect(run(ComposerMarkdownEditing.insertSpace, "x|") == "- [ ] |")
        #expect(run(ComposerMarkdownEditing.insertSpace, "> x|") == "> - [ ] |")
        #expect(run(ComposerMarkdownEditing.insertSpace, "x|rest") == "- [ ] |rest")
    }

    @Test func spaceIsOrdinaryElsewhere() {
        #expect(run(ComposerMarkdownEditing.insertSpace, "a x|") == nil)
        #expect(run(ComposerMarkdownEditing.insertSpace, "- a -|") == nil)
        #expect(run(ComposerMarkdownEditing.insertSpace, "-|") == nil)
        #expect(run(ComposerMarkdownEditing.insertSpace, "# x|") == nil)
        #expect(run(ComposerMarkdownEditing.insertSpace, "```\nx|") == nil)
    }

    // MARK: - Paste

    private func pasted(_ pasted: String, into marked: String) -> String? {
        run({ ComposerMarkdownEditing.paste(pasted, in: $0, selection: $1) }, marked)
    }

    @Test func pastedIndentTabsBecomeSpaces() {
        #expect(pasted("- a\n\t- b\n\t\tc\td", into: "|") == "- a\n    - b\n        c\td|")
        #expect(pasted("> \t- a", into: "x\n|") == "x\n>     - a|")
    }

    @Test func pastedCodeKeepsItsTabs() {
        #expect(pasted("```\n\tfunc\n```\n\t- a", into: "|") == "```\n\tfunc\n```\n    - a|")
        #expect(pasted("\tfunc", into: "```\n|\n```") == nil)
    }

    @Test func pasteWithoutIndentTabsIsOrdinary() {
        #expect(pasted("- a\n  - b", into: "|") == nil)
        #expect(pasted("a\tb", into: "|") == nil)
    }

    // MARK: - Checkbox

    @Test func checkboxToggles() {
        let text = "- [ ] task"
        let box = NSRange(location: 2, length: 3)
        let checked = ComposerMarkdownEditing.toggleCheckbox(box, in: text, selection: NSRange(location: 0, length: 0))
        #expect(checked?.text == "- [x] task")
        let unchecked = ComposerMarkdownEditing.toggleCheckbox(box, in: checked!.text, selection: NSRange(location: 0, length: 0))
        #expect(unchecked?.text == text)
    }

    // MARK: - Caret

    private func snapped(_ text: String, to location: Int, from previous: Int?) -> Int {
        ComposerMarkdownEditing.snappedSelection(
            NSRange(location: location, length: 0),
            previous: previous.map { NSRange(location: $0, length: 0) },
            in: MarkdownLineStructure.lines(in: text)
        ).location
    }

    @Test func caretInsideAHiddenMarkerGoesToTheText() {
        #expect(snapped("a\n- item", to: 2, from: nil) == 4)
        #expect(snapped("a\n- item", to: 3, from: 2) == 4)
    }

    @Test func movingBackFromTheTextJumpsToThePreviousLine() {
        #expect(snapped("a\n- item", to: 3, from: 4) == 1)
        #expect(snapped("a\r\n- item", to: 4, from: 5) == 1)
    }

    @Test func movingToTheLineStartStaysOnTheItem() {
        #expect(snapped("a\n- item", to: 2, from: 4) == 4)
    }

    @Test func renumberingKeepsTheCaretAcrossCRLF() {
        let result = ComposerMarkdownEditing.newline(
            in: "x\r\n8. a\r\n9. b",
            selection: NSRange(location: 7, length: 0)
        )
        #expect(result?.text == "x\r\n8. a\n9. \r\n10. b")
        #expect(result?.selection == NSRange(location: 11, length: 0))
    }

    @Test func firstLineCannotMoveBeforeItsMarker() {
        #expect(snapped("- item", to: 1, from: 2) == 2)
    }

    @Test func shownMarkersAreNotSnapped() {
        #expect(snapped("1. item", to: 1, from: 3) == 1)
        #expect(snapped("# Title", to: 1, from: nil) == 1)
    }
}
