import Foundation
import Testing
@testable import Plume

@MainActor
struct CodexImageTests {
    private let pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9GQAAAAASUVORK5CYII="

    @Test func userDataImageUsesSharedRendererAndRemoteURLStaysVisible() throws {
        let store = CodexItemStore(), tab = UUID()
        store.replace(tabID: tab, items: [.object([
            "id": .string("user"), "type": .string("userMessage"), "content": .array([
                .object(["type": .string("image"), "url": .string("data:image/png;base64," + pixel)]),
                .object(["type": .string("image"), "url": .string("https://example.invalid/image.png")])
            ])
        ])])
        let blocks = try #require(store.transcript(forTab: tab)?.messages.first?.blocks)
        #expect(blocks[0] == .image(ChatImage(mediaType: "image/png", base64: pixel)))
        #expect(blocks[1] == .injected(.systemNote, text: "Image unavailable: https://example.invalid/image.png"))
    }

    @Test func localImagesAreBoundedAndMissingFilesStayVisible() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(base64Encoded: pixel)!.write(to: file)
        #expect(CodexImageDecoder.local(file.path)?.base64 == pixel)
        #expect(CodexImageDecoder.url(file.absoluteString)?.base64 == pixel)
        #expect(CodexImageDecoder.local(file.path + ".missing") == nil)
        #expect(CodexImageDecoder.local("relative.png") == nil)
        let store = CodexItemStore(), tab = UUID()
        store.replace(tabID: tab, items: [.object([
            "id": .string("view"), "type": .string("imageView"), "path": .string(file.path)
        ])])
        guard case .toolCall(let call) = store.transcript(forTab: tab)?.messages.first?.blocks.first else {
            Issue.record("Expected image tool"); return
        }
        #expect(call.resultImages.first?.base64 == pixel)
    }

    @Test func mcpPixelsBecomeImagesWithoutBase64TextDump() throws {
        let input: JSONValue = .object(["content": .array([
            .object(["type": .string("text"), "text": .string("Screenshot taken")]),
            .object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string(pixel)])
        ]), "structuredContent": .object(["ok": .bool(true)])])
        let extracted = CodexImageDecoder.extracting(input)
        #expect(extracted.images == [ChatImage(mediaType: "image/png", base64: pixel)])
        #expect(extracted.text?["structuredContent"]?["ok"] == .bool(true))
        #expect(extracted.text?["content"]?.arrayValue?.first?["text"]?.stringValue == "Screenshot taken")
        #expect(extracted.text?["content"]?.arrayValue?.last == .string("[Image]"))
    }

    @Test func generatedAndDynamicImagesUseNativePayloads() throws {
        let store = CodexItemStore(), tab = UUID()
        store.replace(tabID: tab, items: [.object([
            "id": .string("generation"), "type": .string("imageGeneration"), "result": .string(pixel)
        ]), .object([
            "id": .string("dynamic"), "type": .string("dynamicToolCall"), "tool": .string("snapshot"),
            "contentItems": .array([.object(["type": .string("inputImage"), "imageUrl": .string("data:image/png;base64," + pixel)])])
        ])])
        let messages = try #require(store.transcript(forTab: tab)?.messages)
        #expect(messages.count == 2)
        for message in messages {
            guard case .toolCall(let call) = message.blocks.first else { Issue.record("Expected tool"); continue }
            #expect(call.resultImages.first?.base64 == pixel)
            #expect(call.result?.contains(pixel) != true)
        }
    }

    @Test func localCacheAvoidsRepeatedReadsAndInvalidatesChangedMetadata() {
        let cache = CodexImageDecoder.LocalCache()
        let date = Date(timeIntervalSince1970: 1)
        var reads = 0
        func load() -> ChatImage? {
            reads += 1
            return ChatImage(mediaType: "image/png", base64: pixel)
        }
        _ = cache.image(path: "/image.png", modified: date, size: 10, load: load)
        _ = cache.image(path: "/image.png", modified: date, size: 10, load: load)
        #expect(reads == 1)
        _ = cache.image(path: "/image.png", modified: date.addingTimeInterval(1), size: 10, load: load)
        _ = cache.image(path: "/image.png", modified: date.addingTimeInterval(1), size: 11, load: load)
        #expect(reads == 3)
    }

    @Test func localCacheEvictsByMemoryAndKeepsRecentlyUsedImages() {
        let cache = CodexImageDecoder.LocalCache(countLimit: 3, byteLimit: 8)
        let date = Date(timeIntervalSince1970: 1)
        var reads = 0
        func read(_ path: String) {
            _ = cache.image(path: path, modified: date, size: 3) {
                reads += 1
                return ChatImage(mediaType: "image/png", base64: "AAAA")
            }
        }
        read("a"); read("b"); read("a"); read("c")
        #expect(reads == 3)
        read("a")
        #expect(reads == 3)
        read("b")
        #expect(reads == 4)
    }

    @Test func invalidImageBytesReachTheVisibleDecodePlaceholder() throws {
        let image = try #require(CodexImageDecoder.url("data:image/png;base64,bm90IGFuIGltYWdl"))
        #expect(ChatImageCache.image(for: image) == nil)
        #expect(!image.isOversized)
        // ChatImageView renders “Image could not be decoded” for this state.
        let store = CodexItemStore(), tab = UUID()
        store.replace(tabID: tab, items: [.object([
            "id": .string("invalid"), "type": .string("userMessage"),
            "content": .array([.object(["type": .string("image"),
                "url": .string("data:image/png;base64,bm90IGFuIGltYWdl")])])
        ])])
        #expect(store.transcript(forTab: tab)?.messages.first?.blocks == [.image(image)])
    }

}
