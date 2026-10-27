import SwiftUI

/// The box a composer autocomplete list sits in, above the message field.
/// Purely chrome: the rows come from `row`, and matching, selection and key
/// handling live with the caller.
struct ComposerSuggestionPanel<Item: Identifiable, Row: View>: View, ThemedView {
    @Environment(\.theme) var theme

    let items: [Item]
    let selectedIndex: Int
    let onSelect: (Int) -> Void
    /// Nothing between it and the panel's top edge, so it owes that edge the
    /// same inset it gives the sides. With the queued-messages strip above,
    /// the row spacing sets the gap instead.
    var isTopOfPanel = true
    /// A caption under the rows, set off by a divider.
    var footer: String?
    /// A passing state, such as a search still running. Over rows it draws
    /// across their bottom rather than adding height, so the panel doesn't
    /// jump each time it comes and goes.
    var status: String?
    @ViewBuilder let row: (Int, Item) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty, let status {
                caption(status)
            } else {
                list
                    .overlay(alignment: .bottom) {
                        if let status {
                            statusOverlay(status)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.15), value: status)
            }
            if let footer {
                Divider()
                caption(footer)
            }
        }
        .clipShape(shape)
        .background(washColor, in: shape)
        .overlay { shape.strokeBorder(.separator) }
        .padding(.horizontal, -textInset)
        .padding(.top, isTopOfPanel ? -textInset : 0)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(typography.caption.font)
            .emphasis(.subtle)
            .padding(.horizontal, textInset)
            .padding(.vertical, 5)
    }

    /// Rows scrolling under it fade into the panel's own fill.
    private func statusOverlay(_ text: String) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(washColor)
                .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
                .frame(height: 8)
            caption(text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(washColor)
        }
        .allowsHitTesting(false)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        rowChrome(item, at: index, isSelected: index == selectedIndex)
                            .id(index)
                            .onTapGesture { onSelect(index) }
                    }
                }
                .padding(rowInset)
            }
            .onChange(of: selectedIndex, initial: true) { _, newValue in
                proxy.scrollTo(newValue)
            }
        }
        .frame(maxHeight: 200)
    }

    /// What a row's text pays inside the box before it starts.
    private var textInset: CGFloat { rowInset + dimensions.panelContentInset }

    /// The box steps out past the composer by everything its text pays
    /// inside it, so a row reads down the same edge as the message being
    /// typed. Its corner then cuts concentric to the panel at that smaller
    /// inset rather than at the composer's.
    private var boxCornerRadius: CGFloat {
        ComposerPanelMetrics.concentricRadius(
            outer: dimensions.panelCornerRadius,
            inset: dimensions.composerFieldInset - textInset
        )
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: boxCornerRadius, style: .continuous)
    }

    private let rowInset: CGFloat = 4

    private func rowChrome(_ item: Item, at index: Int, isSelected: Bool) -> some View {
        row(index, item)
            .padding(.horizontal, dimensions.panelContentInset)
            .padding(.vertical, 5)
            .background(
                isSelected ? colors.selection.emphasized(.divider, in: colors) : .clear,
                in: .rect(
                    cornerRadius: ComposerPanelMetrics.concentricRadius(
                        outer: boxCornerRadius,
                        inset: rowInset
                    ),
                    style: .continuous
                )
            )
            .contentShape(.rect)
    }

    private var washColor: AnyShapeStyle {
        colors.background.map(AnyShapeStyle.init) ?? AnyShapeStyle(.regularMaterial)
    }
}
