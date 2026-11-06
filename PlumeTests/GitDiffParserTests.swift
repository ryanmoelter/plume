import Foundation
import Testing
@testable import Plume

struct GitDiffParserTests {
    @Test func nameStatusReadsRenamesAsOldThenNew() {
        let output = "M\0a.txt\0R087\0old name.txt\0new name.txt\0D\0gone.txt\0A\0fresh.txt\0"
        let entries = GitDiffParser.nameStatus(output)
        #expect(entries == [
            .init(status: "M", path: "a.txt", oldPath: nil),
            .init(status: "R", path: "new name.txt", oldPath: "old name.txt"),
            .init(status: "D", path: "gone.txt", oldPath: nil),
            .init(status: "A", path: "fresh.txt", oldPath: nil),
        ])
    }

    @Test func numstatKeysRenamesByNewPathAndBinaryAsNil() {
        let output = "3\t1\ta.txt\0" + "0\t0\t\0old name.txt\0new name.txt\0" + "-\t-\timage.png\0"
        let counts = GitDiffParser.numstat(output)
        #expect(counts["a.txt"] == .init(added: 3, removed: 1))
        #expect(counts["new name.txt"] == .init(added: 0, removed: 0))
        #expect(counts["image.png"] == .init(added: nil, removed: nil))
    }

    @Test func summariesJoinStatusAndCounts() {
        let summaries = GitDiffParser.summaries(
            nameStatus: [
                .init(status: "R", path: "b", oldPath: "a"),
                .init(status: "M", path: "image.png", oldPath: nil),
            ],
            numstat: ["b": .init(added: 2, removed: 1), "image.png": .init(added: nil, removed: nil)]
        )
        #expect(summaries[0] == DiffFileSummary(path: "b", oldPath: "a", kind: .renamed, addedLines: 2, removedLines: 1))
        #expect(summaries[1] == DiffFileSummary(path: "image.png", kind: .modified, isBinary: true))
    }

    @Test func hunkHeaderTreatsAnOmittedCountAsOne() {
        let header = GitDiffParser.hunkHeader("@@ -3 +3,2 @@ func x()")
        #expect(header == .init(oldStart: 3, oldCount: 1, newStart: 3, newCount: 2))
    }

    @Test func patchNumbersLinesOnBothSides() throws {
        let patch = """
        diff --git a/x.swift b/x.swift
        index 1111111..2222222 100644
        --- a/x.swift
        +++ b/x.swift
        @@ -1,3 +1,3 @@ struct X
         let a = 1
        -let b = 2
        +let b = 22
         let c = 3
        @@ -10,2 +10,3 @@
         one
        +two
         three

        """
        guard case .text(let hunks) = GitDiffParser.patch(patch) else {
            Issue.record("expected text")
            return
        }
        #expect(hunks.count == 2)
        #expect(hunks[0].header == "@@ -1,3 +1,3 @@ struct X")
        #expect(hunks[0].lines.map(\.kind) == [.context, .removed, .added, .context])
        #expect(hunks[0].lines[1] == DiffLine(kind: .removed, text: "let b = 2", oldNumber: 2, newNumber: nil))
        #expect(hunks[0].lines[2] == DiffLine(kind: .added, text: "let b = 22", oldNumber: nil, newNumber: 2))
        #expect(hunks[0].lines[3] == DiffLine(kind: .context, text: "let c = 3", oldNumber: 3, newNumber: 3))
        #expect(hunks[1].lines.map(\.newNumber) == [10, 11, 12])
        #expect(hunks[1].lines.map(\.oldNumber) == [10, nil, 11])
    }

    @Test func contentThatLooksLikeAHeaderStaysContent() {
        let patch = """
        @@ -1,2 +1,2 @@
        -@@ -1 +1 @@
        +diff --git a/b b/b
         --- a/x
        """
        guard case .text(let hunks) = GitDiffParser.patch(patch) else {
            Issue.record("expected text")
            return
        }
        #expect(hunks.count == 1)
        #expect(hunks[0].lines.map(\.text) == ["@@ -1 +1 @@", "diff --git a/b b/b", "--- a/x"])
    }

    @Test func noNewlineMarkerAttachesToThePrecedingLine() {
        let patch = """
        @@ -1 +1 @@
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file

        """
        guard case .text(let hunks) = GitDiffParser.patch(patch) else {
            Issue.record("expected text")
            return
        }
        #expect(hunks[0].lines.map(\.missingNewline) == [true, true])
        #expect(hunks[0].lines.map(\.text) == ["old", "new"])
    }

    @Test func binaryPatchIsBinary() {
        let patch = """
        diff --git a/image.png b/image.png
        index 1111111..2222222 100644
        Binary files a/image.png and b/image.png differ

        """
        #expect(GitDiffParser.patch(patch) == .binary)
    }

    @Test func modeChangeAloneIsEmpty() {
        let patch = """
        diff --git a/run.sh b/run.sh
        old mode 100644
        new mode 100755

        """
        #expect(GitDiffParser.patch(patch) == .empty)
    }
}
