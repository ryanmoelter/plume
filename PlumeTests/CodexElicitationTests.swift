import Foundation
import Testing
@testable import Plume

struct CodexElicitationTests {
    @Test func validatesAndPreservesFormValueTypes() throws {
        let request = try makeRequest(mode: "form", schema: """
        {
          "type": "object",
          "required": ["enabled", "seats"],
          "properties": {
            "enabled": {"type": "boolean", "default": false},
            "seats": {"type": "integer", "minimum": 1, "maximum": 4},
            "ratio": {"type": "number", "default": 1.5},
            "name": {"type": "string", "minLength": 2, "maxLength": 4},
            "role": {"type": "string", "enum": ["a", "b"], "enumNames": ["A", "B"]},
            "site": {"type": "string", "oneOf": [{"const": "east", "title": "East"}]},
            "tags": {"type": "array", "minItems": 1, "items": {"anyOf": [
              {"const": "r", "title": "Red"}, {"const": "b", "title": "Blue"}
            ]}},
            "groups": {"type": "array", "maxItems": 1, "items": {"type": "string", "enum": ["staff", "guests"]}}
          }
        }
        """)
        guard case .form(let fields) = request.mode else {
            Issue.record("Expected a form")
            return
        }
        #expect(fields.first { $0.id == "enabled" }?.defaultValue == .bool(false))
        #expect(fields.first { $0.id == "ratio" }?.defaultValue == .number(1.5))
        #expect(fields.first { $0.id == "role" }?.kind == .choice([
            .init(id: "a", title: "A"), .init(id: "b", title: "B"),
        ]))
        #expect(request.accepts(content: ["enabled": .bool(false), "seats": .number(3)]))
        #expect(request.accepts(content: [
            "enabled": .bool(false), "seats": .number(3), "tags": .array([.string("r")]),
            "name": .string("Li"), "site": .string("east"),
        ]))
        #expect(!request.accepts(content: ["enabled": .bool(false)]))
        #expect(!request.accepts(content: ["enabled": .bool(false), "seats": .string("3")]))
        #expect(!request.accepts(content: ["enabled": .bool(false), "seats": .number(3.5)]))
        #expect(!request.accepts(content: ["enabled": .bool(false), "seats": .number(5)]))
        #expect(!request.accepts(content: ["enabled": .bool(false), "seats": .number(3), "unknown": .string("")]))
        #expect(!request.accepts(content: ["enabled": .bool(false), "seats": .number(3), "tags": .array([])]))
        #expect(!request.accepts(content: [
            "enabled": .bool(false), "seats": .number(3), "groups": .array([.string("staff"), .string("guests")]),
        ]))
    }

    @Test(arguments: ["form", "openai/form", "openaiForm"])
    func supportsCompatibleFormModes(_ mode: String) throws {
        let request = try makeRequest(mode: mode, schema: """
        {"type": "object", "properties": {"when": {"type": "string", "format": "date"}}}
        """)
        #expect(request.accepts(content: [:]))
        #expect(request.accepts(content: ["when": .string("2024-02-29")]))
        #expect(!request.accepts(content: ["when": .string("2025-02-29")]))
        #expect(!request.accepts(content: nil))
    }

    @Test func unsupportedSchemaCannotBeAccepted() throws {
        let request = try makeRequest(mode: "openaiForm", schema: """
        {"type": "object", "properties": {"nested": {"type": "object", "properties": {}}}}
        """)
        #expect(request.mode == .unsupported)
        #expect(!request.accepts(content: [:]))
    }

    @Test func urlAcceptanceHasNoContent() throws {
        let request = try makeURLRequest("https://example.com/flow")
        let url = try #require(URL(string: "https://example.com/flow"))
        #expect(request.mode == .url(url, elicitationID: "flow-1"))
        #expect(request.accepts(content: nil))
        #expect(!request.accepts(content: [:]))
    }

    @Test(arguments: ["file:///tmp/x", "javascript:alert(1)", "https:///missing-host", "https://user@example.com"])
    func unsafeURLIsUnsupported(_ url: String) throws {
        let request = try makeURLRequest(url)
        #expect(request.mode == .unsupported)
        #expect(!request.accepts(content: nil))
    }

    private func makeRequest(mode: String, schema: String) throws -> CodexElicitationRequest {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(schema.utf8))
        return try #require(CodexElicitationRequest(params: .object([
            "mode": .string(mode), "serverName": .string("Example"), "threadId": .string("thread-1"),
            "message": .string("Fill in the form"), "requestedSchema": value,
        ])))
    }

    private func makeURLRequest(_ url: String) throws -> CodexElicitationRequest {
        try #require(CodexElicitationRequest(params: .object([
            "mode": .string("url"), "serverName": .string("Example"), "threadId": .string("thread-1"),
            "message": .string("Open the link"), "url": .string(url), "elicitationId": .string("flow-1"),
        ])))
    }
}
