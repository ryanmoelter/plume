import SwiftUI

/// A transcript aside: an API error, a harness warning, a compaction
/// boundary. Compact and full-width — a thing that happened to the session
/// rather than a thing anyone said.
struct ChatNoticeRow: View {
    @Environment(\.chatFontSize) private var chatFontSize

    let notice: ChatNotice

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if isExpanded, let detail = notice.detail {
                Text(detail)
                    .font(.system(size: chatFontSize * 0.8, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        }
        .listItemPadding(vertical: false)
    }

    @ViewBuilder
    private var header: some View {
        let label = HStack(spacing: 6) {
            Image(systemName: symbol)
                .imageScale(.small)
                .foregroundStyle(tint)
            Text(notice.title)
                .foregroundStyle(notice.kind == .error ? tint : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if notice.detail != nil {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: chatFontSize * 0.82))
        .multilineTextAlignment(.leading)

        if notice.detail == nil {
            label
        } else {
            Button { isExpanded.toggle() } label: { label.contentShape(.rect) }
                .buttonStyle(.plain)
        }
    }

    private var tint: Color {
        switch notice.kind {
        case .error: .red
        case .warning: .orange
        case .info, .compaction: .secondary
        }
    }

    private var symbol: String {
        switch notice.kind {
        case .error: "exclamationmark.triangle.fill"
        case .warning: "exclamationmark.circle"
        case .info: "info.circle"
        case .compaction: "arrow.down.right.and.arrow.up.left"
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        ChatNoticeRow(notice: ChatNotice(
            kind: .error,
            title: "API error",
            detail: "HTTP 401: Invalid authentication credentials"
        ))
        ChatNoticeRow(notice: ChatNotice(
            kind: .compaction,
            title: "Conversation compacted",
            detail: "manual compaction · 185k → 9k tokens"
        ))
        ChatNoticeRow(notice: ChatNotice(kind: .warning, title: "Your worktree no longer exists.", detail: nil))
    }
    .padding()
    .frame(width: 480)
}
