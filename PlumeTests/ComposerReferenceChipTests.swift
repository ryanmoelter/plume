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
        MarkdownComposerStyler.style(textView.textStorage!, text: text, fontSize: metrics.fontSize, references: chips)
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
            MarkdownComposerStyler.style(host.composerTextView.textStorage!, text: text, fontSize: metrics.fontSize, references: references)
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

    // MARK: - Titles

    private let tint = NSColor(srgbRed: 0, green: 0.5, blue: 1, alpha: 1)

    private func found(_ text: String, _ resolved: [MentionReference.Kind: ResolvedMention]) -> [ComposerReferenceChip] {
        ComposerReferenceChip.chips(
            in: text,
            caret: NSRange(location: 0, length: 0),
            palette: palette,
            textTint: tint,
            resolution: { resolved[$0] }
        ).chips
    }

    @Test func anIssueAndAPullRequestShowTheirTitlesAndAFileItsName() {
        let found = found("@PLUME-1 #7 @notes.md", [
            issue: resolution,
            .pullRequest(number: 7): ResolvedMention(target: "https://github.com/o/r/pull/7", title: "Fix layout", state: .pullRequest(.open, isDraft: false)),
            .file(path: "notes.md", isDirectory: false): ResolvedMention(target: "notes.md", title: "notes.md", state: .file(isDirectory: false)),
        ])
        #expect(found.map(\.title) == ["Add chips", "Fix layout", nil])
    }

    @Test func anUntitledReferenceShowsItsIdentifier() {
        let untitled = ResolvedMention(target: "https://linear.app/p/issue/PLUME-1", title: nil, state: .linear(.started, colorHex: "#f2c94c"))
        #expect(found("@PLUME-1", [issue: untitled]).first?.title == nil)
        let text = "See @PLUME-1 now"
        let view = styledView(text, chips: found(text, [issue: untitled]))
        #expect(view.textStorage?.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor != .clear)
    }

    @Test func aLongTitleIsCutLikeTheChats() {
        let long = ResolvedMention(target: "x", title: String(repeating: "word ", count: 20), state: .linear(.started, colorHex: "#000000"))
        let title = found("@PLUME-1", [issue: long]).first?.title
        #expect(title == ReferenceChipText.truncatedTitle(String(repeating: "word ", count: 20)))
        #expect(title?.hasSuffix("…") == true)
    }

    @Test func iconsThatNameAKindTakeTheTextColor() {
        let file = MentionReference.Kind.file(path: "notes.md", isDirectory: false)
        let found = found("@PLUME-1 @notes.md", [
            issue: resolution,
            file: ResolvedMention(target: "notes.md", title: "notes.md", state: .file(isDirectory: false)),
        ])
        #expect(found.allSatisfy { $0.textTint == tint })
        #expect(found.last?.tint == tint)
        #expect(found.first?.tint != tint)
    }

    @Test func aTitledChipHidesItsWholeTokenAndLeavesTheTextAlone() {
        let text = "See @PLUME-1 now"
        let view = styledView(text, chips: found(text, [issue: resolution]))
        for location in 4..<12 {
            #expect(view.textStorage?.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor == .clear)
        }
        #expect(view.string == text)
    }

    @Test func aTitledChipHoldsItsTitleAfterItsIcons() throws {
        let text = "See @PLUME-1 now"
        let view = styledView(text, chips: found(text, [issue: resolution]))
        let chip = try #require(ComposerDecorations.rects(in: view, metrics: metrics).referenceChips.first)
        let rect = try #require(chip.rects.first)
        let title = try #require(chip.title)
        let width = MarkdownComposerStyler.titleWidth("Add chips", font: title.font)
        #expect(chip.rects.count == 1)
        #expect(title.text == "Add chips")
        #expect(title.baselineOrigin.x >= chip.iconRect.maxX)
        #expect(title.baselineOrigin.x + width <= rect.maxX)
        #expect(rect.maxX - (title.baselineOrigin.x + width) < metrics.chipPadding + 1)
        #expect(title.baselineOrigin.y > rect.midY && title.baselineOrigin.y < rect.maxY)
    }

    @Test func aTitledChipIsWiderThanItsIdentifier() throws {
        let text = "See @PLUME-1 now"
        func width(_ chips: [ComposerReferenceChip]) throws -> CGFloat {
            let view = styledView(text, chips: chips)
            return try #require(ComposerDecorations.rects(in: view, metrics: metrics, references: chips).referenceChips.first?.rects.first).width
        }
        let long = ResolvedMention(target: "x", title: "A much longer title than the identifier", state: .linear(.started, colorHex: "#000000"))
        #expect(try width(found(text, [issue: long])) > width(chips(text)) + 50)
    }

    @Test func aTitledChipAloneOnALineKeepsItsHeight() {
        func height(_ text: String, references: [ComposerReferenceChip]) -> CGFloat {
            let host = ScrollableComposerTextView()
            host.composerTextView.string = text
            host.composerTextView.bodyFont = metrics.body
            MarkdownComposerStyler.style(host.composerTextView.textStorage!, text: text, fontSize: metrics.fontSize, references: references)
            return host.contentHeight(forWidth: 400)
        }
        let text = "First line\n@PLUME-1\nlast"
        #expect(abs(height(text, references: found(text, [issue: resolution])) - height(text, references: [])) < 0.5)
    }

    // MARK: - Selection over a titled chip

    private let titled = [NSRange(location: 4, length: 8)]

    @Test func extendingASelectionIntoATitledChipTakesItWhole() {
        let forward = ComposerReferenceChip.snappedSelection(
            NSRange(location: 4, length: 1), previous: NSRange(location: 4, length: 0), titledChips: titled)
        #expect(forward == NSRange(location: 4, length: 8))
        let backward = ComposerReferenceChip.snappedSelection(
            NSRange(location: 11, length: 1), previous: NSRange(location: 12, length: 0), titledChips: titled)
        #expect(backward == NSRange(location: 4, length: 8))
    }

    @Test func shrinkingASelectionOutOfATitledChipLeavesItWhole() {
        let shrunk = ComposerReferenceChip.snappedSelection(
            NSRange(location: 4, length: 7), previous: NSRange(location: 4, length: 8), titledChips: titled)
        #expect(shrunk == NSRange(location: 4, length: 0))
        let fromLeft = ComposerReferenceChip.snappedSelection(
            NSRange(location: 5, length: 7), previous: NSRange(location: 4, length: 8), titledChips: titled)
        #expect(fromLeft == NSRange(location: 12, length: 0))
    }

    @Test func aSelectionOutsideATitledChipAndACaretAreLeftAlone() {
        let outside = NSRange(location: 0, length: 3)
        #expect(ComposerReferenceChip.snappedSelection(outside, previous: nil, titledChips: titled) == outside)
        let caret = NSRange(location: 6, length: 0)
        #expect(ComposerReferenceChip.snappedSelection(caret, previous: nil, titledChips: titled) == caret)
        let inside = NSRange(location: 6, length: 2)
        #expect(ComposerReferenceChip.snappedSelection(inside, previous: nil, titledChips: titled) == titled[0])
    }

    @Test func theTextViewSnapsASelectionOverATitledChip() {
        let text = "See @PLUME-1 now"
        let view = styledView(text, chips: found(text, [issue: resolution]))
        view.markdownMetrics = metrics
        view.setSelectedRange(NSRange(location: 4, length: 0))
        view.setSelectedRange(NSRange(location: 4, length: 1))
        #expect(view.selectedRange() == NSRange(location: 4, length: 8))
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

    /// Parks every lookup until opened, and lets a test wait for the first.
    private actor Gate {
        private var isOpen = false
        private var hasWaiter = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var watchers: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            hasWaiter = true
            for watcher in watchers { watcher.resume() }
            watchers = []
            await withCheckedContinuation { waiters.append($0) }
        }

        func firstWaiter() async {
            guard !hasWaiter else { return }
            await withCheckedContinuation { watchers.append($0) }
        }

        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters = []
        }
    }

    @Test func aReferenceWhoseLookupWasCancelledIsLookedUpAgain() async {
        let gate = Gate()
        let resolver = MentionResolver(dependencies: .init(
            linearIssue: { _ in nil },
            lookUpLinear: { _ in },
            pullRequest: { number, _ in
                await gate.wait()
                guard !Task.isCancelled else { return nil }
                return .init(number: number, title: "Pull \(number)", url: "https://github.com/o/r/pull/\(number)", state: .open, isDraft: false, updatedAt: nil)
            },
            fileIsDirectory: { _ in nil },
            homeDirectory: "/home"
        ))
        let coordinator = MarkdownComposerTextView.Coordinator(
            text: .constant(""),
            isFocused: .constant(false),
            onSend: {},
            placeholder: "",
            onTextChange: { _ in }
        )
        coordinator.referenceResolver = ComposerReferenceResolver(tabID: UUID(), directory: "/repo", resolver: resolver)
        coordinator.referencePalette = palette
        coordinator.referenceLookupDelay = .zero
        let view = ComposerNSTextView()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        coordinator.textView = view

        coordinator.apply(text: "See #12 now", fontSize: 13, to: view)
        await gate.firstWaiter()
        coordinator.apply(text: "See #12 and #13 now", fontSize: 13, to: view)
        await gate.open()
        await coordinator.referenceLookupsSettled()

        #expect(view.referenceChips.map(\.range) == [NSRange(location: 4, length: 3), NSRange(location: 12, length: 3)])
    }
}
