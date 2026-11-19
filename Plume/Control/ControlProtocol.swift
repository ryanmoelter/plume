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
        case "pointerDrag": command = .pointerDrag(try PointerDragParams(from: decoder))
        case "screenshot": command = .screenshot(try ScreenshotParams(from: decoder))
        case "recordStart": command = .recordStart(try RecordStartParams(from: decoder))
        case "recordStop": command = .recordStop
        case "hierarchy": command = .hierarchy(try HierarchyParams(from: decoder))
        case "hover": command = .hover(try HoverParams(from: decoder))
        case "clear": command = .clear(try ClearParams(from: decoder))
        case "drag": command = .drag(try DragParams(from: decoder))
        case "key": command = .key(try KeyParams(from: decoder))
        case "menu": command = .menu
        case "windowSize": command = .windowSize(try WindowSizeParams(from: decoder))
        case "selection": command = .selection
        case "selectText": command = .selectText(try SelectTextParams(from: decoder))
        case "tasks": command = .tasks
        case "selectTask": command = .selectTask(try SelectTaskParams(from: decoder))
        case "appendTurn": command = .appendTurn(try AppendTurnParams(from: decoder))
        case "resize": command = .resize(try ResizeParams(from: decoder))
        case "scrollChat": command = .scrollChat(try ScrollChatParams(from: decoder))
        case "tab.move": command = .moveTab(try TabMoveParams(from: decoder))
        case "tab.split": command = .splitTab(try TabMoveParams(from: decoder))
        case "sidebar.reveal": command = .revealInSidebar(try SidebarRevealParams(from: decoder))
        case "tab.status": command = .setTabStatus(try TabStatusParams(from: decoder))
        case "child-session.start": command = .startChildSession(try ChildSessionStartParams(from: decoder))
        case "child-session.report": command = .reportChildSession(try ChildSessionReportParams(from: decoder))
        case "child-session.propose": command = .proposeChildSession(try ChildSessionProposeParams(from: decoder))
        case "child-session.proposals": command = .listChildSessionProposals(try ChildSessionProposalsParams(from: decoder))
        case "child-session.proposal.start": command = .startChildSessionProposal(try ChildSessionProposalParams(from: decoder))
        case "child-session.proposal.dismiss": command = .dismissChildSessionProposal(try ChildSessionProposalParams(from: decoder))
        case "child-session.offer": command = .offerChildSession(try ChildSessionProposeParams(from: decoder))
        case "child-session.offers": command = .listChildSessionOffers(try ChildSessionProposalsParams(from: decoder))
        case "child-session.offer.answer": command = .answerChildSessionOffer(try ChildSessionOfferAnswerParams(from: decoder))
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
    case pointerDrag(PointerDragParams)
    case screenshot(ScreenshotParams)
    case recordStart(RecordStartParams)
    case recordStop
    case hierarchy(HierarchyParams)
    case hover(HoverParams)
    case clear(ClearParams)
    case drag(DragParams)
    case key(KeyParams)
    case menu
    case windowSize(WindowSizeParams)
    case selection
    case selectText(SelectTextParams)
    case tasks
    case selectTask(SelectTaskParams)
    case appendTurn(AppendTurnParams)
    case resize(ResizeParams)
    case scrollChat(ScrollChatParams)
    case moveTab(TabMoveParams)
    case splitTab(TabMoveParams)
    case revealInSidebar(SidebarRevealParams)
    case setTabStatus(TabStatusParams)
    case startChildSession(ChildSessionStartParams)
    case reportChildSession(ChildSessionReportParams)
    case proposeChildSession(ChildSessionProposeParams)
    case listChildSessionProposals(ChildSessionProposalsParams)
    case startChildSessionProposal(ChildSessionProposalParams)
    case dismissChildSessionProposal(ChildSessionProposalParams)
    case offerChildSession(ChildSessionProposeParams)
    case listChildSessionOffers(ChildSessionProposalsParams)
    case answerChildSessionOffer(ChildSessionOfferAnswerParams)
}

/// Sets the window's content size, in points. With `live`, the size steps
/// from the current one to the requested one inside a live resize, the way
/// dragging the window's edge does: `viewWillStartLiveResize`, `steps`
/// sizes, then `viewDidEndLiveResize`.
nonisolated struct ResizeParams: Decodable, Equatable {
    static let stepLimit = 120

    var width: Double
    var height: Double
    var windowNumber: Int?
    var live: Bool = false
    var steps: Int = 8
    /// Seconds between live steps, so each one gets a run-loop pass.
    var stepDelay: Double = 0.016

    private enum CodingKeys: String, CodingKey { case width, height, windowNumber, live, steps, stepDelay }

    init(width: Double, height: Double, windowNumber: Int? = nil, live: Bool = false, steps: Int = 8, stepDelay: Double = 0.016) {
        self.width = width
        self.height = height
        self.windowNumber = windowNumber
        self.live = live
        self.steps = min(max(steps, 1), Self.stepLimit)
        self.stepDelay = min(max(stepDelay, 0), 1)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            width: try c.decode(Double.self, forKey: .width),
            height: try c.decode(Double.self, forKey: .height),
            windowNumber: try c.decodeIfPresent(Int.self, forKey: .windowNumber),
            live: try c.decodeIfPresent(Bool.self, forKey: .live) ?? false,
            steps: try c.decodeIfPresent(Int.self, forKey: .steps) ?? 8,
            stepDelay: try c.decodeIfPresent(Double.self, forKey: .stepDelay) ?? 0.016
        )
    }
}

nonisolated struct ResizeResult: Codable, Equatable {
    var windowNumber: Int
    /// The content size the window ended at, which AppKit clamps to the
    /// window's minimum and maximum.
    var width: Double
    var height: Double
    /// Every content size set along the way; one entry unless `live`.
    var sizes: [Size]
    var live: Bool
}

/// Selects `task` and measures the switch with `SwitchLatencyProbe`,
/// `repeat` times. With `from`, each round first selects `from`, unmeasured,
/// so every measured switch starts from the same task. Tasks match by id,
/// then by exact title, then by a unique title substring, ignoring case.
nonisolated struct SelectTaskParams: Decodable, Equatable {
    static let repeatLimit = 200

    var task: String
    var from: String?
    var repeatCount: Int = 1
    /// Seconds a switch may take to place rows before it counts as timed out.
    var timeout: Double = 5
    /// Seconds to wait after each switch, so work it deferred doesn't land
    /// in the next one's measurement.
    var settle: Double = 0.3

    private enum CodingKeys: String, CodingKey {
        case task, from, timeout, settle
        case repeatCount = "repeat"
    }

    init(task: String, from: String? = nil, repeatCount: Int = 1, timeout: Double = 5, settle: Double = 0.3) {
        self.task = task
        self.from = from
        self.repeatCount = min(max(repeatCount, 1), Self.repeatLimit)
        self.timeout = max(timeout, 0.1)
        self.settle = max(settle, 0)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            task: try c.decode(String.self, forKey: .task),
            from: try c.decodeIfPresent(String.self, forKey: .from),
            repeatCount: try c.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 1,
            timeout: try c.decodeIfPresent(Double.self, forKey: .timeout) ?? 5,
            settle: try c.decodeIfPresent(Double.self, forKey: .settle) ?? 0.3
        )
    }
}

/// Appends a synthetic prompt and reply to the selected task's transcript,
/// `repeat` times, and measures each until the prompt's row is on screen.
nonisolated struct AppendTurnParams: Decodable, Equatable {
    static let repeatLimit = 200

    var repeatCount: Int = 1
    /// Seconds an append may take to show its row before it counts as timed out.
    var timeout: Double = 15
    /// Seconds to wait after each append, so its trailing work stays out of
    /// the next one's measurement.
    var settle: Double = 1
    /// Whether a reply is written with each prompt, in the same write.
    var reply = true

    private enum CodingKeys: String, CodingKey {
        case timeout, settle, reply
        case repeatCount = "repeat"
    }

    init(repeatCount: Int = 1, timeout: Double = 15, settle: Double = 1, reply: Bool = true) {
        self.repeatCount = min(max(repeatCount, 1), Self.repeatLimit)
        self.timeout = max(timeout, 0.1)
        self.settle = max(settle, 0)
        self.reply = reply
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            repeatCount: try c.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 1,
            timeout: try c.decodeIfPresent(Double.self, forKey: .timeout) ?? 15,
            settle: try c.decodeIfPresent(Double.self, forKey: .settle) ?? 1,
            reply: try c.decodeIfPresent(Bool.self, forKey: .reply) ?? true
        )
    }
}

/// Scrolls the focused chat list at `speed` points per second, to `to` (`"top"`
/// or `"bottom"`) or `by` signed points, and times every frame on the way.
/// `to` and `by` are kept raw so a request naming both reaches the backend and
/// fails as bad params rather than as a malformed request.
nonisolated struct ScrollChatParams: Decodable, Equatable {
    nonisolated enum Destination: Equatable {
        case top
        case bottom
        case by(Double)
    }

    nonisolated enum ClockChoice: Equatable {
        case auto
        case timer
    }

    var to: String?
    var by: Double?
    var speed: Double = 4000
    /// Seconds to keep measuring once the destination is reached.
    var settle: Double = 0.3
    var maxSeconds: Double = 30
    /// How many of the longest frame intervals to itemize.
    var worst: Int = 5
    /// `"auto"` or `"timer"`, kept raw like `to` so a bad value fails as bad params.
    var clock: String = "auto"

    private enum CodingKeys: String, CodingKey { case to, by, speed, settle, maxSeconds, worst, clock }

    init(
        to: String? = nil, by: Double? = nil, speed: Double = 4000, settle: Double = 0.3, maxSeconds: Double = 30,
        worst: Int = 5, clock: String = "auto"
    ) {
        self.clock = clock
        self.to = to
        self.by = by
        self.speed = max(speed, 1)
        self.settle = max(settle, 0)
        self.maxSeconds = min(max(maxSeconds, 0.1), 300)
        self.worst = min(max(worst, 0), 100)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            to: try c.decodeIfPresent(String.self, forKey: .to),
            by: try c.decodeIfPresent(Double.self, forKey: .by),
            speed: try c.decodeIfPresent(Double.self, forKey: .speed) ?? 4000,
            settle: try c.decodeIfPresent(Double.self, forKey: .settle) ?? 0.3,
            maxSeconds: try c.decodeIfPresent(Double.self, forKey: .maxSeconds) ?? 30,
            worst: try c.decodeIfPresent(Int.self, forKey: .worst) ?? 5,
            clock: try c.decodeIfPresent(String.self, forKey: .clock) ?? "auto"
        )
    }

    func clockChoice() throws -> ClockChoice {
        switch clock {
        case "auto": return .auto
        case "timer": return .timer
        default: throw ControlError.badParams("clock must be \"auto\" or \"timer\", not \"\(clock)\"")
        }
    }

    func destination() throws -> Destination {
        switch (to, by) {
        case (nil, nil), ("top"?, nil): return .top
        case ("bottom"?, nil): return .bottom
        case (nil, let points?): return .by(points)
        case (_?, _?): throw ControlError.badParams("scrollChat takes to or by, not both")
        case (let other?, nil): throw ControlError.badParams("to must be \"top\" or \"bottom\", not \"\(other)\"")
        }
    }
}

nonisolated struct TaskDescription: Codable, Equatable {
    var id: String
    var title: String
    var isSelected: Bool
    /// The focused tab's kind, nil for a task with no tabs.
    var tabKind: String?
    /// Whether the focused tab has a transcript, so a switch to it waits for
    /// chat rows rather than ending with its first turn.
    var expectsRows: Bool
}

nonisolated struct TaskListResult: Codable, Equatable {
    var tasks: [TaskDescription]
}

/// Resolves a `selectTask` query against the window's tasks.
nonisolated enum TaskQuery {
    static func match(_ query: String, in tasks: [(id: UUID, title: String)]) throws -> UUID {
        if let id = UUID(uuidString: query), tasks.contains(where: { $0.id == id }) { return id }
        let exact = tasks.filter { $0.title.caseInsensitiveCompare(query) == .orderedSame }
        if exact.count == 1 { return exact[0].id }
        let partial = tasks.filter { $0.title.localizedCaseInsensitiveContains(query) }
        switch partial.count {
        case 1: return partial[0].id
        case 0: throw ControlError.notFound("task \"\(query)\"")
        default: throw ControlError.badParams("\(partial.count) tasks match \"\(query)\"; pass an id")
        }
    }
}

/// `matching` selects one span. `from` and `to` select from the start of
/// `from` to the end of the first `to` after it.
nonisolated struct SelectTextParams: Decodable, Equatable {
    var matching: String?
    var from: String?
    var to: String?
    var occurrence: Int = 0

    private enum CodingKeys: String, CodingKey { case matching, from, to, occurrence }

    init(matching: String? = nil, from: String? = nil, to: String? = nil, occurrence: Int = 0) {
        self.matching = matching
        self.from = from
        self.to = to
        self.occurrence = occurrence
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        matching = try c.decodeIfPresent(String.self, forKey: .matching)
        from = try c.decodeIfPresent(String.self, forKey: .from)
        to = try c.decodeIfPresent(String.self, forKey: .to)
        occurrence = try c.decodeIfPresent(Int.self, forKey: .occurrence) ?? 0
    }
}

nonisolated struct SelectionPoint: Codable, Equatable {
    var pieceID: String
    var offset: Int
}

/// The focused chat's transcript selection. Empty strings and nil ends when
/// nothing is selected.
nonisolated struct SelectionResult: Codable, Equatable {
    var markdown: String
    var plainText: String
    var anchor: SelectionPoint?
    var focus: SelectionPoint?
}

/// A chord to press: a single character or a key name from
/// `SyntheticKey.named`, plus modifier names (`command`, `shift`, `option`,
/// `control`). An uppercase letter implies Shift.
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

/// Points are in top-left window coordinates, like `ClickParams`.
nonisolated struct PointerDragParams: Decodable {
    var fromX: Double
    var fromY: Double
    var toX: Double
    var toY: Double
    var windowNumber: Int?
    var clickCount: Int = 1
    var steps: Int = 10

    private enum CodingKeys: String, CodingKey { case fromX, fromY, toX, toY, windowNumber, clickCount, steps }

    init(fromX: Double, fromY: Double, toX: Double, toY: Double, windowNumber: Int? = nil, clickCount: Int = 1, steps: Int = 10) {
        self.fromX = fromX
        self.fromY = fromY
        self.toX = toX
        self.toY = toY
        self.windowNumber = windowNumber
        self.clickCount = clickCount
        self.steps = steps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fromX = try c.decode(Double.self, forKey: .fromX)
        fromY = try c.decode(Double.self, forKey: .fromY)
        toX = try c.decode(Double.self, forKey: .toX)
        toY = try c.decode(Double.self, forKey: .toY)
        windowNumber = try c.decodeIfPresent(Int.self, forKey: .windowNumber)
        clickCount = try c.decodeIfPresent(Int.self, forKey: .clickCount) ?? 1
        steps = try c.decodeIfPresent(Int.self, forKey: .steps) ?? 10
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

/// Out-of-range `fps` and `maxSeconds` are clamped rather than refused, so
/// a forgotten recording always ends within `RecordStartParams.secondsLimit`.
nonisolated struct RecordStartParams: Decodable, Equatable {
    static let fpsRange = 1...60
    static let secondsLimit = 300.0

    var path: String?
    var target: ControlTarget?
    var windowNumber: Int?
    var fps: Int = 30
    var maxSeconds: Double = 30

    private enum CodingKeys: String, CodingKey { case path, target, windowNumber, fps, maxSeconds }

    init(path: String? = nil, target: ControlTarget? = nil, windowNumber: Int? = nil, fps: Int = 30, maxSeconds: Double = 30) {
        self.path = path
        self.target = target
        self.windowNumber = windowNumber
        self.fps = min(max(fps, Self.fpsRange.lowerBound), Self.fpsRange.upperBound)
        self.maxSeconds = min(max(maxSeconds, 0.1), Self.secondsLimit)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            path: try c.decodeIfPresent(String.self, forKey: .path),
            target: try c.decodeIfPresent(ControlTarget.self, forKey: .target),
            windowNumber: try c.decodeIfPresent(Int.self, forKey: .windowNumber),
            fps: try c.decodeIfPresent(Int.self, forKey: .fps) ?? 30,
            maxSeconds: try c.decodeIfPresent(Double.self, forKey: .maxSeconds) ?? 30
        )
    }
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

nonisolated struct Size: Codable, Equatable {
    var width: Double
    var height: Double

    init(_ size: CGSize) {
        width = size.width
        height = size.height
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
    /// The composer's selected range, in UTF-16 offsets into `text`.
    var selection: TextRange?
    /// The composer's checkboxes in its visible area, where a `click`
    /// toggles them.
    var checkboxes: [CheckboxDescription]?

    init(text: String, rows: [TextRow]?, selection: TextRange? = nil, checkboxes: [CheckboxDescription]? = nil) {
        self.text = text
        self.rows = rows
        self.selection = selection
        self.checkboxes = checkboxes
    }
}

nonisolated struct CheckboxDescription: Codable, Equatable {
    /// Zero-based, counting every line of the composer's text.
    var line: Int
    var isChecked: Bool
    var rect: Rect
}

nonisolated struct TextRange: Codable, Equatable {
    var location: Int
    var length: Int
}

/// Sets the window's content size when `width` and `height` are given, and
/// reports it either way.
nonisolated struct WindowSizeParams: Decodable {
    var width: Double?
    var height: Double?
    var windowNumber: Int?
}

nonisolated struct WindowSizeResult: Codable, Equatable {
    var windowNumber: Int
    var width: Double
    var height: Double
}

nonisolated struct ClickResult: Codable, Equatable {
    var rect: Rect
    var windowNumber: Int
    /// The class of the view the mouse-down hit-tested to, which is the view
    /// AppKit sends it to.
    var view: String?

    init(rect: Rect, windowNumber: Int, view: String? = nil) {
        self.rect = rect
        self.windowNumber = windowNumber
        self.view = view
    }
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

nonisolated struct RecordStartResult: Codable, Equatable {
    var path: String
    var width: Int
    var height: Int
    var scale: Double
    var fps: Int
    var maxSeconds: Double
}

nonisolated enum RecordingStopReason: String, Codable {
    case request, limit, windowClosed
}

nonisolated struct RecordStopResult: Codable, Equatable {
    var path: String
    var width: Int
    var height: Int
    var frames: Int
    /// Ticks skipped because the encoder was still busy with an earlier frame
    /// or the window server had no image.
    var dropped: Int
    var duration: Double
    var stoppedBy: RecordingStopReason
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
    /// The class of the window's first responder after the press, which is
    /// where an unclaimed key went.
    var firstResponder: String?
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
    case recordStart(RecordStartResult)
    case recordStop(RecordStopResult)
    case hierarchy(HierarchyResult)
    case hover(HoverResult)
    case drag(DragResult)
    case key(KeyResult)
    case menu(MenuResult)
    case windowSize(WindowSizeResult)
    case selection(SelectionResult)
    case tasks(TaskListResult)
    case switchLatency(SwitchLatencyReport)
    case resize(ResizeResult)
    case scrollHitch(ScrollHitchReport)
    case tab(TabTaskResult)
    case sidebarReveal(SidebarRevealResult)
    case tabStatus(TabStatusResult)
    case childSession(ChildSessionResult)
    case childSessionProposals(ChildSessionProposalsResult)
    case childSessionOffers(ChildSessionOffersResult)

    func encode(to encoder: Encoder) throws {
        switch self {
        case .controls(let v): try v.encode(to: encoder)
        case .description(let v): try v.encode(to: encoder)
        case .invoked(let v): try v.encode(to: encoder)
        case .empty: try [String: String]().encode(to: encoder)
        case .text(let v): try v.encode(to: encoder)
        case .click(let v): try v.encode(to: encoder)
        case .screenshot(let v): try v.encode(to: encoder)
        case .recordStart(let v): try v.encode(to: encoder)
        case .recordStop(let v): try v.encode(to: encoder)
        case .hierarchy(let v): try v.encode(to: encoder)
        case .hover(let v): try v.encode(to: encoder)
        case .drag(let v): try v.encode(to: encoder)
        case .key(let v): try v.encode(to: encoder)
        case .menu(let v): try v.encode(to: encoder)
        case .windowSize(let v): try v.encode(to: encoder)
        case .selection(let v): try v.encode(to: encoder)
        case .tasks(let v): try v.encode(to: encoder)
        case .switchLatency(let v): try v.encode(to: encoder)
        case .resize(let v): try v.encode(to: encoder)
        case .scrollHitch(let v): try v.encode(to: encoder)
        case .tab(let v): try v.encode(to: encoder)
        case .sidebarReveal(let v): try v.encode(to: encoder)
        case .tabStatus(let v): try v.encode(to: encoder)
        case .childSession(let v): try v.encode(to: encoder)
        case .childSessionProposals(let v): try v.encode(to: encoder)
        case .childSessionOffers(let v): try v.encode(to: encoder)
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
