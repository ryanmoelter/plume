import CoreGraphics
import Foundation
import Testing

@testable import Plume

/// Every wire command reaches its backend method, results come back as
/// `ok`, and thrown errors become an `error` string on the same request id.
@MainActor
struct ControlDispatcherTests {
    @Test func eachCommandRoutesToItsMethod() async {
        let backend = FakeControlBackend()
        let lines = [
            #"{"id":"1","command":"list"}"#,
            #"{"id":"2","command":"describe","target":{"id":"x"}}"#,
            #"{"id":"3","command":"invoke","target":{"id":"x"}}"#,
            #"{"id":"4","command":"setValue","target":{"kind":"composer"},"value":"v"}"#,
            #"{"id":"5","command":"readText","target":{"kind":"composer"}}"#,
            #"{"id":"6","command":"clickSpan","matching":"m"}"#,
            #"{"id":"7","command":"click","x":1,"y":2}"#,
            #"{"id":"8","command":"screenshot"}"#,
            #"{"id":"9","command":"hierarchy"}"#,
            #"{"id":"10","command":"hover","x":1,"y":2}"#,
            #"{"id":"11","command":"clear"}"#,
        ]
        for line in lines {
            let response = await ControlDispatcher.handle(line: line, backend: backend)
            #expect(response.ok, "\(line) → \(response.error ?? "")")
        }
        #expect(backend.calls == ["list", "describe", "invoke", "setValue", "readText", "clickSpan", "click", "screenshot", "hierarchy", "hover", "clear"])
        #expect(backend.lastValue == "v")
    }

    @Test func backendErrorsBecomeErrorResponsesOnTheSameID() async {
        let backend = FakeControlBackend()
        backend.failure = ControlError.notFound("x")
        let response = await ControlDispatcher.handle(line: #"{"id":"42","command":"list"}"#, backend: backend)
        #expect(response.id == "42")
        #expect(response.ok == false)
        #expect(response.error == "not found: x")
    }

    @Test func malformedLinesStillAnswer() async {
        let backend = FakeControlBackend()
        let garbage = await ControlDispatcher.handle(line: "not json", backend: backend)
        #expect(garbage.ok == false)
        #expect(garbage.id == nil)

        let unknown = await ControlDispatcher.handle(line: #"{"id":"9","command":"dance"}"#, backend: backend)
        #expect(unknown.ok == false)
        #expect(unknown.id == "9")

        let empty = await ControlDispatcher.handle(line: "   ", backend: backend)
        #expect(empty.ok == false)
        #expect(backend.calls.isEmpty)
    }
}

@MainActor
final class FakeControlBackend: ControlBackend {
    var calls: [String] = []
    var lastValue: String?
    var failure: Error?
    var listResult: [ControlDescription] = []

    private func record(_ name: String) throws {
        calls.append(name)
        if let failure { throw failure }
    }

    func list(_ params: ListParams) throws -> [ControlDescription] {
        try record("list")
        return listResult
    }

    func describe(_ target: ControlTarget) throws -> ControlDescription {
        try record("describe")
        return ControlDescription(id: "x", index: 0, isEnabled: true, frame: Rect(.zero), hasInvoke: false, hasSetValue: false)
    }

    func invoke(_ target: ControlTarget) async throws -> InvokeResult {
        try record("invoke")
        return InvokeResult(via: "closure")
    }

    func setValue(_ target: ControlTarget, value: String) throws {
        try record("setValue")
        lastValue = value
    }

    func readText(_ target: ControlTarget) throws -> TextResult {
        try record("readText")
        return TextResult(text: "", rows: nil)
    }

    func clickSpan(_ params: ClickSpanParams) async throws -> ClickResult {
        try record("clickSpan")
        return ClickResult(rect: Rect(.zero), windowNumber: 0)
    }

    func click(_ params: ClickParams) async throws -> ClickResult {
        try record("click")
        return ClickResult(rect: Rect(.zero), windowNumber: 0)
    }

    func screenshot(_ params: ScreenshotParams) throws -> ScreenshotResult {
        try record("screenshot")
        return ScreenshotResult(path: "/dev/null", width: 0, height: 0, scale: 1)
    }

    func hierarchy(_ params: HierarchyParams) throws -> HierarchyResult {
        try record("hierarchy")
        return HierarchyResult(text: "", root: nil)
    }

    func hover(_ params: HoverParams) async throws -> HoverResult {
        try record("hover")
        return HoverResult(rect: Rect(.zero), windowNumber: 0, regions: 0)
    }

    func clear(_ params: ClearParams) async throws {
        try record("clear")
    }

    func key(_ params: KeyParams) async throws -> KeyResult {
        try record("key")
        return KeyResult(chord: params.key, keyCode: 0, windowNumber: 0, handledBy: nil, handledByEnabled: nil)
    }

    func menu() throws -> MenuResult {
        try record("menu")
        return MenuResult(items: [])
    }
}
