import AppKit
import Testing
@testable import Plume

/// Restyling only the lines an edit touched leaves the storage exactly as a
/// full restyle of the same text would, across random edits to random
/// markdown: fences opening and closing, lists gaining and losing text
/// neighbors, chips, a recognized command and an active mention.
@MainActor
struct ComposerIncrementalStylingTests {
    private static let fragments = [
        "# Heading", "plain text", "**bold** and _it_", "`code`", "[link](url)", "- item", "  - nested",
        "1. one", "- [ ] task", "- [x] done", "> quote", "> > deeper", "```", "```swift", "let x = 1",
        "---", "", "@ref", "@\"My Notes.md\"", "/help", "~~gone~~", "\t", " ", "\n", "\n\n", "x",
    ]

    @Test(arguments: 0..<24)
    func incrementalRestyleMatchesFullRestyle(seed: Int) {
        var random = SeededGenerator(seed: UInt64(seed))
        var text = (0..<Int.random(in: 4...30, using: &random))
            .map { _ in Self.fragments.randomElement(using: &random)! }
            .joined(separator: "\n")
        let storage = NSTextStorage(string: text)
        var snapshot = style(storage, text: text, random: &random, after: nil, unchanged: nil)

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
        }
    }

    @discardableResult
    private func style(
        _ storage: NSTextStorage,
        text: String,
        random: inout SeededGenerator,
        after previous: MarkdownComposerStyler.Snapshot?,
        unchanged: MarkdownComposerStyler.UnchangedEnds?
    ) -> MarkdownComposerStyler.Snapshot? {
        let ns = text as NSString
        let mentionLocation = Int.random(in: 0...ns.length, using: &random)
        let mention = Bool.random(using: &random)
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
            ComposerReferenceChip(
                range: match.range,
                glyph: .symbol("circle"),
                tint: .red,
                wash: .clear,
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
