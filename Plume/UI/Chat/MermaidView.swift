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
struct MermaidBlock<Fallback: View>: View, ThemedView {
    @Environment(\.theme) var theme
    @Environment(\.colorScheme) private var colorScheme

    let source: String
    @ViewBuilder let fallback: () -> Fallback

    @State private var height: CGFloat?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if height == nil {
                fallback()
            }
            MermaidWebView(
                source: source,
                isDark: colorScheme == .dark,
                foregroundHex: MermaidWebView.hex(colors.foreground),
                onOutcome: { outcome in
                    switch outcome {
                    case let .rendered(value): height = value
                    case .failed: height = nil
                    }
                }
            )
            .frame(height: height ?? 0)
            // A new page per appearance: mermaid bakes its theme into the SVG
            // at render time, so the document is rebuilt rather than restyled.
            .id(colorScheme)
        }
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
        MermaidDocument.html(source: source, isDark: isDark, foregroundHex: foregroundHex)
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
