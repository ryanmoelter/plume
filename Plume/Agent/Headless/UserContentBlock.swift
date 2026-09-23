import Foundation

/// A block of a user turn on the headless wire.
///
/// A turn is always an array of these, even when it is one line of text —
/// `docs/headless-protocol.md` has the shape. Images ride as base64 in the
/// same `source` form the transcript records them in, so what Plume sends
/// and what it later reads back parse identically.
nonisolated enum UserContentBlock: Equatable {
    case text(String)
    case image(ChatImage)

    var json: JSONValue {
        switch self {
        case .text(let text):
            .object(["type": .string("text"), "text": .string(text)])
        case .image(let image):
            .object([
                "type": .string("image"),
                "source": .object([
                    "type": .string("base64"),
                    "media_type": .string(image.mediaType),
                    "data": .string(image.base64)
                ])
            ])
        }
    }
}

extension [UserContentBlock] {
    /// The text of these blocks, for the places that still describe a turn as
    /// a single string — a queued-message row, a launch message, a draft.
    var plainText: String {
        compactMap {
            if case .text(let text) = $0 { return text }
            return nil
        }.joined(separator: "\n")
    }

    var hasContent: Bool {
        contains {
            switch $0 {
            case .image: true
            case .text(let text): !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    /// Drops empty text and normalizes what remains, so a turn carrying only
    /// an image does not also send a blank text block.
    var normalized: [UserContentBlock] {
        compactMap {
            guard case .text(let text) = $0 else { return $0 }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .text(trimmed)
        }
    }
}
