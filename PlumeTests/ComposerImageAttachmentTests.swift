import AppKit
import Foundation
import Testing
@testable import Plume

/// Covers the pasteboard-reading half of PLUME-141: a dragged Finder file
/// and a pasted image both funnel through `images(from:)`, which
/// `ComposerNSTextView` calls from both `performDragOperation` and
/// `readSelection(from:)`. This does not exercise the drag gesture itself —
/// only that a pasteboard shaped like one produces a `ChatImage`.
@MainActor
struct ComposerImageAttachmentTests {
    @Test func fileURLPasteboardProducesImage() throws {
        let pngData = try makePNGData()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        try pngData.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])

        let images = ComposerImageAttachment.images(from: pasteboard)
        #expect(images.count == 1)
        #expect(images.first?.mediaType == "image/png")
    }

    @Test func plainImagePasteboardProducesImage() throws {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([image])

        let images = ComposerImageAttachment.images(from: pasteboard)
        #expect(images.count == 1)
        #expect(images.first?.mediaType == "image/png")
    }

    @Test func emptyPasteboardProducesNoImages() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()

        #expect(ComposerImageAttachment.images(from: pasteboard).isEmpty)
        #expect(!ComposerImageAttachment.hasImages(on: pasteboard))
    }

    /// The shape of a Finder drag: the file's URL with its name as text.
    @Test func imageFileWinsOverTextBesideIt() throws {
        let fileURL = try writeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(fileURL.absoluteString, forType: .fileURL)
        item.setString(fileURL.lastPathComponent, forType: .string)
        pasteboard.writeObjects([item])

        #expect(ComposerImageAttachment.hasImages(on: pasteboard))
        #expect(ComposerImageAttachment.images(from: pasteboard).count == 1)
    }

    @Test func textWinsOverBareImageData() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(try makePNGData(), forType: .png)
        item.setString("a snippet", forType: .string)
        pasteboard.writeObjects([item])

        #expect(!ComposerImageAttachment.hasImages(on: pasteboard))
        #expect(ComposerImageAttachment.images(from: pasteboard).isEmpty)
    }

    @Test func nonImageFileProducesNoImages() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try Data("hello".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])

        #expect(!ComposerImageAttachment.hasImages(on: pasteboard))
        #expect(ComposerImageAttachment.images(from: pasteboard).isEmpty)
    }

    private func writeTemporaryPNG() throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        try makePNGData().write(to: fileURL)
        return fileURL
    }

    private func makePNGData() throws -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw TestError.pngGenerationFailed
        }
        return png
    }

    private enum TestError: Error {
        case pngGenerationFailed
    }
}

/// Covers `ComposerNSTextView.performDragOperation` directly, bypassing
/// AppKit's real drag session (which a test host cannot synthesize — see
/// PLUME-141). This proves the override's own logic is sound; it says
/// nothing about whether a real Finder drag ever reaches it.
@MainActor
struct ComposerNSTextViewDragTests {
    @Test func performDragOperationWithImageURLCallsOnAttachImages() throws {
        let pngData = try makePNGData()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        try pngData.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])

        let textView = ComposerNSTextView()
        var attached: [ChatImage] = []
        textView.onAttachImages = { attached = $0 }

        let handled = textView.performDragOperation(FakeDraggingInfo(pasteboard: pasteboard))

        #expect(handled)
        #expect(attached.count == 1)
        #expect(attached.first?.mediaType == "image/png")
    }

    @Test func draggingEnteredClaimsAnImageFileCarryingItsName() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        try makePNGData().write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(fileURL.absoluteString, forType: .fileURL)
        item.setString(fileURL.lastPathComponent, forType: .string)
        pasteboard.writeObjects([item])

        let textView = ComposerNSTextView()
        textView.onAttachImages = { _ in }

        #expect(textView.draggingEntered(FakeDraggingInfo(pasteboard: pasteboard)) == .copy)
    }

    @Test func performDragOperationWithNoOnAttachImagesFallsThrough() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()

        let textView = ComposerNSTextView()
        // onAttachImages left nil, matching ChatTabView's plan-rejection
        // feedback field (PLUME-141 notes this gap; out of scope to fix).
        let handled = textView.performDragOperation(FakeDraggingInfo(pasteboard: pasteboard))

        // Falls through to NSTextView's own handling, which refuses an
        // empty pasteboard.
        #expect(!handled)
    }

    private func makePNGData() throws -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.green.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw TestError.pngGenerationFailed
        }
        return png
    }

    private enum TestError: Error {
        case pngGenerationFailed
    }
}

/// Minimal `NSDraggingInfo` stand-in, enough to drive
/// `performDragOperation` without a real AppKit drag session.
private final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(pasteboard: NSPasteboard) { self.draggingPasteboard = pasteboard }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation {
        get { .default }
        set {}
    }
    var animatesToDestination: Bool {
        get { false }
        set {}
    }
    var numberOfValidItemsForDrop: Int {
        get { 1 }
        set {}
    }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func draggingFrame(for view: NSView?) -> NSRect { .zero }
    func resetSpringLoading() {}
}
