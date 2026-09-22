import AppKit
import Testing

@testable import Plume

/// Registered controls resolve by id, are ranked top-to-bottom then
/// left-to-right when an id repeats, and can be narrowed by label.
@MainActor
struct ControlRegistryTests {
    private func entry(_ id: String, label: String? = nil, x: CGFloat = 0, y: CGFloat = 0) -> ControlEntry {
        ControlEntry(
            token: UUID(), id: id, label: label, value: nil, isEnabled: true,
            frame: CGRect(x: x, y: y, width: 10, height: 10), window: nil, invoke: nil, setValue: nil
        )
    }

    @Test func registerUpdateRemoveByToken() {
        let registry = ControlRegistry()
        let control = entry("send")
        registry.register(control)
        #expect(registry.count == 1)
        registry.update(token: control.token) { $0.isEnabled = false }
        #expect(registry.entries(id: "send").first?.entry.isEnabled == false)
        registry.remove(token: control.token)
        #expect(registry.count == 0)
    }

    @Test func repeatedIDsIndexInVisualOrder() {
        let registry = ControlRegistry()
        registry.register(entry("row", label: "third", y: 200))
        registry.register(entry("row", label: "first", y: 0))
        registry.register(entry("row", label: "second-right", x: 50, y: 100))
        registry.register(entry("row", label: "second-left", x: 0, y: 100))
        let labels = registry.entries(id: "row").map { $0.entry.label }
        #expect(labels == ["first", "second-left", "second-right", "third"])
        #expect(registry.entries(id: "row").map(\.index) == [0, 1, 2, 3])
    }

    @Test func labelFilterKeepsTheVisualIndex() throws {
        let registry = ControlRegistry()
        registry.register(entry("row", label: "Alpha", y: 0))
        registry.register(entry("row", label: "Beta", y: 10))
        let matches = registry.entries(id: "row", label: "bet")
        #expect(matches.count == 1)
        #expect(matches.first?.index == 1)
        let resolved = try registry.resolve(.control(id: "row", index: nil, label: "beta"))
        #expect(resolved.label == "Beta")
    }

    @Test func resolveDistinguishesMissingFromAmbiguous() {
        let registry = ControlRegistry()
        registry.register(entry("row", y: 0))
        registry.register(entry("row", y: 10))
        #expect(throws: ControlError.self) { try registry.resolve(.control(id: "row", index: nil, label: nil)) }
        #expect(throws: ControlError.self) { try registry.resolve(.control(id: "nothing", index: nil, label: nil)) }
        #expect(throws: ControlError.self) { try registry.resolve(.control(id: "row", index: 5, label: nil)) }
        #expect((try? registry.resolve(.control(id: "row", index: 1, label: nil)))?.frame.minY == 10)
        #expect(throws: ControlError.self) { try registry.resolve(.composer) }
    }
}
