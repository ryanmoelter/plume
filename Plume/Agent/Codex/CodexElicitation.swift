import Foundation

nonisolated enum CodexElicitationAction: String, Sendable {
    case accept, decline, cancel
}

nonisolated struct CodexElicitationRequest: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case form([CodexElicitationField])
        case url(URL, elicitationID: String)
        case unsupported
    }

    let threadID: String
    let turnID: String?
    let serverName: String
    let message: String
    let mode: Mode

    init?(params: JSONValue) {
        guard let threadID = params["threadId"]?.stringValue,
              let serverName = params["serverName"]?.stringValue,
              let message = params["message"]?.stringValue else { return nil }
        self.threadID = threadID
        turnID = params["turnId"]?.stringValue
        self.serverName = serverName
        self.message = message

        switch params["mode"]?.stringValue {
        case "form", "openai/form", "openaiForm":
            mode = Self.fields(in: params["requestedSchema"]).map(Mode.form) ?? .unsupported
        case "url":
            if let rawURL = params["url"]?.stringValue,
               let id = params["elicitationId"]?.stringValue,
               let components = URLComponents(string: rawURL),
               ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
               let host = components.host, !host.isEmpty,
               components.user == nil, components.password == nil,
               let url = components.url {
                mode = .url(url, elicitationID: id)
            } else {
                mode = .unsupported
            }
        default:
            mode = .unsupported
        }
    }

    func accepts(content: [String: JSONValue]?) -> Bool {
        switch mode {
        case .form(let fields):
            guard let content else { return false }
            let fieldIDs = Set(fields.map(\.id))
            return Set(content.keys).isSubset(of: fieldIDs) && fields.allSatisfy { field in
                content[field.id].map(field.accepts) ?? !field.required
            }
        case .url:
            return content == nil
        case .unsupported:
            return false
        }
    }

    private static func fields(in schema: JSONValue?) -> [CodexElicitationField]? {
        guard let schema = schema?.objectValue,
              schema["type"]?.stringValue == "object",
              let properties = schema["properties"]?.objectValue,
              Set(schema.keys).isSubset(of: ["type", "properties", "required", "$schema", "additionalProperties"]),
              schema["additionalProperties"] == nil || schema["additionalProperties"]?.boolValue != nil,
              schema["required"] == nil || schema["required"] == .null || schema["required"]?.arrayValue != nil
        else { return nil }
        let requiredValues = schema["required"]?.arrayValue ?? []
        let required = Set(requiredValues.compactMap(\.stringValue))
        guard required.count == requiredValues.count,
              required.isSubset(of: Set(properties.keys)) else { return nil }
        let fields = properties.keys.sorted().compactMap { key in
            properties[key].flatMap { CodexElicitationField(id: key, required: required.contains(key), schema: $0) }
        }
        return fields.count == properties.count ? fields : nil
    }
}

nonisolated struct CodexElicitationField: Equatable, Identifiable, Sendable {
    struct Option: Equatable, Identifiable, Sendable {
        let id: String
        let title: String
    }

    enum Kind: Equatable, Sendable {
        case text(format: String?, minimum: Double?, maximum: Double?)
        case number(integer: Bool, minimum: Double?, maximum: Double?)
        case boolean
        case choice([Option])
        case multiple([Option], minimum: Double?, maximum: Double?)
    }

    let id: String
    let title: String
    let description: String?
    let required: Bool
    let kind: Kind
    private let initialValue: JSONValue?

    var defaultValue: JSONValue? {
        initialValue.flatMap { accepts($0) ? $0 : nil }
    }

    init?(id: String, required: Bool, schema: JSONValue) {
        self.id = id
        title = schema["title"]?.stringValue ?? id
        description = schema["description"]?.stringValue
        self.required = required
        initialValue = schema["default"]
        var keywords: Set<String> = ["title", "description", "default", "type"]
        switch schema["type"]?.stringValue {
        case "string":
            if schema["oneOf"] != nil || schema["enum"] != nil {
                guard let options = Self.options(titled: schema["oneOf"], plain: schema["enum"],
                                                 names: schema["enumNames"]) else { return nil }
                kind = .choice(options)
                keywords.formUnion(["oneOf", "enum", "enumNames"])
            } else {
                let format = schema["format"]?.stringValue
                if let format, !["email", "uri", "date", "date-time"].contains(format) { return nil }
                kind = .text(format: format, minimum: schema["minLength"]?.doubleValue,
                             maximum: schema["maxLength"]?.doubleValue)
                keywords.formUnion(["format", "minLength", "maxLength"])
            }
        case "integer", "number":
            kind = .number(integer: schema["type"]?.stringValue == "integer",
                           minimum: schema["minimum"]?.doubleValue, maximum: schema["maximum"]?.doubleValue)
            keywords.formUnion(["minimum", "maximum"])
        case "boolean":
            kind = .boolean
        case "array":
            guard let items = schema["items"]?.objectValue,
                  Set(items.keys).isSubset(of: ["type", "anyOf", "enum"]),
                  let options = Self.options(titled: items["anyOf"], plain: items["enum"], names: nil) else { return nil }
            kind = .multiple(options, minimum: schema["minItems"]?.doubleValue, maximum: schema["maxItems"]?.doubleValue)
            keywords.formUnion(["items", "minItems", "maxItems"])
        default:
            return nil
        }
        guard let schema = schema.objectValue, Set(schema.keys).isSubset(of: keywords) else { return nil }
    }

    func accepts(_ value: JSONValue) -> Bool {
        switch (kind, value) {
        case (.text(let format, let minimum, let maximum), .string(let text)):
            return Self.within(Double(text.unicodeScalars.count), minimum, maximum) && Self.matches(text, format: format)
        case (.number(let integer, let minimum, let maximum), .number(let number)):
            return number.isFinite && (!integer || number.rounded(.towardZero) == number)
                && Self.within(number, minimum, maximum)
        case (.boolean, .bool):
            return true
        case (.choice(let options), .string(let choice)):
            return options.contains { $0.id == choice }
        case (.multiple(let options, let minimum, let maximum), .array(let choices)):
            let values = choices.compactMap(\.stringValue)
            return values.count == choices.count && Set(values).count == choices.count
                && Set(values).isSubset(of: Set(options.map(\.id)))
                && Self.within(Double(choices.count), minimum, maximum)
        default:
            return false
        }
    }

    private static func within(_ value: Double, _ minimum: Double?, _ maximum: Double?) -> Bool {
        (minimum.map { value >= $0 } ?? true) && (maximum.map { value <= $0 } ?? true)
    }

    private static func matches(_ text: String, format: String?) -> Bool {
        switch format {
        case "email":
            return text.range(of: #"^[^@\s]+@[^@\s]+$"#, options: .regularExpression) != nil
        case "uri":
            return text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
                && URLComponents(string: text)?.scheme != nil
        case "date":
            guard text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
                  let date = try? Date.ISO8601FormatStyle().year().month().day().parse(text) else { return false }
            return date.formatted(Date.ISO8601FormatStyle().year().month().day()) == text
        case "date-time":
            let format = Date.ISO8601FormatStyle()
            return (try? format.parse(text)) != nil || (try? format.time(includingFractionalSeconds: true).parse(text)) != nil
        default:
            return true
        }
    }

    private static func options(titled: JSONValue?, plain: JSONValue?, names: JSONValue?) -> [Option]? {
        let options: [Option]
        if let entries = titled?.arrayValue {
            options = entries.compactMap { entry in
                guard let id = entry["const"]?.stringValue, let title = entry["title"]?.stringValue else { return nil }
                return Option(id: id, title: title)
            }
            guard options.count == entries.count else { return nil }
        } else if let entries = plain?.arrayValue {
            let labels = names?.arrayValue ?? []
            options = entries.enumerated().compactMap { index, entry in
                guard let id = entry.stringValue else { return nil }
                let title = labels.indices.contains(index) ? labels[index].stringValue ?? id : id
                return Option(id: id, title: title)
            }
            guard options.count == entries.count else { return nil }
        } else {
            return nil
        }
        return Set(options.map(\.id)).count == options.count ? options : nil
    }
}
