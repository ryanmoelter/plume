#if DEBUG
import CoreGraphics
import Foundation

/// The control server's wire vocabulary: one NDJSON request per line, one
/// response per line, correlated by `id`. Rects and points are top-left
/// content-view coordinates. `docs/control-server.md` is the reference.
nonisolated struct ControlServerRequest: Decodable {
    let id: String
    let command: ControlCommand

    private enum CodingKeys: String, CodingKey { case id, command }

    init(id: String, command: ControlCommand) {
        self.id = id
        self.command = command
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .command)
        switch name {
        case "list": command = .list(try ListParams(from: decoder))
        case "describe": command = .describe(try TargetParams(from: decoder).target)
        case "invoke": command = .invoke(try TargetParams(from: decoder).target)
        case "setValue": command = .setValue(try SetValueParams(from: decoder))
        case "readText": command = .readText(try TargetParams(from: decoder).target)
        case "clickSpan": command = .clickSpan(try ClickSpanParams(from: decoder))
        case "click": command = .click(try ClickParams(from: decoder))
        case "screenshot": command = .screenshot(try ScreenshotParams(from: decoder))
        case "hierarchy": command = .hierarchy(try HierarchyParams(from: decoder))
        case "hover": command = .hover(try HoverParams(from: decoder))
        case "clear": command = .clear(try ClearParams(from: decoder))
        case "drag": command = .drag(try DragParams(from: decoder))
        case "key": command = .key(try KeyParams(from: decoder))
        case "menu": command = .menu
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .command, in: container, debugDescription: "unknown command \"\(name)\""
            )
        }
    }
}

nonisolated enum ControlCommand {
    case list(ListParams)
    case describe(ControlTarget)
    case invoke(ControlTarget)
    case setValue(SetValueParams)
    case readText(ControlTarget)
    case clickSpan(ClickSpanParams)
    case click(ClickParams)
    case screenshot(ScreenshotParams)
    case hierarchy(HierarchyParams)
    case hover(HoverParams)
    case clear(ClearParams)
    case drag(DragParams)
    case key(KeyParams)
    case menu
}

/// A chord to press, written the way the settings editor writes it: a single
/// character plus modifier names (`command`, `shift`, `option`, `control`).
nonisolated struct KeyParams: Decodable {
    var key: String
    var modifiers: [String] = []
    var windowNumber: Int?

    private enum CodingKeys: String, CodingKey { case key, modifiers, windowNumber }

    init(key: String, modifiers: [String] = [], windowNumber: Int? = nil) {
        self.key = key
        self.modifiers = modifiers
        self.windowNumber = windowNumber
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        modifiers = try c.decodeIfPresent([String].self, forKey: .modifiers) ?? []
        windowNumber = try c.decodeIfPresent(Int.self, forKey: .windowNumber)
    }
}

/// `plumeID`, not `id`: the request envelope's `id` is the correlation id.
nonisolated struct ListParams: Decodable {
    var windowNumber: Int?
    var plumeID: String?
    var label: String?
}

nonisolated struct TargetParams: Decodable {
    var target: ControlTarget
}

nonisolated struct SetValueParams: Decodable {
    var target: ControlTarget
    var value: String
}

nonisolated struct ClickSpanParams: Decodable {
    var matching: String
    var target: ControlTarget?
    var occurrence: Int = 0

    private enum CodingKeys: String, CodingKey { case matching, target, occurrence }

    init(matching: String, target: ControlTarget? = nil, occurrence: Int = 0) {
        self.matching = matching
        self.target = target
        self.occurrence = occurrence
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        matching = try c.decode(String.self, forKey: .matching)
        target = try c.decodeIfPresent(ControlTarget.self, forKey: .target)
        occurrence = try c.decodeIfPresent(Int.self, forKey: .occurrence) ?? 0
    }
}

nonisolated struct ClickParams: Decodable {
    var x: Double
    var y: Double
    var windowNumber: Int?
    var clickCount: Int = 1

    private enum CodingKeys: String, CodingKey { case x, y, windowNumber, clickCount }

    init(x: Double, y: Double, windowNumber: Int? = nil, clickCount: Int = 1) {
        self.x = x
        self.y = y
        self.windowNumber = windowNumber
        self.clickCount = clickCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        windowNumber = try c.decodeIfPresent(Int.self, forKey: .windowNumber)
        clickCount = try c.decodeIfPresent(Int.self, forKey: .clickCount) ?? 1
    }
}

/// Either a `target` or an `x`/`y` point; the point wins when both are given.
nonisolated struct HoverParams: Decodable {
    var target: ControlTarget?
    var x: Double?
    var y: Double?
    var windowNumber: Int?
}

/// What to put on the drag pasteboard, and where to drop it. Either a
/// `target` or an `x`/`y` point names the destination; the point wins when
/// both are given.
nonisolated struct DragParams: Decodable {
    /// Absolute paths, offered as `public.file-url` — a Finder drag.
    var files: [String]?
    /// Offered as `public.utf8-plain-text`, which is what SwiftUI's
    /// `.draggable(String)` puts on the pasteboard.
    var text: String?
    /// Records a Plume `text` payload as the in-app drag first, the way a
    /// real drag source does, so the replay draws feedback and takes the
    /// drop's in-app path instead of loading the payload.
    var inApp: Bool?
    var target: ControlTarget?
    var x: Double?
    var y: Double?
    var windowNumber: Int?
}

/// Every step of the `NSDraggingDestination` handshake, so a drop that
/// highlights and then does nothing is distinguishable from one that was
/// never offered.
nonisolated struct DragResult: Encodable {
    var dropped: Bool
    /// The step that refused, or nil when the drop landed.
    var refusedAt: String?
    /// The class name of the view that answered, or nil when no view under
    /// the point accepts the offered types.
    var view: String?
    var entered: [String]?
    var updated: [String]?
    var prepared: Bool?
    var performed: Bool?
    /// `InAppDrag`'s item and feedback state after `draggingUpdated`, and
    /// after the drop.
    var feedbackAfterUpdate: [String]?
    var feedbackAfterDrop: [String]?
    /// Every drag destination in the window. Reported when the request named
    /// no point, which is how to ask what the window will accept and where.
    var destinations: [DragDestination]?
}

nonisolated struct DragDestination: Encodable {
    var view: String
    var frame: Rect
    var types: [String]
}

nonisolated struct ClearParams: Decodable {
    /// Clears every driven window when nil.
    var windowNumber: Int?
}

nonisolated struct ScreenshotParams: Decodable {
    var path: String?
    var target: ControlTarget?
    var windowNumber: Int?
}

nonisolated enum HierarchyFormat: String, Codable {
    case text, json
}

nonisolated struct HierarchyParams: Decodable {
    var windowNumber: Int?
    var target: ControlTarget?
    var format: HierarchyFormat = .text
    /// Characters of text kept per node; 0 keeps everything.
    var textLimit: Int = 200

    private enum CodingKeys: String, CodingKey { case windowNumber, target, format, textLimit }

    init(windowNumber: Int? = nil, target: ControlTarget? = nil, format: HierarchyFormat = .text, textLimit: Int = 200) {
        self.windowNumber = windowNumber
        self.target = target
        self.format = format
        self.textLimit = textLimit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windowNumber = try c.decodeIfPresent(Int.self, forKey: .windowNumber)
        target = try c.decodeIfPresent(ControlTarget.self, forKey: .target)
        format = try c.decodeIfPresent(HierarchyFormat.self, forKey: .format) ?? .text
        textLimit = try c.decodeIfPresent(Int.self, forKey: .textLimit) ?? 200
    }
}

/// Either a registered control — `{"id": "...", "index"?: n, "label"?: "..."}`
/// — or a well-known surface, `{"kind": "composer" | "chatList" | "window"}`.
nonisolated enum ControlTarget: Codable, Equatable, CustomStringConvertible {
    case control(id: String, index: Int?, label: String?)
    case composer
    case chatList
    case window

    private enum CodingKeys: String, CodingKey { case id, index, label, kind }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let kind = try c.decodeIfPresent(String.self, forKey: .kind) {
            switch kind {
            case "composer": self = .composer
            case "chatList": self = .chatList
            case "window": self = .window
            default:
                throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown kind \"\(kind)\"")
            }
            return
        }
        self = .control(
            id: try c.decode(String.self, forKey: .id),
            index: try c.decodeIfPresent(Int.self, forKey: .index),
            label: try c.decodeIfPresent(String.self, forKey: .label)
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .control(let id, let index, let label):
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(index, forKey: .index)
            try c.encodeIfPresent(label, forKey: .label)
        case .composer: try c.encode("composer", forKey: .kind)
        case .chatList: try c.encode("chatList", forKey: .kind)
        case .window: try c.encode("window", forKey: .kind)
        }
    }

    var description: String {
        switch self {
        case .control(let id, let index, let label):
            id + (index.map { "#\($0)" } ?? "") + (label.map { " \"\($0)\"" } ?? "")
        case .composer: "composer"
        case .chatList: "chatList"
        case .window: "window"
        }
    }
}

nonisolated struct Rect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = rect.minX
        y = rect.minY
        width = rect.width
        height = rect.height
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

nonisolated struct ControlDescription: Codable, Equatable {
    var id: String
    var index: Int
    var label: String?
    var value: String?
    var isEnabled: Bool
    var frame: Rect
    var windowNumber: Int?
    var hasInvoke: Bool
    var hasSetValue: Bool
}

nonisolated struct TextRow: Codable, Equatable {
    var index: Int
    var text: String
}

nonisolated struct TextResult: Codable, Equatable {
    var text: String
    var rows: [TextRow]?
}

nonisolated struct ClickResult: Codable, Equatable {
    var rect: Rect
    var windowNumber: Int
}

nonisolated struct HoverResult: Codable, Equatable {
    var rect: Rect
    var windowNumber: Int
    /// How many `plumeHover` regions the pointer now rests in.
    var regions: Int
}

nonisolated struct ScreenshotResult: Codable, Equatable {
    var path: String
    var width: Int
    var height: Int
    var scale: Double
}

nonisolated struct KeyResult: Codable, Equatable {
    var chord: String
    var keyCode: Int
    var windowNumber: Int
    /// The menu item carrying this chord, or nil when none does. Read this
    /// rather than assuming a press fired the command it was bound to.
    var handledBy: String?
    /// Whether that item was enabled when the chord was looked up. A menu
    /// revalidates as it dispatches, so this can read false for an item that
    /// still fires.
    var handledByEnabled: Bool?
}

/// One menu item, as AppKit holds it — the authority on what chord a command
/// actually carries, as against what `PlumeCommands` asked for.
nonisolated struct MenuItemDescription: Codable, Equatable {
    var path: String
    var keyEquivalent: String?
    var modifiers: [String]
    var isEnabled: Bool
}

nonisolated struct MenuResult: Codable, Equatable {
    var items: [MenuItemDescription]
}

nonisolated struct InvokeResult: Codable, Equatable {
    /// `"closure"` when the control's own action ran, `"click"` when a
    /// synthetic click at its center stood in for one.
    var via: String
}

nonisolated struct HierarchyNode: Codable, Equatable {
    /// The NSView class, or `"control"` for a registered `plumeID` that has
    /// no view of its own.
    var kind: String
    var plumeID: String?
    var index: Int?
    var label: String?
    var value: String?
    var text: String?
    var isEnabled: Bool?
    var frame: Rect
    var children: [HierarchyNode] = []
}

nonisolated struct HierarchyResult: Codable, Equatable {
    var text: String?
    var root: HierarchyNode?
}

nonisolated enum ControlResult: Encodable {
    case controls([ControlDescription])
    case description(ControlDescription)
    case invoked(InvokeResult)
    case empty
    case text(TextResult)
    case click(ClickResult)
    case screenshot(ScreenshotResult)
    case hierarchy(HierarchyResult)
    case hover(HoverResult)
    case drag(DragResult)
    case key(KeyResult)
    case menu(MenuResult)

    func encode(to encoder: Encoder) throws {
        switch self {
        case .controls(let v): try v.encode(to: encoder)
        case .description(let v): try v.encode(to: encoder)
        case .invoked(let v): try v.encode(to: encoder)
        case .empty: try [String: String]().encode(to: encoder)
        case .text(let v): try v.encode(to: encoder)
        case .click(let v): try v.encode(to: encoder)
        case .screenshot(let v): try v.encode(to: encoder)
        case .hierarchy(let v): try v.encode(to: encoder)
        case .hover(let v): try v.encode(to: encoder)
        case .drag(let v): try v.encode(to: encoder)
        case .key(let v): try v.encode(to: encoder)
        case .menu(let v): try v.encode(to: encoder)
        }
    }
}

nonisolated struct ControlServerResponse: Encodable {
    var id: String?
    var ok: Bool
    var result: ControlResult?
    var error: String?

    static func success(id: String, _ result: ControlResult) -> ControlServerResponse {
        ControlServerResponse(id: id, ok: true, result: result, error: nil)
    }

    static func failure(id: String?, _ message: String) -> ControlServerResponse {
        ControlServerResponse(id: id, ok: false, result: nil, error: message)
    }

    func encodedLine() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(self)) ?? Data("{\"ok\":false,\"error\":\"unencodable response\"}".utf8)
        data.append(0x0A)
        return data
    }
}

nonisolated enum ControlError: Error, LocalizedError {
    case notFound(String)
    case ambiguous(String, count: Int)
    case noWindow
    case noComposer
    case unsupported(String)
    case badParams(String)
    case spanNotFound(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let what): "not found: \(what)"
        case .ambiguous(let id, let count): "\(count) controls match \(id); pass index or label"
        case .noWindow: "no window"
        case .noComposer: "no composer in the window"
        case .unsupported(let what): "unsupported: \(what)"
        case .badParams(let what): "bad params: \(what)"
        case .spanNotFound(let needle): "no text matching \"\(needle)\""
        case .io(let what): "io: \(what)"
        }
    }
}
#endif
