import Foundation
import Testing
@testable import Plume

@MainActor struct CodexSkillTests {
    @Test func catalogFiltersDisabledOtherDirectoriesAndDuplicateNames() {
        let response: JSONValue = .object(["data": .array([
            .object(["cwd": .string("/project"), "skills": .array([
                .object(["name": .string("review"), "path": .string("/skills/review/SKILL.md"), "enabled": .bool(true)]),
                .object(["name": .string("review"), "path": .string("/duplicate/SKILL.md")]),
                .object(["name": .string("disabled"), "path": .string("/disabled/SKILL.md"), "enabled": .bool(false)])
            ])]),
            .object(["cwd": .string("/other"), "skills": .array([
                .object(["name": .string("other"), "path": .string("/other/SKILL.md")])
            ])])
        ])])
        #expect(CodexSkill.decode(response, directory: "/project").map(\.name) == ["review"])
    }

    @Test func explicitSkillReferencesAttachKnownPathsOnly() {
        let skill = CodexSkill(name: "review", path: "/skills/review/SKILL.md", description: "Review")
        let inputs = CodexSkill.input(text: "$review inspect this with $unknown", skills: [skill])
        #expect(inputs.count == 2)
        #expect(inputs[1]["type"]?.stringValue == "skill")
        #expect(inputs[1]["path"]?.stringValue == skill.path)
        #expect(CodexSkill.input(text: "review $reviewer", skills: [skill]).count == 1)
    }

    @Test func dollarCompletionPreservesArgumentsAndClaudeSlashBehavior() {
        let command = SlashCommand(name: "review", description: "", argumentHint: "")
        #expect(SlashCommandMatcher.query(text: "$rev", caretLocation: 4, prefix: "$") == "rev")
        #expect(SlashCommandMatcher.query(text: "$rev", caretLocation: 4) == nil)
        #expect(SlashCommandMatcher.accepting(command, in: "$rev inspect", prefix: "$").text == "$review  inspect")
        #expect(SlashCommandMatcher.accepting(command, in: "/rev").text == "/review ")
    }
}
