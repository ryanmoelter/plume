import AppKit
import SwiftUI

/// Popover content for a Homebrew install's "Update Available" row.
///
/// A Homebrew install can't be updated in place by Sparkle, so this is
/// informational only: what changed, and the `brew upgrade` command to run.
struct UpdatePanel: View {
    let update: AvailableUpdate
    @State private var didCopyCommand = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Plume \(update.displayVersion) is available")
                .font(.headline)

            releaseNotes

            if let fullReleaseNotesURL = update.fullReleaseNotesURL {
                Link("Full release notes", destination: fullReleaseNotesURL)
                    .font(.callout)
                    .plumeID(AccessibilityID.updatePanelFullReleaseNotesLink)
            }

            Divider()

            Text("Update with Homebrew in your terminal:")
                .font(.callout)

            HStack(spacing: 6) {
                Text(UpdateController.homebrewUpgradeCommand)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                Button {
                    copyCommand()
                } label: {
                    Text(didCopyCommand ? "Copied" : "Copy")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .plumeID(AccessibilityID.updatePanelCopyBrewCommandButton)
            }
        }
        .padding(12)
        .frame(width: 340)
        .plumeID(AccessibilityID.updatePanel)
    }

    @ViewBuilder
    private var releaseNotes: some View {
        if let releaseNotes = update.releaseNotes, !releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch update.releaseNotesFormat {
            case .markdown:
                MarkdownContentView(content: releaseNotes)
                    .frame(maxHeight: 300)
            case .plainText:
                ScrollView {
                    Text(releaseNotes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
            case .html:
                ScrollView {
                    Text(HTMLReleaseNotes.render(releaseNotes))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
            }
        }
    }

    private func copyCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(UpdateController.homebrewUpgradeCommand, forType: .string)

        didCopyCommand = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            didCopyCommand = false
        }
    }
}

/// Renders `html`-formatted release notes. `NSAttributedString(html:)` is
/// synchronous and handles ordinary appcast markup; a tag-stripped plain
/// string is the fallback for whatever it can't parse, rather than shipping
/// a full HTML renderer for a format Plume's own appcast never emits.
enum HTMLReleaseNotes {
    static func render(_ html: String) -> AttributedString {
        if let data = html.data(using: .utf8),
           let attributed = NSAttributedString(html: data, documentAttributes: nil),
           let converted = try? AttributedString(attributed, including: \.appKit) {
            return converted
        }
        return AttributedString(plainText(html))
    }

    /// Pure so it's testable without an `NSAttributedString` round trip:
    /// strips tags and decodes the handful of entities release notes are
    /// likely to contain.
    static func plainText(_ html: String) -> String {
        html
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
