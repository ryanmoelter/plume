import AppKit
import SwiftUI

/// Decoded images, keyed by their base64 payload.
///
/// A transcript's images are base64 in a struct the parser rebuilds on every
/// file change, and `body` runs far more often than that. Decoding there would
/// turn a scroll into a stream of megapixel decodes, so the pixels live here
/// instead — bounded like `MarkdownCache`, and for the same reason.
@MainActor
enum ChatImageCache {
    /// A screenful of thumbnails, well short of what a screenshot-heavy
    /// session accumulates.
    private static let limit = 24

    private static var cache: [String: NSImage] = [:]

    static func image(for chatImage: ChatImage) -> NSImage? {
        guard !chatImage.isOversized else { return nil }
        if let cached = cache[chatImage.base64] { return cached }
        guard let data = Data(base64Encoded: chatImage.base64, options: .ignoreUnknownCharacters),
              let image = NSImage(data: data)
        else { return nil }
        if cache.count >= limit { cache.removeAll(keepingCapacity: true) }
        cache[chatImage.base64] = image
        return image
    }

    static func reset() {
        cache.removeAll()
    }
}

/// An inline transcript image, bounded so a full-screen capture does not take
/// over the conversation. Clicking opens it at full size in Preview.
struct ChatImageView: View {
    @Environment(\.chatFontSize) private var chatFontSize

    let image: ChatImage

    var body: some View {
        if let decoded = ChatImageCache.image(for: image) {
            Image(nsImage: decoded)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 320, alignment: .leading)
                .clipShape(.rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                }
                .onTapGesture { open(decoded) }
                .help("Open at full size")
                .listItemPadding(vertical: false)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Label(
            image.isOversized ? "Image too large to show" : "Image could not be decoded",
            systemImage: "photo"
        )
        .font(.system(size: chatFontSize * 0.82))
        .foregroundStyle(.secondary)
        .listItemPadding(vertical: false)
    }

    /// A temporary file, because `NSImage` has no viewer of its own and the
    /// system one takes a URL.
    private func open(_ decoded: NSImage) {
        guard let representation = decoded.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: representation),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plume-image-\(UUID().uuidString).png")
        guard (try? png.write(to: url)) != nil else { return }
        NSWorkspace.shared.open(url)
    }
}
