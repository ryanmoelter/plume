import AppKit
import SwiftUI

/// Content for `UpdatePanelWindow`. A Homebrew install can't be updated in place by Sparkle, so this is
/// informational only: what changed, and the `brew upgrade` command to run.
struct UpdatePanel: View {
    let update: AvailableUpdate

    var body: some View {
        ScrollView {
            UpdatePanelContent(update: update)
        }
        .plumeID(AccessibilityID.updatePanel)
    }
}

/// The panel's content, apart from the scrolling: `UpdatePanelWindow` also
/// measures this on its own, unscrolled, to size the window to it.
struct UpdatePanelContent: View, ThemedView {
    @Environment(\.theme) var theme
    @Environment(\.colorScheme) private var colorScheme
    let update: AvailableUpdate
    @State private var didCopyCommand = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            notes

            if let fullReleaseNotesURL = update.fullReleaseNotesURL {
                Link("Full release notes", destination: fullReleaseNotesURL)
                    .font(.callout)
                    .plumeID(AccessibilityID.updatePanelFullReleaseNotesLink)
            }

            homebrewCallout
        }
        .frame(maxWidth: dimensions.contentWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UpdatePanelMetrics.padding)
    }

    private var versionHeading: String {
        "# Plume \(update.displayVersion)"
    }

    @ViewBuilder
    private var notes: some View {
        switch update.releaseNotesFormat {
        case .markdown:
            MarkdownView("\(versionHeading)\n\n\(trimmedReleaseNotes ?? "")", isAgentVoice: false)
        case .plainText:
            VStack(alignment: .leading, spacing: 12) {
                MarkdownView(versionHeading, isAgentVoice: false)
                if let trimmedReleaseNotes {
                    Text(trimmedReleaseNotes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .html:
            VStack(alignment: .leading, spacing: 12) {
                MarkdownView(versionHeading, isAgentVoice: false)
                if let trimmedReleaseNotes {
                    Text(HTMLReleaseNotes.render(trimmedReleaseNotes))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var trimmedReleaseNotes: String? {
        guard let releaseNotes = update.releaseNotes else { return nil }
        let trimmed = releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var homebrewCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Update with Homebrew. Plume quits during the upgrade and reopens when it's done.")
                .font(.callout)

            HStack(spacing: 6) {
                Text(UpdateController.homebrewUpgradeCommand)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(ChatRole.attention(for: colorScheme))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Button {
                    copyCommand()
                } label: {
                    Image(systemName: didCopyCommand ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy command")
                .plumeID(AccessibilityID.updatePanelCopyBrewCommandButton)

                Spacer(minLength: 0)

                Button("Run in Terminal") {
                    HomebrewUpgrade.runInTerminal(homebrewPrefix: UpdateController.shared.homebrewPrefix)
                }
                .buttonStyle(.borderedProminent)
                .plumeID(AccessibilityID.updatePanelRunInTerminalButton)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: UpdatePanelMetrics.calloutCornerRadius)
                .fill(ChatRole.attention(for: colorScheme).emphasized(.backgroundTint, colorScheme: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: UpdatePanelMetrics.calloutCornerRadius)
                .stroke(ChatRole.attention(for: colorScheme).emphasized(.divider, colorScheme: colorScheme))
        )
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

enum UpdatePanelMetrics {
    static let padding: CGFloat = 20
    static let calloutCornerRadius: CGFloat = 10
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
