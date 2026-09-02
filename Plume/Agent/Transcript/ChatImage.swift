import Foundation

/// An inline image from a transcript, kept as its undecoded base64 payload.
///
/// Decoding is deferred to the render path (`ChatImageCache`), because a
/// screenshot-heavy session holds tens of megabytes of pixels and only a
/// screenful is ever on display.
nonisolated struct ChatImage: Equatable {
    /// The largest base64 payload worth carrying. Above this the image
    /// renders as a placeholder — a transcript with a dozen full-screen
    /// captures would otherwise dominate both parse time and memory.
    static let maxBase64Length = 8 * 1024 * 1024

    let mediaType: String
    let base64: String

    var isOversized: Bool { base64.count > Self.maxBase64Length }

    /// Roughly the decoded byte count; base64 carries 3 bytes per 4 characters.
    var approximateByteCount: Int { base64.count / 4 * 3 }
}
