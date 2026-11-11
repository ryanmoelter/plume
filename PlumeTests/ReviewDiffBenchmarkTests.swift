import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Plume

/// Timings for the review spike (PLUME-412): the engine on a large real diff,
/// and the native review document's first paint, scrolling, live update and
/// memory on that diff, in an offscreen window. Prints rather than asserts;
/// run with `TEST_RUNNER_PLUME_REVIEW_BENCH=1 xcodebuild … -only-testing:PlumeTests/ReviewDiffBenchmarkTests`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PLUME_REVIEW_BENCH"] == "1"))
struct ReviewDiffBenchmarkTests {
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

    /// A 10,000-line Swift file with every other line changed.
    private static func fixture() throws -> (root: String, file: DiffFileSummary, range: ResolvedDiffRange) {
        let root = FileManager.default.temporaryDirectory.appending(path: "plume-bench-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
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
        let range = try GitDiffEngine.resolve(.workingTree(baseRef: "main"), in: root)
        let files = try GitDiffEngine.files(in: range)
        return (root, files[0], range)
    }

    @Test func engineOnALargeDiff() throws {
        let fixture = try Self.fixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        var range: ResolvedDiffRange?
        var files: [DiffFileSummary] = []
        var content = DiffFileContent.empty
        var body = ReviewFileBody.placeholder(.empty)
        let resolve = try Self.time { range = try GitDiffEngine.resolve(.workingTree(baseRef: "main"), in: fixture.root) }
        let list = try Self.time { files = try GitDiffEngine.files(in: range!) }
        let load = try Self.time { content = try GitDiffEngine.content(for: files[0], in: range!, lineCap: nil) }
        let flatten = Self.time { body = ReviewDocument.body(for: content, path: files[0].path) }
        guard case .rows(let rows, _) = body else { throw CancellationError() }
        Self.report("REVIEW-BENCH engine: \(files[0].changedLines) changed lines, \(rows.count) rows; resolve \(resolve)ms, list \(list)ms, load+parse \(load)ms, rows+highlight \(flatten)ms")
    }

    private static func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        RunLoop.main.run(until: Date())
    }

    /// Physical footprint, the number Activity Monitor shows as Memory.
    private static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }

    @Test func nativeDocument() throws {
        let fixture = try Self.fixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let content = try GitDiffEngine.content(for: fixture.file, in: fixture.range, lineCap: nil)
        let state = ReviewContentState.loaded(ReviewDocument.body(for: content, path: fixture.file.path), version: 1)
        let segment = ReviewDocument.segment(file: fixture.file, state: state, collapsed: false, comments: [])

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
        let appearance = ReviewDocumentAppearance(
            palette: Palette(colorScheme: .light, definitions: nil),
            font: .monospacedSystemFont(ofSize: 12, weight: .regular)
        )
        let memoryBefore = Self.footprint()
        let controller = ReviewDocumentController(appearance: appearance)
        let mount = Self.time {
            controller.scrollView.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
            window.contentView = controller.scrollView
            controller.setSegments([segment])
            Self.settle(window)
        }
        let memoryPainted = Self.footprint()
        let scrollView = controller.scrollView
        let clip = scrollView.contentView
        let documentHeight = controller.tableView.frame.height

        var steps: [Double] = []
        for step in 1...60 {
            steps.append(Self.time {
                autoreleasepool {
                    clip.scroll(to: NSPoint(x: 0, y: CGFloat(step) * 300))
                    scrollView.reflectScrolledClipView(clip)
                    Self.settle(window)
                }
            })
        }
        let jump = Self.time {
            clip.scroll(to: NSPoint(x: 0, y: max(0, documentHeight - 800)))
            scrollView.reflectScrolledClipView(clip)
            Self.settle(window)
        }

        // A save that edits one line near the middle.
        var rows = segment.rows
        let middle = rows.count / 2
        if case .line(let line, _, let wraps) = rows[middle].kind {
            let edited = DiffLine(kind: line.kind, text: line.text + " edited", oldNumber: line.oldNumber, newNumber: line.newNumber)
            rows[middle] = ReviewDocumentRow(path: segment.path, kind: .line(edited, spans: [], wraps: wraps))
        }
        let editedSegment = ReviewDocumentSegment(path: segment.path, rows: rows, columns: segment.columns)
        clip.scroll(to: NSPoint(x: 0, y: controller.tableView.rect(ofRow: middle).minY - 200))
        scrollView.reflectScrolledClipView(clip)
        Self.settle(window)
        let topBefore = clip.bounds.minY
        let update = Self.time {
            controller.setSegments([editedSegment])
            Self.settle(window)
        }
        let memoryAfter = Self.footprint()

        let sorted = steps.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[Int(Double(sorted.count) * 0.95)]
        Self.report("REVIEW-BENCH native rows=\(segment.rows.count): first paint \(mount)ms, documentHeight \(documentHeight), scroll-step median \(median)ms p95 \(p95)ms max \(sorted.last ?? 0)ms, jump-to-end \(jump)ms, one-line update \(update)ms (top moved \(clip.bounds.minY - topBefore)pt), footprint +\(memoryPainted - memoryBefore)MB after first paint, +\(memoryAfter - memoryBefore)MB after scrolling, \(controller.tableView.subviews.count) row views")
    }
}
