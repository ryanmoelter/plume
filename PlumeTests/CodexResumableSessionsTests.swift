import Foundation
import Testing
@testable import Plume

@MainActor
struct CodexResumableSessionsTests {
    private func thread(_ id: String, updatedAt: Double = 1, name: String? = nil) -> JSONValue {
        .object([
            "id": .string(id), "cwd": .string("/repo"), "updatedAt": .number(updatedAt),
            "name": name.map(JSONValue.string) ?? .null,
            "preview": .string("First message\nwith more detail"), "source": .string("cli")
        ])
    }

    @Test func discoversAllPagesWithoutResumingAndSortsNewestFirst() async throws {
        var calls: [JSONValue] = []
        let result = try await CodexResumableSessions.loadPages(directories: ["/repo", "/worktree"]) { params in
            calls.append(params)
            if calls.count == 1 {
                return .object(["data": .array([thread("older")]), "nextCursor": .string("page2")])
            }
            return .object(["data": .array([thread("newer", updatedAt: 2, name: "Named conversation")])])
        }
        #expect(result.map(\.id) == ["newer", "older"])
        #expect(result[0].displayTitle == "Named conversation")
        #expect(result[1].displayTitle == "First message")
        #expect(calls[0]["cwd"] == .array([.string("/repo"), .string("/worktree")]))
        #expect(calls[1]["cursor"] == .string("page2"))
        #expect(result.allSatisfy { $0.transcriptPath.isEmpty })
    }

    @Test func repeatedCursorFailsInsteadOfLoopingForever() async {
        await #expect(throws: CodexResumableSessions.DiscoveryError.self) {
            _ = try await CodexResumableSessions.loadPages(directories: ["/repo"]) { _ in
                .object(["data": .array([]), "nextCursor": .string("same")])
            }
        }
    }

    @Test func childThreadsCannotBeOfferedForResume() {
        let child: JSONValue = .object([
            "id": .string("child"), "cwd": .string("/repo"),
            "source": .object(["subAgent": .object(["thread_spawn": .object([:])])])
        ])
        #expect(CodexResumableSessions.storedSession(thread: child) == nil)
    }

    @Test func titleUsesNameThenPreviewsFirstLine() {
        #expect(CodexThreadTitle.title(thread: thread("id", name: "  A title  ")) == "A title")
        #expect(CodexThreadTitle.title(thread: thread("id", name: "\n ")) == "First message")
        #expect(CodexThreadTitle.preview(String(repeating: "x", count: 200))?.count == 61)
        #expect(CodexThreadTitle.name(" \n") == nil)
    }
}
