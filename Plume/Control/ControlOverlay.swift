#if DEBUG
import AppKit

/// A transparent child window over a driven window that draws where the
/// synthetic pointer is and where it last clicked, so a person watching can
/// follow the driver. The real pointer never moves. The glyph is
/// `pointer.arrow.ipad`, deliberately unlike the system arrow.
@MainActor
final class ControlOverlay {
    private static var overlays: [Int: ControlOverlay] = [:]

    static func overlay(for window: NSWindow) -> ControlOverlay {
        if let existing = overlays[window.windowNumber] { return existing }
        let overlay = ControlOverlay(over: window)
        overlays[window.windowNumber] = overlay
        return overlay
    }

    static func existing(for window: NSWindow) -> ControlOverlay? {
        overlays[window.windowNumber]
    }

    static var all: [ControlOverlay] { Array(overlays.values) }

    private weak var parent: NSWindow?
    let panel: NSWindow
    let view: OverlayView
    private var observers: [NSObjectProtocol] = []

    private init(over parent: NSWindow) {
        self.parent = parent
        view = OverlayView(frame: parent.contentView?.bounds ?? .zero)
        panel = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.level = parent.level
        panel.contentView = view
        parent.addChildWindow(panel, ordered: .above)
        reframe()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didResizeNotification, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reframe() }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.remove() }
            },
        ]
    }

    /// `point` is in the parent window's AppKit coordinates.
    func moveCursor(to point: NSPoint) {
        view.cursor = point
    }

    func flashClick(at point: NSPoint) {
        view.cursor = point
        view.addRing(at: point)
    }

    func remove() {
        guard let parent else { return }
        Self.overlays[parent.windowNumber] = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        parent.removeChildWindow(panel)
        panel.orderOut(nil)
        self.parent = nil
    }

    private func reframe() {
        guard let parent, let content = parent.contentView else { return }
        let inWindow = content.convert(content.bounds, to: nil)
        panel.setFrame(parent.convertToScreen(inWindow), display: true)
        view.frame = CGRect(origin: .zero, size: inWindow.size)
    }
}

/// Draws the pointer glyph and fading click rings.
final class OverlayView: NSView {
    private struct Ring {
        let center: NSPoint
        let started: TimeInterval
    }

    private static let ringDuration: TimeInterval = 0.5
    private static let glyph: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 26, weight: .medium)
        return NSImage(systemSymbolName: "pointer.arrow.ipad", accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }()

    var cursor: NSPoint? {
        didSet { needsDisplay = true }
    }
    private var rings: [Ring] = []
    private var timer: Timer?

    func addRing(at point: NSPoint) {
        rings.append(Ring(center: point, started: Date.timeIntervalSinceReferenceDate))
        needsDisplay = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let now = Date.timeIntervalSinceReferenceDate
                self.rings.removeAll { now - $0.started > Self.ringDuration }
                self.needsDisplay = true
                if self.rings.isEmpty { timer.invalidate(); self.timer = nil }
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let now = Date.timeIntervalSinceReferenceDate
        for ring in rings {
            let progress = min(1, (now - ring.started) / Self.ringDuration)
            let radius = 6 + 14 * progress
            let path = NSBezierPath(ovalIn: CGRect(x: ring.center.x - radius, y: ring.center.y - radius, width: radius * 2, height: radius * 2))
            path.lineWidth = 2
            NSColor.systemBlue.withAlphaComponent(1 - progress).setStroke()
            path.stroke()
        }
        guard let cursor, let glyph = Self.glyph else { return }
        // The arrow's tip sits a couple of points inside the glyph's top-left
        // corner. The symbol draws black; a white shadow keeps it legible on
        // dark chrome.
        let origin = CGPoint(x: cursor.x - 3, y: cursor.y - glyph.size.height + 3)
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = .white
        shadow.shadowBlurRadius = 2
        shadow.set()
        glyph.draw(in: CGRect(origin: origin, size: glyph.size), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
#endif
