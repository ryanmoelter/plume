import AppKit
import SwiftUI
import Testing
@testable import Plume

/// A session card's brief reports itself truncated only when its three-line
/// cut hides text at the width it is laid out in.
@MainActor
struct DecisionCardBriefTests {
    private final class Flag {
        var value = false
    }

    private func isTruncated(_ text: String, width: CGFloat = 300, expanded: Bool = false) async -> Bool {
        let flag = Flag()
        let binding = Binding(get: { flag.value }, set: { flag.value = $0 })
        let view = NSHostingView(rootView: DecisionCardBrief(text: text, isExpanded: expanded, isTruncated: binding))
        view.frame = CGRect(x: 0, y: 0, width: width, height: 400)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        for _ in 0..<5 {
            view.layoutSubtreeIfNeeded()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }
        return flag.value
    }

    private static let long = String(repeating: "The child should read the failing test first. ", count: 12)

    @Test func aShortBriefIsNotTruncated() async {
        #expect(await isTruncated("Fix the login test.") == false)
    }

    @Test func aLongBriefIsTruncated() async {
        #expect(await isTruncated(Self.long))
    }

    @Test func aWideColumnFitsWhatANarrowOneCuts() async {
        let text = String(repeating: "word ", count: 30)
        #expect(await isTruncated(text, width: 120))
        #expect(await isTruncated(text, width: 2000) == false)
    }

    @Test func anExpandedBriefStillReportsTheCut() async {
        #expect(await isTruncated(Self.long, expanded: true))
    }
}
