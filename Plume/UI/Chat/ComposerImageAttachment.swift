import AppKit
import UniformTypeIdentifiers

/// Turns dropped or pasted payloads into the `ChatImage` form the wire and
/// the transcript both use.
///
/// The CLI accepts only the media types the API accepts, so anything else —
/// a TIFF from a screenshot, a HEIC from Photos — is re-encoded as PNG
/// rather than refused.
nonisolated enum ComposerImageAttachment {
    static let supportedMediaTypes: Set<String> = [
        "image/png", "image/jpeg", "image/gif", "image/webp"
    ]

    /// Reads every image on `pasteboard`, preferring file URLs so a dragged
    /// file keeps its original encoding instead of being rasterized.
    @MainActor
    static func images(from pasteboard: NSPasteboard) -> [ChatImage] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           !urls.isEmpty {
            let images = urls.compactMap { image(atFileURL: $0) }
            if !images.isEmpty { return images }
        }
        if let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage] {
            return images.compactMap { image(from: $0) }
        }
        return []
    }

    static func image(atFileURL url: URL) -> ChatImage? {
        guard let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .image),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return image(data: data, mediaType: type.preferredMIMEType)
    }

    /// Passes through data already in a media type the API accepts, and
    /// re-encodes anything else as PNG.
    static func image(data: Data, mediaType: String?) -> ChatImage? {
        guard !data.isEmpty else { return nil }
        if let mediaType, supportedMediaTypes.contains(mediaType) {
            return bounded(ChatImage(mediaType: mediaType, base64: data.base64EncodedString()))
        }
        guard let png = pngData(from: data) else { return nil }
        return bounded(ChatImage(mediaType: "image/png", base64: png.base64EncodedString()))
    }

    @MainActor
    static func image(from image: NSImage) -> ChatImage? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return nil }
        return bounded(ChatImage(mediaType: "image/png", base64: png.base64EncodedString()))
    }

    private static func pngData(from data: Data) -> Data? {
        guard let bitmap = NSBitmapImageRep(data: data) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// An image too large to render is also too large to send — it would
    /// blow the turn's token budget before it ever displayed.
    private static func bounded(_ image: ChatImage) -> ChatImage? {
        image.isOversized ? nil : image
    }
}
