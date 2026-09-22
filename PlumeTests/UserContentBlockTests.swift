import Testing
import Foundation
@testable import Plume

/// The encoding of a user turn's content blocks, and the guarantee that an
/// image Plume sends reads back as the same image through the transcript
/// decoder that later renders it.
struct UserContentBlockTests {
    private static let pixel = ChatImage(
        mediaType: "image/png",
        base64: "iVBORw0KGgoAAAANSUhEUg=="
    )

    private func decodeTurn(_ line: String) throws -> [[String: JSONValue]] {
        let value = try #require(
            try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        )
        guard case .object(let root) = value,
              case .object(let message)? = root["message"],
              case .array(let content)? = message["content"]
        else {
            Issue.record("turn was not {message:{content:[…]}}")
            return []
        }
        return content.compactMap {
            if case .object(let block) = $0 { return block }
            return nil
        }
    }

    @Test
    func textOnlyTurnKeepsItsExistingShape() throws {
        let line = try #require(StreamJSONEncoder.userTurn(text: "hello"))
        let blocks = try decodeTurn(line)

        #expect(blocks.count == 1)
        #expect(blocks.first?["type"] == .string("text"))
        #expect(blocks.first?["text"] == .string("hello"))
    }

    @Test
    func textAndImageBlocksEncodeInOrder() throws {
        let line = try #require(StreamJSONEncoder.userTurn(blocks: [
            .text("look at this"),
            .image(Self.pixel)
        ]))
        let blocks = try decodeTurn(line)

        #expect(blocks.count == 2)
        #expect(blocks.first?["type"] == .string("text"))
        #expect(blocks.last?["type"] == .string("image"))

        guard case .object(let source)? = blocks.last?["source"] else {
            Issue.record("image block carried no source object")
            return
        }
        #expect(source["type"] == .string("base64"))
        #expect(source["media_type"] == .string("image/png"))
        #expect(source["data"] == .string(Self.pixel.base64))
    }

    /// The wire form and the transcript form are the same form. If they ever
    /// diverge, a sent image renders as nothing when it is read back.
    @Test
    func aSentImageDecodesAsATranscriptImageBlock() throws {
        let line = try #require(StreamJSONEncoder.userTurn(blocks: [.image(Self.pixel)]))
        let encoded = try decodeTurn(line)
        let blockData = try JSONEncoder().encode(JSONValue.object(try #require(encoded.first)))

        let block = try JSONDecoder().decode(TranscriptBlock.self, from: blockData)
        guard case .image(let image) = block else {
            Issue.record("a sent image block did not decode as .image, got \(block)")
            return
        }
        #expect(image == Self.pixel)
    }

    @Test
    func normalizingDropsBlankTextButKeepsImages() {
        let blocks: [UserContentBlock] = [.text("  \n "), .image(Self.pixel), .text(" hi ")]

        #expect(blocks.normalized == [.image(Self.pixel), .text("hi")])
    }

    @Test
    func anImageAloneCountsAsContent() {
        #expect([UserContentBlock.image(Self.pixel)].hasContent)
        #expect(![UserContentBlock.text("   ")].hasContent)
        #expect([UserContentBlock.text("x")].hasContent)
    }

    @Test
    func plainTextJoinsOnlyTheTextBlocks() {
        let blocks: [UserContentBlock] = [.text("one"), .image(Self.pixel), .text("two")]

        #expect(blocks.plainText == "one\ntwo")
    }
}
