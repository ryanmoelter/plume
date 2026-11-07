import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Plume

/// Timings for the review spike (PLUME-412): the engine on a large real diff,
/// and the SwiftUI diff body's first layout and scrolling in an offscreen
/// window. Prints rather than asserts; run with
/// `TEST_RUNNER_PLUME_REVIEW_BENCH=1 xcodebuild … -only-testing:PlumeTests/ReviewDiffBenchmarkTests`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PLUME_REVIEW_BENCH"] == "1"))
struct ReviewDiffBenchmarkTests {
    static let palette = CodeSyntaxPalette(palette: Palette(colorScheme: .light, definitions: nil))

    /// The test host's stdout never reaches the xcodebuild console.
    private static func report(_ line: String) {
        let url = FileManager.default.temporaryDirectory.appending(path: "plume-review-bench.txt")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }

    private static func time(_ work: () throws -> Void) rethrows -> Double {
        let start = ContinuousClock.now
        try work()
        return milliseconds(ContinuousClock.now - start)
    }

    private static func swiftLine(_ index: Int) -> String {
        "    let value\(index) = compute(\"item \(index)\", count: \(index * 3)) // note \(index)"
    }

    @Test func engineOnALargeDiff() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "plume-bench-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try GitRunner.run(["init", "-b", "main"], in: root)
        try GitRunner.run(["config", "user.email", "t@example.com"], in: root)
        try GitRunner.run(["config", "user.name", "T"], in: root)
        try GitRunner.run(["config", "commit.gpgsign", "false"], in: root)
        let lineCount = 10_000
        let old = (0..<lineCount).map(Self.swiftLine).joined(separator: "\n") + "\n"
        try old.write(toFile: "\(root)/Big.swift", atomically: true, encoding: .utf8)
        try GitRunner.run(["add", "."], in: root)
        try GitRunner.run(["commit", "-m", "init"], in: root)
        let new = (0..<lineCount).map { $0 % 2 == 0 ? Self.swiftLine($0) + " changed" : Self.swiftLine($0) }
            .joined(separator: "\n") + "\n"
        try new.write(toFile: "\(root)/Big.swift", atomically: true, encoding: .utf8)

        var range: ResolvedDiffRange?
        var files: [DiffFileSummary] = []
        var content = DiffFileContent.empty
        var rows: [ReviewDiffRow] = []
        let resolve = try Self.time { range = try GitDiffEngine.resolve(.workingTree(baseRef: "main"), in: root) }
        let list = try Self.time { files = try GitDiffEngine.files(in: range!) }
        let load = try Self.time { content = try GitDiffEngine.content(for: files[0], in: range!, lineCap: nil) }
        let flatten = Self.time { rows = ReviewDiffRow.rows(for: content, language: "swift", palette: Self.palette) }
        Self.report("REVIEW-BENCH engine: \(files[0].changedLines) changed lines, \(rows.count) rows; resolve \(resolve)ms, list \(list)ms, load+parse \(load)ms, flatten \(flatten)ms")
    }

    private static func rows(count: Int) -> [ReviewDiffRow] {
        var lines: [DiffLine] = []
        for index in 0..<count {
            switch index % 3 {
            case 0: lines.append(DiffLine(kind: .removed, text: swiftLine(index), oldNumber: index, newNumber: nil))
            case 1: lines.append(DiffLine(kind: .added, text: swiftLine(index) + " changed", oldNumber: nil, newNumber: index))
            default: lines.append(DiffLine(kind: .context, text: swiftLine(index), oldNumber: index, newNumber: index))
            }
        }
        let hunk = DiffHunk(header: "@@ -1,\(count) +1,\(count) @@", oldStart: 1, oldCount: count, newStart: 1, newCount: count, lines: lines)
        return ReviewDiffRow.rows(for: .text([hunk]), language: "swift", palette: Self.palette)
    }

    private static func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        RunLoop.main.run(until: Date())
    }

    @Test(arguments: [1_000, 5_000, 20_000])
    func swiftUIBody(rowCount: Int) async throws {
        let rows = Self.rows(count: rowCount)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.close()
        }

        let mount = Self.time {
            window.contentView = NSHostingView(rootView:
                ReviewDiffBody(rows: rows, columns: ReviewDiffRow.columns(of: rows), wraps: false)
                    .plumeTheme(bodySize: 13, setsAmbientFont: false)
                    .frame(width: 1000, height: 800)
            )
            Self.settle(window)
        }
        try await Task.sleep(for: .milliseconds(50))
        Self.settle(window)

        let content = try #require(window.contentView)
        let scrollView = try #require(ViewFinder.first(NSScrollView.self, in: content))
        let documentHeight = scrollView.documentView?.frame.height ?? 0

        var steps: [Double] = []
        let clip = scrollView.contentView
        for step in 1...60 {
            let y = CGFloat(step) * 300
            steps.append(Self.time {
                clip.scroll(to: NSPoint(x: 0, y: y))
                scrollView.reflectScrolledClipView(clip)
                Self.settle(window)
            })
        }
        let jump = Self.time {
            clip.scroll(to: NSPoint(x: 0, y: max(0, documentHeight - 800)))
            scrollView.reflectScrolledClipView(clip)
            Self.settle(window)
        }
        let sorted = steps.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[Int(Double(sorted.count) * 0.95)]
        Self.report("REVIEW-BENCH swiftui rows=\(rowCount): mount \(mount)ms, documentHeight \(documentHeight), scroll-step median \(median)ms p95 \(p95)ms max \(sorted.last ?? 0)ms, jump-to-end \(jump)ms")
    }

    /// The comparison point: a view-based `NSTableView` drawing the same rows,
    /// highlighted the same way, with cells reused as it scrolls.
    @Test(arguments: [1_000, 20_000])
    func appKitTable(rowCount: Int) throws {
        let rows = Self.rows(count: rowCount)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let source = TableSource(rows: rows)
        defer {
            window.contentView = nil
            window.close()
        }

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        let mount = Self.time {
            let table = NSTableView()
            table.addTableColumn(NSTableColumn(identifier: .init("line")))
            table.headerView = nil
            table.rowHeight = 17
            table.intercellSpacing = .zero
            table.dataSource = source
            table.delegate = source
            scrollView.documentView = table
            scrollView.hasVerticalScroller = true
            window.contentView = scrollView
            Self.settle(window)
        }
        let clip = scrollView.contentView
        var steps: [Double] = []
        for step in 1...60 {
            steps.append(Self.time {
                clip.scroll(to: NSPoint(x: 0, y: CGFloat(step) * 300))
                scrollView.reflectScrolledClipView(clip)
                Self.settle(window)
            })
        }
        let jump = Self.time {
            clip.scroll(to: NSPoint(x: 0, y: CGFloat(rowCount) * 17 - 800))
            scrollView.reflectScrolledClipView(clip)
            Self.settle(window)
        }
        let sorted = steps.sorted()
        Self.report("REVIEW-BENCH appkit rows=\(rowCount): mount \(mount)ms, scroll-step median \(sorted[sorted.count / 2])ms p95 \(sorted[Int(Double(sorted.count) * 0.95)])ms max \(sorted.last ?? 0)ms, jump-to-end \(jump)ms")
    }

    private final class TableSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let rows: [ReviewDiffRow]

        init(rows: [ReviewDiffRow]) {
            self.rows = rows
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("cell")
            let field = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField
                ?? {
                    let field = NSTextField(labelWithString: "")
                    field.identifier = identifier
                    field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                    return field
                }()
            switch rows[row].kind {
            case .hunk(let header):
                field.stringValue = header
            case .line(let line, let code):
                let prefix = "\(line.oldNumber.map(String.init) ?? "")\t\(line.newNumber.map(String.init) ?? "")\t"
                field.attributedStringValue = NSAttributedString(AttributedString(prefix) + code)
            }
            return field
        }
    }
}
