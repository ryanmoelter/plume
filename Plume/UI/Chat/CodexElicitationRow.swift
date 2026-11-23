import AppKit
import SwiftUI

struct CodexElicitationRow: View, ThemedView {
    @Environment(\.theme) var theme

    let request: CodexElicitationRequest
    let permissionID: String
    let isChild: Bool
    let answer: (CodexElicitationAction, [String: JSONValue]?) -> Void

    @State private var values: [String: JSONValue]
    @State private var numberText: [String: String]
    @State private var included: Set<String>

    init(
        request: CodexElicitationRequest,
        permissionID: String,
        isChild: Bool,
        answer: @escaping (CodexElicitationAction, [String: JSONValue]?) -> Void
    ) {
        self.request = request
        self.permissionID = permissionID
        self.isChild = isChild
        self.answer = answer

        let fields: [CodexElicitationField]
        if case .form(let formFields) = request.mode {
            fields = formFields
        } else {
            fields = []
        }
        let defaults = Dictionary(uniqueKeysWithValues: fields.compactMap { field in
            field.defaultValue.map { (field.id, $0) }
        })
        _values = State(initialValue: defaults)
        _numberText = State(initialValue: defaults.compactMapValues { $0.doubleValue.map { String($0) } })
        _included = State(initialValue: Set(fields.filter { $0.required || $0.defaultValue != nil }.map(\.id)))
    }

    private var content: [String: JSONValue]? {
        guard case .form(let fields) = request.mode else { return nil }
        var content: [String: JSONValue] = [:]
        for field in fields where included.contains(field.id) {
            let value = value(for: field)
            guard let value, field.accepts(value) else { return nil }
            content[field.id] = value
        }
        return content
    }

    private var canAccept: Bool { request.accepts(content: content) }

    var body: some View {
        VStack(alignment: .leading, spacing: DecisionCard.sectionSpacing) {
            DecisionCardHeader(
                title: request.serverName,
                symbol: "questionmark.circle",
                subject: .inquiry,
                trailing: isChild ? (text: "subagent", symbol: StatusSymbol.subagents.name) : nil
            )
            Text(request.message)
                .fixedSize(horizontal: false, vertical: true)
                .chatTextColumn()
            switch request.mode {
            case .form(let fields):
                if !fields.isEmpty {
                    ViewThatFits(in: .vertical) {
                        form(fields)
                        ScrollView { form(fields) }
                            .frame(height: 240)
                    }
                    .frame(maxHeight: 240)
                    .chatTextColumn()
                }
            case .url(let url, _):
                VStack(alignment: .leading, spacing: DecisionCard.rowSpacing) {
                    if let host = url.host() {
                        Text(host).font(typography.caption.semibold)
                    }
                    Text(url.absoluteString)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Button("Open Link", systemImage: "arrow.up.right.square") { openURL(url) }
                        .plumeID(AccessibilityID.elicitationOpenURL, label: permissionID, invoke: { openURL(url) })
                }
                .chatTextColumn()
            case .unsupported:
                Text("This request uses an unsupported format.")
                    .chatTextColumn()
            }
            HStack {
                Spacer()
                responseButton("Cancel", id: AccessibilityID.elicitationCancel, action: .cancel)
                responseButton("Decline", id: AccessibilityID.elicitationDecline, action: .decline)
                Button(acceptTitle, action: submit)
                    .buttonStyle(.borderedProminent)
                    .plumeID(AccessibilityID.elicitationAccept, label: permissionID, invoke: submit)
                    .disabled(!canAccept)
            }
            .chatTextColumn()
        }
        .font(typography.caption.font)
        .decisionCard(subject: .inquiry, colors: colors)
    }

    private var acceptTitle: String {
        if case .url = request.mode { return "Continue" }
        return "Submit"
    }

    private func openURL(_ url: URL) {
        Task.detached(priority: .userInitiated) {
            NSWorkspace.shared.open(url)
        }
    }

    private func submit() {
        let payload = content
        guard request.accepts(content: payload) else { return }
        answer(.accept, payload)
    }

    private func responseButton(_ title: String, id: String, action: CodexElicitationAction) -> some View {
        Button(title) { answer(action, nil) }
            .plumeID(id, label: permissionID, invoke: { answer(action, nil) })
    }

    private func form(_ fields: [CodexElicitationField]) -> some View {
        VStack(alignment: .leading, spacing: DecisionCard.sectionSpacing) {
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: DecisionCard.rowSpacing) {
                    if field.required {
                        Text(field.title).font(typography.caption.semibold)
                    } else {
                        Toggle(field.title, isOn: inclusion(for: field))
                            .plumeID(AccessibilityID.elicitationIncludeField, label: label(for: field),
                                     value: included.contains(field.id) ? "included" : "omitted",
                                     invoke: { inclusion(for: field).wrappedValue.toggle() })
                    }
                    if let description = field.description {
                        Text(description).foregroundStyle(.secondary)
                    }
                    if included.contains(field.id) {
                        editor(for: field)
                        if invalidValue(for: field) {
                            Text("Enter a valid value for \(field.title).")
                                .foregroundStyle(colors.warning)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inclusion(for field: CodexElicitationField) -> Binding<Bool> {
        Binding {
            included.contains(field.id)
        } set: { isIncluded in
            if isIncluded {
                included.insert(field.id)
            } else {
                included.remove(field.id)
            }
        }
    }

    private func label(for field: CodexElicitationField) -> String { "\(permissionID) · \(field.id)" }

    private func value(for field: CodexElicitationField) -> JSONValue? {
        switch field.kind {
        case .text: return values[field.id] ?? .string("")
        case .number: return numberText[field.id].flatMap(Double.init).map(JSONValue.number)
        case .multiple: return values[field.id] ?? .array([])
        case .boolean, .choice: return values[field.id]
        }
    }

    private func invalidValue(for field: CodexElicitationField) -> Bool {
        if let value = value(for: field) { return !field.accepts(value) }
        return !(numberText[field.id] ?? "").isEmpty
    }

    @ViewBuilder
    private func editor(for field: CodexElicitationField) -> some View {
        switch field.kind {
        case .text(let format, _, _):
            let input = Binding {
                values[field.id]?.stringValue ?? ""
            } set: {
                values[field.id] = .string($0)
            }
            textField(field, input: input, prompt: formatHint(format))
        case .number(let integer, _, _):
            let input = Binding {
                numberText[field.id] ?? ""
            } set: {
                numberText[field.id] = $0
            }
            textField(field, input: input, prompt: integer ? "Whole number" : "Number")
        case .boolean:
            HStack {
                option("Yes", field: field, selected: values[field.id] == .bool(true)) {
                    values[field.id] = .bool(true)
                }
                option("No", field: field, selected: values[field.id] == .bool(false)) {
                    values[field.id] = .bool(false)
                }
            }
        case .choice(let options):
            VStack(alignment: .leading, spacing: DecisionCard.rowSpacing) {
                ForEach(options) { choice in
                    option(choice.title, field: field, selected: values[field.id] == .string(choice.id)) {
                        values[field.id] = .string(choice.id)
                    }
                }
            }
        case .multiple(let options, _, _):
            VStack(alignment: .leading, spacing: DecisionCard.rowSpacing) {
                ForEach(options) { choice in
                    let choices = values[field.id]?.arrayValue ?? []
                    let selection = JSONValue.string(choice.id)
                    option(choice.title, field: field, selected: choices.contains(selection)) {
                        values[field.id] = .array(choices.contains(selection)
                            ? choices.filter { $0 != selection }
                            : choices + [selection])
                    }
                }
            }
        }
    }

    private func option(
        _ title: String,
        field: CodexElicitationField,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: selected ? "checkmark.circle.fill" : "circle")
        }
        .plumeID(AccessibilityID.elicitationOption, label: "\(label(for: field)) · \(title)",
                 value: selected ? "selected" : "unselected", invoke: action)
    }

    private func formatHint(_ format: String?) -> String {
        switch format {
        case "date": "YYYY-MM-DD"
        case "date-time": "YYYY-MM-DDThh:mm:ssZ"
        case "email": "Email address"
        case "uri": "URI"
        default: ""
        }
    }

    private func textField(_ field: CodexElicitationField, input: Binding<String>, prompt: String) -> some View {
        TextField(field.title, text: input, prompt: Text(prompt))
            .plumeID(AccessibilityID.elicitationField, label: label(for: field),
                     setValue: { input.wrappedValue = $0 })
    }
}
