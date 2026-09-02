import Foundation
import Testing

@testable import Plume

/// Line shapes taken from real transcripts on this machine — a failed turn
/// must not look identical to a silent one.
struct TranscriptNoticeTests {
    private func parse(_ lines: [String]) -> Transcript {
        TranscriptParser.parse(Data(lines.joined(separator: "\n").utf8))
    }

    private func notices(_ transcript: Transcript) -> [ChatNotice] {
        transcript.messages.flatMap { message in
            message.blocks.compactMap { block in
                if case .notice(let notice) = block { return notice }
                return nil
            }
        }
    }

    @Test func anApiErrorBecomesAnErrorNotice() {
        let line = """
        {"type":"system","subtype":"api_error","level":"error","uuid":"e1",\
        "error":{"status":401,"error":{"type":"error","error":{"type":"authentication_error",\
        "message":"Invalid authentication credentials"}}}}
        """
        let found = notices(parse([line]))
        #expect(found.count == 1)
        #expect(found.first?.kind == .error)
        #expect(found.first?.title == "API error")
        #expect(found.first?.detail == "HTTP 401: Invalid authentication credentials")
    }

    @Test func aCompactBoundaryBecomesACompactionNotice() {
        let line = """
        {"type":"system","subtype":"compact_boundary","level":"info","uuid":"c1",\
        "content":"Conversation compacted",\
        "compactMetadata":{"trigger":"manual","preTokens":185960,"postTokens":9755}}
        """
        let found = notices(parse([line]))
        #expect(found.first?.kind == .compaction)
        #expect(found.first?.title == "Conversation compacted")
        #expect(found.first?.detail == "manual compaction · 185k → 9k tokens")
    }

    @Test func anInformationalWarningKeepsItsLevel() {
        let line = """
        {"type":"system","subtype":"informational","level":"warning","uuid":"w1",\
        "content":"Your worktree no longer exists."}
        """
        let found = notices(parse([line]))
        #expect(found.first?.kind == .warning)
        #expect(found.first?.title == "Your worktree no longer exists.")
    }

    /// Bookkeeping subtypes make up most of the `system` lines in a real
    /// transcript. Rendering them would bury the ones that matter.
    @Test func bookkeepingSystemLinesStayDropped() {
        let lines = [
            #"{"type":"system","subtype":"turn_duration","durationMs":1200,"uuid":"t1"}"#,
            #"{"type":"system","subtype":"stop_hook_summary","level":"suggestion","uuid":"t2"}"#,
            #"{"type":"system","subtype":"away_summary","content":"…","uuid":"t3"}"#,
        ]
        #expect(notices(parse(lines)).isEmpty)
    }

    /// A subtype nobody has modeled still surfaces when it is flagged as an
    /// error — silence is the failure mode worth guarding against.
    @Test func anUnknownErrorLevelSubtypeStillSurfaces() {
        let line = #"{"type":"system","subtype":"whatever_is_new","level":"error","content":"It broke","uuid":"x1"}"#
        let found = notices(parse([line]))
        #expect(found.first?.kind == .error)
        #expect(found.first?.title == "It broke")
    }

    @Test func anApiErrorAssistantLineBecomesANoticeRatherThanProse() {
        let line = """
        {"type":"assistant","uuid":"a1","isApiErrorMessage":true,"message":{"role":"assistant",\
        "content":[{"type":"text","text":"API Error: Your computer went to sleep mid-response."}]}}
        """
        let transcript = parse([line])
        #expect(transcript.messages.count == 1)
        #expect(transcript.messages.first?.role == .notice)
        #expect(notices(transcript).first?.kind == .error)
    }

    /// A notice must break the run of assistant lines rather than land inside
    /// it, or an error would render above the text it followed.
    @Test func aNoticeFlushesThePendingAssistantMessage() {
        let lines = [
            #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"text","text":"Before"}]}}"#,
            #"{"type":"system","subtype":"api_error","level":"error","uuid":"e1","error":{"status":500}}"#,
            #"{"type":"assistant","uuid":"a2","message":{"role":"assistant","content":[{"type":"text","text":"After"}]}}"#,
        ]
        let transcript = parse(lines)
        #expect(transcript.messages.map(\.role) == [.assistant, .notice, .assistant])
    }
}

struct TranscriptImageTests {
    private func parse(_ line: String) -> Transcript {
        TranscriptParser.parse(Data(line.utf8))
    }

    private let pixel = "iVBORw0KGgoAAAANSUhEUg=="

    @Test func aUserImageBlockIsModeled() {
        let transcript = parse("""
        {"type":"user","uuid":"u1","message":{"role":"user","content":[\
        {"type":"image","source":{"type":"base64","media_type":"image/png","data":"\(pixel)"}}]}}
        """)
        let images = transcript.messages.flatMap(\.blocks).compactMap { block -> ChatImage? in
            if case .image(let image) = block { return image }
            return nil
        }
        #expect(images.count == 1)
        #expect(images.first?.mediaType == "image/png")
        #expect(images.first?.base64 == pixel)
    }

    @Test func anImageInAToolResultAttachesToItsCall() {
        let lines = [
            """
            {"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[\
            {"type":"tool_use","id":"t1","name":"Screenshot","input":{}}]}}
            """,
            """
            {"type":"user","uuid":"u1","message":{"role":"user","content":[\
            {"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"captured"},\
            {"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"\(pixel)"}}]}]}}
            """,
        ]
        let transcript = TranscriptParser.parse(Data(lines.joined(separator: "\n").utf8))
        let calls = transcript.messages.flatMap(\.blocks).compactMap { block -> ToolCall? in
            if case .toolCall(let call) = block { return call }
            return nil
        }
        #expect(calls.first?.result == "captured")
        #expect(calls.first?.resultImages.count == 1)
        #expect(calls.first?.resultImages.first?.mediaType == "image/jpeg")
    }

    /// A URL source needs a fetch, which the parser must stay free of.
    @Test func aNonBase64SourceIsIgnored() {
        let transcript = parse("""
        {"type":"user","uuid":"u1","message":{"role":"user","content":[\
        {"type":"image","source":{"type":"url","url":"https://example.com/x.png"}}]}}
        """)
        #expect(transcript.messages.isEmpty)
    }

    @Test func anOversizedImageIsFlaggedRatherThanDecoded() {
        let image = ChatImage(
            mediaType: "image/png",
            base64: String(repeating: "A", count: ChatImage.maxBase64Length + 1)
        )
        #expect(image.isOversized)
    }
}
