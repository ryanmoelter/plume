import AppKit
import Foundation
import Testing
@testable import Plume

struct ComposerDocumentInvariantsTests {
    private static let style = ComposerTextStyle(bodySize: 14)

    private func kind(at location: Int, in storage: NSAttributedString) -> ComposerBlockKind? {
        storage.attribute(.plumeBlock, at: location, effectiveRange: nil) as? ComposerBlockKind
    }

    @Test func emptyDocumentDoesNothing() {
        let storage = NSMutableAttributedString(string: "")
        ComposerDocumentInvariants.normalize(storage, editedRange: NSRange(location: 0, length: 0), style: Self.style)
        #expect(storage.length == 0)
    }

    /// Simulates a fresh line whose block tag a caller cleared on insertion
    /// — the untagged case `normalize`'s continuation rule exists for.
    @Test func trailingNewlineGetsTheContinuationKind() {
        let storage = NSMutableAttributedString(
            string: "1. one\n",
            attributes: Self.style.attributes(for: .numbered(depth: 0, number: 1))
        )
        storage.append(NSAttributedString(string: "second item"))
        ComposerDocumentInvariants.normalize(storage, editedRange: NSRange(location: 7, length: 11), style: Self.style)

        #expect(kind(at: 7, in: storage) == .numbered(depth: 0, number: 2))
    }

    /// Inserting a newline mid-paragraph doesn't touch the characters after
    /// the caret, so the half after the break never lost its original tag —
    /// `normalize` just has to notice it's already there and keep it.
    @Test func splitCopiesKind() {
        let storage = NSMutableAttributedString(
            string: "1. one and",
            attributes: Self.style.attributes(for: .numbered(depth: 0, number: 1))
        )
        storage.replaceCharacters(in: NSRange(location: 7, length: 0), with: "\n")
        ComposerDocumentInvariants.normalize(storage, editedRange: NSRange(location: 7, length: 1), style: Self.style)

        #expect(kind(at: 0, in: storage) == .numbered(depth: 0, number: 1))
        #expect(kind(at: 8, in: storage) == .numbered(depth: 0, number: 1))
    }

    /// Deleting the newline between two paragraphs merges them into one
    /// physical paragraph. The second half's old tag is still sitting on
    /// its own characters; `normalize` overwrites it with the first half's
    /// kind, read from the merged paragraph's start.
    @Test func mergeKeepsTheFirstParagraphsKind() {
        let storage = NSMutableAttributedString()
        storage.append(NSAttributedString(
            string: "1. one",
            attributes: Self.style.attributes(for: .numbered(depth: 0, number: 1))
        ))
        storage.append(NSAttributedString(
            string: "\n",
            attributes: Self.style.attributes(for: .numbered(depth: 0, number: 1))
        ))
        storage.append(NSAttributedString(string: "second paragraph", attributes: Self.style.attributes(for: .paragraph)))
        storage.deleteCharacters(in: NSRange(location: 6, length: 1))
        ComposerDocumentInvariants.normalize(storage, editedRange: NSRange(location: 6, length: 0), style: Self.style)

        #expect(kind(at: 0, in: storage) == .numbered(depth: 0, number: 1))
        #expect(kind(at: 6, in: storage) == .numbered(depth: 0, number: 1))
    }

    /// A replacement spanning the boundary between two paragraphs removes
    /// the newline between them, so the same merge behavior applies: the
    /// surviving text takes the first paragraph's kind throughout.
    @Test func crossParagraphReplacementNormalizesToOneParagraph() {
        let storage = NSMutableAttributedString()
        storage.append(NSAttributedString(string: "## Heading", attributes: Self.style.attributes(for: .heading(2))))
        storage.append(NSAttributedString(string: "\n", attributes: Self.style.attributes(for: .heading(2))))
        storage.append(NSAttributedString(string: "body text", attributes: Self.style.attributes(for: .paragraph)))

        storage.replaceCharacters(in: NSRange(location: 7, length: 6), with: "X")
        #expect(storage.string == "## HeadXdy text")

        ComposerDocumentInvariants.normalize(storage, editedRange: NSRange(location: 7, length: 1), style: Self.style)

        #expect(kind(at: 0, in: storage) == .heading(2))
        #expect(kind(at: 8, in: storage) == .heading(2))
    }

    @Test func twoSameLanguageCodeBlocksWithDifferentBlockIDsStaySeparate() {
        let first = ComposerBlockKind.codeBlock(language: "swift")
        let second = ComposerBlockKind.codeBlock(language: "swift")
        #expect(first.kind == second.kind)
        #expect(first.blockID != second.blockID)
        #expect(first != second)
    }

    private func lists(at location: Int, in storage: NSAttributedString) -> [NSTextList] {
        (storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?.textLists ?? []
    }

    /// TextKit numbers a list from its own start, so a list that opens at 3
    /// has to say so — otherwise its markers read 1. and 2. while the same
    /// paragraphs serialize as 3. and 4.
    @Test func aListOpeningAtThreeDrawsItsMarkersFromThree() throws {
        let storage = NSMutableAttributedString(
            attributedString: ComposerDocument.attributedString(markdown: "3. three\n4. four", style: Self.style)
        )
        ComposerDocumentInvariants.renumber(storage, style: Self.style)
        ComposerParagraphStyles.apply(to: storage, style: Self.style)

        #expect(kind(at: 0, in: storage) == .numbered(depth: 0, number: 3))
        let list = try #require(lists(at: 0, in: storage).first)
        #expect(list.startingItemNumber == 3)
        // One list instance across both items is what keeps them counting up.
        #expect(lists(at: storage.length - 1, in: storage).first === list)
    }

    /// A bullet between two numbered items ends the first list. The item
    /// after it starts a new one, so it keeps its own number rather than
    /// counting on from the item above the bullet.
    @Test func aBulletRestartsTheNumberingAfterIt() throws {
        let storage = NSMutableAttributedString(
            attributedString: ComposerDocument.attributedString(markdown: "1. a\n- b\n1. c", style: Self.style)
        )
        ComposerDocumentInvariants.renumber(storage, style: Self.style)
        ComposerParagraphStyles.apply(to: storage, style: Self.style)

        let third = storage.length - 1
        #expect(kind(at: third, in: storage) == .numbered(depth: 0, number: 1))
        let list = try #require(lists(at: third, in: storage).first)
        #expect(list.startingItemNumber == 1)
    }

    @Test func renumberFixesDriftedNumbers() {
        let storage = NSMutableAttributedString()
        storage.append(NSAttributedString(
            string: "1. one",
            attributes: Self.style.attributes(for: .numbered(depth: 0, number: 1))
        ))
        storage.append(NSAttributedString(
            string: "\n",
            attributes: Self.style.attributes(for: .numbered(depth: 0, number: 1))
        ))
        storage.append(NSAttributedString(
            string: "2. two",
            attributes: Self.style.attributes(for: .numbered(depth: 0, number: 5))
        ))
        storage.append(NSAttributedString(
            string: "\n",
            attributes: Self.style.attributes(for: .numbered(depth: 0, number: 5))
        ))
        storage.append(NSAttributedString(
            string: "3. three",
            attributes: Self.style.attributes(for: .numbered(depth: 0, number: 5))
        ))

        ComposerDocumentInvariants.renumber(storage, style: Self.style)

        #expect(kind(at: 0, in: storage) == .numbered(depth: 0, number: 1))
        #expect(kind(at: 7, in: storage) == .numbered(depth: 0, number: 2))
        #expect(kind(at: 14, in: storage) == .numbered(depth: 0, number: 3))
    }
}
