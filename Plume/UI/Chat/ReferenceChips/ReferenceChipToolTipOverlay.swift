import SwiftUI

extension View {
    /// Gives each reference chip in this `Text`, built by `styled.text()`, a
    /// tooltip with what its title leaves out.
    @ViewBuilder
    func referenceChipToolTips(_ styled: StyledInline) -> some View {
        if styled.referenceURLs.isEmpty {
            self
        } else {
            modifier(ReferenceChipToolTipOverlay(pad: styled.pad))
        }
    }
}

/// A tooltip region over each chip's rect on each line it spans.
///
/// The regions take the click from the link beneath, so a click opens the
/// link through `openURL` exactly as the `Text` would.
private struct ReferenceChipToolTipOverlay: ViewModifier {
    let pad: CGFloat
    @Environment(\.chatLinkDirectory) private var linkDirectory
    @Environment(\.openURL) private var openURL

    private struct Region: Identifiable {
        let id: Int
        let rect: CGRect
        let url: URL
    }

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(Text.LayoutKey.self) { layouts in
            GeometryReader { proxy in
                if let anchored = layouts.first {
                    let origin = proxy[anchored.origin]
                    ForEach(regions(in: anchored.layout)) { region in
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: region.rect.width, height: region.rect.height)
                            .help(toolTip(for: region.url))
                            .onTapGesture { openURL(region.url) }
                            .offset(x: origin.x + region.rect.minX, y: origin.y + region.rect.minY)
                    }
                }
            }
        }
    }

    private func regions(in layout: Text.Layout) -> [Region] {
        InlineChips(pad: pad, fill: .clear, references: nil).placements(in: layout).enumerated().compactMap { index, placement in
            guard case .reference(_, let url) = placement.chip else { return nil }
            return Region(id: index, rect: placement.rect, url: url)
        }
    }

    private func toolTip(for url: URL) -> String {
        guard let target = ReferenceTarget.classify(url, base: linkDirectory) else { return url.absoluteString }
        let store = ReferenceChipStore.shared
        return ReferenceChipTooltip.text(
            for: target,
            detail: store.detail(for: target),
            title: store.title(for: target),
            directory: linkDirectory?.path
        )
    }
}
