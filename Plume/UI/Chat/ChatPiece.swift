import Foundation

/// One item of the chat list.
///
/// A piece is the smallest unit the list can place on its own: one markdown
/// block, one thinking row, one tool call, one notice, the streaming overlay,
/// the working indicator. Splitting messages this way is what keeps a single
/// item from towering over its neighbors — see `docs/chat-list.md` for why
/// that matters and `ChatPieceSplitter` for how it is done.
struct ChatPiece: Identifiable, Equatable {
    /// Deterministic from the message id and the block's original index, so a
    /// re-parse or a tool result landing keeps a row's view state alive.
    ///
    /// Unique across kinds by the depth of the path rather than by naming the
    /// kind: `<message>/<block>` for a whole block, one component deeper for a
    /// markdown block within it, one deeper again for a segment of a split
    /// one. Every component is an `Int`, so no shorter path can collide with a
    /// longer one. A duplicate here is a hang rather than a visible glitch, so
    /// `ChatPieceSplitterTests` asserts it.
    var id: String
    var messageID: String
    var role: ChatMessage.Role
    var content: Content
    var wash: Wash
    /// Where this piece sits in its message's wash group.
    var segment: Segment = .single
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    /// The raw markdown of a block the stream wrote, kept so the piece can
    /// type it out. Set while the block is still arriving and kept after it
    /// settles, which is what lets one view finish a reveal the block's
    /// completion would otherwise cut short. Nil for transcript content,
    /// which never types.
    var streamSource: String?
    /// Whether the stream is still writing this block.
    var isArriving: Bool = false
    /// The markdown this piece's own copy button yields — the lines it was
    /// parsed from where the splitter kept them, written back from the block
    /// otherwise. Nil for a piece that is not markdown at all.
    var copySource: String?
    /// The markdown of every block in this piece's message, set only on the
    /// message's last markdown piece so one footer copies the whole reply.
    var messageCopySource: String?
    /// When the message was sent, shown beside the copy button in the footer.
    /// Set on the same piece as `messageCopySource`, and nil where the
    /// transcript recorded no time.
    var timestamp: Date?

    enum Content: Equatable {
        case markdown(MarkdownBlock, index: Int)
        case codeSegment(CodeSegment)
        case listSegment(ListSegment)
        case thinking(String)
        case toolCall(ToolCall, isPending: Bool)
        case injected(InjectedContent, text: String)
        /// Names the agent whose message the pieces below it are.
        case agentMessageTitle(name: String?)
        case notice(ChatNotice)
        case image(ChatImage)
        case streaming(ChatStreamHandoff.Overlay)
        case working
    }

    /// The background a message's pieces share, drawn per piece with only the
    /// corners and edges that piece owns.
    enum Wash: Equatable {
        case none
        /// The user's bubble.
        case bubble
        /// Another agent's message, in the user's bubble but on the opposite
        /// side, since it arrived rather than being sent.
        case agentBubble
        /// The needs-input treatment on the newest assistant message.
        case attention

        /// Whether the wash is a message bubble, which hugs its text and sits
        /// against one edge of the column.
        var isBubble: Bool { self == .bubble || self == .agentBubble }
    }

    enum Segment: Equatable {
        case single
        case first
        case middle
        case last

        var isFirst: Bool { self == .single || self == .first }
        var isLast: Bool { self == .single || self == .last }
    }

    /// The agent's voice earns the serif; the user's own words and a tool's
    /// output stay in the system face.
    var isAgentVoice: Bool { role == .assistant }

    /// A short name for the kind of content, for the stats probe's log.
    var kindName: String {
        switch content {
        case .markdown(let block, _): "markdown.\(block.kindName)"
        case .codeSegment: "code"
        case .listSegment: "list"
        case .thinking: "thinking"
        case .toolCall: "toolCall"
        case .injected: "injected"
        case .agentMessageTitle: "agentMessageTitle"
        case .notice: "notice"
        case .image: "image"
        case .streaming: "streaming"
        case .working: "working"
        }
    }

    var isStreaming: Bool {
        if case .streaming = content { return true }
        return false
    }

    /// A piece the turn in flight is still changing, by either route.
    var isLive: Bool { isStreaming || isArriving }

    /// A piece whose wash continues into its neighbours. The gap above it is
    /// painted inside that wash, so the joined shape has no break in it.
    var isJoined: Bool { wash != .none && segment != .single }

    /// Whether the list applies this piece's top inset outside its wash.
    var paysInsetOutside: Bool { !isJoined || segment == .first }

    /// The markdown this piece offers to copy on its own.
    ///
    /// A table only. Every other block is either prose the reader can select,
    /// or a code block that carries `CodeBlockCopyButton` already — a button
    /// on each of them would put one on every paragraph of every reply.
    var tableCopySource: String? {
        guard case .markdown(.table, _) = content else { return nil }
        return copySource
    }

    /// Whether this piece offers the whole message's markdown. Never while
    /// the turn is still writing it, when the source is still growing.
    var offersMessageCopy: Bool { messageCopySource != nil && !isLive }
}

/// One fenced code block, always whole: a long one is bounded and scrolls
/// inside itself rather than being split across pieces.
struct CodeSegment: Equatable {
    var language: String?
    var code: String
    var isMermaid: Bool = false
}

/// A slice of one list.
///
/// Each item carries its own depth and number, so a segment needs nothing
/// from the items above it to indent and number itself correctly.
struct ListSegment: Equatable {
    var items: [MarkdownBlock.ListItem]
    var position: ChatPiece.Segment = .single
}
