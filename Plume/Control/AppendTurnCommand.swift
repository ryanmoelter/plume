#if DEBUG
import AppKit
import Foundation
import SwiftData

extension InProcessControlBackend {
    func appendTurn(_ params: AppendTurnParams) async throws -> SwitchLatencyReport {
        guard let window = CLICommandHandler.shared.frontmostWindow else { throw ControlError.noWindow }
        guard let taskID = window.selectedTaskID(),
              let task = try window.context.fetch(.init(predicate: #Predicate<WorkTask> { $0.id == taskID })).first
        else { throw ControlError.notFound("a selected task") }
        guard let tab = task.orderedTabs.first(where: { $0.id == task.selectedTabID }) ?? task.orderedTabs.first,
              let path = TranscriptStore.shared.watchedPath(forTab: tab.id)
        else { throw ControlError.badParams("the selected task's tab watches no transcript") }
        if let refusal = AppendTurnTarget.refusal(
            path: path,
            seedPaths: AppendTurnTarget.seedPaths(in: ProcessInfo.processInfo.environment),
            hasLiveProcess: Self.hasLiveProcess(tabID: tab.id)
        ) {
            throw ControlError.unsupported(refusal)
        }

        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "Measuring transcript appends"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }
        var parent = SyntheticTurn.lastMessageUUID(inFileAt: path)
        var samples: [SwitchLatencyMeasurement] = []
        for round in 0..<params.repeatCount {
            let turn = SyntheticTurn(parentUUID: parent, index: round, withReply: params.reply)
            parent = turn.lastUUID
            let sample = try await withCheckedThrowingContinuation { continuation in
                SwitchLatencyProbe.begin(
                    "append \(round + 1)",
                    tabID: tab.id,
                    timeout: params.timeout,
                    awaitingMessageID: turn.promptUUID
                ) { continuation.resume(returning: $0) }
                do {
                    try turn.append(toFileAt: path)
                } catch {
                    SwitchLatencyProbe.cancel()
                    continuation.resume(throwing: error)
                }
            }
            samples.append(sample)
            try await Task.sleep(for: .seconds(params.settle))
        }
        return SwitchLatencyReport(samples: samples)
    }

    private static func hasLiveProcess(tabID: UUID) -> Bool {
        SurfaceManager.shared.existingSession(for: tabID).map { !$0.hasExited } ?? false
            || AgentSessionManager.shared.existingSession(for: tabID).map { !$0.hasExited } ?? false
    }
}

/// Whether `appendTurn` may write to a tab's transcript: a seeded fixture
/// always, anything else only while no agent process could be writing it.
nonisolated enum AppendTurnTarget {
    /// Nil when the append may go ahead, else why it may not.
    static func refusal(path: String, seedPaths: [String], hasLiveProcess: Bool) -> String? {
        let canonical = Set(seedPaths.map(Self.canonical))
        if canonical.contains(Self.canonical(path)) || !hasLiveProcess { return nil }
        return "appendTurn writes only to a PLUME_SEED_TRANSCRIPT_PATH fixture or a transcript no agent process is writing, and an agent process backs this tab"
    }

    /// The paths `SmokeHarness` seeds from `PLUME_SEED_TRANSCRIPT_PATH`.
    static func seedPaths(in environment: [String: String]) -> [String] {
        guard let paths = environment["PLUME_SEED_TRANSCRIPT_PATH"] else { return [] }
        return paths.split(separator: ",").map { NSString(string: String($0)).expandingTildeInPath }
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// A prompt, and optionally its reply, shaped like the rows Claude Code
/// writes, chained onto the transcript's last message.
nonisolated struct SyntheticTurn {
    let promptUUID = UUID().uuidString
    let replyUUID: String?
    let lines: [String]

    var lastUUID: String { replyUUID ?? promptUUID }

    init(parentUUID: String?, index: Int, withReply: Bool, now: Date = Date()) {
        replyUUID = withReply ? UUID().uuidString : nil
        let timestamp = ISO8601DateFormatter.withFractionalSeconds.string(from: now)
        var rows: [[String: Any]] = [[
            "parentUuid": parentUUID ?? NSNull(),
            "isSidechain": false,
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": "Synthetic prompt \(index + 1)"]]],
            "uuid": promptUUID,
            "timestamp": timestamp,
        ]]
        if let replyUUID {
            rows.append([
                "parentUuid": promptUUID,
                "isSidechain": false,
                "type": "assistant",
                "message": [
                    "id": "msg_synthetic_\(replyUUID)",
                    "type": "message",
                    "role": "assistant",
                    "model": "synthetic",
                    "content": [["type": "text", "text": "Synthetic reply \(index + 1), with **some** `markdown`."]],
                    "stop_reason": "end_turn",
                ],
                "uuid": replyUUID,
                "timestamp": timestamp,
            ])
        }
        lines = rows.compactMap { row in
            (try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    /// Refuses a file that ends mid-line: its last row may still be being
    /// written, and finishing it is not this turn's to do.
    func append(toFileAt path: String) throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forUpdating: URL(fileURLWithPath: path))
        } catch {
            throw ControlError.io("can't open the transcript for writing: \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                guard try handle.read(upToCount: 1) == Data("\n".utf8) else {
                    throw ControlError.unsupported("the transcript ends mid-line, so appendTurn won't write to it")
                }
                try handle.seekToEnd()
            }
            try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        } catch let error as ControlError {
            throw error
        } catch {
            throw ControlError.io("can't write the transcript: \(error.localizedDescription)")
        }
    }

    /// The uuid of the file's last user or assistant row, from its tail.
    static func lastMessageUUID(inFileAt path: String, tailBytes: UInt64 = 4 << 20) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > tailBytes ? end - tailBytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = row["type"] as? String, type == "user" || type == "assistant",
                  let uuid = row["uuid"] as? String
            else { continue }
            return uuid
        }
        return nil
    }
}

private extension ISO8601DateFormatter {
    nonisolated static var withFractionalSeconds: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
#endif
