#if DEBUG
import Foundation
import SwiftData

/// Repairs the debug harness that stamped Codex onto existing Claude tabs.
/// A UUID's shape is not evidence of its provider: require the original
/// Claude transcript path and a matching session record inside that file.
@MainActor
enum SeededProviderRecovery {
    static func recover(in context: ModelContext) throws {
        let tabs = try context.fetch(FetchDescriptor<TaskTab>())
        var changed = false
        for tab in tabs where tab.provider == .codex {
            guard let path = tab.sessionJSONLPath,
                  let file = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? file.close() }
            guard let prefix = try? file.read(upToCount: 65_536),
                  recover(tab, transcriptPrefix: prefix) else { continue }
            changed = true
        }
        if changed { try context.save() }
    }

    @discardableResult
    static func recover(_ tab: TaskTab, transcriptPrefix: Data) -> Bool {
        guard tab.kind == .agent, tab.provider == .codex,
              let sessionID = tab.agentSessionID, !sessionID.isEmpty,
              let path = tab.sessionJSONLPath,
              path.contains("/.claude/projects/"),
              URL(fileURLWithPath: path).lastPathComponent == "\(sessionID).jsonl"
        else { return false }

        let hasMatchingRecord = transcriptPrefix.split(separator: 0x0A).contains { line in
            guard let record = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  record["sessionId"] as? String == sessionID,
                  let type = record["type"] as? String else { return false }
            return ["user", "assistant", "queue-operation", "system", "attachment"].contains(type)
        }
        guard hasMatchingRecord else { return false }
        tab.provider = .claudeCode
        return true
    }
}
#endif
