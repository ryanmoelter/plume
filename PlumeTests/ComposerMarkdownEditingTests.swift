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

    @Test func returnKeepsQuotedCodeInTheQuote() {
        #expect(run(ComposerMarkdownEditing.newline, "> ```|") == "> ```\n> |")
        #expect(run(ComposerMarkdownEditing.newline, "> ```\n> |") == "> ```\n> \n> |")
    }

    @Test func returnIsOrdinaryElsewhere() {
        #expect(run(ComposerMarkdownEditing.newline, "plain|") == nil)
        #expect(run(ComposerMarkdownEditing.newline, "# Title|") == nil)
        #expect(run(ComposerMarkdownEditing.newline, "```\n- code|") == nil)
    }

    @Test func returnInAnItemsTextKeepsItsIndent() {
        #expect(run(ComposerMarkdownEditing.newline, "- a\n  more|") == "- a\n  more\n  |")
        #expect(run(ComposerMarkdownEditing.newline, "- a\n  mo|re") == "- a\n  mo\n  |re")
        #expect(run(ComposerMarkdownEditing.newline, "- a\n  |more") == "- a\n  \n  |more")
        #expect(run(ComposerMarkdownEditing.newline, "1. a\n   more|") == "1. a\n   more\n   |")
        #expect(run(ComposerMarkdownEditing.newline, "10. a\n    more|") == "10. a\n    more\n    |")
        #expect(run(ComposerMarkdownEditing.newline, "- [ ] a\n  more|") == "- [ ] a\n  more\n  |")
        #expect(run(ComposerMarkdownEditing.newline, "> - a\n>   more|") == "> - a\n>   more\n>   |")
    }

    @Test func returnInANestedItemsTextKeepsItsIndent() {
        #expect(run(ComposerMarkdownEditing.newline, "- a\n  1. b\n     more|") == "- a\n  1. b\n     more\n     |")
        #expect(run(ComposerMarkdownEditing.newline, "- a\n  - b\n  more|") == "- a\n  - b\n  more\n  |")
    }

    @Test func returnFindsTheItemPastBlankAndCodeLines() {
        #expect(run(ComposerMarkdownEditing.newline, "- a\n\n  one\n  two|") == "- a\n\n  one\n  two\n  |")
        #expect(run(ComposerMarkdownEditing.newline, "- a\n  ```\n  x\n  ```\n  more|") == "- a\n  ```\n  x\n  ```\n  more\n  |")
    }

    @Test func returnOnAnEmptyLineInAnItemsTextLeavesTheItem() {
        #expect(run(ComposerMarkdownEditing.newline, "- a\n  more\n  |") == "- a\n  more\n|")
        #expect(run(ComposerMarkdownEditing.newline, "10. a\n    |") == "10. a\n|")
        #expect(run(ComposerMarkdownEditing.newline, "- a\n  - b\n    |") == "- a\n  - b\n  |")
        #expect(run(ComposerMarkdownEditing.newline, "- a\n  - b\n  |") == "- a\n  - b\n|")
        #expect(run(ComposerMarkdownEditing.newline, "> - a\n>   |") == "> - a\n> |")
    }

    @Test func returnOnIndentedTextOutsideAListIsOrdinary() {
        #expect(run(ComposerMarkdownEditing.newline, "    indented|") == nil)
        #expect(run(ComposerMarkdownEditing.newline, "- a\nlazy\n  more|") == nil)
        #expect(run(ComposerMarkdownEditing.newline, "1. a\n  short|") == nil)
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

    @Test func shiftTabRestartsTheItemsLeftBehind() {
        #expect(
            run(ComposerMarkdownEditing.outdent, "1. a\n   1. x\n   2. |y\n   3. z\n2. c")
                == "1. a\n   1. x\n2. |y\n   1. z\n3. c"
        )
    }

    @Test func tabAndShiftTabCarryTheWholeSelection() {
        let indented = ComposerMarkdownEditing.indent(in: "- a\n- b\n  - c", selection: NSRange(location: 6, length: 7))
        #expect(indented == .init(text: "- a\n  - b\n    - c", selection: NSRange(location: 8, length: 9)))
        let outdented = ComposerMarkdownEditing.outdent(in: "- a\n  - b\n    - c", selection: NSRange(location: 8, length: 9))
        #expect(outdented == .init(text: "- a\n- b\n  - c", selection: NSRange(location: 6, length: 7)))
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

    // MARK: - Code inside a list item

    @Test func returnInsideAListItemsCodeKeepsItsIndent() {
        #expect(run(ComposerMarkdownEditing.newline, "- a\n  ```\n  x|\n  ```") == "- a\n  ```\n  x\n  |\n  ```")
        #expect(run(ComposerMarkdownEditing.newline, "- a\n  ```|\n  ```") == "- a\n  ```\n  |\n  ```")
        #expect(run(ComposerMarkdownEditing.newline, "- a\n  ```\n  x\n  ```|") == "- a\n  ```\n  x\n  ```\n  |")
        #expect(run(ComposerMarkdownEditing.newline, "> - a\n>   ```\n>   x|") == "> - a\n>   ```\n>   x\n>   |")
    }

    @Test func returnAfterAListItemsCodeContinuesTheList() {
        #expect(run(ComposerMarkdownEditing.newline, "- a\n  - b\n  ```\n  x\n  ```\n  - c|") == "- a\n  - b\n  ```\n  x\n  ```\n  - c\n  - |")
    }

    @Test func tabAndShiftTabAfterAListItemsCode() {
        let block = "- a\n  - b\n  ```\n  x\n  ```\n"
        #expect(run(ComposerMarkdownEditing.indent, block + "  - |c") == block + "    - |c")
        #expect(run(ComposerMarkdownEditing.outdent, block + "  - |c") == block + "- |c")
    }

    @Test func tabCarriesAnItemsCodeWithIt() {
        #expect(
            run(ComposerMarkdownEditing.indent, "- a\n- |b\n  ```\n  x\n\n  ```\n- c")
                == "- a\n  - |b\n    ```\n    x\n\n    ```\n- c"
        )
    }

    @Test func deleteAfterAListItemsCodeOutdents() {
        #expect(run(ComposerMarkdownEditing.deleteBackward, "- a\n  ```\n  x\n  ```\n  - |c") == "- a\n  ```\n  x\n  ```\n- |c")
    }

    @Test func deleteAtACodeLinesIndentJoinsTheLineAbove() {
        #expect(run(ComposerMarkdownEditing.deleteBackward, "- a\n  ```\n  x\n  |y\n  ```") == "- a\n  ```\n  x|y\n  ```")
        #expect(run(ComposerMarkdownEditing.deleteBackward, "- a\n  ```\n  x\n  y|\n  ```") == nil)
    }

    @Test func anItemsCodeKeepsAnOrderedListTogether() {
        #expect(
            run(ComposerMarkdownEditing.newline, "1. a|\n   ```\n   x\n   ```\n2. b")
                == "1. a\n2. |\n   ```\n   x\n   ```\n3. b"
        )
    }

    @Test func contentColumnFollowsTheMarkerWidth() {
        #expect(run(ComposerMarkdownEditing.indent, "- a\n- |b") == "- a\n  - |b")
        #expect(run(ComposerMarkdownEditing.indent, "* a\n* |b") == "* a\n  * |b")
        #expect(run(ComposerMarkdownEditing.indent, "1. a\n2. |b") == "1. a\n   1. |b")
        #expect(run(ComposerMarkdownEditing.indent, "10. a\n11. |b") == "10. a\n    1. |b")
        #expect(run(ComposerMarkdownEditing.indent, "- [ ] a\n- [ ] |b") == "- [ ] a\n  - [ ] |b")
    }

    @Test func nestedLevelsAddTheirContentColumns() {
        #expect(run(ComposerMarkdownEditing.indent, "1. a\n   - b\n   - |c") == "1. a\n   - b\n     - |c")
        #expect(run(ComposerMarkdownEditing.indent, "- a\n  1. b\n  2. |c") == "- a\n  1. b\n     1. |c")
    }

    @Test func anOrderedItemsCodeKeepsItsContentColumn() {
        #expect(run(ComposerMarkdownEditing.newline, "1. a\n   ```\n   x|\n   ```") == "1. a\n   ```\n   x\n   |\n   ```")
        #expect(run(ComposerMarkdownEditing.newline, "10. a\n    ```\n    x|\n    ```") == "10. a\n    ```\n    x\n    |\n    ```")
        #expect(
            run(ComposerMarkdownEditing.indent, "1. a\n2. |b\n   ```\n   x\n   ```")
                == "1. a\n   1. |b\n      ```\n      x\n      ```"
        )
        #expect(
            run(ComposerMarkdownEditing.indent, "10. a\n11. |b\n    ```\n    x\n    ```")
                == "10. a\n    1. |b\n        ```\n        x\n        ```"
        )
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

    @Test func bracketsStartATask() {
        #expect(run(ComposerMarkdownEditing.insertSpace, "[]|") == "- [ ] |")
        #expect(run(ComposerMarkdownEditing.insertSpace, "[ ]|") == "- [ ] |")
        #expect(run(ComposerMarkdownEditing.insertSpace, "> [ ]|") == "> - [ ] |")
        #expect(run(ComposerMarkdownEditing.insertSpace, "- a\n- []|b") == "- [ ] a\n- [ ] |b")
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
