#if DEBUG
import AppKit
import SwiftUI

/// What the document asks of whoever owns its data.
struct ReviewDocumentActions {
    /// The files near the viewport, nearest first.
    var want: ([String]) -> Void = { _ in }
    var topFileChanged: (String) -> Void = { _ in }
    var toggleCollapsed: (String) -> Void = { _ in }
    var loadAnyway: (String) -> Void = { _ in }
    /// `extending` replaces an empty draft the last click left in the file.
    var comment: (_ path: String, _ lines: [DiffLine], _ extending: Bool) -> Void = { _, _, _ in }
    var commentRoot: (UUID) -> AnyView? = { _ in nil }
    var moveFile: (Int) -> Void = { _ in }
}

/// Every changed file as one view-based table: rows recycle, line rows draw
/// with Core Text, and only comment drafts host SwiftUI.
///
/// Rows have fixed heights from the font, except prose lines, which wrap at
/// heights measured off the main actor, comment drafts, which report their
/// own, and a file not loaded yet, which reserves its estimate. Any change
/// in height keeps the line at the top of the viewport where it was.
@MainActor
final class ReviewDocumentController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let scrollView = NSScrollView()
    let tableView = ReviewDocumentTableView()
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("document"))

    var actions = ReviewDocumentActions()
    private(set) lazy var gutter = ReviewGutterInteraction(controller: self)

    private(set) var appearance: ReviewDocumentAppearance
    private(set) var metrics: ReviewDocumentMetrics
    private(set) var segments: [ReviewDocumentSegment] = []
    private(set) var rows: [ReviewDocumentRow] = []
    private var segmentStarts: [String: Int] = [:]
    private var hasLoaded = false
    private var maxColumns = 0

    /// Wrapped heights by text, valid at `wrapWidth`.
    private var wrapHeights: [String: CGFloat] = [:]
    private var wrapWidth: CGFloat = 0
    private var commentHeights: [UUID: CGFloat] = [:]

    private var pendingReveal: (path: String, done: () -> Void)?
    /// Counts as the top file while its header is on screen, since the last
    /// files can't scroll their headers to the top.
    private var revealedPath: String?
    private var lastWanted: [String] = []
    private var lastTop: String?
    private var lastClip: CGRect = .zero
    private var isViewportReportScheduled = false

    init(appearance: ReviewDocumentAppearance) {
        self.appearance = appearance
        metrics = ReviewDocumentMetrics(font: appearance.font)
        super.init()
        column.resizingMask = []
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.intercellSpacing = .zero
        tableView.style = .plain
        tableView.selectionHighlightStyle = .none
        tableView.usesAutomaticRowHeights = false
        tableView.gridStyleMask = []
        tableView.focusRingType = .none
        tableView.backgroundColor = appearance.background
        tableView.dataSource = self
        tableView.delegate = self
        tableView.controller = self
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.backgroundColor = appearance.background
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipChanged), name: NSView.boundsDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self, selector: #selector(clipChanged), name: NSView.frameDidChangeNotification, object: clip)
    }

    // MARK: Content

    func setSegments(_ new: [ReviewDocumentSegment]) {
        guard hasLoaded else {
            hasLoaded = true
            adopt(new)
            tableView.reloadData()
            didUpdate()
            return
        }
        let changes = ReviewDocumentChanges.between(segments, new)
        guard !changes.isEmpty else {
            adopt(new)
            return
        }
        preservingAnchor {
            adopt(new)
            tableView.beginUpdates()
            if !changes.removed.isEmpty { tableView.removeRows(at: changes.removed, withAnimation: []) }
            if !changes.inserted.isEmpty { tableView.insertRows(at: changes.inserted, withAnimation: []) }
            tableView.endUpdates()
            if !changes.reloaded.isEmpty {
                tableView.reloadData(forRowIndexes: changes.reloaded, columnIndexes: IndexSet(integer: 0))
                tableView.noteHeightOfRows(withIndexesChanged: changes.reloaded)
            }
        }
        didUpdate()
    }

    func setAppearance(_ new: ReviewDocumentAppearance) {
        guard new != appearance else { return }
        let fontChanged = new.font != appearance.font
        appearance = new
        metrics = ReviewDocumentMetrics(font: new.font)
        tableView.backgroundColor = new.background
        scrollView.backgroundColor = new.background
        if fontChanged {
            wrapHeights = [:]
            wrapWidth = 0
            updateDocumentWidth()
        }
        guard hasLoaded else { return }
        preservingAnchor { tableView.reloadData() }
        if fontChanged { measureWraps() }
    }

    /// Scrolls `path`'s header to the top, once the file is in the document.
    func reveal(_ path: String, done: @escaping () -> Void) {
        pendingReveal = (path, done)
        resolveReveal()
    }

    func setCommentHeight(_ height: CGFloat, for id: UUID) {
        let height = ceil(height)
        guard height > 0, commentHeights[id] != height else { return }
        commentHeights[id] = height
        guard let row = rows.firstIndex(where: { $0.identity == .comment(id) }) else { return }
        preservingAnchor { tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row)) }
    }

    func index(of identity: ReviewDocumentRow.Identity, in path: String) -> Int? {
        guard let start = segmentStarts[path] else { return nil }
        var index = start
        while index < rows.count, rows[index].path == path {
            if rows[index].identity == identity { return index }
            index += 1
        }
        return nil
    }

    func row(at event: NSEvent) -> Int? {
        let row = tableView.row(at: tableView.convert(event.locationInWindow, from: nil))
        return row >= 0 ? row : nil
    }

    private func adopt(_ new: [ReviewDocumentSegment]) {
        segments = new
        var rows: [ReviewDocumentRow] = []
        rows.reserveCapacity(new.reduce(0) { $0 + $1.rows.count })
        var starts: [String: Int] = [:]
        var columns = 0
        for segment in new {
            starts[segment.path] = rows.count
            rows.append(contentsOf: segment.rows)
            columns = max(columns, segment.columns)
        }
        self.rows = rows
        segmentStarts = starts
        if columns != maxColumns {
            maxColumns = columns
            updateDocumentWidth()
        }
    }

    private func didUpdate() {
        measureWraps()
        resolveReveal()
        scheduleViewportReport()
    }

    private func resolveReveal() {
        guard let (path, done) = pendingReveal, let header = segmentStarts[path] else { return }
        pendingReveal = nil
        scroll(toY: tableView.rect(ofRow: header).minY)
        revealedPath = path
        lastTop = path
        Task { done() }
    }

    // MARK: Anchoring

    private struct Anchor {
        let path: String
        let identity: ReviewDocumentRow.Identity
        let offset: CGFloat
        let headerOffset: CGFloat
    }

    private func preservingAnchor(_ update: () -> Void) {
        let anchor = captureAnchor()
        update()
        if let anchor { restore(anchor) }
    }

    private func captureAnchor() -> Anchor? {
        let clip = scrollView.contentView.bounds
        guard clip.minY > 0 else { return nil }
        let row = tableView.row(at: NSPoint(x: clip.minX, y: clip.minY))
        guard rows.indices.contains(row), let header = segmentStarts[rows[row].path] else { return nil }
        return Anchor(
            path: rows[row].path,
            identity: rows[row].identity,
            offset: clip.minY - tableView.rect(ofRow: row).minY,
            headerOffset: clip.minY - tableView.rect(ofRow: header).minY
        )
    }

    private func restore(_ anchor: Anchor) {
        let y: CGFloat
        if let row = index(of: anchor.identity, in: anchor.path) {
            y = tableView.rect(ofRow: row).minY + anchor.offset
        } else if let header = segmentStarts[anchor.path] {
            y = tableView.rect(ofRow: header).minY + anchor.headerOffset
        } else {
            return
        }
        scroll(toY: y)
    }

    private func scroll(toY y: CGFloat) {
        let clip = scrollView.contentView
        let maxY = max(tableView.frame.height - clip.bounds.height, 0)
        let target = min(max(y, 0), maxY)
        guard target != clip.bounds.minY else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Viewport

    @objc private func clipChanged() {
        let clip = scrollView.contentView.bounds
        let widthChanged = clip.width != lastClip.width
        let xChanged = clip.minX != lastClip.minX
        lastClip = clip
        if widthChanged {
            updateDocumentWidth()
            measureWraps()
        }
        if widthChanged || xChanged { pinVisibleCells() }
        scheduleViewportReport()
    }

    private func pinVisibleCells() {
        let clip = scrollView.contentView.bounds
        tableView.enumerateAvailableRowViews { rowView, _ in
            (rowView.view(atColumn: 0) as? ReviewDocumentCell)?.pin(x: clip.minX, width: clip.width)
        }
    }

    private func updateDocumentWidth() {
        let clipWidth = scrollView.contentView.bounds.width
        let width = max(clipWidth, maxColumns > 0 ? metrics.codeWidth(columns: maxColumns) : 0)
        guard column.width != width else { return }
        column.width = width
    }

    /// Reports after the current update, so a report never writes to the
    /// model from inside a SwiftUI update.
    private func scheduleViewportReport() {
        guard !isViewportReportScheduled else { return }
        isViewportReportScheduled = true
        Task { [weak self] in
            guard let self else { return }
            isViewportReportScheduled = false
            reportViewport()
        }
    }

    private func reportViewport() {
        guard !rows.isEmpty else { return }
        let visible = scrollView.contentView.bounds
        let shown = tableView.rows(in: visible)
        let near = tableView.rows(in: visible.insetBy(dx: 0, dy: -visible.height))
        var paths: [String] = []
        var seen = Set<String>()
        func add(_ range: some Sequence<Int>) {
            for row in range where rows.indices.contains(row) && seen.insert(rows[row].path).inserted {
                paths.append(rows[row].path)
            }
        }
        add(shown.location ..< NSMaxRange(shown))
        add(NSMaxRange(shown) ..< NSMaxRange(near))
        add((near.location ..< shown.location).reversed())
        if paths != lastWanted {
            lastWanted = paths
            actions.want(paths)
        }

        let topRow = tableView.row(at: NSPoint(x: visible.minX, y: visible.minY))
        guard rows.indices.contains(topRow) else { return }
        var top = rows[topRow].path
        if let revealedPath {
            if let header = segmentStarts[revealedPath], tableView.rect(ofRow: header).intersects(visible) {
                top = revealedPath
            } else {
                self.revealedPath = nil
            }
        }
        if top != lastTop {
            lastTop = top
            actions.topFileChanged(top)
        }
    }

    // MARK: Wrapping

    private var wrapTextWidth: CGFloat {
        scrollView.contentView.bounds.width - ReviewDocumentMetrics.gutterWidth - ReviewDocumentMetrics.textInset - 8
    }

    /// Measures prose lines off the main actor: every one when the width
    /// changed, else only those not measured yet.
    private func measureWraps() {
        let width = wrapTextWidth
        guard width > 0 else { return }
        let remeasures = width != wrapWidth
        var texts: [String] = []
        for segment in segments where ReviewDocument.wraps(segment.path) {
            for row in segment.rows {
                guard case .line(let line, _, true) = row.kind else { continue }
                if remeasures || wrapHeights[line.text] == nil { texts.append(line.text) }
            }
        }
        guard !texts.isEmpty else {
            if remeasures { wrapWidth = width }
            return
        }
        let font = appearance.font
        let fontName = font.fontName
        let fontSize = font.pointSize
        let tabInterval = metrics.characterWidth * CGFloat(ReviewDocument.tabWidth)
        let lineHeight = metrics.lineHeight
        let measured = texts
        Task { [weak self] in
            let heights = await Task.detached(priority: .userInitiated) {
                ReviewWrapMeasure.heights(
                    of: measured, fontName: fontName, fontSize: fontSize,
                    tabInterval: tabInterval, width: width, lineHeight: lineHeight
                )
            }.value
            self?.applyWrapHeights(heights, width: width, fontName: fontName, fontSize: fontSize)
        }
    }

    private func applyWrapHeights(_ heights: [String: CGFloat], width: CGFloat, fontName: String, fontSize: CGFloat) {
        guard width == wrapTextWidth, fontName == appearance.font.fontName, fontSize == appearance.font.pointSize else { return }
        if width == wrapWidth {
            wrapHeights.merge(heights) { _, new in new }
        } else {
            wrapHeights = heights
            wrapWidth = width
        }
        var changed = IndexSet()
        for (index, row) in rows.enumerated() {
            if case .line(let line, _, true) = row.kind, heights[line.text] != nil { changed.insert(index) }
        }
        guard !changed.isEmpty else { return }
        preservingAnchor { tableView.noteHeightOfRows(withIndexesChanged: changed) }
        tableView.enumerateAvailableRowViews { rowView, _ in
            (rowView.view(atColumn: 0) as? ReviewLineCell)?.redraw()
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row].kind {
        case .fileHeader: ReviewDocumentMetrics.headerHeight
        case .hunk: metrics.lineHeight + 6
        case .line(let line, _, let wraps): wraps ? wrapHeights[line.text] ?? metrics.lineHeight : metrics.lineHeight
        case .placeholder(.pending(let estimatedRows)):
            max(CGFloat(estimatedRows) * metrics.lineHeight, ReviewDocumentMetrics.messageHeight)
        case .placeholder(.tooLarge): ReviewPlaceholderCell.tooLargeHeight
        case .placeholder: ReviewDocumentMetrics.messageHeight
        case .comment(let id): commentHeights[id] ?? ReviewDocumentMetrics.defaultCommentHeight
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        let cell: ReviewDocumentCell
        switch item.kind {
        case .line(let line, let spans, let wraps):
            let lineCell = reuse(ReviewLineCell.reuseIdentifier, ReviewLineCell.init)
            lineCell.configure(path: item.path, line: line, spans: spans, wraps: wraps, controller: self)
            cell = lineCell
        case .hunk(let header):
            let hunkCell = reuse(ReviewHunkCell.reuseIdentifier, ReviewHunkCell.init)
            hunkCell.configure(header: header, controller: self)
            cell = hunkCell
        case .fileHeader(let file, let collapsed):
            let headerCell = reuse(ReviewFileHeaderCell.reuseIdentifier, ReviewFileHeaderCell.init)
            headerCell.configure(file: file, collapsed: collapsed, controller: self)
            cell = headerCell
        case .placeholder(let placeholder):
            let placeholderCell = reuse(ReviewPlaceholderCell.reuseIdentifier, ReviewPlaceholderCell.init)
            placeholderCell.configure(path: item.path, placeholder: placeholder, controller: self)
            cell = placeholderCell
        case .comment(let id):
            let commentCell = reuse(ReviewCommentCell.reuseIdentifier, ReviewCommentCell.init)
            if let root = actions.commentRoot(id) {
                commentCell.configure(id: id, root: root, controller: self)
            }
            cell = commentCell
        }
        let clip = scrollView.contentView.bounds
        cell.pin(x: clip.minX, width: clip.width)
        return cell
    }

    private func reuse<Cell: ReviewDocumentCell>(_ identifier: NSUserInterfaceItemIdentifier, _ make: () -> Cell) -> Cell {
        tableView.makeView(withIdentifier: identifier, owner: nil) as? Cell ?? make()
    }
}

/// Gutter clicks, in rows. A click drafts a comment on its line; a
/// shift-click drafts one from the last clicked line to this one, within a
/// file. A drag-select range belongs in `mouseDragged`.
@MainActor
final class ReviewGutterInteraction {
    private unowned let controller: ReviewDocumentController
    private var anchor: (path: String, identity: ReviewDocumentRow.Identity)?
    private var press: (row: Int, extending: Bool)?

    init(controller: ReviewDocumentController) {
        self.controller = controller
    }

    func mouseDown(row: Int, event: NSEvent) {
        press = (row, event.modifierFlags.contains(.shift))
    }

    func mouseDragged(row: Int, event: NSEvent) {}

    func mouseUp(row: Int?, event: NSEvent) {
        guard let press else { return }
        self.press = nil
        click(row: press.row, extending: press.extending)
    }

    func click(row: Int, extending: Bool) {
        let rows = controller.rows
        guard rows.indices.contains(row), case .line = rows[row].kind else { return }
        let path = rows[row].path
        var bounds = row ... row
        if extending, let anchor, anchor.path == path, let start = controller.index(of: anchor.identity, in: path) {
            bounds = min(start, row) ... max(start, row)
        }
        let lines = rows[bounds].compactMap { item -> DiffLine? in
            if case .line(let line, _, _) = item.kind { return line }
            return nil
        }
        anchor = (path, rows[row].identity)
        controller.actions.comment(path, lines, extending)
    }
}

final class ReviewDocumentTableView: NSTableView {
    weak var controller: ReviewDocumentController?

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return super.keyDown(with: event)
        }
        let offset: Int? = switch (event.charactersIgnoringModifiers, event.keyCode) {
        case ("j", _), (_, 125): 1
        case ("k", _), (_, 126): -1
        default: nil
        }
        if let offset {
            controller?.actions.moveFile(offset)
        } else {
            super.keyDown(with: event)
        }
    }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool { true }
}
#endif
