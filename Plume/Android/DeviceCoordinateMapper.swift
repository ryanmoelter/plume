import CoreGraphics

nonisolated enum DeviceRotation: Sendable, Equatable, CaseIterable {
    case portrait
    case landscape
    case reversePortrait
    case reverseLandscape
}

nonisolated enum DeviceCoordinateMapper {
    static func fittedRect(imageSize: CGSize, in viewSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return .zero
        }
        let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (viewSize.width - size.width) / 2,
            y: (viewSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// Touches are always in natural-orientation device pixels, while the frame arrives already rotated.
    static func devicePoint(
        for point: CGPoint,
        viewSize: CGSize,
        imageSize: CGSize,
        deviceSize: CGSize,
        rotation: DeviceRotation,
        clampOutside: Bool
    ) -> CGPoint? {
        let rect = fittedRect(imageSize: imageSize, in: viewSize)
        guard rect.width > 0, rect.height > 0, deviceSize.width > 0, deviceSize.height > 0 else { return nil }
        if !clampOutside {
            let inside = point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
            if !inside { return nil }
        }

        let u = min(max((point.x - rect.minX) / rect.width, 0), 1)
        let v = min(max((point.y - rect.minY) / rect.height, 0), 1)

        let natural: (x: CGFloat, y: CGFloat)
        switch rotation {
        case .portrait: natural = (u, v)
        case .landscape: natural = (1 - v, u)
        case .reverseLandscape: natural = (v, 1 - u)
        case .reversePortrait: natural = (1 - u, 1 - v)
        }

        return CGPoint(
            x: min(max((natural.x * deviceSize.width).rounded(), 0), deviceSize.width - 1),
            y: min(max((natural.y * deviceSize.height).rounded(), 0), deviceSize.height - 1)
        )
    }
}
