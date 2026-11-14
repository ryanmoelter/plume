import Foundation

/// The `<side-sessions-event>` footer under a note one session sends another.
///
/// Plume's footers hold this as JSON, so the chat can name the other session
/// and select its tab. Claude Code Desktop writes prose there instead, which
/// decodes as `.other` carrying that prose.
nonisolated struct SideSessionEvent: Equatable, Codable {
    enum Kind: String, Codable {
        case turnFinished = "turn_finished"
        case message
        /// The user started a session the parent had proposed.
        case proposalStarted = "proposal_started"
        /// The user started a session from the parent's offer after the
        /// parent's call had stopped waiting for the answer.
        case offerStarted = "offer_started"
        case other
    }

    static let tag = "side-sessions-event"

    var kind: Kind
    /// The other session: the one the note is about, which a click selects.
    var sessionID: String?
    var name: String?
    var title: String?
    var text: String
    /// True when the note came from the session that started this one.
    var fromParent: Bool = false

    private enum CodingKeys: String, CodingKey {
        case kind = "event"
        case sessionID = "session_id"
        case name, title, text
        case fromParent = "from_parent"
    }

    init(kind: Kind, sessionID: String? = nil, name: String? = nil, title: String? = nil, text: String, fromParent: Bool = false) {
        self.kind = kind
        self.sessionID = sessionID
        self.name = name
        self.title = title
        self.text = text
        self.fromParent = fromParent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container.decode(Kind.self, forKey: .kind)) ?? .other
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        fromParent = try container.decodeIfPresent(Bool.self, forKey: .fromParent) ?? false
    }

    /// A footer's body: Plume's JSON, or anything else as prose.
    static func decoding(body: String) -> SideSessionEvent {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), let event = try? JSONDecoder().decode(SideSessionEvent.self, from: Data(trimmed.utf8)) {
            return event
        }
        return SideSessionEvent(kind: .other, text: trimmed)
    }

    var footer: String {
        let encoder = JSONEncoder()
        // Slashes stay escaped, so quoted text can never close the tag as `</`.
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "<\(Self.tag)>\(json)</\(Self.tag)>"
    }

    var displayName: String? { name ?? title }

    /// The note as one line of plain text: "↳ fix-login finished a turn:
    /// Tests pass". A view draws `InjectedContent.markerSymbol` beside
    /// `sentence` instead.
    var summary: String {
        switch kind {
        case .turnFinished, .message, .proposalStarted, .offerStarted: "\(fromParent ? "↑" : "↳") \(sentence)"
        case .other: sentence
        }
    }

    /// "fix-login finished a turn: Tests pass".
    var sentence: String {
        let firstLine = text.split(omittingEmptySubsequences: true) {
            $0 == "\n" || $0 == ChildSessionFormats.newlineMark
        }.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let who = displayName ?? "A session"
        switch kind {
        case .turnFinished:
            return firstLine.isEmpty ? "\(who) finished a turn" : "\(who) finished a turn: \(firstLine)"
        case .message:
            return firstLine.isEmpty ? "\(who) sent a message" : "\(who) sent a message: \(firstLine)"
        case .proposalStarted:
            return "\(who) started from its proposal"
        case .offerStarted:
            return "\(who) started from its offer"
        case .other:
            return firstLine.isEmpty ? "Sessions update" : firstLine
        }
    }
}
