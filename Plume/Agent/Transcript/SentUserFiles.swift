import Foundation

/// A call to Claude Code's `SendUserFile`, which hands local files to the user
/// with an optional caption.
nonisolated struct SentUserFiles: Equatable {
    static let toolName = "SendUserFile"

    /// The tool's hint for how a file should appear.
    enum Display: Equatable {
        /// Inline, where the file can be drawn inline.
        case render
        /// As a file to open, never drawn inline.
        case attach
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp",
    ]

    let files: [URL]
    let caption: String?
    let display: Display

    init?(name: String, input: [String: JSONValue]) {
        guard name == Self.toolName else { return nil }
        files = (input["files"]?.arrayValue ?? [])
            .compactMap(\.stringValue)
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
        guard !files.isEmpty else { return nil }
        let caption = input["caption"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.caption = caption?.isEmpty == false ? caption : nil
        display = input["display"]?.stringValue == "attach" ? .attach : .render
    }

    /// The files drawn as images, in order.
    var inlineImages: [URL] {
        files.filter(showsInline)
    }

    /// The files drawn as cards, in order.
    var cards: [URL] {
        files.filter { !showsInline($0) }
    }

    /// HTML and PDF stay cards even when `render` asks otherwise: drawing
    /// either inline would mean embedding a web view or a PDF view in a row
    /// the chat measures, for a file one click opens in its own app.
    func showsInline(_ file: URL) -> Bool {
        display == .render && Self.isImage(file)
    }

    static func isImage(_ file: URL) -> Bool {
        imageExtensions.contains(file.pathExtension.lowercased())
    }
}
