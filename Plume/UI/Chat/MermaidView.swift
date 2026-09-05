import AppKit
import os
import SwiftUI
import WebKit

/// Draws one ```mermaid fence as a diagram, falling back to the fence's raw
/// text while mermaid loads and whenever it rejects the source.
///
/// The web view reports its rendered height once and the row takes an explicit
/// frame from it, so the chat's `LazyVStack` gets a row whose size stops
/// changing — a view that kept resizing would reopen the placement loop in
/// `docs/chat-list-hang.md`. Until that height lands the fallback occupies the
/// row, so it is never blank.
///
/// Past `MermaidLayout.maximumInlineHeight` the row keeps that height and the
/// diagram scales to fit inside it, so one tall diagram cannot own the whole
/// viewport. Reading it in full is what the expand button is for.
struct MermaidBlock<Fallback: View>: View, ThemedView {
    @Environment(\.theme) var theme
    @Environment(\.colorScheme) private var colorScheme

    let source: String
    var isRevealed: Bool = false
    @ViewBuilder let fallback: () -> Fallback

    @State private var height: CGFloat?
    @State private var isFullScreen = false

    private var isCapped: Bool {
        (height ?? 0) > MermaidLayout.maximumInlineHeight
    }

    private var inlineHeight: CGFloat {
        min(height ?? 0, MermaidLayout.maximumInlineHeight)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if height == nil {
                fallback()
            }
            MermaidWebView(
                source: source,
                isDark: colorScheme == .dark,
                foregroundHex: MermaidWebView.hex(colors.foreground),
                // A capped diagram re-renders scaled to the frame it is given.
                sizing: isCapped ? .fit : .natural,
                onOutcome: { outcome in
                    switch outcome {
                    case let .rendered(value):
                        // Only the natural pass decides the row's height. A
                        // capped diagram's re-render reports its scaled
                        // height, and taking that would shrink the frame,
                        // which would rescale, which would report again.
                        if !isCapped { height = value }
                    case .failed:
                        height = nil
                    }
                }
            )
            .frame(height: inlineHeight)
            // A new page per appearance: mermaid bakes its theme into the SVG
            // at render time, so the document is rebuilt rather than restyled.
            .id(colorScheme)
        }
        .overlay(alignment: .topTrailing) {
            if height != nil {
                MermaidExpandButton(isRevealed: isRevealed) { isFullScreen = true }
                    // Clear of the copy button the markdown block pins to the
                    // same corner.
                    .padding(.trailing, 34)
            }
        }
        .sheet(isPresented: $isFullScreen) {
            MermaidFullScreenView(source: source) { isFullScreen = false }
        }
    }
}

enum MermaidLayout {
    /// Past this a diagram is taller than a comfortable row, so the inline
    /// copy scales to fit and the fullscreen button becomes the way to read
    /// it. The frame stays explicit either way, so the row's size still
    /// settles.
    static let maximumInlineHeight: CGFloat = 420
}

/// Opens the diagram over the chat, where a capped or simply tall diagram is
/// readable. Revealed on hover beside the block's copy button.
private struct MermaidExpandButton: View, ThemedView {
    @Environment(\.theme) var theme

    let isRevealed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(colors.foreground)
                .padding(6)
                .background(colors.surface(.backgroundTint), in: .circle)
        }
        .buttonStyle(.plain)
        .padding(6)
        .opacity(isRevealed ? 1 : 0)
        .help("Open diagram full screen")
        .accessibilityLabel("Open diagram full screen")
        .accessibilityIdentifier(AccessibilityID.mermaidExpandButton)
    }
}

/// One diagram filling a panel over the chat, scaled to fit rather than
/// reporting a height — the container decides the size here, so the page
/// never drives a frame and there is no loop to reopen.
private struct MermaidFullScreenView: View, ThemedView {
    @Environment(\.theme) var theme
    @Environment(\.colorScheme) private var colorScheme

    let source: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            MermaidWebView(
                source: source,
                isDark: colorScheme == .dark,
                foregroundHex: MermaidWebView.hex(colors.foreground),
                sizing: .fit,
                onOutcome: { _ in }
            )
            .padding(16)
            .id(colorScheme)
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    private var header: some View {
        HStack {
            Text("Diagram")
                .font(.headline)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .emphasis(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .accessibilityLabel("Close")
            .accessibilityIdentifier(AccessibilityID.mermaidFullScreenClose)
        }
        .padding(12)
    }
}

/// Hosts the `WKWebView` that runs mermaid.
private struct MermaidWebView: NSViewRepresentable {
    enum Outcome: Equatable {
        case rendered(CGFloat)
        case failed
    }

    let source: String
    let isDark: Bool
    let foregroundHex: String
    var sizing: MermaidDocument.Sizing = .natural
    let onOutcome: (Outcome) -> Void

    static func hex(_ color: Color) -> String {
        guard let components = NSColor(color).usingColorSpace(.sRGB) else { return "#000000" }
        let channel = { (value: CGFloat) in Int((value * 255).rounded()) }
        return String(
            format: "#%02x%02x%02x",
            channel(components.redComponent),
            channel(components.greenComponent),
            channel(components.blueComponent)
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onOutcome: onOutcome)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(
            context.coordinator,
            name: MermaidDocument.messageHandlerName
        )
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.load(into: view, document: document)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.onOutcome = onOutcome
        // Only a changed document reloads. Re-loading on every SwiftUI pass
        // would restart mermaid and make the row's height oscillate.
        context.coordinator.load(into: view, document: document)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(
            forName: MermaidDocument.messageHandlerName
        )
    }

    private var document: String {
        MermaidDocument.html(
            source: source,
            isDark: isDark,
            foregroundHex: foregroundHex,
            sizing: sizing
        )
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onOutcome: (Outcome) -> Void
        private var loaded: String?

        init(onOutcome: @escaping (Outcome) -> Void) {
            self.onOutcome = onOutcome
        }

        func load(into view: WKWebView, document: String) {
            guard loaded != document else { return }
            loaded = document
            view.loadHTMLString(document, baseURL: MermaidRuntime.baseURL)
        }

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let payload = message.body as? [String: Any],
                  let kind = payload["kind"] as? String else { return }
            switch kind {
            case "rendered":
                let height = (payload["height"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
                Log.app.info("mermaid rendered, height \(height, privacy: .public)")
                onOutcome(.rendered(max(height, 1)))
            case "error":
                let message = payload["message"] as? String ?? "unknown"
                Log.app.error("mermaid parse error: \(message, privacy: .public)")
                onOutcome(.failed)
            default:
                break
            }
        }
    }
}

/// Where the bundled mermaid build lives.
///
/// Synchronized groups flatten resources into `Contents/Resources`, so the
/// script sits directly beside the app's other resources and the page's
/// relative `<script src>` resolves against that directory as its base URL.
enum MermaidRuntime {
    static let baseURL: URL? = Bundle.main.url(forResource: "mermaid", withExtension: "min.js")?
        .deletingLastPathComponent()
}
