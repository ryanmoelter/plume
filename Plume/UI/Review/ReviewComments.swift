#if DEBUG
import Foundation
import SwiftUI

/// A local note on some lines of a review, sent to the agent in a batch.
nonisolated struct ReviewComment: Identifiable, Equatable, Sendable {
    enum Side: Equatable, Sendable {
        /// Line numbers in the file on disk.
        case new
        /// Line numbers at the base, for lines the change removed.
        case old
    }

    let id: UUID
    let path: String
    let side: Side
    let lines: ClosedRange<Int>
    /// The commented lines' text, as they read when the comment was made.
    let quote: [String]
    var body: String

    init(id: UUID = UUID(), path: String, side: Side, lines: ClosedRange<Int>, quote: [String], body: String = "") {
        self.id = id
        self.path = path
        self.side = side
        self.lines = lines
        self.quote = quote
        self.body = body
    }

    /// Anchors on the new side where any line has a new number, since that
    /// is the file the agent can open; a run of removed lines anchors on the
    /// old side.
    init?(path: String, lines: [DiffLine], body: String = "") {
        guard !lines.isEmpty else { return nil }
        let newNumbers = lines.compactMap(\.newNumber)
        let numbers = newNumbers.isEmpty ? lines.compactMap(\.oldNumber) : newNumbers
        guard let first = numbers.min(), let last = numbers.max() else { return nil }
        self.init(
            path: path,
            side: newNumbers.isEmpty ? .old : .new,
            lines: first...last,
            quote: lines.map(\.text),
            body: body
        )
    }

    /// Whether `line` is the last one the comment covers, where it shows.
    func endsAt(_ line: DiffLine) -> Bool {
        switch side {
        case .new: line.newNumber == lines.upperBound
        case .old: line.newNumber == nil && line.oldNumber == lines.upperBound
        }
    }
}

/// Turns drafted comments into the one message the agent receives.
nonisolated enum ReviewCommentBatch {
    static let maxQuotedLines = 3
    static let maxQuotedLineLength = 120

    static func message(_ comments: [ReviewComment]) -> String {
        let written = comments.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let noun = written.count == 1 ? "comment" : "comments"
        var parts = ["Review \(noun) on the working tree. Address each one:"]
        for comment in written {
            parts.append(section(for: comment))
        }
        return parts.joined(separator: "\n\n")
    }

    private static func section(for comment: ReviewComment) -> String {
        var lines = ["`\(comment.path)` \(location(of: comment))"]
        for text in comment.quote.prefix(maxQuotedLines) {
            lines.append("> " + clipped(text))
        }
        if comment.quote.count > maxQuotedLines {
            lines.append("> …")
        }
        lines.append(comment.body.trimmingCharacters(in: .whitespacesAndNewlines))
        return lines.joined(separator: "\n")
    }

    private static func location(of comment: ReviewComment) -> String {
        let range = comment.lines
        let span = range.count == 1 ? "line \(range.lowerBound)" : "lines \(range.lowerBound)–\(range.upperBound)"
        return comment.side == .old ? "\(span) (removed, numbered at the base)" : span
    }

    private static func clipped(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.count > maxQuotedLineLength ? String(trimmed.prefix(maxQuotedLineLength)) + "…" : trimmed
    }
}

/// Where a review's comments go: the task's agent tab, through the same
/// `AgentSession.submit` the composer sends with, so a busy agent queues
/// the batch beside the composer's own queued messages.
@MainActor
enum ReviewCommentDelivery {
    enum Target {
        case ready(TaskTab, any AgentSession)
        case unavailable(String)
    }

    /// The selected tab when it is an agent, else the task's first agent tab.
    static func target(in task: WorkTask) -> Target {
        let tabs = task.orderedTabs
        let selected = tabs.first { $0.id == task.selectedTabID && $0.kind == .agent }
        guard let tab = selected ?? tabs.first(where: { $0.kind == .agent }) else {
            return .unavailable("This task has no agent tab")
        }
        guard tab.transport == .headless else {
            return .unavailable("Comments go only to a chat agent tab")
        }
        guard let session = AgentSessionManager.shared.existingSession(for: tab.id) else {
            return .unavailable("Start the agent first")
        }
        return .ready(tab, session)
    }

    /// The batch's index in the session's queue, while it waits there.
    static func queuedIndex(of batch: ReviewModel.SentBatch, in task: WorkTask) -> Int? {
        guard let session = AgentSessionManager.shared.existingSession(for: batch.tabID) else { return nil }
        return session.queuedMessages.firstIndex(of: batch.blocks.normalized)
    }

    static func send(_ model: ReviewModel, in task: WorkTask) {
        guard case .ready(let tab, var session) = target(in: task) else { return }
        let text = ReviewCommentBatch.message(model.writtenComments)
        let blocks: [UserContentBlock] = [.text(text)]
        if session.hasExited {
            guard let resumed = AgentLauncher.relaunchHeadless(task: task, tab: tab) else { return }
            session = resumed
        }
        switch session.submit(blocks: blocks) {
        case .sent:
            model.clearComments()
        case .queued:
            model.markQueued(.init(tabID: tab.id, blocks: blocks))
        }
    }

    /// Takes the batch back out of the queue and keeps the drafts.
    static func cancel(_ model: ReviewModel, in task: WorkTask) {
        guard let batch = model.queuedBatch else { return }
        if let index = queuedIndex(of: batch, in: task) {
            AgentSessionManager.shared.existingSession(for: batch.tabID)?.removeQueuedMessage(at: index)
        }
        model.markQueued(nil)
    }
}

/// The header's comment count, and sending them.
struct ReviewCommentBar: View, ThemedView {
    @Environment(\.theme) var theme
    let task: WorkTask
    let model: ReviewModel

    var body: some View {
        let written = model.writtenComments.count
        let queued = model.queuedBatch.flatMap { ReviewCommentDelivery.queuedIndex(of: $0, in: task) } != nil
        HStack(spacing: 6) {
            if !model.comments.isEmpty {
                Text(written == 1 ? "1 comment" : "\(written) comments")
                    .font(typography.caption.font)
                    .emphasis(.secondary)
                    .plumeID(AccessibilityID.reviewCommentCount, value: "\(written)")
            }
            if queued {
                Text("Queued")
                    .font(typography.caption.font)
                    .foregroundStyle(colors.attention)
                Button("Cancel") { ReviewCommentDelivery.cancel(model, in: task) }
                    .controlSize(.small)
                    .plumeID(AccessibilityID.reviewCommentCancelButton, invoke: {
                        ReviewCommentDelivery.cancel(model, in: task)
                    })
            } else if !model.comments.isEmpty {
                sendButton(written: written)
            }
        }
        // A queued batch that has left the queue was delivered with the
        // next turn.
        .onChange(of: queued, initial: true) { _, isQueued in
            if !isQueued, model.queuedBatch != nil { model.clearComments() }
        }
    }

    private func sendButton(written: Int) -> some View {
        let target = ReviewCommentDelivery.target(in: task)
        let reason: String? = switch target {
        case .ready: written == 0 ? "Write a comment first" : nil
        case .unavailable(let reason): reason
        }
        return Button("Send to agent") { ReviewCommentDelivery.send(model, in: task) }
            .controlSize(.small)
            .disabled(reason != nil)
            .help(reason ?? "Send every comment as one message")
            .plumeID(
                AccessibilityID.reviewCommentSendButton,
                value: reason,
                invoke: { ReviewCommentDelivery.send(model, in: task) }
            )
    }
}

/// A draft below the line it ends at.
struct ReviewCommentEditor: View, ThemedView {
    @Environment(\.theme) var theme
    let model: ReviewModel
    let comment: ReviewComment

    @FocusState private var isEditing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(typography.caption.font)
                    .emphasis(.subtle)
                Spacer()
                Button {
                    model.deleteComment(comment.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete comment")
                .plumeID(AccessibilityID.reviewCommentDeleteButton, label: label, invoke: {
                    model.deleteComment(comment.id)
                })
            }
            TextField("Comment for the agent", text: body(of: comment.id), axis: .vertical)
                .textFieldStyle(.plain)
                .font(typography.body.font)
                .lineLimit(1...8)
                .focused($isEditing)
                .plumeID(AccessibilityID.reviewCommentField, label: label, setValue: { model.updateComment(comment.id, body: $0) })
        }
        .padding(8)
        .background(colors.attention.opacity(0.08), in: .rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(colors.attention.opacity(0.3)))
        .padding(.leading, ReviewDocumentMetrics.gutterWidth)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .onAppear { if comment.body.isEmpty { isEditing = true } }
    }

    private var label: String {
        let range = comment.lines
        let span = range.count == 1 ? "Line \(range.lowerBound)" : "Lines \(range.lowerBound)–\(range.upperBound)"
        return comment.side == .old ? "\(span) (removed)" : span
    }

    private func body(of id: UUID) -> Binding<String> {
        Binding(
            get: { model.comments.first { $0.id == id }?.body ?? "" },
            set: { model.updateComment(id, body: $0) }
        )
    }
}
#endif
