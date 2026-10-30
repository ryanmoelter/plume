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
        var isDormant = false
        var hasSession = false
        /// What a pending, non-interactive permission request wants to run.
        var permissionToolName: String?
        var workStartedAt: Date?
        /// The last assistant prose, consulted only for an unread tab.
        var preview: String?
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

        var id: UUID { tabID }
    }

    private(set) var needsYou: [Item] = []
    private(set) var running: [Item] = []
    private(set) var notStarted: [Item] = []

    static let previewCharacterLimit = 280

    init(entries: [Entry]) {
        let agentTabCounts = Dictionary(entries.map { ($0.taskID, 1) }, uniquingKeysWith: +)
        var needsYou: [(index: Int, item: Item)] = []
        for (index, entry) in entries.enumerated() {
            let item = Item(
                taskID: entry.taskID,
                tabID: entry.tabID,
                taskTitle: entry.taskTitle,
                tabTitle: agentTabCounts[entry.taskID, default: 0] > 1 ? entry.tabTitle : nil,
                status: entry.status,
                isUnread: entry.isUnread,
                reason: Self.reason(for: entry),
                workStartedAt: entry.status.isActive ? entry.workStartedAt : nil
            )
            if Self.needsYou(status: entry.status, isUnread: entry.isUnread) {
                needsYou.append((index, item))
            } else if entry.status.isActive {
                running.append(item)
            } else if (entry.isDormant && entry.hasSession) || entry.status == .interrupted {
                notStarted.append(item)
            }
        }
        // A tab that wants an answer outranks one that only finished, and the
        // sidebar's order breaks ties.
        self.needsYou = needsYou.sorted { lhs, rhs in
            let left = Self.rank(lhs.item), right = Self.rank(rhs.item)
            return left != right ? left > right : lhs.index < rhs.index
        }.map(\.item)
    }

    static func needsYou(status: TaskStatus, isUnread: Bool) -> Bool {
        status.wantsAttention || isUnread
    }

    private static func rank(_ item: Item) -> Int {
        item.status.wantsAttention ? item.status.priority : -1
    }

    static func reason(for entry: Entry) -> String? {
        switch entry.status {
        case .planApproval: return "Plan ready for review"
        case .questionAsked: return "Asked a question"
        case .permissionNeeded:
            return entry.permissionToolName.map { "Wants to run \($0)" } ?? "Wants permission to continue"
        case .needsTerminalInput: return "Waiting for terminal input"
        case .notStarted, .working, .waitingOnSubagents, .awaitingReply, .done, .interrupted, .error:
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
    /// their own line — headings, quotes, list bullets — then joins the rest.
    static func previewText(_ markdown: String) -> String? {
        var inFence = false
        var lines: [Substring] = []
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.drop { $0.isWhitespace }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            guard !inFence else { continue }
            let stripped = strippingLineMarker(line)
            if !stripped.isEmpty { lines.append(stripped) }
        }
        let joined = lines.joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !joined.isEmpty else { return nil }
        guard joined.count > previewCharacterLimit else { return joined }
        let cut = joined.prefix(previewCharacterLimit)
            .trimmingCharacters(in: .whitespaces)
        return cut + "…"
    }

    private static func strippingLineMarker(_ line: Substring) -> Substring {
        var line = line
        if line.hasPrefix("#") || line.hasPrefix(">") {
            line = line.drop { $0 == "#" || $0 == ">" }
        } else if let marker = line.first, "-*+".contains(marker), line.dropFirst().first == " " {
            line = line.dropFirst()
        }
        return line.drop { $0.isWhitespace }
    }
}
