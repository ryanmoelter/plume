import Testing
@testable import Plume

/// The collapsed one-liner: which detail each tool contributes, which face it
/// asks for, and where a long one is cut.
struct ToolCallSummaryTests {
    @Test func bashUsesTheFirstLineOfTheCommand() {
        let summary = ToolCallSummary(name: "Bash", input: ["command": .string("git status")])
        #expect(summary.detail == "git status")
        #expect(summary.detailStyle == .code)
        #expect(summary.plainText == "Bash: git status…")
    }

    @Test func bashTakesOnlyTheFirstLineOfAMultilineCommand() {
        let summary = ToolCallSummary(name: "Bash", input: ["command": .string("git status\ngit diff")])
        #expect(summary.detail == "git status")
    }

    @Test func aLongDetailIsCutAtSixtyCharactersAndTheNameIsNot() {
        let longCommand = String(repeating: "x", count: 100)
        let summary = ToolCallSummary(name: "Bash", input: ["command": .string(longCommand)])
        #expect(summary.name == "Bash")
        #expect(summary.detail?.count == 60)
    }

    @Test func aDetailAtTheLimitIsKeptWhole() {
        let command = String(repeating: "x", count: 60)
        let summary = ToolCallSummary(name: "Bash", input: ["command": .string(command)])
        #expect(summary.detail == command)
    }

    /// The marker stands for the input the row hides, so it is drawn whether
    /// or not the detail was cut.
    @Test func theTrailingMarkerIsUnconditional() {
        let short = ToolCallSummary(name: "Bash", input: ["command": .string("ls")])
        let long = ToolCallSummary(
            name: "Bash", input: ["command": .string(String(repeating: "x", count: 100))]
        )
        #expect(short.plainText.hasSuffix("…"))
        #expect(long.plainText.hasSuffix("…"))
    }

    @Test func readUsesTheFileBasename() {
        let summary = ToolCallSummary(
            name: "Read", input: ["file_path": .string("/Users/me/Plume/CLAUDE.md")]
        )
        #expect(summary.detail == "CLAUDE.md")
        #expect(summary.detailStyle == .code)
    }

    @Test func writeUsesTheFileBasename() {
        let summary = ToolCallSummary(
            name: "Write", input: ["file_path": .string("/tmp/out.swift")]
        )
        #expect(summary.detail == "out.swift")
    }

    @Test func editUsesTheFileBasename() {
        let summary = ToolCallSummary(
            name: "Edit", input: ["file_path": .string("/tmp/out.swift")]
        )
        #expect(summary.detail == "out.swift")
    }

    @Test func grepUsesThePattern() {
        let summary = ToolCallSummary(name: "Grep", input: ["pattern": .string("TODO")])
        #expect(summary.detail == "TODO")
        #expect(summary.detailStyle == .code)
    }

    @Test func globUsesThePattern() {
        let summary = ToolCallSummary(name: "Glob", input: ["pattern": .string("**/*.swift")])
        #expect(summary.detail == "**/*.swift")
        #expect(summary.detailStyle == .code)
    }

    @Test func agentCombinesSubagentTypeAndDescriptionAsProse() {
        let summary = ToolCallSummary(
            name: "Agent",
            input: ["subagent_type": .string("Explore"), "description": .string("find the parser")]
        )
        #expect(summary.detail == "Explore: find the parser")
        #expect(summary.detailStyle == .prose)
    }

    @Test func skillUsesTheSkillName() {
        let summary = ToolCallSummary(name: "Skill", input: ["skill": .string("debug")])
        #expect(summary.detail == "debug")
        #expect(summary.detailStyle == .code)
    }

    @Test func webFetchUsesTheURLHost() {
        let summary = ToolCallSummary(
            name: "WebFetch", input: ["url": .string("https://docs.swift.org/reference")]
        )
        #expect(summary.detail == "docs.swift.org")
        #expect(summary.detailStyle == .code)
    }

    @Test func unknownToolsFallBackToTheBareName() {
        let summary = ToolCallSummary(name: "SomeFutureTool", input: [:])
        #expect(summary.detail == nil)
        #expect(summary.plainText == "SomeFutureTool")
    }

    @Test func missingExpectedInputFallsBackToTheBareName() {
        let summary = ToolCallSummary(name: "Bash", input: [:])
        #expect(summary.detail == nil)
        #expect(summary.plainText == "Bash")
    }
}

struct ToolCallInputRenderingTests {
    @Test func bashRendersTheFullMultilineCommandAsShellCode() {
        let command = "git status\ngit diff --stat"
        let rendering = ToolCallInputRendering.render(
            name: "Bash",
            input: ["command": .string(command)],
            prettyJSON: "{\"command\":\"git status\\ngit diff --stat\"}"
        )
        #expect(rendering == .code(language: "sh", text: command))
    }

    /// The escaped `\n` of the JSON form never reaches the block.
    @Test func aHeredocKeepsItsRealNewlines() {
        let command = "python3 - <<'PY'\nprint(\"hi\")\nPY"
        let rendering = ToolCallInputRendering.render(
            name: "Bash",
            input: ["command": .string(command)],
            prettyJSON: "{}"
        )
        guard case .code(_, let text) = rendering else {
            Issue.record("expected shell code")
            return
        }
        #expect(text.split(separator: "\n").count == 3)
        #expect(!text.contains("\\n"))
    }

    @Test func nonBashToolsRenderAsJSON() {
        let json = "{\"file_path\":\"/tmp/out.swift\"}"
        let rendering = ToolCallInputRendering.render(
            name: "Read",
            input: ["file_path": .string("/tmp/out.swift")],
            prettyJSON: json
        )
        #expect(rendering == .json(json))
    }

    @Test func bashWithNoCommandKeyDegradesToJSON() {
        let json = "{}"
        let rendering = ToolCallInputRendering.render(name: "Bash", input: [:], prettyJSON: json)
        #expect(rendering == .json(json))
    }
}
