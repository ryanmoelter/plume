import SwiftUI

/// A transcript aside: an API error, a harness warning, a compaction
/// boundary. Compact and full-width — a thing that happened to the session
/// rather than a thing anyone said.
struct ChatNoticeRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatFontSize) private var chatFontSize

    let notice: ChatNotice

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if isExpanded, let detail = notice.detail {
                Text(detail)
                    .font(.system(size: chatFontSize * 0.8, design: .monospaced))
                    .emphasis(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(tintFill, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tintBorder, lineWidth: 1)
        }
        .listItemPadding(vertical: false)
    }

    @ViewBuilder
    private var header: some View {
        let label = HStack(spacing: 6) {
            Image(systemName: symbol)
                .imageScale(.small)
                .foregroundStyle(tintStyle)
            Text(notice.title)
                .foregroundStyle(AnyShapeStyle.role(ChatRole.danger, when: notice.kind == .error, otherwise: .secondary))
                .frame(maxWidth: .infinity, alignment: .leading)
            if notice.detail != nil {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .imageScale(.small)
                    .emphasis(.secondary)
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

    /// Only error and warning carry a hue. An info or compaction notice is
    /// a boundary marker, so it takes the surface wash and the text hierarchy
    /// instead of a color no one needs to decode.
    private var roleTint: Color? {
        switch notice.kind {
        case .error: ChatRole.danger
        case .warning: ChatRole.warning
        case .info, .compaction: nil
        }
    }

    private var tintStyle: AnyShapeStyle {
        roleTint.map(AnyShapeStyle.init) ?? AnyShapeStyle(Emphasis.secondary.textHierarchy)
    }

    private var tintFill: Color {
        roleTint?.emphasized(.backgroundTint, colorScheme: colorScheme)
            ?? .chatSurface(.backgroundTint, colorScheme: colorScheme)
    }

    private var tintBorder: Color {
        roleTint?.emphasized(.disabled, colorScheme: colorScheme)
            ?? .chatSurface(.divider, colorScheme: colorScheme)
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
