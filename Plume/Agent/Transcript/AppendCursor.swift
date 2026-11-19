import Foundation

/// How far a JSONL file that only grows has been read: through its last
/// newline, plus the bytes just before that point, compared on the next read
/// to tell an append from a rewrite of the same file.
nonisolated struct AppendCursor: Sendable {
    static let seamLength = 64

    /// Anything after this is a line still being written, read again whole
    /// next time.
    private(set) var consumed: UInt64 = 0
    private(set) var seam = Data()

    init() {}

    /// Splits `bytes`, which continue the file from `consumed`, after their
    /// last newline, and moves past the complete lines.
    mutating func advance(over bytes: Data) -> (complete: Data, unfinished: Data) {
        let completeLength = bytes.lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 - bytes.startIndex } ?? 0
        let complete = bytes.prefix(completeLength)
        consumed += UInt64(completeLength)
        seam = complete.count >= Self.seamLength
            ? Data(complete.suffix(Self.seamLength))
            : Data((seam + complete).suffix(Self.seamLength))
        return (complete, bytes.dropFirst(completeLength))
    }

    /// The bytes after `consumed`, or nil when the bytes before it no longer
    /// match `seam`: the file was rewritten rather than appended to.
    func appendedBytes(atPath path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let seamStart = consumed - UInt64(seam.count)
        guard (try? handle.seek(toOffset: seamStart)) != nil,
              let data = try? handle.readToEnd() ?? Data(),
              data.count >= seam.count,
              data.prefix(seam.count) == seam
        else { return nil }
        return Data(data.dropFirst(seam.count))
    }
}
