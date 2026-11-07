#if DEBUG
import SwiftData
import SwiftUI

/// A review tab: the task folder's changes against its merge base with the
/// default branch, as a file list beside the selected file's diff.
struct ReviewTabView: View {
    let task: WorkTask
    let isFocused: Bool

    var body: some View {
        Group {
            if let directory = task.workingDirectoryPath {
                ReviewTabContent(model: ReviewStore.shared.model(for: directory), isFocused: isFocused)
                    .id(directory)
            } else {
                ContentUnavailableView("No Folder", systemImage: "folder", description: Text("This task has no folder to review."))
            }
        }
        .plumeTheme(bodySize: CGFloat(AppSettings.defaultChatFontSize), setsAmbientFont: false)
        .plumeID(AccessibilityID.reviewTab)
    }
}

private struct ReviewTabContent: View, ThemedView {
    @Environment(\.theme) var theme
    let model: ReviewModel
    let isFocused: Bool

    @FocusState private var hasKeyFocus: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                ReviewFileList(model: model)
                    .frame(width: 280)
                Divider()
                ReviewDiffPane(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyFocus)
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            model.selectFile(offset: press.key == .upArrow ? -1 : 1)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "jk")) { press in
            model.selectFile(offset: press.characters == "k" ? -1 : 1)
            return .handled
        }
        .onAppear {
            model.setPalette(CodeSyntaxPalette(palette: colors))
            model.retain()
            if isFocused { hasKeyFocus = true }
        }
        .onDisappear { model.release() }
        .onChange(of: CodeSyntaxPalette(palette: colors)) { _, palette in
            model.setPalette(palette)
        }
        .onChange(of: isFocused) { _, focused in
            if focused { hasKeyFocus = true }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            ReviewBasePicker(model: model)
            Text(summary)
                .font(typography.caption.font)
                .emphasis(.secondary)
                .lineLimit(1)
            Spacer()
            if let duration = model.lastListDuration {
                Text("list \(Self.milliseconds(duration))")
                    .font(typography.caption.mono)
                    .emphasis(.subtle)
            }
            if let duration = model.lastContentDuration {
                Text("file \(Self.milliseconds(duration))")
                    .font(typography.caption.mono)
                    .emphasis(.subtle)
            }
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
            .plumeID(AccessibilityID.reviewRefreshButton, invoke: { model.refresh() })
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var summary: String {
        switch model.phase {
        case .idle, .loading:
            return "Loading changes…"
        case .failed(let message):
            return "Couldn't list changes: \(message)"
        case .loaded:
            let added = model.files.reduce(0) { $0 + $1.addedLines }
            let removed = model.files.reduce(0) { $0 + $1.removedLines }
            let base = model.range.map { String($0.baseCommit.prefix(8)) } ?? "?"
            return "\(model.files.count) files  +\(added) −\(removed)  at \(base)"
        }
    }

    static func milliseconds(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        return "\(Int(Double(seconds) * 1000 + Double(attoseconds) / 1e15))ms"
    }
}

private struct ReviewFileList: View, ThemedView {
    @Environment(\.theme) var theme
    let model: ReviewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.files) { file in
                        row(file)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: model.selectedPath) { _, path in
                guard let path else { return }
                proxy.scrollTo(path)
            }
        }
        .overlay {
            if model.phase == .loaded, model.files.isEmpty {
                Text("No changes")
                    .emphasis(.secondary)
            }
        }
        .plumeID(AccessibilityID.reviewFileList, value: model.selectedPath)
    }

    private func row(_ file: DiffFileSummary) -> some View {
        let isSelected = file.path == model.selectedPath
        let name = (file.path as NSString).lastPathComponent
        let folder = (file.path as NSString).deletingLastPathComponent
        return Button {
            model.selectedPath = file.path
        } label: {
            HStack(spacing: 6) {
                ReviewChangeBadge(kind: file.kind)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !folder.isEmpty || file.oldPath != nil {
                        Text(file.oldPath.map { "from \($0)" } ?? folder)
                            .font(typography.caption.font)
                            .emphasis(.subtle)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                ReviewLineCounts(file: file)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(.rect)
            .background(isSelected ? colors.selection : .clear, in: .rect(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .id(file.path)
        .plumeID(
            AccessibilityID.reviewFileRow,
            label: file.path,
            value: isSelected ? "selected" : nil,
            invoke: { model.selectedPath = file.path }
        )
    }
}

/// Picks what the folder's review compares against. The tab and the pane
/// share one model, so they share the pick.
struct ReviewBasePicker: View, ThemedView {
    @Environment(\.theme) var theme
    let model: ReviewModel

    var body: some View {
        let options = model.baseOptions
        let current = model.base
        Menu {
            ForEach(options?.available ?? [], id: \.self) { base in
                Toggle(
                    options?.menuTitle(for: base) ?? base.rawValue,
                    isOn: Binding(get: { base == current }, set: { if $0 { model.selectBase(base) } })
                )
            }
        } label: {
            Text("vs \(options?.title(for: current) ?? "…")")
                .font(typography.caption.font)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(options == nil)
        .help("Compare against")
        .plumeID(AccessibilityID.reviewBasePicker, value: current.rawValue)
    }
}

struct ReviewChangeBadge: View, ThemedView {
    @Environment(\.theme) var theme
    let kind: DiffChangeKind

    var body: some View {
        Text(kind.badge)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(Self.color(for: kind, in: colors))
            .frame(width: 14, height: 14)
            .background(Self.color(for: kind, in: colors).opacity(0.15), in: .rect(cornerRadius: 3))
    }

    static func color(for kind: DiffChangeKind, in colors: Palette) -> Color {
        switch kind {
        case .added: colors.success
        case .modified: colors.warning
        case .deleted: colors.danger
        case .renamed: colors.attention
        }
    }
}

struct ReviewLineCounts: View, ThemedView {
    @Environment(\.theme) var theme
    let file: DiffFileSummary

    var body: some View {
        if file.isBinary || file.isUncounted {
            Text(file.isBinary ? "bin" : "large")
                .font(typography.caption.mono)
                .emphasis(.subtle)
        } else {
            HStack(spacing: 4) {
                Text("+\(file.addedLines)").foregroundStyle(colors.success)
                Text("−\(file.removedLines)").foregroundStyle(colors.danger)
            }
            .font(typography.caption.mono)
        }
    }
}

/// The selected file's diff, or why there is none.
private struct ReviewDiffPane: View, ThemedView {
    @Environment(\.theme) var theme
    let model: ReviewModel

    var body: some View {
        Group {
            if let file = model.selectedFile {
                switch model.contents[file.path] {
                case nil, .loading:
                    ProgressView().controlSize(.small)
                case .failed(let error):
                    message(error)
                case .loaded(let content, let rows):
                    loaded(content, rows: rows, file: file)
                }
            } else {
                message(model.files.isEmpty ? "" : "Select a file")
            }
        }
        .plumeID(AccessibilityID.reviewDiffBody, label: model.selectedPath)
    }

    @ViewBuilder
    private func loaded(_ content: DiffFileContent, rows: [ReviewDiffRow], file: DiffFileSummary) -> some View {
        switch content {
        case .text:
            ReviewDiffBody(rows: rows)
                .id(file.path)
        case .binary:
            message("Binary file")
        case .empty:
            message("No line changes")
        case .tooLarge(let changedLines):
            VStack(spacing: 8) {
                message(changedLines.map { "\($0) changed lines — too large to show by default" }
                    ?? "Too large to count — not shown by default")
                Button("Load Anyway") { model.loadContent(for: file.path, liftingCap: true) }
                    .plumeID(AccessibilityID.reviewLoadAnywayButton, invoke: {
                        model.loadContent(for: file.path, liftingCap: true)
                    })
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .emphasis(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
