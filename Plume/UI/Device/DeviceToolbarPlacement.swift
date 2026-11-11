import CoreGraphics

/// Where a device tab puts its toolbar: the side that leaves the fitted device frame the most area.
nonisolated enum DeviceToolbarPlacement: Equatable {
    case top
    case leading

    static let topThickness: CGFloat = 36
    static let leadingThickness: CGFloat = 40

    /// `deviceAspect` is the displayed frame's width over height, rotation applied. Nil or non-positive
    /// means unknown, which keeps the toolbar on top. A tie also stays on top.
    static func choose(tabSize: CGSize, deviceAspect: CGFloat?) -> DeviceToolbarPlacement {
        guard let aspect = deviceAspect, aspect > 0, tabSize.width > 0, tabSize.height > 0 else { return .top }
        let top = fittedArea(aspect: aspect, in: CGSize(width: tabSize.width, height: tabSize.height - topThickness))
        let leading = fittedArea(aspect: aspect, in: CGSize(width: tabSize.width - leadingThickness, height: tabSize.height))
        return leading > top ? .leading : .top
    }

    static func aspect(of size: CGSize?, rotation: DeviceRotation) -> CGFloat? {
        guard let size, size.width > 0, size.height > 0 else { return nil }
        switch rotation {
        case .portrait, .reversePortrait: return size.width / size.height
        case .landscape, .reverseLandscape: return size.height / size.width
        }
    }

    private static func fittedArea(aspect: CGFloat, in size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 0 }
        let width = min(size.width, size.height * aspect)
        return width * (width / aspect)
    }
}
