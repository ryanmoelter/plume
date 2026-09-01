import Testing
@testable import Plume

struct ToolCallSummaryTests {
    @Test func bashUsesTheFirstLineOfTheCommand() {
        let summary = ToolCallSummary.summary(name: "Bash", input: ["command": .string("git status")])
        #expect(summary == "Bash(git status)")
    }

    @Test func bashTakesOnlyTheFirstLineOfAMultilineCommand() {
        let summary = ToolCallSummary.summary(name: "Bash", input: ["command": .string("git status\ngit diff")])
        #expect(summary == "Bash(git status)")
    }

    @Test func bashElidesALongCommand() {
        let longCommand = String(repeating: "x", count: 100)
        let summary = ToolCallSummary.summary(name: "Bash", input: ["command": .string(longCommand)])
        #expect(summary.hasSuffix("…)"))
        #expect(summary.count < longCommand.count)
    }

    @Test func readUsesTheFileBasename() {
        let summary = ToolCallSummary.summary(
            name: "Read", input: ["file_path": .string("/Users/me/Plume/CLAUDE.md")]
        )
        #expect(summary == "Read(CLAUDE.md)")
    }

    @Test func writeUsesTheFileBasename() {
        let summary = ToolCallSummary.summary(
            name: "Write", input: ["file_path": .string("/tmp/out.swift")]
        )
        #expect(summary == "Write(out.swift)")
    }

    @Test func editUsesTheFileBasename() {
        let summary = ToolCallSummary.summary(
            name: "Edit", input: ["file_path": .string("/tmp/out.swift")]
        )
        #expect(summary == "Edit(out.swift)")
    }

    @Test func grepUsesThePattern() {
        let summary = ToolCallSummary.summary(name: "Grep", input: ["pattern": .string("TODO")])
        #expect(summary == "Grep(TODO)")
    }

    @Test func globUsesThePattern() {
        let summary = ToolCallSummary.summary(name: "Glob", input: ["pattern": .string("**/*.swift")])
        #expect(summary == "Glob(**/*.swift)")
    }

    @Test func agentCombinesSubagentTypeAndDescription() {
        let summary = ToolCallSummary.summary(
            name: "Agent",
            input: ["subagent_type": .string("Explore"), "description": .string("find the parser")]
        )
        #expect(summary == "Agent(Explore: find the parser)")
    }

    @Test func skillUsesTheSkillName() {
        let summary = ToolCallSummary.summary(name: "Skill", input: ["skill": .string("debug")])
        #expect(summary == "Skill(debug)")
    }

    @Test func webFetchUsesTheURLHost() {
        let summary = ToolCallSummary.summary(
            name: "WebFetch", input: ["url": .string("https://docs.swift.org/reference")]
        )
        #expect(summary == "WebFetch(docs.swift.org)")
    }

    @Test func unknownToolsFallBackToTheBareName() {
        let summary = ToolCallSummary.summary(name: "SomeFutureTool", input: [:])
        #expect(summary == "SomeFutureTool")
    }

    @Test func missingExpectedInputFallsBackToTheBareName() {
        let summary = ToolCallSummary.summary(name: "Bash", input: [:])
        #expect(summary == "Bash")
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
