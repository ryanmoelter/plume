import Foundation

@MainActor
final class CodexLinearActivity {
    static let shared = CodexLinearActivity(sink: LinearStore.shared)

    private let sink: LinearActivitySink
    private var parents: [UUID: [LinearEvidence]] = [:]
    private var children: [UUID: [LinearEvidence]] = [:]

    init(sink: LinearActivitySink) { self.sink = sink }

    func replaceParent(tabID: UUID, evidence: [LinearEvidence]) {
        guard parents[tabID] != evidence else { return }
        parents[tabID] = evidence.isEmpty ? nil : evidence
        publish(tabID: tabID)
    }

    func replaceChildren(tabID: UUID, evidence: [LinearEvidence]) {
        guard children[tabID] != evidence else { return }
        children[tabID] = evidence.isEmpty ? nil : evidence
        publish(tabID: tabID)
    }

    private func publish(tabID: UUID) {
        var seen = Set<LinearEvidence>()
        let evidence = ((parents[tabID] ?? []) + (children[tabID] ?? [])).filter { seen.insert($0).inserted }
        sink.replaceActivity(tabID: tabID, evidence: evidence)
    }
}
