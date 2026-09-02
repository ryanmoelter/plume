import Foundation
import Testing

@testable import Plume

struct FileDiffTests {
    @Test func aWriteIsAllAddition() {
        let diff = FileDiffBuilder.build(path: "/tmp/x", oldText: "", newText: "one\ntwo")
        #expect(diff.addedCount == 2)
        #expect(diff.removedCount == 0)
        #expect(diff.lines.allSatisfy { $0.kind == .added })
    }

    @Test func matchingEndsBecomeContext() {
        let diff = FileDiffBuilder.build(
            path: nil,
            oldText: "a\nb\nc",
            newText: "a\nB\nc"
        )
        #expect(diff.lines.map(\.kind) == [.context, .removed, .added, .context])
        #expect(diff.lines.map(\.text) == ["a", "b", "B", "c"])
    }

    @Test func anUnchangedEditProducesNoChangedLines() {
        let diff = FileDiffBuilder.build(path: nil, oldText: "same", newText: "same")
        #expect(diff.addedCount == 0)
        #expect(diff.removedCount == 0)
    }

    @Test func pureInsertionKeepsBothEndsAsContext() {
        let diff = FileDiffBuilder.build(
            path: nil,
            oldText: "a\nc",
            newText: "a\nb\nc"
        )
        #expect(diff.addedCount == 1)
        #expect(diff.removedCount == 0)
        #expect(diff.lines.map(\.text) == ["a", "b", "c"])
    }

    @Test func pureDeletionRemovesTheMiddle() {
        let diff = FileDiffBuilder.build(path: nil, oldText: "a\nb\nc", newText: "a\nc")
        #expect(diff.removedCount == 1)
        #expect(diff.addedCount == 0)
    }

    /// A short prefix and suffix must not both claim the same line, which
    /// would produce more output lines than either side has.
    @Test func overlappingPrefixAndSuffixDoNotDoubleCount() {
        let diff = FileDiffBuilder.build(path: nil, oldText: "x", newText: "x\nx")
        #expect(diff.addedCount == 1)
        #expect(diff.removedCount == 0)
    }

    @Test func aHugeChangeIsTruncated() {
        let long = (0..<(FileDiffBuilder.maxRenderedLines + 50)).map(String.init).joined(separator: "\n")
        let diff = FileDiffBuilder.build(path: nil, oldText: "", newText: long)
        #expect(diff.lines.count == FileDiffBuilder.maxRenderedLines)
        #expect(diff.truncatedLineCount == 50)
    }

    @Test func anEditRendersAsADiff() {
        let input: [String: JSONValue] = [
            "file_path": .string("/tmp/x.swift"),
            "old_string": .string("let a = 1"),
            "new_string": .string("let a = 2"),
        ]
        let rendered = ToolCallInputRendering.render(name: "Edit", input: input, prettyJSON: "{}")
        guard case .diff(let diff) = rendered else {
            Issue.record("expected a diff, got \(rendered)")
            return
        }
        #expect(diff.path == "/tmp/x.swift")
        #expect(diff.addedCount == 1)
        #expect(diff.removedCount == 1)
    }

    @Test func aWriteRendersAsADiff() {
        let input: [String: JSONValue] = [
            "file_path": .string("/tmp/new.txt"),
            "content": .string("hello\n"),
        ]
        guard case .diff = ToolCallInputRendering.render(name: "Write", input: input, prettyJSON: "{}") else {
            Issue.record("expected a diff")
            return
        }
    }

    /// An `Edit` missing its strings has no diff to show, so it must keep the
    /// JSON rather than render an empty change.
    @Test func anEditWithoutStringsFallsBackToJSON() {
        let rendered = ToolCallInputRendering.render(
            name: "Edit",
            input: ["file_path": .string("/tmp/x")],
            prettyJSON: "{\"file_path\":\"/tmp/x\"}"
        )
        guard case .json = rendered else {
            Issue.record("expected JSON, got \(rendered)")
            return
        }
    }

    @Test func bashStillRendersAsShell() {
        let rendered = ToolCallInputRendering.render(
            name: "Bash",
            input: ["command": .string("ls -la")],
            prettyJSON: "{}"
        )
        #expect(rendered == .code(language: "sh", text: "ls -la"))
    }
}
