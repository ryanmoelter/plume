import AppKit
import SwiftUI
import Testing

@testable import Plume

/// The input rules reached the way a keyboard reaches them: key events through
/// `keyDown` and `interpretKeyEvents`, into the real `MarkdownComposerTextView`
/// hosted in a window, with its binding writing back into SwiftUI state that
/// the next update pass reads again.
@MainActor
struct ComposerHostedTypingTests {
    private final class Draft {
        var markdown = ""
    }

    private struct Host: View {
        let draft: Draft
        @State private var text = ""
        @State private var isFocused = true

        var body: some View {
            MarkdownComposerTextView(
                text: Binding(get: { text }, set: { text = $0; draft.markdown = $0 }),
                placeholder: "",
                fontSize: 13,
                isFocused: $isFocused,
                sendKey: .commandReturn,
                onSend: {}
            )
            .frame(width: 400, height: 200)
        }
    }

    private struct Harness {
        let window: NSWindow
        let view: ComposerNSTextView
        let draft: Draft

        /// Each key press gets its own main-queue turn, the way the event loop
        /// delivers them, so SwiftUI's update pass runs between keystrokes.
        func type(_ text: String) async throws {
            for character in text {
                let event = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: String(character), charactersIgnoringModifiers: String(character),
                    isARepeat: false, keyCode: character == "\r" ? 36 : character == "\u{7F}" ? 51 : 0
                ))
                view.keyDown(with: event)
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        var host: ScrollableComposerTextView? {
            view.enclosingScrollView?.superview as? ScrollableComposerTextView
        }

        /// The height the live text view lays out, insets included — what the
        /// host's measured height has to agree with.
        var liveHeight: CGFloat {
            let layoutManager = view.textLayoutManager!
            layoutManager.ensureLayout(for: layoutManager.documentRange)
            return layoutManager.usageBoundsForTextContainer.maxY + view.textContainerInset.height * 2
        }

        /// The insertion point, in text-container coordinates.
        var caretFrame: NSRect? {
            let layoutManager = view.textLayoutManager!
            guard let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
                  let location = contentStorage.location(
                      contentStorage.documentRange.location,
                      offsetBy: view.selectedRange().location
                  )
            else { return nil }
            var frame: NSRect?
            layoutManager.enumerateTextSegments(in: NSTextRange(location: location), type: .selection, options: []) { _, segment, _, _ in
                frame = segment
                return false
            }
            return frame
        }

        /// The leading edge of the character at `location`, in text-container
        /// coordinates.
        func characterMinX(at location: Int) -> CGFloat? {
            let layoutManager = view.textLayoutManager!
            guard let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
                  let start = contentStorage.location(contentStorage.documentRange.location, offsetBy: location),
                  let end = contentStorage.location(start, offsetBy: 1),
                  let range = NSTextRange(location: start, end: end)
            else { return nil }
            var minX: CGFloat?
            layoutManager.enumerateTextSegments(in: range, type: .standard, options: []) { _, segment, _, _ in
                minX = segment.minX
                return false
            }
            return minX
        }

        /// How many pixels in `rect`, in view coordinates, the view draws
        /// anything into over a white background.
        func inkedPixels(in rect: NSRect) -> Int {
            view.appearance = NSAppearance(named: .aqua)
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.white.setFill()
            view.bounds.fill()
            NSGraphicsContext.restoreGraphicsState()
            view.cacheDisplay(in: view.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / view.bounds.width
            var count = 0
            for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
                    if let color = rep.colorAt(x: x, y: y), color.brightnessComponent < 0.8 { count += 1 }
                }
            }
            return count
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
        return Harness(window: window, view: view, draft: draft)
    }

    @Test func aTypedBulletMarkerConvertsAndStaysConverted() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }

        try await harness.type("- x")

        #expect(harness.view.string == "x")
        #expect(harness.draft.markdown == "- x")
    }

    @Test func typedBoldDelimitersConvertAndStayConverted() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }

        try await harness.type("**b**")

        #expect(harness.view.string == "b")
        #expect(harness.draft.markdown == "**b**")
    }

    @Test func aTypedBreakBecomesARuleOnReturn() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }

        try await harness.type("---\rx")

        #expect(harness.view.string == "\nx")
        #expect(harness.draft.markdown == "---\n\nx")
    }

    // MARK: The character-less last line

    @Test func returnAfterAHeadingLeavesABodyHeightLine() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }

        try await harness.type("# Title\r")
        let host = try #require(harness.host)
        let afterReturn = host.contentHeight(forWidth: 400)
        #expect(abs(afterReturn - harness.liveHeight) < 0.5)

        try await harness.type("x")
        #expect(abs(host.contentHeight(forWidth: 400) - afterReturn) < 0.5)
    }

    /// The edit lays the heading out again with the caret off the empty
    /// line, which is when TextKit sizes that line from the final newline.
    @Test func editingTheHeadingAboveKeepsTheEmptyLineBodyHeight() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }

        try await harness.type("# Title\r")
        let host = try #require(harness.host)
        let afterReturn = host.contentHeight(forWidth: 400)
        harness.view.setSelectedRange(NSRange(location: 1, length: 0))
        try await harness.type("z")

        #expect(abs(host.contentHeight(forWidth: 400) - harness.liveHeight) < 0.5)
        let headingSpacing = harness.view.style.bodySize * 0.4
        #expect(host.contentHeight(forWidth: 400) <= afterReturn + headingSpacing + 0.5)
    }

    @Test(arguments: [
        (keys: "- ", marker: "•"),
        (keys: "- a\r", marker: "•"),
        (keys: "1. a\r", marker: "2"),
        (keys: "- a\r\t", marker: "◦"),
    ])
    func anEmptyLastListItemShowsItsMarkerAndIndent(keys: String, marker: String) async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }
        try await harness.type(keys)
        let view = harness.view

        let kind = try #require(view.trailingLineKind)
        let layout = try #require(view.trailingListMarker(for: kind))
        #expect(layout.fragment.textLineFragments.first?.attributedString.string.contains(marker) == true)
        let decorations = ComposerDecorations.rects(in: view, style: view.style)
        let point = try #require(decorations.trailingListMarker)

        let caret = try #require(harness.caretFrame)
        let origin = view.textContainerOrigin
        let markerArea = NSRect(x: point.x, y: caret.minY + origin.y, width: caret.minX - point.x - 2, height: caret.height)
        #expect(harness.inkedPixels(in: markerArea) > 0)

        let caretX = caret.minX
        try await harness.type("b")
        let typedX = try #require(harness.characterMinX(at: view.selectedRange().location - 1))
        #expect(abs(typedX - caretX) < 0.5)
    }

    @Test func backspaceOnAnEmptyLastBulletTakesItsMarkerAway() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }
        try await harness.type("- \u{7F}")
        let view = harness.view

        #expect(view.trailingLineKind == .paragraph)
        #expect(ComposerDecorations.rects(in: view, style: view.style).trailingListMarker == nil)
        let padding = view.textContainer?.lineFragmentPadding ?? 0
        let caret = try #require(harness.caretFrame)
        #expect(abs(caret.minX - padding) < 0.5)
    }

    @Test func anEmptyLastQuoteDrawsItsBar() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }
        try await harness.type("> ")
        let view = harness.view

        let bars = ComposerDecorations.rects(in: view, style: view.style).quoteBars
        try #require(bars.count == 1)
        let padding = view.textContainer?.lineFragmentPadding ?? 0
        #expect(abs(bars[0].minX - (view.textContainerOrigin.x + padding)) < 0.5)
        let caret = try #require(harness.caretFrame)
        #expect(abs(bars[0].minY - (caret.minY + view.textContainerOrigin.y)) < 0.5)
        #expect(abs(bars[0].height - caret.height) < 0.5)
    }

    @Test func anEmptyLastHeadingIsHeadingHeight() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }
        try await harness.type("a\r# ")
        let host = try #require(harness.host)

        #expect(abs(host.contentHeight(forWidth: 400) - harness.liveHeight) < 0.5)
        let caret = try #require(harness.caretFrame)
        #expect(caret.height > harness.view.style.body.boundingRectForFont.height * 1.5)
    }

    @Test func aTypedFenceOpensACodeBlockOnReturn() async throws {
        let harness = try await Self.makeHarness()
        defer { harness.close() }

        try await harness.type("```\rx")

        #expect(harness.view.string == "x")
        #expect(harness.draft.markdown == "```\nx\n```")
    }
}
