import Foundation

/// Adapts protocol images to the existing bounded transcript image renderer.
/// Remote URLs stay visible as text; parsing never makes a network request.
nonisolated enum CodexImageDecoder {
    static func inline(_ value: String?, mediaType: String = "image/png") -> ChatImage? {
        guard let value, !value.isEmpty else { return nil }
        if value.hasPrefix("data:") {
            guard let comma = value.firstIndex(of: ",") else { return nil }
            let header = String(value[value.index(value.startIndex, offsetBy: 5)..<comma])
            guard header.hasPrefix("image/"), header.hasSuffix(";base64") else { return nil }
            return ChatImage(mediaType: String(header.dropLast(7)), base64: String(value[value.index(after: comma)...]))
        }
        // Image generation's result is raw base64, unlike UserInput.image.url.
        guard !value.contains(":"), !value.contains(" "),
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || [43, 47, 61, 10, 13].contains($0) }) else { return nil }
        return ChatImage(mediaType: mediaType, base64: value)
    }

    @MainActor
    static func url(_ value: String?) -> ChatImage? {
        guard let value else { return nil }
        if value.hasPrefix("data:") { return inline(value) }
        if let url = URL(string: value), url.isFileURL { return local(url.path) }
        return nil
    }

    @MainActor
    static func local(_ path: String?) -> ChatImage? {
        guard let path, path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.intValue <= ChatImage.maxBase64Length / 4 * 3,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return localCache.image(path: url.path, modified: modified, size: size.intValue) {
            readLocal(url)
        }
    }

    @MainActor private static let localCache = LocalCache()

    private static func readLocal(_ url: URL) -> ChatImage? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: ChatImage.maxBase64Length / 4 * 3 + 1),
              !data.isEmpty, data.count <= ChatImage.maxBase64Length / 4 * 3 else { return nil }
        let type = switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "heic": "image/heic"
        default: "image/png"
        }
        return ChatImage(mediaType: type, base64: data.base64EncodedString())
    }

    /// Only encoded pixels are cached here; the shared ChatImageCache still
    /// decodes on demand. Metadata checks invalidate overwritten screenshots.
    @MainActor
    final class LocalCache {
        private struct Entry {
            let modified: Date
            let size: Int
            let image: ChatImage?
            var accessed: UInt64
        }
        private var entries: [String: Entry] = [:]
        private var clock: UInt64 = 0
        private var cost = 0
        private let countLimit: Int
        private let byteLimit: Int

        init(countLimit: Int = 24, byteLimit: Int = 32 * 1024 * 1024) {
            self.countLimit = max(1, countLimit)
            self.byteLimit = max(1, byteLimit)
        }

        func image(path: String, modified: Date, size: Int, load: () -> ChatImage?) -> ChatImage? {
            clock &+= 1
            if var entry = entries[path], entry.modified == modified, entry.size == size {
                entry.accessed = clock
                entries[path] = entry
                return entry.image
            }
            if let previous = entries.removeValue(forKey: path) { cost -= previous.image?.base64.utf8.count ?? 0 }
            let image = load()
            let imageCost = image?.base64.utf8.count ?? 0
            guard imageCost <= byteLimit else { return image }
            while entries.count >= countLimit || cost + imageCost > byteLimit {
                guard let oldest = entries.min(by: { $0.value.accessed < $1.value.accessed })?.key,
                      let removed = entries.removeValue(forKey: oldest) else { break }
                cost -= removed.image?.base64.utf8.count ?? 0
            }
            entries[path] = Entry(modified: modified, size: size, image: image, accessed: clock)
            cost += imageCost
            return image
        }
    }

    /// Remove pixel payloads from the textual result, retaining other fields
    /// and unsupported content so tool errors and metadata remain inspectable.
    @MainActor
    static func extracting(_ value: JSONValue?) -> (text: JSONValue?, images: [ChatImage]) {
        guard let value else { return (nil, []) }
        if let array = value.arrayValue {
            let parts = array.map { extracting($0) }
            return (.array(parts.compactMap(\.text)), parts.flatMap(\.images))
        }
        guard case .object(var fields) = value else { return (value, []) }
        let type = fields["type"]?.stringValue
        var image: ChatImage?
        if type == "image" {
            image = inline(fields["data"]?.stringValue, mediaType: fields["mimeType"]?.stringValue ?? "image/png")
                ?? url(fields["url"]?.stringValue)
        } else if type == "inputImage" { image = url(fields["imageUrl"]?.stringValue) }
        if let image { return (.string("[Image]"), [image]) }
        if type == "image" || type == "inputImage" {
            fields.removeValue(forKey: "data")
            for key in ["url", "imageUrl"] where fields[key]?.stringValue?.hasPrefix("data:") == true {
                fields[key] = .string("Image could not be decoded")
            }
            return (.object(fields), [])
        }
        if let content = fields["content"] {
            let extracted = extracting(content)
            fields["content"] = extracted.text
            return (.object(fields), extracted.images)
        }
        return (value, [])
    }
}
