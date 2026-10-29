import AppKit
import Foundation
import SwiftUI
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

    @Test func aLinkAfterAFencedBlockIsNotReadAsInlineCode() {
        let cache = ChatPieceCache()
        let pieces = build(
            cache,
            "```\nlet x = 1\n```\n\nSee [PLUME-1](\(issueURL)) and `x`.",
            titles: [.linear(identifier: "PLUME-1"): "Add chips"]
        )
        #expect(cache.referenceTargets == [.linear(identifier: "PLUME-1")])
        #expect(paragraphText(pieces) == "See [\(chip)Add chips](\(issueURL)) and `x`.")
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

    // MARK: - Selection and copy

    private func chipPieces() -> [ChatPiece] {
        build(ChatPieceCache(), "See [PLUME-1](\(issueURL)) now.", titles: [.linear(identifier: "PLUME-1"): "Add chips"])
    }

    @Test func theSelectableTextCountsWhatTheChipShows() throws {
        let piece = try #require(chipPieces().first)
        #expect(ChatSelectableText(piece: piece).length == piece.selectableLength)
    }

    @Test func aWholePieceCopiesItsSource() {
        let pieces = chipPieces()
        let markdown = ChatSelectionSerializer.markdown(of: pieces, selection: ChatSelectionFixtures.everything(pieces))
        #expect(markdown == "See [PLUME-1](\(issueURL)) now.")
    }

    @Test func partOfAChipCopiesTheWholeReference() throws {
        let pieces = chipPieces()
        let piece = try #require(pieces.first)
        let selection = ChatSelectionFixtures.selection(piece, ChatSelectionFixtures.range(of: "ps now", in: piece))
        #expect(ChatSelectionSerializer.markdown(of: pieces, selection: selection) == "[PLUME-1](\(issueURL)) now")
        #expect(ChatSelectionSerializer.plainText(of: pieces, selection: selection) == "Add chips now")
    }

    @Test func plainTextAndRTFCarryTheTitle() throws {
        let pieces = chipPieces()
        let everything = ChatSelectionFixtures.everything(pieces)
        #expect(ChatSelectionSerializer.plainText(of: pieces, selection: everything) == "See Add chips now.")
        let rtf = try #require(ChatSelectionSerializer.rtf(of: pieces, selection: everything))
        let attributed = try #require(NSAttributedString(rtf: rtf, documentAttributes: nil))
        #expect(attributed.string == "See Add chips now.")
        let link = attributed.attribute(.link, at: 5, effectiveRange: nil)
        #expect((link as? URL)?.absoluteString == issueURL || (link as? String) == issueURL)
    }

    // MARK: - Measurement

    @Test func aLongTitleMeasuresTallerThanItsCanonicalLabel() throws {
        let long = String(repeating: "Wrap ", count: 8)
        let titled = build(ChatPieceCache(), "[#12](https://github.com/o/r/pull/12)", titles: [.pullRequest(owner: "o", repo: "r", number: 12): long])
        let plain = build(ChatPieceCache(), "[#12](https://github.com/o/r/pull/12)")
        func height(_ pieces: [ChatPiece]) throws -> CGFloat {
            let text = try #require(paragraphText(pieces))
            let controller = NSHostingController(rootView: MarkdownBlockView(block: .paragraph(text)))
            return controller.sizeThatFits(in: CGSize(width: 200, height: CGFloat.greatestFiniteMagnitude)).height
        }
        let titledHeight = try height(titled)
        let plainHeight = try height(plain)
        #expect(titledHeight > plainHeight)
    }
}
