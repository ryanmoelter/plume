import Foundation
import Testing
@testable import Plume

/// The piece cache writes each resolved reference's title into its block's
/// text, so the reveal and selection count what the chip shows, while copy
/// keeps the source as written.
@MainActor
struct ReferenceChipPieceTests {
    private let dimensions = Dimensions(bodySize: 13)
    private let issueURL = "https://linear.app/p/issue/PLUME-1/slug"
    private let chip = String(ReferenceChipText.placeholder)

    private func build(
        _ cache: ChatPieceCache,
        _ text: String,
        revision: Int = 0,
        titles: [ReferenceTarget: String] = [:]
    ) -> [ChatPiece] {
        cache.pieces(
            for: [ChatMessage(id: "a", role: .assistant, blocks: [.markdown(text)], timestamp: nil, isLive: false)],
            status: .awaitingReply,
            hiddenToolUseIDs: [],
            dimensions: dimensions,
            referenceRevision: revision,
            linkBase: URL(fileURLWithPath: "/repo"),
            referenceTitle: { titles[$0] }
        )
    }

    private func paragraphText(_ pieces: [ChatPiece]) -> String? {
        for piece in pieces {
            if case let .markdown(.paragraph(text), _) = piece.content { return text }
        }
        return nil
    }

    @Test func anUnresolvedReferenceLeavesThePiecesAsTheyWere() {
        let text = "See [PLUME-1](\(issueURL))."
        let plain = ChatPieceCache().pieces(
            for: [ChatMessage(id: "a", role: .assistant, blocks: [.markdown(text)], timestamp: nil, isLive: false)],
            status: .awaitingReply,
            hiddenToolUseIDs: [],
            dimensions: dimensions
        )
        let cache = ChatPieceCache()
        #expect(build(cache, text) == plain)
        #expect(cache.referenceTargets == [.linear(identifier: "PLUME-1")])
    }

    @Test func aResolvedReferenceIsRewrittenAndCopiesAsWritten() throws {
        let text = "See [PLUME-1](\(issueURL))."
        let pieces = build(ChatPieceCache(), text, titles: [.linear(identifier: "PLUME-1"): "Add chips"])
        #expect(paragraphText(pieces) == "See [\(chip)Add chips](\(issueURL)).")
        let piece = try #require(pieces.first { if case .markdown = $0.content { true } else { false } })
        #expect(piece.copySource == text)
        #expect(piece.selectableLength == ("See \(chip)Add chips." as NSString).length)
    }

    @Test func aRevisionBumpRewritesWithoutReparsing() {
        let cache = ChatPieceCache()
        let text = "See [PLUME-1](\(issueURL))."
        _ = build(cache, text)
        #expect(cache.parseCount == 1)
        let pieces = build(cache, text, revision: 1, titles: [.linear(identifier: "PLUME-1"): "Add chips"])
        #expect(cache.parseCount == 1)
        #expect(paragraphText(pieces) == "See [\(chip)Add chips](\(issueURL)).")
    }

    @Test func aRelativeFileLinkResolvesAgainstTheBase() {
        let cache = ChatPieceCache()
        let pieces = build(cache, "Open [App.swift](Sources/App.swift#L4).", titles: [.file(path: "/repo/Sources/App.swift"): "App.swift"])
        #expect(paragraphText(pieces) == "Open [\(chip)App.swift](Sources/App.swift#L4).")
    }
}
