import Testing
import Foundation
@testable import Plume

/// The `generate_session_title` wire format, locked against what the real
/// CLI accepts. `docs/headless-protocol.md` records the capture.
struct SessionTitleEncodingTests {
    private func decoded(_ line: String?) throws -> [String: Any] {
        let line = try #require(line)
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return try #require(object as? [String: Any])
    }

    @Test
    func theRequestCarriesTheSubtypeAndDescription() throws {
        let body = try decoded(StreamJSONEncoder.generateSessionTitle(
            description: "Add OAuth2 login",
            requestID: "plume-7"
        ))
        #expect(body["type"] as? String == "control_request")
        #expect(body["request_id"] as? String == "plume-7")

        let request = try #require(body["request"] as? [String: Any])
        #expect(request["subtype"] as? String == "generate_session_title")
        // Required, and must be a string — the CLI rejects the request
        // outright otherwise.
        #expect(request["description"] as? String == "Add OAuth2 login")
    }

    @Test
    func aSuccessfulReplyCarriesTheTitle() throws {
        let line = """
        {"type":"control_response","response":{"subtype":"success","request_id":"plume-7",\
        "response":{"title":"OAuth2 login with Google in Flask"}}}
        """
        let message = try #require(StreamJSONDecoder.decode(line: line))
        guard case .controlResponse(let response) = message else {
            Issue.record("expected a control response, got \(message)")
            return
        }
        #expect(!response.isError)
        #expect(response.payload["title"]?.stringValue == "OAuth2 login with Google in Flask")
    }

    /// A description the CLI will not title comes back as a null title rather
    /// than an error, so the two have to read the same way: keep the title
    /// the tab already has.
    @Test
    func aDeclinedTitleIsNullRatherThanAnError() throws {
        let line = """
        {"type":"control_response","response":{"subtype":"success","request_id":"plume-7",\
        "response":{"title":null}}}
        """
        let message = try #require(StreamJSONDecoder.decode(line: line))
        guard case .controlResponse(let response) = message else {
            Issue.record("expected a control response, got \(message)")
            return
        }
        #expect(!response.isError)
        #expect(response.payload["title"]?.stringValue == nil)
    }

    @Test
    func aMissingDescriptionIsRejected() throws {
        let line = """
        {"type":"control_response","response":{"subtype":"error","request_id":"plume-7",\
        "error":"generate_session_title: description must be a string"}}
        """
        let message = try #require(StreamJSONDecoder.decode(line: line))
        guard case .controlResponse(let response) = message else {
            Issue.record("expected a control response, got \(message)")
            return
        }
        #expect(response.isError)
        #expect(response.errorMessage == "generate_session_title: description must be a string")
    }
}
