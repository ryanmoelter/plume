import Foundation
import SQLite3

/// Reads another app's WAL-mode SQLite database without touching it.
///
/// The owner may be writing while Plume reads, so the reader opens a private
/// copy of the database and its `-wal`. Opening the copy replays the log;
/// `immutable=1` on the original would skip it and miss recent writes.
nonisolated enum SQLitePrivateCopy {
    private static let copyAttempts = 3

    /// Nil when the file is missing, cannot be copied consistently, fails
    /// `PRAGMA quick_check`, or cannot be opened.
    static func read<T>(_ url: URL, _ body: (OpaquePointer) -> T) -> T? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let scratch = fileManager.temporaryDirectory.appendingPathComponent("plume-sqlite-copy-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent(url.lastPathComponent)
        guard copyConsistently(url, to: copy) else { return nil }

        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db,
              textRows(db, "PRAGMA quick_check", columns: 1) == [["ok"]]
        else { return nil }
        return body(db)
    }

    private struct FileStamp: Equatable {
        let size: UInt64?
        let modified: Date?
        let inode: UInt64?

        init(_ path: String) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            size = (attributes?[.size] as? NSNumber)?.uint64Value
            modified = attributes?[.modificationDate] as? Date
            inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        }
    }

    /// The owner can write between the two copies, leaving a database and log
    /// that never coexisted. A write during the copy shows as a changed stamp.
    private static func copyConsistently(_ url: URL, to copy: URL) -> Bool {
        let fileManager = FileManager.default
        let walSource = url.path + "-wal"
        let walCopy = copy.path + "-wal"
        for _ in 0..<copyAttempts {
            let before = (FileStamp(url.path), FileStamp(walSource))
            do {
                try? fileManager.removeItem(at: copy.deletingLastPathComponent())
                try fileManager.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: url, to: copy)
                if fileManager.fileExists(atPath: walSource) {
                    try fileManager.copyItem(atPath: walSource, toPath: walCopy)
                }
            } catch {
                continue
            }
            if before == (FileStamp(url.path), FileStamp(walSource)) { return true }
        }
        return false
    }

    /// Every row of a query whose columns are all text. Nil when the query
    /// cannot be prepared, such as when its table does not exist.
    static func textRows(_ db: OpaquePointer, _ sql: String, columns: Int32) -> [[String?]]? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }

        var rows: [[String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((0..<columns).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            })
        }
        return rows
    }
}
