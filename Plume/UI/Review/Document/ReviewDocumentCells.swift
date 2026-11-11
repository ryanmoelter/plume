#if DEBUG
import AppKit
import SwiftUI

/// A recycled row of the review document. A row spans the document's full
/// width, but draws only through its canvas, which covers the visible part:
/// `pinX` is the visible left edge and `pinWidth` the visible width. That
/// keeps every backing store the size of the viewport, however long the
/// document's widest line.
class ReviewDocumentCell: NSView {
    weak var controller: ReviewDocumentController?
    private(set) var pinX: CGFloat = 0
    private(set) var pinWidth: CGFloat = 0
    private let canvas: ReviewCanvasView?

    override var isFlipped: Bool { true }

    init(identifier: NSUserInterfaceItemIdentifier, draws: Bool) {
        canvas = draws ? ReviewCanvasView() : nil
        super.init(frame: .zero)
        self.identifier = identifier
        if let canvas {
            canvas.cell = self
            addSubview(canvas)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func pin(x: CGFloat, width: CGFloat) {
        guard x != pinX || width != pinWidth else { return }
        pinX = x
        pinWidth = width
        needsLayout = true
        redraw()
    }

    func redraw() {
        canvas?.needsDisplay = true
    }

    override func layout() {
        super.layout()
        canvas?.frame = NSRect(x: pinX, y: 0, width: pinWidth, height: bounds.height)
    }

    /// Draws in the row's own coordinates; `rect` is the part to draw.
    func drawContent(_ rect: CGRect, in context: CGContext) {}

    var appearanceValues: ReviewDocumentAppearance? { controller?.appearance }
    var metrics: ReviewDocumentMetrics? { controller?.metrics }
}

final class ReviewCanvasView: NSView {
    weak var cell: ReviewDocumentCell?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let cell, let context = NSGraphicsContext.current?.cgContext else { return }
        let offset = frame.minX
        context.saveGState()
        context.translateBy(x: -offset, y: 0)
        cell.drawContent(dirtyRect.offsetBy(dx: offset, dy: 0), in: context)
        context.restoreGState()
    }
}

// MARK: - Lines

final class ReviewLineCell: ReviewDocumentCell {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("review-line")

    let gutter = ReviewGutterView()
    private var line: DiffLine?
    private var text: CTLine?
    private var textWidth: CGFloat = 0
    private var wrappedText: CTFramesetter?
    private var oldNumber: CTLine?
    private var newNumber: CTLine?
    private var marker: CTLine?

    init() {
        super.init(identifier: Self.reuseIdentifier, draws: true)
        addSubview(gutter)
    }

    func configure(path: String, line: DiffLine, spans: [CodeSyntax.Span], wraps: Bool, controller: ReviewDocumentController) {
        self.controller = controller
        self.line = line
        let appearance = controller.appearance
        let attributed = ReviewDocumentText.attributed(line.text, spans: spans, appearance: appearance, metrics: controller.metrics)
        if wraps {
            wrappedText = CTFramesetterCreateWithAttributedString(attributed)
            text = nil
        } else {
            let text = CTLineCreateWithAttributedString(attributed)
            self.text = text
            textWidth = CGFloat(CTLineGetTypographicBounds(text, nil, nil, nil))
            wrappedText = nil
        }
        func number(_ value: Int?) -> CTLine? {
            value.map {
                CTLineCreateWithAttributedString(NSAttributedString(string: String($0), attributes: [
                    .font: appearance.font, .foregroundColor: appearance.subtle,
                ]))
            }
        }
        oldNumber = number(line.oldNumber)
        newNumber = number(line.newNumber)
        let markerText: String? = switch line.kind {
        case .context: nil
        case .added: "+"
        case .removed: "-"
        }
        marker = markerText.map {
            CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: [
                .font: appearance.font,
                .foregroundColor: line.kind == .added ? appearance.success : appearance.danger,
            ]))
        }
        gutter.configure(path: path, line: line, controller: controller)
        redraw()
    }

    override func layout() {
        super.layout()
        gutter.frame = NSRect(x: pinX, y: 0, width: ReviewDocumentMetrics.gutterWidth, height: bounds.height)
    }

    override func drawContent(_ rect: CGRect, in context: CGContext) {
        guard let line, let appearance = appearanceValues, let metrics else { return }
        let tint = appearance.tint(for: line.kind)
        if let tint {
            tint.setFill()
            rect.fill(using: .sourceOver)
        }
        let codeX = ReviewDocumentMetrics.gutterWidth + ReviewDocumentMetrics.textInset
        if let wrappedText {
            let frame = CGRect(x: pinX + codeX, y: 1, width: max(pinWidth - codeX - 8, 1), height: bounds.height - 2)
            ReviewDocumentText.draw(wrappedText, in: frame, context: context)
        } else if let text {
            ReviewDocumentText.draw(text, at: CGPoint(x: codeX, y: 0), baseline: metrics.baseline, in: context)
            if line.missingNewline {
                ReviewDocumentSymbols.draw(
                    "return", color: appearance.danger, size: appearance.font.pointSize * 0.8,
                    in: CGRect(x: codeX + textWidth + 4, y: 0, width: metrics.lineHeight, height: metrics.lineHeight)
                )
            }
        }
        drawGutter(tint: tint, appearance: appearance, metrics: metrics, in: context)
    }

    private func drawGutter(tint: NSColor?, appearance: ReviewDocumentAppearance, metrics: ReviewDocumentMetrics, in context: CGContext) {
        let gutter = CGRect(x: pinX, y: 0, width: ReviewDocumentMetrics.gutterWidth, height: bounds.height)
        appearance.background.setFill()
        gutter.fill()
        if let tint {
            tint.setFill()
            gutter.fill(using: .sourceOver)
        }
        let numberWidth = ReviewDocumentMetrics.numberWidth
        for (index, number) in [oldNumber, newNumber].enumerated() {
            guard let number else { continue }
            let width = CGFloat(CTLineGetTypographicBounds(number, nil, nil, nil))
            let right = pinX + CGFloat(index + 1) * (numberWidth + 4) - 4
            ReviewDocumentText.draw(number, at: CGPoint(x: right - width, y: 0), baseline: metrics.baseline, in: context)
        }
        if let marker {
            let width = CGFloat(CTLineGetTypographicBounds(marker, nil, nil, nil))
            let x = pinX + (numberWidth + 4) * 2 + (ReviewDocumentMetrics.markerWidth - width) / 2
            ReviewDocumentText.draw(marker, at: CGPoint(x: x, y: 0), baseline: metrics.baseline, in: context)
        }
    }
}

/// Where a click drafts a comment. It draws nothing — the row draws the
/// numbers — and hands every mouse event to the controller's
/// `ReviewGutterInteraction`, which sees rows rather than views.
final class ReviewGutterView: NSView {
    private weak var controller: ReviewDocumentController?
    private lazy var registration = AppKitControlRegistration(view: self)

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        toolTip = "Comment on this line; shift-click to comment on a range"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(path: String, line: DiffLine, controller: ReviewDocumentController) {
        self.controller = controller
        let label = "\(path):\(line.oldNumber.map(String.init) ?? "-"):\(line.newNumber.map(String.init) ?? "-")"
        registration.set(id: AccessibilityID.reviewDiffGutter, label: label) { [weak self] in
            guard let self, let row = self.row else { return }
            self.controller?.gutter.click(row: row, extending: false)
        }
    }

    private var row: Int? {
        guard let table = controller?.tableView else { return nil }
        let row = table.row(for: self)
        return row >= 0 ? row : nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registration.sync()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let row else { return }
        controller?.gutter.mouseDown(row: row, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let controller, let row = controller.row(at: event) else { return }
        controller.gutter.mouseDragged(row: row, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let controller else { return }
        controller.gutter.mouseUp(row: controller.row(at: event), event: event)
    }
}

// MARK: - Hunks

final class ReviewHunkCell: ReviewDocumentCell {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("review-hunk")
    private var text: CTLine?

    init() { super.init(identifier: Self.reuseIdentifier, draws: true) }

    func configure(header: String, controller: ReviewDocumentController) {
        self.controller = controller
        text = CTLineCreateWithAttributedString(NSAttributedString(string: header, attributes: [
            .font: controller.appearance.font, .foregroundColor: controller.appearance.attention,
        ]))
        redraw()
    }

    override func drawContent(_ rect: CGRect, in context: CGContext) {
        guard let appearance = appearanceValues, let metrics, let text else { return }
        appearance.hunkTint.setFill()
        rect.fill(using: .sourceOver)
        let y = (bounds.height - metrics.lineHeight) / 2
        ReviewDocumentText.draw(
            text, at: CGPoint(x: pinX + ReviewDocumentMetrics.gutterWidth + ReviewDocumentMetrics.textInset, y: y),
            baseline: metrics.baseline, in: context
        )
    }
}

// MARK: - File headers

/// A file's path, its change at a glance, and the fold. A click anywhere on
/// it folds or unfolds the file.
final class ReviewFileHeaderCell: ReviewDocumentCell {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("review-file-header")
    static let topGap: CGFloat = 8

    private var file: DiffFileSummary?
    private var collapsed = false
    private lazy var registration = AppKitControlRegistration(view: self)

    init() { super.init(identifier: Self.reuseIdentifier, draws: true) }

    func configure(file: DiffFileSummary, collapsed: Bool, controller: ReviewDocumentController) {
        self.controller = controller
        self.file = file
        self.collapsed = collapsed
        registration.set(
            id: AccessibilityID.reviewFileHeader, label: file.path, value: collapsed ? "collapsed" : "expanded"
        ) { [weak controller] in
            controller?.actions.toggleCollapsed(file.path)
        }
        redraw()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registration.sync()
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard let file, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        controller?.actions.toggleCollapsed(file.path)
    }

    override func drawContent(_ rect: CGRect, in context: CGContext) {
        guard let file, let appearance = appearanceValues, let metrics else { return }
        let band = CGRect(x: pinX, y: Self.topGap, width: pinWidth, height: bounds.height - Self.topGap)
        appearance.headerTint.setFill()
        band.fill(using: .sourceOver)
        appearance.divider.setFill()
        CGRect(x: band.minX, y: band.minY, width: band.width, height: 1).fill(using: .sourceOver)
        CGRect(x: band.minX, y: band.maxY - 1, width: band.width, height: 1).fill(using: .sourceOver)

        let textTop = band.minY + (band.height - metrics.lineHeight) / 2
        let midY = band.midY
        var left = band.minX + 10
        ReviewDocumentSymbols.draw(
            collapsed ? "chevron.right" : "chevron.down", color: appearance.subtle, size: 9,
            in: CGRect(x: left, y: midY - 6, width: 12, height: 12)
        )
        left += 18
        let badge = line(file.kind.badge, color: appearance.color(for: file.kind), appearance: appearance)
        ReviewDocumentText.draw(badge, at: CGPoint(x: left, y: textTop), baseline: metrics.baseline, in: context)
        left += Self.width(of: badge) + 10

        var right = band.maxX - 12
        let counts = counts(of: file, appearance: appearance)
        right -= Self.width(of: counts)
        ReviewDocumentText.draw(counts, at: CGPoint(x: right, y: textTop), baseline: metrics.baseline, in: context)
        right -= 10
        let boxes = ReviewChangeMagnitude.boxCount(changedLines: file.changedLines)
        if boxes > 0 {
            appearance.color(for: ReviewChangeMagnitude.tint(added: file.addedLines, removed: file.removedLines)).setFill()
            let sides = (0 ..< boxes).map(ReviewChangeMagnitude.side(ofBox:))
            let total = sides.reduce(0, +) + CGFloat(boxes - 1) * 2
            var x = right - total
            let bottom = midY + (sides.last ?? 0) / 2
            for side in sides {
                NSBezierPath(roundedRect: CGRect(x: x, y: bottom - side, width: side, height: side), xRadius: 1.5, yRadius: 1.5).fill()
                x += side + 2
            }
            right -= total + 10
        }
        let title = file.oldPath.map { "\($0) → \(file.path)" } ?? file.path
        let pathLine = line(title, color: appearance.foreground, appearance: appearance)
        let available = max(right - left, 20)
        let fitted = Self.width(of: pathLine) <= available
            ? pathLine
            : CTLineCreateTruncatedLine(pathLine, available, .start, line("…", color: appearance.foreground, appearance: appearance)) ?? pathLine
        ReviewDocumentText.draw(fitted, at: CGPoint(x: left, y: textTop), baseline: metrics.baseline, in: context)
    }

    private func line(_ text: String, color: NSColor, appearance: ReviewDocumentAppearance) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: appearance.font, .foregroundColor: color,
        ]))
    }

    private func counts(of file: DiffFileSummary, appearance: ReviewDocumentAppearance) -> CTLine {
        if file.isBinary || file.isUncounted {
            return line(file.isBinary ? "bin" : "large", color: appearance.subtle, appearance: appearance)
        }
        let font = appearance.font
        let string = NSMutableAttributedString(string: "+\(file.addedLines)", attributes: [.font: font, .foregroundColor: appearance.success])
        string.append(NSAttributedString(string: " −\(file.removedLines)", attributes: [.font: font, .foregroundColor: appearance.danger]))
        return CTLineCreateWithAttributedString(string)
    }

    private static func width(of line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}

// MARK: - Placeholders

/// What stands in for a file's lines. A pending file's row can be very tall,
/// so this cell has no canvas and keeps its controls at its top.
final class ReviewPlaceholderCell: ReviewDocumentCell {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("review-placeholder")
    static let tooLargeHeight: CGFloat = 64

    private let label = NSTextField(labelWithString: "")
    private let loadButton = NSButton(title: "Load Anyway", target: nil, action: nil)
    private var path = ""
    private lazy var registration = AppKitControlRegistration(view: loadButton)

    init() {
        super.init(identifier: Self.reuseIdentifier, draws: false)
        label.lineBreakMode = .byTruncatingTail
        loadButton.controlSize = .small
        loadButton.bezelStyle = .push
        loadButton.target = self
        loadButton.action = #selector(loadAnyway)
        addSubview(label)
        addSubview(loadButton)
    }

    func configure(path: String, placeholder: ReviewFilePlaceholder, controller: ReviewDocumentController) {
        self.controller = controller
        self.path = path
        let appearance = controller.appearance
        label.font = appearance.font
        label.textColor = appearance.subtle
        loadButton.isHidden = true
        switch placeholder {
        case .pending:
            label.stringValue = "Loading…"
        case .binary:
            label.stringValue = "Binary file"
        case .empty:
            label.stringValue = "No line changes"
        case .failed(let message):
            label.stringValue = message
            label.textColor = appearance.danger
        case .tooLarge(let changedLines):
            label.stringValue = changedLines.map { "\($0) changed lines — too large to show by default" }
                ?? "Too large to count — not shown by default"
            loadButton.isHidden = false
        }
        if loadButton.isHidden {
            registration.clear()
        } else {
            registration.set(id: AccessibilityID.reviewLoadAnywayButton, label: path) { [weak self] in self?.loadAnyway() }
        }
        needsLayout = true
    }

    @objc private func loadAnyway() {
        controller?.actions.loadAnyway(path)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registration.sync()
    }

    override func layout() {
        super.layout()
        let x = pinX + ReviewDocumentMetrics.gutterWidth + ReviewDocumentMetrics.textInset
        let width = max(pinWidth - (x - pinX) - 12, 20)
        let labelHeight = label.intrinsicContentSize.height
        label.frame = NSRect(x: x, y: 10, width: width, height: labelHeight)
        let buttonSize = loadButton.intrinsicContentSize
        loadButton.frame = NSRect(x: x, y: 14 + labelHeight, width: buttonSize.width, height: buttonSize.height)
    }
}

// MARK: - Comment drafts

/// A comment draft, as SwiftUI: one host per visible draft, never per line.
final class ReviewCommentCell: ReviewDocumentCell {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("review-comment")

    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private(set) var commentID: UUID?

    init() {
        super.init(identifier: Self.reuseIdentifier, draws: false)
        host.sizingOptions = []
        addSubview(host)
    }

    func configure(id: UUID, root: AnyView, controller: ReviewDocumentController) {
        self.controller = controller
        guard id != commentID else { return }
        commentID = id
        host.rootView = root
    }

    override func layout() {
        super.layout()
        host.frame = NSRect(x: pinX, y: 0, width: pinWidth, height: bounds.height)
    }
}

// MARK: - Symbols

@MainActor
enum ReviewDocumentSymbols {
    static func draw(_ name: String, color: NSColor, size: CGFloat, in rect: CGRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let imageSize = image.size
        let target = CGRect(
            x: rect.midX - imageSize.width / 2, y: rect.midY - imageSize.height / 2,
            width: imageSize.width, height: imageSize.height
        )
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
#endif
