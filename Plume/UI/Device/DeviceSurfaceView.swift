import AppKit
import QuartzCore
import SwiftUI

/// Draws a device's frames into its layer and turns mouse, scroll and key
/// events into device input. It streams only while it is in a visible
/// window, so a hidden or occluded tab costs nothing.
final class DeviceSurfaceView: NSView, DeviceFrameSink {
    var session: DeviceSession? {
        didSet {
            guard session !== oldValue else { return }
            if let oldValue, isSink { oldValue.removeSink(self) }
            isSink = false
            pressedAndroidKeys = AndroidPressedKeys()
            updateSink()
        }
    }

    private var isSink = false
    private var imageSize: CGSize = .zero
    private var deviceRotation: DeviceRotation = .portrait
    private var isTouching = false
    /// Owns the layer's surface until the next frame replaces it.
    private var presentedFrame: DeviceFrame?
    private var wheel = WheelAccumulator()
    private var previousFlags: NSEvent.ModifierFlags = []
    private var pressedAndroidKeys = AndroidPressedKeys()
    private var occlusionObserver: NSObjectProtocol?
    private var resizeWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resizeAspect
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var requestedPixelSize: CGSize {
        let scale = window?.backingScaleFactor ?? 2
        return CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
    }

    func present(_ frame: DeviceFrame) {
        imageSize = frame.pixelSize
        deviceRotation = frame.rotation
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = frame.layerContents
        CATransaction.commit()
        presentedFrame = frame
    }

    // MARK: Visibility

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateSink() }
            }
        }
        updateSink()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.session?.sinkSizeChanged() }
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func detach() {
        resizeWork?.cancel()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        session = nil
    }

    private func updateSink() {
        let shouldStream = session != nil && window?.occlusionState.contains(.visible) == true
        guard shouldStream != isSink, let session else { return }
        isSink = shouldStream
        EmulatorLog.info("tab \(session.tabID.uuidString.prefix(8)) surface \(shouldStream ? "visible" : "hidden")")
        if shouldStream {
            session.addSink(self)
        } else {
            session.removeSink(self)
            layer?.contents = nil
            presentedFrame = nil
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let point = devicePoint(for: event, clamped: false) else { return }
        isTouching = true
        session?.send(.touch(.down, point))
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTouching, let point = devicePoint(for: event, clamped: true) else { return }
        session?.send(.touch(.move, point))
    }

    override func mouseUp(with event: NSEvent) {
        guard isTouching else { return }
        isTouching = false
        guard let point = devicePoint(for: event, clamped: true) else { return }
        session?.send(.touch(.up, point))
    }

    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began { wheel.reset() }
        let delta = wheel.add(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas
        )
        guard delta.dx != 0 || delta.dy != 0 else { return }
        session?.send(.scroll(at: devicePoint(for: event, clamped: false), dx: delta.dx, dy: delta.dy))
    }

    private func devicePoint(for event: NSEvent, clamped: Bool) -> DevicePoint? {
        let deviceSize = naturalDeviceSize
        let point = DeviceCoordinateMapper.devicePoint(
            for: convert(event.locationInWindow, from: nil),
            viewSize: bounds.size,
            imageSize: imageSize,
            deviceSize: deviceSize,
            rotation: deviceRotation,
            clampOutside: clamped
        )
        return point.map { DevicePoint(point: $0, deviceSize: deviceSize) }
    }

    /// Falls back to the frame itself, un-rotated, when status gave no size.
    private var naturalDeviceSize: CGSize {
        if let size = session?.deviceSize { return size }
        switch deviceRotation {
        case .portrait, .reversePortrait: return imageSize
        case .landscape, .reverseLandscape: return CGSize(width: imageSize.height, height: imageSize.width)
        }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if !forward(type: .keyDown, event: event) { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if !forward(type: .keyUp, event: event) { super.keyUp(with: event) }
    }

    override func flagsChanged(with event: NSEvent) {
        _ = forward(type: .flagsChanged, event: event)
        previousFlags = event.modifierFlags
        super.flagsChanged(with: event)
    }

    private func forward(type: KeyEventType, event: NSEvent) -> Bool {
        guard let session, session.isConnected else { return false }
        let inputs: [DeviceInput]
        if session.isPhysical {
            guard let keys = pressedAndroidKeys.inputs(
                type: type,
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags,
                characters: type == .flagsChanged ? nil : event.characters,
                charactersIgnoringModifiers: type == .flagsChanged ? nil : event.charactersIgnoringModifiers,
                isRepeat: type == .keyDown && event.isARepeat
            ) else { return false }
            inputs = keys.map { .androidKey($0) }
        } else {
            let keys = EmulatorKeyMapper.keyEvents(
                type: type,
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags,
                previousFlags: previousFlags
            )
            guard !keys.isEmpty else { return false }
            inputs = keys.map { .emulatorKey($0) }
        }
        for input in inputs { session.send(input) }
        return true
    }
}

struct DeviceSurface: NSViewRepresentable {
    let session: DeviceSession

    func makeNSView(context: Context) -> DeviceSurfaceView {
        let view = DeviceSurfaceView(frame: .zero)
        view.session = session
        return view
    }

    func updateNSView(_ view: DeviceSurfaceView, context: Context) {
        view.session = session
    }

    static func dismantleNSView(_ view: DeviceSurfaceView, coordinator: ()) {
        view.detach()
    }
}
