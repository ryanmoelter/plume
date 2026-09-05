import Testing
import Foundation
@testable import Plume

/// Recovering what a subagent was asked to do — from its `.meta.json`
/// sidecar, and from the parent's spawning tool call when there is none.
struct SubagentDescriptorTests {
    private func data(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    @Test func theSidecarCarriesTheDescription() {
        let descriptor = SubagentMetadataReader.decode(Data(#"""
        {"agentType":"Plan","description":"Design notification layer","toolUseId":"toolu_1","spawnDepth":1}
        """#.utf8))

        #expect(descriptor?.description == "Design notification layer")
        #expect(descriptor?.agentType == "Plan")
        #expect(descriptor?.toolUseID == "toolu_1")
    }

    /// A stopped agent's sidecar can carry no description at all.
    @Test func aSidecarWithNoDescriptionStillNamesItsType() {
        let descriptor = SubagentMetadataReader.decode(Data(#"{"agentType":"Explore","stoppedByUser":true}"#.utf8))

        #expect(descriptor?.description == nil)
        #expect(descriptor?.agentType == "Explore")
        #expect(descriptor?.label(fallback: "abc") == "Explore")
    }

    @Test func anEmptySidecarDescribesNothing() {
        #expect(SubagentMetadataReader.decode(Data("{}".utf8)) == nil)
        #expect(SubagentMetadataReader.decode(Data("not json".utf8)) == nil)
    }

    @Test func theSidecarSitsBesideTheTranscript() {
        #expect(
            SubagentMetadataReader.metadataPath(forSubagentPath: "/s/subagents/agent-a1.jsonl")
                == "/s/subagents/agent-a1.meta.json"
        )
    }

    @Test func labelJoinsTypeAndDescription() {
        let descriptor = SubagentDescriptor(description: "Find the leak", agentType: "Explore")
        #expect(descriptor.label(fallback: "a1") == "Explore: Find the leak")
    }

    @Test func labelFallsBackToTheIdWhenNothingDescribesIt() {
        #expect(SubagentDescriptor().label(fallback: "a1") == "a1")
    }

    /// The `Task` call names no agent id; only its result does, so the two
    /// have to be matched through the tool_use id.
    @Test func theParentSpawnCallIsMatchedToItsAgentIDThroughTheResult() {
        let descriptors = SubagentSpawnScanner.descriptors(in: data([
            #"""
            {"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Task","input":{"description":"Explore the status engine","subagent_type":"Explore"}}]}}
            """#,
            #"""
            {"type":"user","uuid":"u1","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"Async agent launched successfully.\nagentId: a807fe56 (internal ID)"}]}}
            """#,
        ]))

        #expect(descriptors.count == 1)
        #expect(descriptors["a807fe56"]?.description == "Explore the status engine")
        #expect(descriptors["a807fe56"]?.agentType == "Explore")
        #expect(descriptors["a807fe56"]?.toolUseID == "toolu_1")
    }

    @Test func theOlderAgentToolNameIsScannedToo() {
        let descriptors = SubagentSpawnScanner.descriptors(in: data([
            #"""
            {"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_9","name":"Agent","input":{"description":"Write the tests","subagent_type":"general-purpose"}}]}}
            """#,
            #"""
            {"type":"user","uuid":"u1","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_9","content":"agentId: aaa111"}]}}
            """#,
        ]))

        #expect(descriptors["aaa111"]?.description == "Write the tests")
    }

    @Test func anUnansweredSpawnCallYieldsNoDescriptor() {
        let descriptors = SubagentSpawnScanner.descriptors(in: data([
            #"""
            {"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Task","input":{"description":"Never launched","subagent_type":"Explore"}}]}}
            """#,
        ]))

        #expect(descriptors.isEmpty)
    }

    @Test func nonSpawnToolCallsAreIgnored() {
        let descriptors = SubagentSpawnScanner.descriptors(in: data([
            #"""
            {"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"echo hi"}}]}}
            """#,
            #"""
            {"type":"user","uuid":"u1","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"hi"}]}}
            """#,
        ]))

        #expect(descriptors.isEmpty)
    }

    @Test func spawnResultsAreLookedUpByToolUseID() {
        let results = SubagentSpawnResults(parentData: data([
            #"""
            {"type":"user","uuid":"u1","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"the report"}]}}
            """#,
        ]))

        #expect(results.result(forToolUseID: "toolu_1") == "the report")
        #expect(results.result(forToolUseID: "toolu_missing") == nil)
    }

    /// Every line of a subagent's own transcript is marked `isSidechain`, so
    /// the default parse drops all of them.
    @Test func parsingASubagentTranscriptNeedsSidechainLinesIncluded() {
        let sidechain = data([
            #"{"type":"user","uuid":"u1","isSidechain":true,"message":{"role":"user","content":"go"}}"#,
            #"{"type":"assistant","uuid":"a1","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}"#,
        ])

        #expect(TranscriptParser.parse(sidechain).messages.isEmpty)
        #expect(TranscriptParser.parse(sidechain, includeSidechain: true).messages.count == 2)
    }
}
