import AppKit
import SwiftUI
import Testing
@testable import Plume

/// A resolved reference in the draft becomes a chip: its trigger is hidden
/// under an icon drawn inside the composer's visible edge, the text itself
/// never changes, and a reference still being typed stays plain.
@MainActor
struct ComposerReferenceChipTests {
    private let metrics = ComposerMarkdownMetrics(fontSize: 13)
    private let palette = ReferenceChipPalette(
        colors: Palette(colorScheme: .dark, definitions: nil),
        colorScheme: .dark,
        linearStrategy: .themePalette
    )
    private let issue = MentionReference.Kind.linear(identifier: "PLUME-1")
    private let resolution = ResolvedMention(
        target: "https://linear.app/p/issue/PLUME-1",
        title: "Add chips",
        state: .linear(.started, colorHex: "#f2c94c")
    )

    private func chips(_ text: String, caret: Int? = nil) -> [ComposerReferenceChip] {
        let location = caret ?? (text as NSString).length + 1
        return ComposerReferenceChip.chips(
            in: text,
            caret: NSRange(location: location, length: 0),
            palette: palette,
            resolution: { $0 == issue ? resolution : nil }
        ).chips
    }

    private func styledView(_ text: String, chips: [ComposerReferenceChip]) -> ComposerNSTextView {
        let textView = ComposerNSTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        textView.string = text
        MarkdownComposerStyler.style(textView.textStorage!, text: text, fontSize: metrics.fontSize, references: chips.map(\.range))
        textView.markdownMetrics = metrics
        textView.referenceChips = chips
        textView.textLayoutManager?.ensureLayout(for: textView.textLayoutManager!.documentRange)
        return textView
    }

    @Test func aResolvedReferenceIsAChip() {
        let text = "See @PLUME-1 now"
        #expect(chips(text).map(\.range) == [NSRange(location: 4, length: 8)])
    }

    @Test func anUnresolvedReferenceIsMissed() {
        let found = ComposerReferenceChip.chips(
            in: "See @PLUME-2 now",
            caret: NSRange(location: 0, length: 0),
            palette: palette,
            resolution: { _ in nil }
        )
        #expect(found.chips.isEmpty)
        #expect(found.misses == [.linear(identifier: "PLUME-2")])
    }

    @Test(arguments: [8, 12])
    func aReferenceTheCaretIsInOrJustAfterStaysPlain(_ caret: Int) {
        #expect(chips("See @PLUME-1 now", caret: caret).isEmpty)
    }

    @Test func theCaretBeforeAReferenceKeepsItsChip() {
        #expect(chips("See @PLUME-1 now", caret: 4).count == 1)
    }

    @Test func theTriggerIsHiddenAndTheTextUnchanged() {
        let text = "See @PLUME-1 now"
        let view = styledView(text, chips: chips(text))
        #expect(view.textStorage?.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor == .clear)
        #expect(view.string == text)
    }

    @Test func theIconSitsInsideTheChip() throws {
        let text = "See @PLUME-1 now"
        let view = styledView(text, chips: chips(text))
        let chip = try #require(ComposerDecorations.rects(in: view, metrics: metrics).referenceChips.first)
        let rect = try #require(chip.rects.first)
        #expect(chip.rects.count == 1)
        #expect(rect.minX < chip.iconRect.minX)
        #expect(rect.contains(NSPoint(x: chip.iconRect.midX, y: chip.iconRect.midY)))
        #expect(chip.iconRect.minX >= 5)
    }

    @Test func aChipOpeningTheTextStaysInsideTheVisibleEdge() throws {
        let text = "@PLUME-1 first"
        let view = styledView(text, chips: chips(text))
        let chip = try #require(ComposerDecorations.rects(in: view, metrics: metrics).referenceChips.first)
        #expect(chip.rects.allSatisfy { $0.minX >= 5 })
        #expect(chip.iconRect.minX >= 5)
    }

    @Test func aChipDoesNotChangeTheMeasuredHeight() {
        func height(_ text: String, references: [ComposerReferenceChip]) -> CGFloat {
            let host = ScrollableComposerTextView()
            host.composerTextView.string = text
            host.composerTextView.bodyFont = metrics.body
            MarkdownComposerStyler.style(host.composerTextView.textStorage!, text: text, fontSize: metrics.fontSize, references: references.map(\.range))
            return host.contentHeight(forWidth: 400)
        }
        let text = "@PLUME-1 first"
        #expect(abs(height(text, references: chips(text)) - height(text, references: [])) < 0.5)
    }

    @Test func aChipStaysOnTextKit2() throws {
        let text = "See @PLUME-1 now"
        let view = styledView(text, chips: chips(text))
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(view.textLayoutManager != nil)
    }

    @Test func theCoordinatorChipsWhatTheResolverKnows() {
        let tabID = UUID()
        let resolver = MentionResolver(dependencies: .init(
            linearIssue: { _ in nil },
            lookUpLinear: { _ in },
            pullRequest: { _, _ in nil },
            fileIsDirectory: { _ in nil },
            homeDirectory: "/home"
        ))
        resolver.remember(resolution, for: issue, tabID: tabID)
        let coordinator = MarkdownComposerTextView.Coordinator(
            text: .constant(""),
            isFocused: .constant(false),
            onSend: {},
            placeholder: "",
            onTextChange: { _ in }
        )
        coordinator.referenceResolver = ComposerReferenceResolver(tabID: tabID, directory: nil, resolver: resolver)
        coordinator.referencePalette = palette
        let view = ComposerNSTextView()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        coordinator.apply(text: "See @PLUME-1 now", fontSize: 13, to: view)
        #expect(view.referenceChips.map(\.range) == [NSRange(location: 4, length: 8)])
        #expect(view.string == "See @PLUME-1 now")
    }
}
