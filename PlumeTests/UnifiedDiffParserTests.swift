import Testing
@testable import Plume

struct UnifiedDiffParserTests {
    @Test func parsesHunksWithoutRenderingPatchHeaders() {
        let diff = UnifiedDiffParser.parse(
            """
            diff --git a/a.swift b/a.swift
            --- a/a.swift
            +++ b/a.swift
            @@ -1,2 +1,2 @@
             let a = 1
            -let b = 2
            +let b = 3
            \\ No newline at end of file
            """,
            path: "/repo/a.swift"
        )

        #expect(diff.path == "/repo/a.swift")
        #expect(diff.lines == [
            .init(kind: .context, text: "let a = 1"),
            .init(kind: .removed, text: "let b = 2"),
            .init(kind: .added, text: "let b = 3")
        ])
    }

    @Test func truncatesVeryLargePatches() {
        let patch = (0...FileDiffBuilder.maxRenderedLines)
            .map { "+line \($0)" }
            .joined(separator: "\n")
        let diff = UnifiedDiffParser.parse(patch)
        #expect(diff.lines.count == FileDiffBuilder.maxRenderedLines)
        #expect(diff.truncatedLineCount == 1)
    }
}
