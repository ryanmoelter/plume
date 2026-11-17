import AppKit
import SwiftUI
import Testing

@testable import Plume

/// The markdown editing keys reached the way a keyboard reaches them: key
/// events through `keyDown` into the real `MarkdownComposerTextView` hosted in
/// a window, with its binding writing back into SwiftUI state that the next
/// update pass reads again.
@MainActor
struct ComposerHostedTypingTests {
    @Observable
    fileprivate final class Draft {
        var markdown = ""
        var width: CGFloat = 400
        var referenceResolver: ComposerReferenceResolver?
        var referencePalette: ReferenceChipPalette?
    }

    private struct Host: View {
        let draft: Draft
        @State private var isFocused = true

        var body: some View {
            var composer = MarkdownComposerTextView(
                text: Binding(get: { draft.markdown }, set: { draft.markdown = $0 }),
                placeholder: "",
                fontSize: 13,
                isFocused: $isFocused,
                sendKey: .commandReturn,
                onSend: {}
            )
            composer.referenceResolver = draft.referenceResolver
            composer.referencePalette = draft.referencePalette
            return composer.frame(width: draft.width, height: 200)
        }
    }

    @MainActor private struct Harness {
        let window: NSWindow
        let view: ComposerNSTextView
        let draft: Draft

        /// Each key press gets its own main-queue turn, the way the event loop
        /// delivers them, so SwiftUI's update pass runs between keystrokes.
        func type(_ text: String) async throws {
            for character in text {
                let keyCode: UInt16 = switch character {
                case "\r": 36
                case "\t": 48
                case "\u{7F}": 51
                default: 0
                }
                try await press(String(character), keyCode: keyCode)
            }
        }

        func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) async throws {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode
            ))
            try await handle { view.keyDown(with: event) }
        }

        /// Runs one event in its own undo group. The app's event loop closes
        /// the undo manager's per-event group after every event, and a test's
        /// run loop never does, so the harness turns `groupsByEvent` off and
        /// groups by hand.
        func handle(_ event: () -> Void) async throws {
            let manager = try #require(view.undoManager)
            manager.beginUndoGrouping()
            event()
            manager.endUndoGrouping()
            try await Task.sleep(for: .milliseconds(20))
        }

        func shiftTab() async throws {
            try await press("\u{19}", keyCode: 48, modifiers: .shift)
        }

        func left() async throws {
            try await press(String(UnicodeScalar(NSLeftArrowFunctionKey)!), keyCode: 123, modifiers: [.numericPad, .function])
        }

        func click(at point: NSPoint) async throws {
            let location = view.convert(point, to: nil)
            let event = try #require(NSEvent.mouseEvent(
                with: .leftMouseDown, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            try await handle { view.mouseDown(with: event) }
        }

        func close() {
            window.contentView = nil
            window.close()
        }
    }

    private static func makeHarness() async throws -> Harness {
        let draft = Draft()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let content = NSHostingView(rootView: Host(draft: draft))
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let view = try #require(ViewFinder.first(ComposerNSTextView.self, in: content))
        window.makeFirstResponder(view)
        view.undoManager?.groupsByEvent = false
        return Harness(window: window, view: view, draft: draft)
    }

    @Test(arguments: [
        (keys: "- a\rb", expected: "- a\n- b"),
        (keys: "1. a\rb", expected: "1. a\n2. b"),
        (keys: "- a\r\r", expected: "- a\n"),
        (keys: "- a\r\tb", expected: "- a\n  - b"),
        (keys: "1. a\r\tb", expected: "1. a\n   1. b"),
        (keys: "- \u{7F}", expected: ""),
        (keys: "> a\rb", expected: "> a\n> b"),
        (keys: "```\r- a\r", expected: "```\n- a\n\n```"),
        (keys: "- a\rx b", expected: "- [ ] a\n- [ ] b"),
        (keys: "1. a\r- b", expected: "- a\n- b"),
        (keys: "[ ] a", expected: "- [ ] a"),
    ])
    func editingKeys(keys: String, expected: String) async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }

        try await harness.type(keys)

        #expect(harness.view.string == expected)
        #expect(harness.draft.markdown == expected)
    }

    @Test func shiftTabOutdents() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }

        try await harness.type("- a\r\t")
        try await harness.shiftTab()
        try await harness.type("b")

        #expect(harness.draft.markdown == "- a\n- b")
    }

    @Test func caretSkipsAHiddenBullet() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }

        try await harness.type("a\r- b")
        try await harness.left()
        #expect(harness.view.selectedRange().location == 4)
        try await harness.left()
        #expect(harness.view.selectedRange().location == 1)
    }

    @Test func aListReturnIsOneUndoStep() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }

        try await harness.type("- a\r")
        #expect(harness.view.string == "- a\n- ")
        harness.view.undoManager?.undo()

        #expect(harness.view.string == "- a")
    }

    @Test func undoAfterAShortcutKeepsTheTypedMarker() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }

        try await harness.type("X ")
        #expect(harness.view.string == "- [ ] ")
        harness.view.undoManager?.undo()
        try await harness.type("axis")

        #expect(harness.draft.markdown == "X axis")
    }

    @Test func replacingTheTextFromOutsideClearsUndo() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }
        try await harness.type("hello world")

        harness.draft.markdown = ""
        try await Task.sleep(for: .milliseconds(50))

        #expect(harness.view.string == "")
        #expect(harness.view.undoManager?.canUndo == false)
    }

    @Test func clickingACheckboxTogglesItAsOneUndoStep() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }
        try await harness.type("- [ ] task")
        let metrics = try #require(harness.view.markdownMetrics)
        let box = try #require(ComposerDecorations.rects(in: harness.view, metrics: metrics).checkboxes.first)

        try await harness.click(at: NSPoint(x: box.rect.midX, y: box.rect.midY))
        #expect(harness.draft.markdown == "- [x] task")

        harness.view.undoManager?.undo()
        #expect(harness.view.string == "- [ ] task")
    }

    @Test func typingInAScrolledComposerKeepsItsPlace() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }
        try await harness.type("intro\r- one\rtwo\rthree\rfour\r\r1. a\rb\rc\rd\r\r> q\rr\rs\r\rpara\rpara\rpara\rlast")
        let clip = try #require(harness.view.enclosingScrollView?.contentView)
        let scrolledTo = clip.bounds.origin.y
        #expect(scrolledTo > 0)

        try await harness.type(" \u{7F}")

        #expect(clip.bounds.origin.y == scrolledTo)
    }

    @Test func typingAfterAResizeKeepsItsPlaceAndDecorations() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }
        let block = "# Heading\nA paragraph long enough to wrap once the composer is narrower than it was.\n- item\n> quote\n```\ncode\n```\n"
        harness.draft.markdown = String(repeating: block, count: 40)
        try await Task.sleep(for: .milliseconds(50))
        let view = harness.view
        let wideWidth = view.frame.width
        await withCheckedContinuation { continuation in
            view.didLayOutAllText = {
                guard view.frame.width != wideWidth else { return }
                view.didLayOutAllText = nil
                continuation.resume()
            }
            harness.draft.width = 260
        }
        #expect(view.frame.width < wideWidth)
        #expect(!view.needsFullLayout)
        let ns = view.string as NSString
        let caret = NSMaxRange(ns.range(of: "- item", options: .backwards))
        view.setSelectedRange(NSRange(location: caret, length: 0))
        view.scrollRangeToVisible(view.selectedRange())
        let clip = try #require(view.enclosingScrollView?.contentView)
        let scrolledTo = clip.bounds.origin.y
        #expect(scrolledTo > 0)

        try await harness.type("x")

        #expect(clip.bounds.origin.y == scrolledTo)
        let metrics = ComposerMarkdownMetrics(fontSize: 13)
        func decorations() -> ComposerDecorations.Decorations {
            ComposerDecorations.rects(in: view, metrics: metrics, visibleRect: view.visibleRect, structure: .init(text: view.string))
        }
        let shown = decorations()
        #expect(!shown.bullets.isEmpty)
        let layoutManager = try #require(view.textLayoutManager)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        #expect(decorations() == shown)
    }

    @Test(arguments: ["para", "- item"])
    func aNewEmptyLastLineScrollsIntoView(lastLine: String) async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }
        try await harness.type("a\rb\rc\rd\re\rf\rg\rh\ri\rj\r" + lastLine)
        let clip = try #require(harness.view.enclosingScrollView?.contentView)

        try await harness.type("\r")

        #expect(clip.bounds.maxY >= harness.view.frame.maxY - 0.5, "\(clip.bounds) vs \(harness.view.frame)")
    }

    @Test func aPasteWithIndentTabsIsOneUndoStep() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ComposerHostedTypingTests.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("- a\n\t- b", forType: .string)

        try await harness.handle { _ = harness.view.readSelection(from: pasteboard, type: .string) }
        #expect(harness.draft.markdown == "- a\n    - b")

        harness.view.undoManager?.undo()
        #expect(harness.view.string == "")
    }

    @Test func aPasteIsOneUndoStep() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ComposerHostedTypingTests.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("- a\n- b", forType: .string)

        try await harness.handle { _ = harness.view.readSelection(from: pasteboard, type: .string) }
        #expect(harness.draft.markdown == "- a\n- b")

        harness.view.undoManager?.undo()
        #expect(harness.view.string == "")
    }
}

private struct KeystrokeSample {
    var key: Duration
    var restyle: Duration
    var layout: Duration
    var decorations: Duration
    var draw: Duration
    var height: Duration
    var scroll: Duration
}

#if DEBUG
/// Times one keystroke in a long draft, split into the restyle, the layout,
/// the decoration rects a redraw needs, and the height measurement SwiftUI
/// asks for, then the redraw after a scroll. Each length runs once plain and
/// once with a resolved reference chip in every block. Opt-in: pass
/// `TEST_RUNNER_PLUME_COMPOSER_BENCH=<results file>` to `xcodebuild test`.
extension ComposerHostedTypingTests {
    private nonisolated static let benchmarkOutput = ProcessInfo.processInfo.environment["PLUME_COMPOSER_BENCH"]

    @Test(.enabled(if: benchmarkOutput != nil))
    func keystrokeCostOnLongText() async throws {
        var report: [String] = []
        for lineCount in [300, 3000] {
            for withChips in [false, true] {
                report.append(try await Self.measureKeystrokes(lineCount: lineCount, withChips: withChips))
            }
            report.append(try await Self.measureKeystrokes(lineCount: lineCount, withChips: false, nearTop: true))
            if let output = Self.benchmarkOutput {
                try report.joined(separator: "\n").write(toFile: output, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Types at the end of line 2 when `nearTop`, which lays out almost the
    /// whole text after each key, or in the middle line otherwise.
    private static func measureKeystrokes(lineCount: Int, withChips: Bool, nearTop: Bool = false) async throws -> String {
        let harness = try await makeHarness()
        defer { harness.close() }
        if withChips {
            let resolver = MentionResolver(dependencies: .init(
                linearIssue: { _ in nil },
                lookUpLinear: { _ in },
                pullRequest: { _, _ in nil },
                fileIsDirectory: { _ in nil },
                homeDirectory: "/home"
            ))
            let tabID = UUID()
            resolver.remember(
                ResolvedMention(target: "https://linear.app/p/issue/PLUME-1", title: "Add chips", state: .linear(.started, progress: .half, colorHex: "#f2c94c")),
                for: .linear(identifier: "PLUME-1"),
                tabID: tabID
            )
            harness.draft.referenceResolver = ComposerReferenceResolver(tabID: tabID, directory: nil, resolver: resolver)
            harness.draft.referencePalette = ReferenceChipPalette(
                colors: Palette(colorScheme: .dark, definitions: nil),
                colorScheme: .dark,
                linearStrategy: .themePalette
            )
        }
        let text = benchmarkText(lineCount: lineCount, withChips: withChips)
        harness.draft.markdown = text
        try await Task.sleep(for: .milliseconds(100))
        let view = harness.view
        let coordinator = try #require(view.composerCoordinator)
        let host = try #require(view.enclosingScrollView?.superview as? ScrollableComposerTextView)
        let ns = text as NSString
        let caret = nearTop
            ? NSMaxRange(ns.range(of: "## Section"))
            : NSMaxRange(ns.range(of: "Plain line after code.", range: NSRange(location: ns.length / 2, length: ns.length / 2)))
        view.setSelectedRange(NSRange(location: caret, length: 0))
        view.scrollRangeToVisible(view.selectedRange())

        let undoManager = try #require(view.undoManager)
        let clock = ContinuousClock()
        var samples: [KeystrokeSample] = []
        for round in 0..<13 {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: harness.window.windowNumber,
                context: nil, characters: "x", charactersIgnoringModifiers: "x",
                isARepeat: false, keyCode: 7
            ))
            undoManager.beginUndoGrouping()
            var start = clock.now
            view.keyDown(with: event)
            let key = clock.now - start
            undoManager.endUndoGrouping()
            start = clock.now
            view.display()
            let draw = clock.now - start
            start = clock.now
            _ = host.contentHeight(forWidth: 400)
            let height = clock.now - start
            let clip = try #require(view.enclosingScrollView?.contentView)
            clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + (round.isMultiple(of: 2) ? 30 : -30)))
            start = clock.now
            view.display()
            let scroll = clock.now - start
            if round >= 3 {
                samples.append(KeystrokeSample(
                    key: key,
                    restyle: coordinator.lastKeystrokeCost.restyle,
                    layout: coordinator.lastKeystrokeCost.layout,
                    decorations: view.lastDecorationCost,
                    draw: draw,
                    height: height,
                    scroll: scroll
                ))
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(harness.draft.markdown.count == text.count + 13)
        #expect(view.referenceChips.isEmpty != withChips)

        func median(_ value: (KeystrokeSample) -> Duration) -> String {
            let middle = samples.map(value).sorted()[samples.count / 2]
            return String(format: "%.1f ms", Double(middle.components.seconds) * 1000 + Double(middle.components.attoseconds) / 1e15)
        }
        return "lines=\(lineCount)\(withChips ? " chips" : "")\(nearTop ? " near-top" : "") key=\(median { $0.key }) restyle=\(median { $0.restyle }) layout=\(median { $0.layout }) "
            + "decorations=\(median { $0.decorations }) draw=\(median { $0.draw }) height=\(median { $0.height }) scroll=\(median { $0.scroll })"
    }

    private static func benchmarkText(lineCount: Int, withChips: Bool) -> String {
        let block = [
            withChips ? "Tracked in @PLUME-1 for now." : "Tracked in PLUME-1 for now.",
            "## Section",
            "Some paragraph text with **bold**, _italic_, `code` and a [link](https://example.com).",
            "- bullet one",
            "- bullet two with `inline`",
            "  - nested bullet",
            "1. first",
            "2. second",
            "- [ ] open task",
            "- [x] done task",
            "> quoted line",
            "> another quoted line with **bold**",
            "",
            "```swift",
            "let x = 1",
            "let y = x + 2",
            "```",
            "",
            "Plain line after code.",
            "---",
            "",
        ]
        return (0..<lineCount).map { block[$0 % block.count] }.joined(separator: "\n")
    }
}
#endif
