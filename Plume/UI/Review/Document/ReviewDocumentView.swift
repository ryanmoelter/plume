#if DEBUG
import AppKit
import SwiftUI

/// The review's diff: every changed file in one scrolling document.
struct ReviewDocumentView: NSViewRepresentable {
    let model: ReviewModel

    func makeCoordinator() -> ReviewDocumentBridge {
        ReviewDocumentBridge(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.start(appearance: Self.appearance(in: context.environment))
        return context.coordinator.controller.scrollView
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.controller.setAppearance(Self.appearance(in: context.environment))
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: ReviewDocumentBridge) {
        coordinator.stop()
    }

    static func appearance(in environment: EnvironmentValues) -> ReviewDocumentAppearance {
        let theme = environment.theme
        let size = theme.typography.bodySize * AppSettings.shared.codeFontSizeMultiplier
        let font = Font.chatCode(size: size).resolve(in: environment.fontResolutionContext).ctFont as NSFont
        return ReviewDocumentAppearance(palette: theme.colors, font: font)
    }
}

/// Feeds the model's files to the document as segments, rebuilding only the
/// files whose rows changed.
@MainActor
final class ReviewDocumentBridge {
    private let model: ReviewModel
    private(set) var controller: ReviewDocumentController!
    private var cache: [String: Cached] = [:]
    private var isActive = false

    private struct Cached {
        let key: Key
        let segment: ReviewDocumentSegment
    }

    private struct Key: Equatable {
        let file: DiffFileSummary
        let collapsed: Bool
        let state: State
        let comments: [Anchor]
    }

    private enum State: Equatable {
        case pending
        case failed(String)
        case loaded(version: Int)

        init(_ state: ReviewContentState?) {
            switch state {
            case nil, .loading: self = .pending
            case .failed(let message): self = .failed(message)
            case .loaded(_, let version): self = .loaded(version: version)
            }
        }
    }

    private struct Anchor: Equatable {
        let id: UUID
        let side: ReviewComment.Side
        let line: Int
    }

    init(model: ReviewModel) {
        self.model = model
    }

    func start(appearance: ReviewDocumentAppearance) {
        let controller = ReviewDocumentController(appearance: appearance)
        self.controller = controller
        let model = model
        controller.actions = ReviewDocumentActions(
            want: { model.want($0) },
            topFileChanged: { model.noteTopFile($0) },
            toggleCollapsed: { model.toggleCollapsed($0) },
            loadAnyway: { model.loadContent(for: $0, liftingCap: true) },
            comment: { path, lines, extending in
                if extending, let previous = model.comments.last, previous.path == path, previous.body.isEmpty {
                    model.deleteComment(previous.id)
                }
                model.addComment(path: path, lines: lines)
            },
            commentRoot: { [weak controller] id in
                guard let comment = model.comments.first(where: { $0.id == id }) else { return nil }
                return AnyView(ReviewCommentRow(model: model, comment: comment) { height in
                    controller?.setCommentHeight(height, for: id)
                })
            },
            moveFile: { model.selectFile(offset: $0) }
        )
        isActive = true
        observe()
    }

    func stop() {
        isActive = false
    }

    private func observe() {
        guard isActive else { return }
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func apply() {
        let comments = Dictionary(grouping: model.comments, by: \.path)
        let collapsed = model.collapsedPaths
        let contents = model.contents
        var segments: [ReviewDocumentSegment] = []
        segments.reserveCapacity(model.files.count)
        var next: [String: Cached] = [:]
        for file in model.files {
            let drafts = comments[file.path] ?? []
            let key = Key(
                file: file,
                collapsed: collapsed.contains(file.path),
                state: State(contents[file.path]),
                comments: drafts.map { Anchor(id: $0.id, side: $0.side, line: $0.lines.upperBound) }
            )
            let cached = cache[file.path].flatMap { $0.key == key ? $0 : nil } ?? Cached(
                key: key,
                segment: ReviewDocument.segment(file: file, state: contents[file.path], collapsed: key.collapsed, comments: drafts)
            )
            next[file.path] = cached
            segments.append(cached.segment)
        }
        cache = next
        controller.setSegments(segments)
        if let request = model.revealRequest {
            controller.reveal(request.path) { [weak model] in model?.consumeReveal(request) }
        }
    }
}

/// A draft in the document, top-aligned in its row, reporting its height.
private struct ReviewCommentRow: View {
    let model: ReviewModel
    let comment: ReviewComment
    let onHeight: (CGFloat) -> Void

    var body: some View {
        ReviewCommentEditor(model: model, comment: comment)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                Task { onHeight(height) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .plumeTheme(bodySize: CGFloat(AppSettings.defaultChatFontSize), setsAmbientFont: false)
    }
}
#endif
