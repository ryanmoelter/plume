import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Plume

struct ReviewDocumentTests {
    static func file(_ path: String, added: Int = 2, removed: Int = 1, kind: DiffChangeKind = .modified) -> DiffFileSummary {
        DiffFileSummary(path: path, kind: kind, addedLines: added, removedLines: removed)
    }

    static func body(_ path: String, lines: [String], startingAt start: Int = 1) -> ReviewFileBody {
        let diffLines = lines.enumerated().map { offset, text in
            DiffLine(kind: .added, text: text, oldNumber: nil, newNumber: start + offset)
        }
        let hunk = DiffHunk(header: "@@ -0,0 +\(start),\(lines.count) @@", oldStart: 0, oldCount: 0, newStart: start, newCount: lines.count, lines: diffLines)
        return ReviewDocument.body(for: .text([hunk]), path: path)
    }

    static func loaded(_ path: String, lines: [String], version: Int = 1) -> ReviewContentState {
        .loaded(body(path, lines: lines), version: version)
    }

    @Test func estimatesAddedFilesAsOneHunkAndModifiedOnesWithContext() {
        #expect(ReviewDocument.estimatedRows(for: Self.file("a", added: 0, removed: 0)) == 1)
        #expect(ReviewDocument.estimatedRows(for: Self.file("a", added: 30, removed: 0, kind: .added)) == 31)
        // 24 changed lines read as two hunks of seven rows each.
        #expect(ReviewDocument.estimatedRows(for: Self.file("a", added: 20, removed: 4)) == 24 + 2 * 7)
    }

    @Test func segmentPlacesADraftAfterTheLineItEndsAt() throws {
        let comment = try #require(ReviewComment(path: "a.swift", lines: [
            DiffLine(kind: .added, text: "one", oldNumber: nil, newNumber: 1),
            DiffLine(kind: .added, text: "two", oldNumber: nil, newNumber: 2),
        ]))
        let segment = ReviewDocument.segment(
            file: Self.file("a.swift"),
            state: Self.loaded("a.swift", lines: ["one", "two", "three"]),
            collapsed: false,
            comments: [comment]
        )
        let kinds = segment.rows.map(\.identity)
        #expect(kinds == [
            .fileHeader("a.swift"),
            .hunk("a.swift", "@@ -0,0 +1,3 @@"),
            .line("a.swift", old: nil, new: 1, "one"),
            .line("a.swift", old: nil, new: 2, "two"),
            .comment(comment.id),
            .line("a.swift", old: nil, new: 3, "three"),
        ])
    }

    @Test func collapsedAndPendingFilesShowOnlyTheirHeaderAndEstimate() {
        let file = Self.file("a.swift")
        let collapsed = ReviewDocument.segment(file: file, state: Self.loaded("a.swift", lines: ["x"]), collapsed: true, comments: [])
        #expect(collapsed.rows.map(\.identity) == [.fileHeader("a.swift")])
        let pending = ReviewDocument.segment(file: file, state: nil, collapsed: false, comments: [])
        #expect(pending.rows.last?.kind == .placeholder(.pending(estimatedRows: ReviewDocument.estimatedRows(for: file))))
    }

    @Test func proseWrapsAndHasNoColumns() {
        guard case .rows(let rows, let columns) = Self.body("README.md", lines: ["a long line of prose"]) else {
            Issue.record("expected rows")
            return
        }
        #expect(columns == 0)
        #expect(rows.allSatisfy { row in
            if case .line(_, _, let wraps) = row.kind { return wraps }
            return true
        })
    }

    // MARK: Changes

    static func segment(_ path: String, lines: [String]?, collapsed: Bool = false) -> ReviewDocumentSegment {
        ReviewDocument.segment(
            file: file(path),
            state: lines.map { loaded(path, lines: $0) },
            collapsed: collapsed,
            comments: []
        )
    }

    @Test func anEditInPlaceReloadsOnlyThatRow() {
        let old = [Self.segment("a", lines: ["one", "two", "three"])]
        let new = [Self.segment("a", lines: ["one", "TWO", "three"])]
        // A changed text is a new identity, so the middle run is the same
        // length and reloads.
        #expect(ReviewDocumentChanges.between(old, new) == ReviewDocumentChanges(reloaded: [3]))
    }

    @Test func anInsertedLineReplacesTheRunItShifted() {
        let old = [Self.segment("a", lines: ["one", "three"]), Self.segment("b", lines: ["x"])]
        let new = [Self.segment("a", lines: ["one", "two", "three"]), Self.segment("b", lines: ["x"])]
        let changes = ReviewDocumentChanges.between(old, new)
        // The hunk header's counts and the later new numbers changed, so
        // only the file header survives the prefix.
        #expect(changes.removed == IndexSet(1...3))
        #expect(changes.inserted == IndexSet(1...4))
        #expect(changes.reloaded.isEmpty)
    }

    @Test func filesComingAndGoingInsertAndRemoveTheirRows() {
        let a = Self.segment("a", lines: ["one"])
        let b = Self.segment("b", lines: ["two", "three"])
        let c = Self.segment("c", lines: ["four"])
        let changes = ReviewDocumentChanges.between([a, b], [a, c])
        #expect(changes.removed == IndexSet(3..<7))
        #expect(changes.inserted == IndexSet(3..<6))
    }

    @Test func collapsingReloadsTheHeaderAndRemovesTheBody() {
        let open = Self.segment("a", lines: ["one", "two"])
        let closed = Self.segment("a", lines: ["one", "two"], collapsed: true)
        let changes = ReviewDocumentChanges.between([open], [closed])
        #expect(changes.reloaded == [0])
        #expect(changes.removed == IndexSet(1...3))
        #expect(changes.inserted.isEmpty)
    }

    @Test func aLoadReplacesTheEstimateWithLines() {
        let pending = Self.segment("a", lines: nil)
        let loaded = Self.segment("a", lines: ["one", "two"])
        let changes = ReviewDocumentChanges.between([pending], [loaded])
        #expect(changes.removed == [1])
        #expect(changes.inserted == IndexSet(1...3))
    }
}

/// The document mounted in an offscreen window: a load above the viewport
/// must not move the line the reader is looking at.
@MainActor
struct ReviewDocumentControllerTests {
    static func makeWindow(_ controller: ReviewDocumentController) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        window.contentView = controller.scrollView
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    /// Lays out and turns the run loop until the table has a view for every
    /// visible row, which it makes a pass or two after it lays out.
    static func settle(_ window: NSWindow, _ controller: ReviewDocumentController) {
        let table = controller.tableView
        let deadline = Date(timeIntervalSinceNow: 5)
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            let visible = table.rows(in: table.visibleRect)
            let made = (visible.lowerBound..<visible.upperBound).allSatisfy { table.view(atColumn: 0, row: $0, makeIfNecessary: false) != nil }
            if made { return }
        } while Date() < deadline
    }

    static var appearance: ReviewDocumentAppearance {
        ReviewDocumentAppearance(
            palette: Palette(colorScheme: .light, definitions: nil),
            font: .monospacedSystemFont(ofSize: 12, weight: .regular)
        )
    }

    @Test func aLoadAboveTheViewportKeepsTheTopLineInPlace() throws {
        let controller = ReviewDocumentController(appearance: Self.appearance)
        let window = Self.makeWindow(controller)
        defer {
            window.contentView = nil
            window.close()
        }
        let lines = (1...200).map { "line \($0)" }
        let above = ReviewDocumentTests.file("a", added: 40, removed: 0)
        let pending = ReviewDocument.segment(file: above, state: nil, collapsed: false, comments: [])
        let below = ReviewDocumentTests.segment("b", lines: lines)
        controller.setSegments([pending, below])
        window.contentView?.layoutSubtreeIfNeeded()

        let target = try #require(controller.index(of: .line("b", old: nil, new: 100, "line 100"), in: "b"))
        let clip = controller.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: controller.tableView.rect(ofRow: target).minY))
        controller.scrollView.reflectScrolledClipView(clip)
        let before = clip.bounds.minY

        let loaded = ReviewDocument.segment(
            file: above,
            state: ReviewDocumentTests.loaded("a", lines: (1...5).map { "short \($0)" }),
            collapsed: false,
            comments: []
        )
        controller.setSegments([loaded, below])

        let moved = try #require(controller.index(of: .line("b", old: nil, new: 100, "line 100"), in: "b"))
        #expect(controller.tableView.rect(ofRow: moved).minY == clip.bounds.minY)
        // The estimate was 61 rows; a hunk and five lines replaced it.
        #expect(clip.bounds.minY < before)
    }

    /// The registry lists a gutter only for a line row the table shows: not a
    /// collapsed file's lines, and not a row the table prepared beyond the
    /// visible rect while scrolling.
    @Test func onlyShownLinesKeepAGutterInTheRegistry() throws {
        let controller = ReviewDocumentController(appearance: Self.appearance)
        let window = Self.makeWindow(controller)
        defer {
            window.contentView = nil
            window.close()
        }
        window.orderFrontRegardless()
        let table = controller.tableView
        func labels() -> [String] {
            ControlRegistry.shared.entries(id: AccessibilityID.reviewDiffGutter)
                .filter { $0.entry.window === window }
                .compactMap(\.entry.label)
        }
        func shownLines() -> [String] {
            let visible = table.rows(in: table.visibleRect)
            return (visible.lowerBound..<visible.upperBound).compactMap { row -> String? in
                let item = controller.rows[row]
                guard case .line(let line, _, _) = item.kind else { return nil }
                return "\(item.path):\(line.oldNumber.map(String.init) ?? "-"):\(line.newNumber.map(String.init) ?? "-")"
            }
        }
        let long = (1...200).map { "line \($0)" }
        controller.setSegments([ReviewDocumentTests.segment("a", lines: ["one", "two", "three"]), ReviewDocumentTests.segment("b", lines: long)])
        Self.settle(window, controller)
        #expect(labels().contains { $0.hasPrefix("a:") })
        #expect(Set(labels()) == Set(shownLines()))

        controller.setSegments([ReviewDocumentTests.segment("a", lines: ["one", "two", "three"], collapsed: true), ReviewDocumentTests.segment("b", lines: long)])
        Self.settle(window, controller)
        #expect(!labels().contains { $0.hasPrefix("a:") })
        #expect(Set(labels()) == Set(shownLines()))

        table.scroll(NSPoint(x: 0, y: 2000))
        Self.settle(window, controller)
        #expect(Set(labels()) == Set(shownLines()), "registered \(labels().count), shown \(shownLines().count)")
    }

    /// A press, drag and release in the gutter: the rows under the drag tint
    /// while it lasts, the release drafts a comment on every line it covered
    /// in the file it started in, and Esc drafts nothing.
    @Test func aGutterDragDraftsACommentOnItsLines() throws {
        let controller = ReviewDocumentController(appearance: Self.appearance)
        var drafted: [(String, [Int])] = []
        controller.actions.comment = { path, lines, _ in drafted.append((path, lines.compactMap(\.newNumber))) }
        let window = Self.makeWindow(controller)
        defer {
            window.contentView = nil
            window.close()
        }
        window.orderFrontRegardless()
        controller.setSegments([ReviewDocumentTests.segment("a", lines: ["one", "two", "three"]), ReviewDocumentTests.segment("b", lines: ["four"])])
        Self.settle(window, controller)
        let table = controller.tableView
        func point(ofRow row: Int) -> NSPoint {
            table.convert(NSPoint(x: 10, y: table.rect(ofRow: row).midY), to: nil)
        }
        func event(_ type: NSEvent.EventType, row: Int) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: point(ofRow: row), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }
        // header a, hunk, one, two, three, header b, hunk, four
        controller.gutter.mouseDown(row: 2, event: try event(.leftMouseDown, row: 2))
        NSApp.sendEvent(try event(.leftMouseDragged, row: 7))
        #expect(controller.selectingRows == 2...4)
        #expect(controller.highlight(ofRow: 3) == .selecting)
        NSApp.sendEvent(try event(.leftMouseUp, row: 7))
        #expect(controller.selectingRows == nil)
        #expect(drafted.count == 1)
        #expect(drafted.first?.0 == "a" && drafted.first?.1 == [1, 2, 3])

        controller.gutter.mouseDown(row: 3, event: try event(.leftMouseDown, row: 3))
        NSApp.sendEvent(try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        )))
        #expect(controller.selectingRows == nil)
        NSApp.sendEvent(try event(.leftMouseUp, row: 3))
        #expect(drafted.count == 1)

        controller.gutter.click(row: 7, extending: false)
        #expect(drafted.last?.0 == "b" && drafted.last?.1 == [1])
    }
}
