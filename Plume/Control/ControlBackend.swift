#if DEBUG
import Foundation

/// What a control transport can ask of the app. `InProcessControlBackend`
/// answers from inside the process; a desktop-control backend could answer
/// the same vocabulary from outside it.
@MainActor
protocol ControlBackend {
    func list(_ params: ListParams) throws -> [ControlDescription]
    func describe(_ target: ControlTarget) throws -> ControlDescription
    func invoke(_ target: ControlTarget) async throws -> InvokeResult
    func setValue(_ target: ControlTarget, value: String) throws
    func readText(_ target: ControlTarget) throws -> TextResult
    func clickSpan(_ params: ClickSpanParams) async throws -> ClickResult
    func click(_ params: ClickParams) async throws -> ClickResult
    func screenshot(_ params: ScreenshotParams) throws -> ScreenshotResult
    func hierarchy(_ params: HierarchyParams) throws -> HierarchyResult
    func hover(_ params: HoverParams) async throws -> HoverResult
    func clear(_ params: ClearParams) async throws
}

/// The one switch over `ControlCommand`, so a transport only moves bytes.
@MainActor
enum ControlDispatcher {
    static func handle(line: String, backend: any ControlBackend) async -> ControlServerResponse {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(id: nil, "empty request") }
        let request: ControlServerRequest
        do {
            request = try JSONDecoder().decode(ControlServerRequest.self, from: Data(trimmed.utf8))
        } catch {
            let id = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any])?["id"] as? String
            return .failure(id: id, "malformed request: \(error)")
        }
        return await handle(request, backend: backend)
    }

    static func handle(_ request: ControlServerRequest, backend: any ControlBackend) async -> ControlServerResponse {
        do {
            let result: ControlResult
            switch request.command {
            case .list(let params): result = .controls(try backend.list(params))
            case .describe(let target): result = .description(try backend.describe(target))
            case .invoke(let target): result = .invoked(try await backend.invoke(target))
            case .setValue(let params):
                try backend.setValue(params.target, value: params.value)
                result = .empty
            case .readText(let target): result = .text(try backend.readText(target))
            case .clickSpan(let params): result = .click(try await backend.clickSpan(params))
            case .click(let params): result = .click(try await backend.click(params))
            case .screenshot(let params): result = .screenshot(try backend.screenshot(params))
            case .hierarchy(let params): result = .hierarchy(try backend.hierarchy(params))
            case .hover(let params): result = .hover(try await backend.hover(params))
            case .clear(let params):
                try await backend.clear(params)
                result = .empty
            }
            return .success(id: request.id, result)
        } catch {
            return .failure(id: request.id, (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }
}
#endif
