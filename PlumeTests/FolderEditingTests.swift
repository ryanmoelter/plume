import Testing
@testable import Plume

@MainActor
struct FolderEditingTests {
    @Test func codexOnlyOffersFolderEditingForHeadlessChats() {
        #expect(FolderEditingPolicy.canEdit(provider: .codex, transport: .headless))
        #expect(!FolderEditingPolicy.canEdit(provider: .codex, transport: .terminal))
        #expect(FolderEditingPolicy.canEdit(provider: .claudeCode, transport: .headless))
        #expect(FolderEditingPolicy.canEdit(provider: .claudeCode, transport: .terminal))
    }

    @Test func codexFolderChangesWaitForTheNextTurnWithoutRestarting() {
        let facts = FolderRestartFacts(blockers: [], canRestartNow: false, appliesOnNextTurn: true)
        #expect(facts.note == "Applies to the next turn")
        #expect(!facts.canRestartNow)

        let rows = FolderRowsInput(
            workingDirectory: "/repo",
            launchDirectory: "/repo",
            added: ["/new"],
            launched: ["/old"]
        ).rows()
        #expect(rows.first { $0.path == "/new" }?.pending == .addsAfterTurn)
        #expect(rows.first { $0.path == "/old" }?.pending == .removesAfterTurn)
    }
}
