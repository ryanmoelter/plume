import Foundation
import os

/// Reads hook event files, remembering how far it got.
///
/// Events are appended by hooks while Plume may be closed, so reading is
/// offset-based rather than notification-based: on startup the whole backlog
/// replays, and afterwards each change reads only what was added.
final class HookEventIngester {
    /// Files above this are truncated after a read, so a long-running session
    /// cannot grow one without bound.
    static let rotationThreshold = 1024 * 1024

    private var offsets: [URL: UInt64] = [:]
    private let decoder = JSONDecoder()

    /// Events appended since the last read of this file.
    func readNewEvents(at url: URL) -> [HookEvent] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let offset = offsets[url] ?? 0
        let size = (try? handle.seekToEnd()) ?? 0

        // A file that shrank was rotated or replaced; start over.
        let start = size < offset ? 0 : offset
        guard size > start else {
            offsets[url] = size
            return []
        }

        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }
        offsets[url] = size

        return decodeEvents(from: data)
    }

    func decodeEvents(from data: Data) -> [HookEvent] {
        data.split(separator: UInt8(ascii: "\n"))
            .compactMap { line in
                guard !line.isEmpty else { return nil }
                return try? decoder.decode(HookEvent.self, from: Data(line))
            }
    }

    /// Truncates an oversized file. Safe to call any time: it only acts once
    /// everything written so far has been read.
    func rotateIfNeeded(at url: URL) {
        let size = fileSize(at: url)
        guard size > Self.rotationThreshold, offsets[url] ?? 0 >= UInt64(size) else { return }

        try? Data().write(to: url)
        offsets[url] = 0
        Log.agent.info("Rotated hook events file at \(url.lastPathComponent, privacy: .public)")
    }

    func forget(_ url: URL) {
        offsets.removeValue(forKey: url)
    }

    /// Treats everything already in the file as read, so only later events
    /// are reported.
    func skipExisting(at url: URL) {
        offsets[url] = UInt64(fileSize(at: url))
    }

    private func fileSize(at url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int
        else { return 0 }
        return size
    }
}
