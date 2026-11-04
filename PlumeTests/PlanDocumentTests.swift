import Foundation
import Testing
@testable import Plume

/// A plan renders as one agent message in the chat list: a piece per block,
/// every prose piece selectable, and nothing that belongs to a live turn.
@MainActor
struct PlanDocumentTests {
    private let plan = """
    # Ship the thing

    First, the reason.

    - one
    - two

    ```swift
    let x = 1
    ```
    """

    private func pieces(_ markdown: String?) throws -> [ChatPiece] {
        let messages = try #require(PlanDocument.messages(for: markdown))
        return ChatPieceCache().pieces(
            for: messages,
            status: .awaitingReply,
            hiddenToolUseIDs: [],
            dimensions: Dimensions(bodySize: 13)
        )
    }

    @Test func nothingToShowIsNoDocument() {
        #expect(PlanDocument.messages(for: nil) == nil)
        #expect(PlanDocument.messages(for: " \n\n ") == nil)
    }

    @Test func aPlanSplitsIntoSelectablePieces() throws {
        let result = try pieces(plan)
        #expect(result.count >= 5)
        #expect(result.allSatisfy { $0.messageID == PlanDocument.messageID })
        #expect(!result.contains { $0.content.isActivityIndicator })
        let prose = result.filter {
            switch $0.content {
            case .markdown, .listSegment: true
            default: false
            }
        }
        #expect(prose.count >= 4)
        #expect(prose.allSatisfy { $0.selectableLength > 0 })
    }

    @Test func anEditedPlanKeepsItsUnchangedPieces() throws {
        let before = try pieces(plan)
        let after = try pieces(plan + "\n\nA new closing line.")
        #expect(after.count == before.count + 1)
        #expect(after.map(\.id).starts(with: before.map(\.id)))
    }
}
