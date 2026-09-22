import SwiftUI

/// The subagents a conversation has spawned, as a compact row each — what it
/// was asked to do, and how it is doing. Absent entirely when there are none.
///
/// Reading one is a separate act from scanning the list, so a row opens the
/// full transcript in an overlay rather than expanding in place; several
/// subagents running at once is the case this is for, and a nested disclosure
/// made the list unreadable at exactly that moment.
///
/// A finished subagent stays among the live rows for
/// `SubagentCompletionTracker.lingerDuration` so its result is seen landing,
/// then folds into a collapsed section that keeps the live list short on a
/// long session. Both the timing and the observation that starts it live
/// outside this view — in the shared tracker, driven by `TranscriptStore` —
/// because selecting another task unmounts this view while the agents it was
/// showing keep working.
struct SubagentListView: View, ThemedView {
    @Environment(\.theme) var theme

    let subagents: [SubagentTranscript]
    /// Which tab's rows these are. The tracker outlives this view, so it needs
    /// the key the view itself no longer holds once the task changes.
    let tabID: UUID
    /// Opens a subagent's transcript. The overlay is hosted by `ChatTabView`,
    /// which owns the space to draw it over.
    var onOpen: (SubagentTranscript) -> Void = { _ in }
    var part: Part = .whole

    /// The custom chat list draws the header and the rows as separate items,
    /// so the rows can fold behind the composer while the header holds.
    enum Part {
        case whole
        case header
        case rows
    }

    private var tracker: SubagentCompletionTracker { .shared }
    private var overrides: SubagentStatusOverrides { .shared }
    @State private var showsCompleted = false

    private func row(_ subagent: SubagentTranscript) -> some View {
        SubagentRow(
            subagent: subagent,
            onOpen: { onOpen(subagent) },
            onOverride: { TranscriptStore.shared.setOverride($0, tabID: tabID, subagentID: subagent.id) },
            currentOverride: overrides.override(tabID: tabID, subagentID: subagent.id)
        )
    }

    private var live: [SubagentTranscript] {
        subagents.filter { !tracker.hasSettled($0, tabID: tabID) }
    }

    private var completed: [SubagentTranscript] {
        subagents.filter { tracker.hasSettled($0, tabID: tabID) }
    }

    var body: some View {
        if !subagents.isEmpty {
            switch part {
            case .whole:
                VStack(alignment: .leading, spacing: 2) {
                    header
                    rows
                }
                .padding(.vertical, 6)
            case .header:
                // Its own section after the reply, the way a message is.
                header.padding(.top, dimensions.messageSpacing)
            case .rows:
                VStack(alignment: .leading, spacing: 2) { rows }
                    // With no live rows the header draws nothing, and the
                    // completed toggle opens the section instead.
                    .padding(.top, live.isEmpty ? dimensions.messageSpacing : 2)
                    .padding(.bottom, dimensions.verticalPadding)
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        if !live.isEmpty {
            Label(
                "\(live.count) subagent\(live.count == 1 ? "" : "s")",
                systemImage: StatusSymbol.subagents.name
            )
            .font(typography.caption.font)
            .emphasis(.subtle)
            .padding(.bottom, 2)
        }
    }

    @ViewBuilder
    private var rows: some View {
        ForEach(live) { subagent in
            row(subagent)
                .id(subagent.id)
        }
        if !completed.isEmpty {
            completedSection
        }
    }

    private var completedSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                showsCompleted.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(typography.caption.font)
                        .rotationEffect(.degrees(showsCompleted ? 90 : 0))
                    Label(
                        "Completed subagents (\(completed.count))",
                        systemImage: StatusSymbol.subagents.name
                    )
                    .font(typography.caption.font)
                    Spacer(minLength: 0)
                }
                .emphasis(.subtle)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(.rect(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .plumeID(AccessibilityID.completedSubagentsToggle)

            if showsCompleted {
                ForEach(completed) { subagent in
                    row(subagent)
                        .id(subagent.id)
                }
            }
        }
    }
}

private struct SubagentRow: View, ThemedView {
    @Environment(\.theme) var theme

    let subagent: SubagentTranscript
    let onOpen: () -> Void
    var onOverride: (SubagentStatusOverrides.Override?) -> Void = { _ in }
    var currentOverride: SubagentStatusOverrides.Override?

    @State private var isHovering = false

    private var messageCount: Int {
        subagent.transcript.messages.count
    }

    private var caption: SubagentCaption {
        SubagentCaption(subagent: subagent)
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusBadge(status: subagent.status)
                    .frame(width: 12, alignment: .center)
                VStack(alignment: .leading, spacing: 1) {
                    Text(subagent.title)
                        .font(typography.body.font)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // Rendered even while empty, so a row keeps its height as
                    // the facts arrive on the next read.
                    Text(caption.text)
                        .font(typography.caption.font)
                        .emphasis(.subtle)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("\(messageCount)")
                    .font(typography.caption.mono)
                    .emphasis(.subtle)
                Image(systemName: "chevron.right")
                    .font(typography.caption.font)
                    .emphasis(.subtle)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(.rect(cornerRadius: 6))
            .background(
                isHovering ? colors.surfaceTint : Color.clear,
                in: .rect(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .plumeHover { isHovering = $0 }
        .help(subagent.descriptor?.description ?? subagent.id)
        .plumeID(AccessibilityID.subagentRow, label: subagent.title)
        .contextMenu { menu }
    }

    /// The escape hatch for a row nothing can settle on its own. Offered only
    /// where it applies: a subagent still reporting working, or one the user
    /// already marked and may want to put back.
    @ViewBuilder
    private var menu: some View {
        if currentOverride != nil {
            Button("Clear Status Override") { onOverride(nil) }
                .plumeID(AccessibilityID.subagentClearOverride)
        } else if subagent.status == .working {
            Button("Mark as Done") { onOverride(.done) }
                .plumeID(AccessibilityID.subagentMarkDone)
            Button("Mark as Interrupted") { onOverride(.interrupted) }
                .plumeID(AccessibilityID.subagentMarkInterrupted)
        }
    }
}

#Preview {
    SubagentListView(
        subagents: [
            SubagentTranscript(
                id: "a1",
                transcript: Transcript(messages: [
                    ChatMessage(id: "m1", role: .assistant, blocks: [.markdown("Looking")], timestamp: nil)
                ]),
                modifiedAt: nil,
                descriptor: SubagentDescriptor(description: "Explore the status engine", agentType: "Explore"),
                status: .working
            ),
            SubagentTranscript(
                id: "a2",
                transcript: Transcript(),
                modifiedAt: nil,
                descriptor: SubagentDescriptor(description: "Design the notification layer", agentType: "Plan"),
                status: .done
            ),
        ],
        tabID: UUID()
    )
    .padding()
    .frame(width: 420)
}
