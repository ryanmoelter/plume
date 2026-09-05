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
        #if DEBUG
        .onAppear {
            if MermaidFullScreenHarness.claimsFirstBlock() { isFullScreen = true }
        }
        #endif
    }
}

#if DEBUG
/// `PLUME_OPEN_MERMAID_FULLSCREEN=1` opens the first diagram's sheet as it
/// appears, so the fullscreen render can be read from the log without the UI
/// scripting this environment has no permission for.
@MainActor
enum MermaidFullScreenHarness {
    private static var claimed = false

    static func claimsFirstBlock() -> Bool {
        guard !claimed,
              ProcessInfo.processInfo.environment["PLUME_OPEN_MERMAID_FULLSCREEN"] != nil
        else { return false }
        claimed = true
        Log.app.info("Smoke harness opening the first mermaid diagram full screen")
        return true
    }
}
#endif

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
///
/// Unlike the inline block this hosts a plain, magnifying `WKWebView`: pinch
/// and ⌘+/⌘-/⌘0 zoom the diagram, and once zoomed past 1x a two-finger scroll
/// pans it, since `.fitZoomable` lets the page overflow its viewport instead
/// of clipping.
private struct MermaidFullScreenView: View, ThemedView {
    @Environment(\.theme) var theme
    @Environment(\.colorScheme) private var colorScheme

    let source: String
    let onClose: () -> Void

    @State private var zoomController = MermaidZoomController()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            MermaidZoomableWebView(
                source: source,
                isDark: colorScheme == .dark,
                foregroundHex: MermaidWebView.hex(colors.foreground),
                controller: zoomController
            )
            // A WKWebView has no intrinsic size, so without claiming the
            // space it collapses and the page's percentage heights resolve
            // against nothing — a sheet that opens on a blank diagram.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
            .id(colorScheme)
        }
        .frame(
            minWidth: Self.size.width,
            maxWidth: .infinity,
            minHeight: Self.size.height,
            maxHeight: .infinity
        )
    }

    /// Most of the window the chat is in, so a diagram capped inline has room
    /// to be read. Falls back to a size that suits a small display when there
    /// is no key window to measure.
    private static var size: CGSize {
        guard let frame = NSApp.keyWindow?.frame else { return CGSize(width: 900, height: 650) }
        return CGSize(width: max(frame.width * 0.8, 900), height: max(frame.height * 0.8, 650))
    }

    private var header: some View {
        HStack {
            Text("Diagram")
                .font(.headline)
            Spacer()
            zoomControls
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

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button(action: { zoomController.zoomOut() }) {
                Image(systemName: "minus")
            }
            .help("Zoom out")
            .keyboardShortcut("-", modifiers: .command)

            Button(action: { zoomController.resetToFit() }) {
                Text("Fit")
            }
            .help("Reset to fit")
            .keyboardShortcut("0", modifiers: .command)

            Button(action: { zoomController.zoomIn() }) {
                Image(systemName: "plus")
            }
            .help("Zoom in")
            .keyboardShortcut("+", modifiers: .command)
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(colors.foreground)
        .padding(.horizontal, 8)
    }
}

/// The zoom range `MermaidZoomController` clamps to, and the step ⌘+/⌘- move
/// by. `WKWebView.magnification` itself has no built-in limits.
enum MermaidZoom {
    static let range: ClosedRange<CGFloat> = 0.25...4
    static let step: CGFloat = 0.25
}

/// SwiftUI's hook into the fullscreen `WKWebView`'s magnification — the
/// toolbar buttons drive this rather than touching the web view directly,
/// since the view is only reachable inside the `NSViewRepresentable`.
@MainActor
@Observable
final class MermaidZoomController {
    fileprivate weak var webView: WKWebView?

    func zoomIn() { setMagnification(currentMagnification + MermaidZoom.step) }
    func zoomOut() { setMagnification(currentMagnification - MermaidZoom.step) }
    func resetToFit() { setMagnification(1) }

    private var currentMagnification: CGFloat {
        webView?.magnification ?? 1
    }

    private func setMagnification(_ value: CGFloat) {
        webView?.magnification = min(max(value, MermaidZoom.range.lowerBound), MermaidZoom.range.upperBound)
    }
}

/// The fullscreen sheet's own web view: a plain, magnifying `WKWebView`
/// rather than the inline block's non-scrolling one, since panning a zoomed
/// diagram needs the page's own scrolling. `.fitZoomable` is what makes that
/// safe at 1x — see `MermaidDocument.Sizing`.
private struct MermaidZoomableWebView: NSViewRepresentable {
    let source: String
    let isDark: Bool
    let foregroundHex: String
    let controller: MermaidZoomController

    func makeCoordinator() -> MermaidWebView.Coordinator {
        MermaidWebView.Coordinator(role: "fullscreen", onOutcome: { _ in })
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(
            context.coordinator,
            name: MermaidDocument.messageHandlerName
        )
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = true
        view.magnification = 1
        context.coordinator.load(into: view, document: document)
        controller.webView = view
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        // Only a changed document reloads. Re-loading on every SwiftUI pass
        // would restart mermaid and reset the user's zoom.
        context.coordinator.load(into: view, document: document)
        controller.webView = view
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: MermaidWebView.Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(
            forName: MermaidDocument.messageHandlerName
        )
    }

    private var document: String {
        MermaidDocument.html(
            source: source,
            isDark: isDark,
            foregroundHex: foregroundHex,
            sizing: .fitZoomable
        )
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
    /// Names the pass in the log, so a fullscreen render can be told from the
    /// inline one it shares a page template with.
    var role: String = "inline"
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
        Coordinator(role: role, onOutcome: onOutcome)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(
            context.coordinator,
            name: MermaidDocument.messageHandlerName
        )
        let view = NonScrollingWebView(frame: .zero, configuration: configuration)
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
        private let role: String
        private var loaded: String?

        init(role: String, onOutcome: @escaping (Outcome) -> Void) {
            self.role = role
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
                let number = { (key: String) in (payload[key] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0 }
                let height = number("height")
                let container = "\(number("viewportWidth"))x\(number("viewportHeight"))"
                Log.app.info(
                    "mermaid \(self.role, privacy: .public) rendered, height \(height, privacy: .public) width \(number("width"), privacy: .public) in container \(container, privacy: .public)"
                )
                onOutcome(.rendered(max(height, 1)))
            case "error":
                let message = payload["message"] as? String ?? "unknown"
                Log.app.error("mermaid \(self.role, privacy: .public) parse error: \(message, privacy: .public)")
                onOutcome(.failed)
            default:
                break
            }
        }
    }
}

/// A web view that never scrolls itself.
///
/// WebKit consumes `scrollWheel(with:)` whether or not the page has anywhere
/// to scroll, which would swallow every wheel event landing on a diagram
/// instead of scrolling the chat list underneath. Forwarding to the next
/// responder puts the event back on the chain that reaches the list's scroll
/// view. The page also sets `overflow: hidden`, so there is nothing to scroll
/// on either side of this.
private final class NonScrollingWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
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
