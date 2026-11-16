import AppKit
import Testing
@testable import Plume

/// Restyling only the lines an edit touched leaves the storage exactly as a
/// full restyle of the same text would, across random edits to random
/// markdown: fences opening and closing, lists gaining and losing text
/// neighbors, chips, a recognized command and an active mention, and the
/// line separators that end a line but not a paragraph.
@MainActor
struct ComposerIncrementalStylingTests {
    private static let fragments = [
        "# Heading", "plain text", "**bold** and _it_", "`code`", "[link](url)", "- item", "  - nested",
        "1. one", "- [ ] task", "- [x] done", "> quote", "> > deeper", "```", "```swift", "let x = 1",
        "---", "", "@ref", "@\"My Notes.md\"", "/help", "~~gone~~", "\t", " ", "\n", "\n\n", "x",
        "\u{2028}", "- a\u{2028}- b", "\u{85}", "\r", "\r\n",
    ]

    @Test(arguments: 0..<24)
    func incrementalRestyleMatchesFullRestyle(seed: Int) {
        var random = SeededGenerator(seed: UInt64(seed))
        var text = (0..<Int.random(in: 4...30, using: &random))
            .map { _ in Self.fragments.randomElement(using: &random)! }
            .joined(separator: "\n")
        let storage = NSTextStorage(string: text)
        var snapshot = style(storage, text: text, random: &random, after: nil, unchanged: nil)
        var partialRestyles = 0

        for step in 0..<40 {
            let ns = text as NSString
            let location = Int.random(in: 0...ns.length, using: &random)
            let length = Int.random(in: 0...min(6, ns.length - location), using: &random)
            let replacement = Bool.random(using: &random) ? Self.fragments.randomElement(using: &random)! : ""
            let range = Self.composedCharacterRange(NSRange(location: location, length: length), in: ns)
            storage.replaceCharacters(in: range, with: replacement)
            var unchanged = MarkdownComposerStyler.UnchangedEnds.all
            unchanged.exclude(NSRange(location: range.location, length: (replacement as NSString).length), length: storage.length)
            text = storage.string

            var full = random
            snapshot = style(storage, text: text, random: &random, after: snapshot, unchanged: unchanged)
            let expected = NSTextStorage(string: text)
            style(expected, text: text, random: &full, after: nil, unchanged: nil)
            #expect(storage.isEqual(to: expected), "seed \(seed), step \(step): \(text.debugDescription)")
            if !storage.isEqual(to: expected) { return }
            if (snapshot?.restyled?.length ?? 0) < storage.length { partialRestyles += 1 }
        }
        #expect(partialRestyles > 0)
    }

    @Test(arguments: ["\u{2028}", "\u{85}"])
    func anEditBeforeALineSeparatorRestylesTheWholeParagraph(separator: String) {
        let text = "- a\(separator)- b\nc"
        let storage = NSTextStorage(string: text)
        var random = SeededGenerator(seed: 0)
        let first = style(storage, text: text, random: &random, after: nil, unchanged: nil, mentions: false)
        storage.replaceCharacters(in: NSRange(location: 3, length: 0), with: "x")
        var unchanged = MarkdownComposerStyler.UnchangedEnds.all
        unchanged.exclude(NSRange(location: 3, length: 1), length: storage.length)

        style(storage, text: storage.string, random: &random, after: first, unchanged: unchanged, mentions: false)

        let expected = NSTextStorage(string: storage.string)
        style(expected, text: storage.string, random: &random, after: nil, unchanged: nil, mentions: false)
        #expect(storage.isEqual(to: expected))
    }

    @Test func anEditBelowAChipLeavesTheChipsLineAlone() throws {
        let text = "See @ref here\nsecond\nthird"
        let storage = NSTextStorage(string: text)
        var random = SeededGenerator(seed: 0)
        let first = style(storage, text: text, random: &random, after: nil, unchanged: nil, mentions: false)
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "x")
        var unchanged = MarkdownComposerStyler.UnchangedEnds.all
        unchanged.exclude(NSRange(location: storage.length - 1, length: 1), length: storage.length)

        let second = try #require(style(storage, text: storage.string, random: &random, after: first, unchanged: unchanged, mentions: false))

        let restyled = try #require(second.restyled)
        #expect(restyled.location == (text as NSString).range(of: "third").location)
    }

    @discardableResult
    private func style(
        _ storage: NSTextStorage,
        text: String,
        random: inout SeededGenerator,
        after previous: MarkdownComposerStyler.Snapshot?,
        unchanged: MarkdownComposerStyler.UnchangedEnds?,
        mentions: Bool = true
    ) -> MarkdownComposerStyler.Snapshot? {
        let ns = text as NSString
        let mentionLocation = Int.random(in: 0...ns.length, using: &random)
        let mention = mentions && Bool.random(using: &random)
            ? Self.composedCharacterRange(NSRange(location: mentionLocation, length: min(3, ns.length - mentionLocation)), in: ns)
            : nil
        return MarkdownComposerStyler.style(
            storage,
            text: text,
            fontSize: 13,
            recognizedSlashCommandNames: ["help"],
            accent: .systemOrange,
            references: Self.chips(in: ns),
            activeMention: mention,
            after: previous,
            unchanged: unchanged
        )
    }

    private static func chips(in ns: NSString) -> [ComposerReferenceChip] {
        let pattern = try! NSRegularExpression(pattern: "@(\"[^\"\\n]*\"|\\w+)")
        return pattern.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)).map { match in
            // A fresh dynamic color each restyle, the way the composer's
            // theme accent arrives.
            ComposerReferenceChip(
                range: match.range,
                glyph: .symbol("circle"),
                tint: NSColor(name: nil) { _ in .red },
                wash: NSColor(name: nil) { _ in .clear },
                brand: match.range.location.isMultiple(of: 3) ? .linear : nil,
                textTint: NSColor(name: nil) { _ in .linkColor },
                title: match.range.location.isMultiple(of: 2) ? "Title" : nil
            )
        }
    }

    private static func composedCharacterRange(_ range: NSRange, in ns: NSString) -> NSRange {
        guard ns.length > 0 else { return range }
        return range.length > 0 || range.location < ns.length
            ? ns.rangeOfComposedCharacterSequences(for: range)
            : range
    }
}

/// SplitMix64, so a failing seed reproduces.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
