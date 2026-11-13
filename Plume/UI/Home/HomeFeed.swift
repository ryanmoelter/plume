import Foundation

/// What the Home view lists, sorted into the conversations that need the user
/// and the quieter ones that are running or can be resumed.
///
/// Built from plain `Entry` values rather than live stores, so it is testable
/// without SwiftData or running sessions. It only reads: nothing here launches
/// or resumes an agent.
struct HomeFeed: Equatable {
    /// One live agent tab, in the order the sidebar shows it.
    struct Entry: Equatable {
        let taskID: UUID
        let tabID: UUID
        let taskTitle: String
        let tabTitle: String
        var status: TaskStatus = .notStarted
        var isUnread = false
        var hasSession = false
        /// Restored from the last launch, with no live session reported yet.
        var isDormant = false
        /// When the task was last opened, or created if never opened.
        var lastOpenedAt: Date?
        /// What a pending, non-interactive permission request wants to run.
        var permissionToolName: String?
        var workStartedAt: Date?
        /// The last assistant prose, consulted only for an unread tab.
        var preview: String?
        var iconName: String?
        var iconTint: SidebarTint?
        var barTint: SidebarTint?
        var context = HomeRowContext()
        var sideWork: [HomeSideWork] = []
    }

    struct Item: Identifiable, Equatable {
        let taskID: UUID
        let tabID: UUID
        let taskTitle: String
        /// Nil unless the task has more than one agent tab, where the task
        /// title alone can't say which conversation this is.
        let tabTitle: String?
        let status: TaskStatus
        let isUnread: Bool
        let reason: String?
        let workStartedAt: Date?
        let iconName: String?
        let iconTint: SidebarTint?
        let barTint: SidebarTint?
        let context: HomeRowContext
        /// Listed under "Not started", which the sidebar's rule dims: never
        /// messaged, or resumed mid-turn.
        let isInactive: Bool
        /// Empty unless the tab is running.
        let sideWork: [HomeSideWork]

        var id: UUID { tabID }

        /// An unread turn's reason is assistant prose; every other reason is
        /// a fixed phrase or a tool name.
        var reasonIsPreview: Bool {
            isUnread && !status.wantsAttention && status != .error
        }
    }

    private(set) var needsYou: [Item] = []
    private(set) var running: [Item] = []
    private(set) var idle: [Item] = []
    private(set) var fromLastTime: [Item] = []
    private(set) var notStarted: [Item] = []

    static let previewCharacterLimit = 280

    init(entries: [Entry]) {
        let agentTabCounts = Dictionary(entries.map { ($0.taskID, 1) }, uniquingKeysWith: +)
        var needsYou: [(index: Int, item: Item)] = []
        var idle: [(index: Int, openedAt: Date?, item: Item)] = []
        for (index, entry) in entries.enumerated() {
            let isUnstarted = !entry.status.isActive
                && !Self.needsYou(status: entry.status, isUnread: entry.isUnread)
                && Self.isUnstarted(entry)
            let item = Item(
                taskID: entry.taskID,
                tabID: entry.tabID,
                taskTitle: entry.taskTitle,
                tabTitle: agentTabCounts[entry.taskID, default: 0] > 1 ? entry.tabTitle : nil,
                status: entry.status,
                isUnread: entry.isUnread,
                reason: Self.reason(for: entry),
                workStartedAt: entry.status.isActive ? entry.workStartedAt : nil,
                iconName: entry.iconName,
                iconTint: entry.iconTint,
                barTint: entry.barTint,
                context: entry.context,
                isInactive: isUnstarted,
                sideWork: entry.sideWork
            )
            if entry.status.isActive {
                running.append(item)
            } else if Self.needsYou(status: entry.status, isUnread: entry.isUnread) {
                needsYou.append((index, item))
            } else if isUnstarted {
                notStarted.append(item)
            } else if entry.isDormant {
                fromLastTime.append(item)
            } else {
                idle.append((index, entry.lastOpenedAt, item))
            }
        }
        // A tab that wants an answer outranks one that only finished, and the
        // sidebar's order breaks ties.
        self.needsYou = needsYou.sorted { lhs, rhs in
            let left = Self.rank(lhs.item), right = Self.rank(rhs.item)
            return left != right ? left > right : lhs.index < rhs.index
        }.map(\.item)
        self.idle = idle.sorted { lhs, rhs in
            switch (lhs.openedAt, rhs.openedAt) {
            case let (left?, right?) where left != right: left > right
            case (nil, _?): false
            case (_?, nil): true
            default: lhs.index < rhs.index
            }
        }.map(\.item)
    }

    static func needsYou(status: TaskStatus, isUnread: Bool) -> Bool {
        guard !status.isActive else { return false }
        return status.wantsAttention || status == .interruptedByRestart || status == .error || isUnread
    }

    /// A conversation never messaged, or one the user cut off mid-turn. An
    /// idle one with a session is finished, and lists as idle, or under
    /// "From last time" while it is still dormant.
    private static func isUnstarted(_ entry: Entry) -> Bool {
        entry.status == .interrupted || !entry.hasSession
    }

    /// Higher sorts first. Home's own order, apart from `TaskStatus.priority`,
    /// which the sidebar uses.
    private static func rank(_ item: Item) -> Int {
        switch item.status {
        case .error: 6
        case .interruptedByRestart: 5
        case .permissionNeeded: 4
        case .needsTerminalInput: 3
        case .questionAsked: 2
        case .planApproval: 1
        default: 0
        }
    }

    static func reason(for entry: Entry) -> String? {
        switch entry.status {
        case .planApproval: return "Plan ready for review"
        case .questionAsked: return "Asked a question"
        case .permissionNeeded:
            return entry.permissionToolName.map { "Wants to run \($0)" } ?? "Wants permission to continue"
        case .needsTerminalInput: return "Waiting for terminal input"
        case .error: return "Stopped with an error"
        case .interruptedByRestart: return "Interrupted by restart"
        case .notStarted, .working, .waitingOnSubagents, .awaitingReply, .done, .interrupted:
            guard entry.isUnread else { return nil }
            return entry.preview ?? "Finished a turn you haven't read"
        }
    }

    /// The prose of the last assistant message that has any, flattened to one
    /// line for a two-line preview.
    static func preview(of messages: [ChatMessage]) -> String? {
        for message in messages.reversed() where message.role == .assistant {
            for block in message.blocks.reversed() {
                guard case .markdown(let markdown) = block,
                      let text = previewText(markdown)
                else { continue }
                return text
            }
        }
        return nil
    }

    /// Drops code blocks and the line markers that only mean something on
    /// their own line — headings, quotes, list markers — then joins the rest.
    static func previewText(_ markdown: String) -> String? {
        var openFence: (character: Character, length: Int)?
        var lines: [Substring] = []
        for rawLine in markdown.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = rawLine.drop { $0.isWhitespace }
            if let fence = openFence {
                if closes(fence, line) { openFence = nil }
                continue
            }
            if let fence = fenceOpening(line) {
                openFence = fence
                continue
            }
            if let stripped = strippingLineMarker(line) { lines.append(stripped) }
        }
        let joined = lines.joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !joined.isEmpty else { return nil }
        guard joined.count > previewCharacterLimit else { return joined }
        let head = joined.prefix(previewCharacterLimit - 1)
        let endsOnWordBoundary = joined[head.endIndex].isWhitespace
        let words = endsOnWordBoundary ? head : head[..<(head.lastIndex(where: \.isWhitespace) ?? head.endIndex)]
        return words.trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func fenceOpening(_ line: Substring) -> (character: Character, length: Int)? {
        guard let character = line.first, character == "`" || character == "~" else { return nil }
        let length = line.prefix { $0 == character }.count
        return length >= 3 ? (character, length) : nil
    }

    private static func closes(_ fence: (character: Character, length: Int), _ line: Substring) -> Bool {
        let run = line.prefix { $0 == fence.character }
        return run.count >= fence.length && run.count == line.trimmingCharacters(in: .whitespaces).count
    }

    private static func strippingLineMarker(_ line: Substring) -> Substring? {
        var line = line
        if isRuleOrTableSeparator(line) { return nil }
        while let rest = removingOneMarker(from: line) { line = rest.drop { $0.isWhitespace } }
        return line.isEmpty || line.allSatisfy({ $0 == "#" }) ? nil : line
    }

    private static func removingOneMarker(from line: Substring) -> Substring? {
        let marker = line.prefix { $0 == "#" || $0 == ">" }
        if !marker.isEmpty, line.dropFirst(marker.count).first == " " {
            return line.dropFirst(marker.count)
        }
        if let bullet = line.first, "-*+".contains(bullet), line.dropFirst().first == " " {
            return line.dropFirst()
        }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        let afterDigits = line.dropFirst(digits.count)
        if !digits.isEmpty, let end = afterDigits.first, ".)".contains(end), afterDigits.dropFirst().first == " " {
            return afterDigits.dropFirst()
        }
        return nil
    }

    private static func isRuleOrTableSeparator(_ line: Substring) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        if compact.count >= 3, let first = compact.first, "-*_".contains(first), compact.allSatisfy({ $0 == first }) {
            return true
        }
        return compact.contains("|") && compact.allSatisfy { "|-:".contains($0) } && compact.contains("-")
    }
}
