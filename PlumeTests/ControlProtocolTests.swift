import CoreGraphics
import Foundation
import Testing

@testable import Plume

/// The control server's NDJSON vocabulary decodes every command from its
/// flat request shape and encodes results and errors the client can key on.
struct ControlProtocolTests {
    private func decode(_ json: String) throws -> ControlServerRequest {
        try JSONDecoder().decode(ControlServerRequest.self, from: Data(json.utf8))
    }

    @Test func listDecodesItsFilterWithoutEatingTheRequestID() throws {
        let request = try decode(#"{"id":"7","command":"list","plumeID":"task-row","label":"Fix"}"#)
        #expect(request.id == "7")
        guard case .list(let params) = request.command else { Issue.record("not list"); return }
        #expect(params.plumeID == "task-row")
        #expect(params.label == "Fix")
        #expect(params.windowNumber == nil)
    }

    @Test func targetDecodesBothForms() throws {
        let control = try decode(#"{"id":"1","command":"describe","target":{"id":"tab-chip","index":2}}"#)
        guard case .describe(let target) = control.command else { Issue.record("not describe"); return }
        #expect(target == .control(id: "tab-chip", index: 2, label: nil))

        let surface = try decode(#"{"id":"2","command":"readText","target":{"kind":"composer"}}"#)
        guard case .readText(let kind) = surface.command else { Issue.record("not readText"); return }
        #expect(kind == .composer)
    }

    @Test func everyCommandDecodes() throws {
        let lines = [
            #"{"id":"a","command":"invoke","target":{"id":"x"}}"#,
            #"{"id":"b","command":"setValue","target":{"kind":"composer"},"value":"hi"}"#,
            #"{"id":"c","command":"clickSpan","matching":"world"}"#,
            #"{"id":"d","command":"click","x":10,"y":20}"#,
            #"{"id":"e","command":"screenshot"}"#,
            #"{"id":"f","command":"hierarchy","format":"json","textLimit":0}"#,
        ]
        for line in lines {
            _ = try decode(line)
        }
        guard case .clickSpan(let span) = try decode(lines[2]).command else { Issue.record("not clickSpan"); return }
        #expect(span.occurrence == 0)
        guard case .click(let click) = try decode(lines[3]).command else { Issue.record("not click"); return }
        #expect(click.clickCount == 1)
        guard case .hierarchy(let hierarchy) = try decode(lines[5]).command else { Issue.record("not hierarchy"); return }
        #expect(hierarchy.format == .json)
        #expect(hierarchy.textLimit == 0)
    }

    @Test func unknownCommandsAndKindsAreRejected() {
        #expect(throws: DecodingError.self) { try decode(#"{"id":"1","command":"dance"}"#) }
        #expect(throws: DecodingError.self) { try decode(#"{"id":"1","command":"readText","target":{"kind":"menu"}}"#) }
    }

    @Test func responsesEncodeOKAndErrorShapes() throws {
        let ok = ControlServerResponse.success(id: "1", .text(TextResult(text: "hi", rows: nil))).encodedLine()
        let okJSON = try JSONSerialization.jsonObject(with: ok.dropLast()) as? [String: Any]
        #expect(okJSON?["ok"] as? Bool == true)
        #expect((okJSON?["result"] as? [String: Any])?["text"] as? String == "hi")
        #expect(ok.last == 0x0A)

        let failed = ControlServerResponse.failure(id: nil, "nope").encodedLine()
        let failedJSON = try JSONSerialization.jsonObject(with: failed.dropLast()) as? [String: Any]
        #expect(failedJSON?["ok"] as? Bool == false)
        #expect(failedJSON?["error"] as? String == "nope")
        #expect(failedJSON?["id"] == nil)
    }

    @Test func hierarchyNodesRoundTrip() throws {
        let node = HierarchyNode(
            kind: "NSTextField", plumeID: nil, index: nil, label: nil, value: nil, text: "hello",
            isEnabled: true, frame: Rect(CGRect(x: 1, y: 2, width: 3, height: 4)),
            children: [HierarchyNode(kind: "control", plumeID: "t", index: 0, frame: Rect(.zero))]
        )
        let data = try JSONEncoder().encode(node)
        #expect(try JSONDecoder().decode(HierarchyNode.self, from: data) == node)
    }
}
