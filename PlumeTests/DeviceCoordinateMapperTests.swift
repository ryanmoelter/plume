import CoreGraphics
import Testing
@testable import Plume

struct DeviceCoordinateMapperTests {
    private let device = CGSize(width: 1080, height: 2400)

    @Test func wideViewLetterboxesHorizontally() {
        let rect = DeviceCoordinateMapper.fittedRect(
            imageSize: CGSize(width: 100, height: 200), in: CGSize(width: 400, height: 200))
        #expect(rect == CGRect(x: 150, y: 0, width: 100, height: 200))
    }

    @Test func tallViewLetterboxesVertically() {
        let rect = DeviceCoordinateMapper.fittedRect(
            imageSize: CGSize(width: 100, height: 200), in: CGSize(width: 100, height: 400))
        #expect(rect == CGRect(x: 0, y: 100, width: 100, height: 200))
    }

    @Test func pointInLetterboxIsNilUnlessClamped() {
        let view = CGSize(width: 400, height: 200)
        let image = CGSize(width: 100, height: 200)
        let outside = CGPoint(x: 10, y: 100)
        #expect(DeviceCoordinateMapper.devicePoint(
            for: outside, viewSize: view, imageSize: image, deviceSize: device,
            rotation: .portrait, clampOutside: false) == nil)
        let clamped = DeviceCoordinateMapper.devicePoint(
            for: outside, viewSize: view, imageSize: image, deviceSize: device,
            rotation: .portrait, clampOutside: true)
        #expect(clamped == CGPoint(x: 0, y: 1200))
    }

    @Test func clampedPointBeyondFarCornerLandsOnLastPixel() {
        let p = DeviceCoordinateMapper.devicePoint(
            for: CGPoint(x: 9999, y: 9999), viewSize: CGSize(width: 100, height: 200),
            imageSize: CGSize(width: 100, height: 200), deviceSize: device,
            rotation: .portrait, clampOutside: true)
        #expect(p == CGPoint(x: 1079, y: 2399))
    }

    @Test func scaledImageMapsToDevicePixels() {
        let p = DeviceCoordinateMapper.devicePoint(
            for: CGPoint(x: 22.5, y: 50), viewSize: CGSize(width: 90, height: 200),
            imageSize: CGSize(width: 540, height: 1200), deviceSize: device,
            rotation: .portrait, clampOutside: false)
        #expect(p == CGPoint(x: 270, y: 600))
    }

    @Test(arguments: [
        // (rotation, u, v, expected natural fraction x, y)
        (DeviceRotation.portrait, 0.0, 0.0, 0.0, 0.0),
        (.portrait, 1.0, 1.0, 1.0, 1.0),
        (.portrait, 0.5, 0.5, 0.5, 0.5),
        (.landscape, 0.0, 0.0, 1.0, 0.0),
        (.landscape, 1.0, 0.0, 1.0, 1.0),
        (.landscape, 0.0, 1.0, 0.0, 0.0),
        (.landscape, 0.5, 0.5, 0.5, 0.5),
        (.reverseLandscape, 0.0, 0.0, 0.0, 1.0),
        (.reverseLandscape, 1.0, 0.0, 0.0, 0.0),
        (.reverseLandscape, 0.0, 1.0, 1.0, 1.0),
        (.reverseLandscape, 0.5, 0.5, 0.5, 0.5),
        (.reversePortrait, 0.0, 0.0, 1.0, 1.0),
        (.reversePortrait, 1.0, 1.0, 0.0, 0.0),
        (.reversePortrait, 0.5, 0.5, 0.5, 0.5),
    ])
    func rotationMapsImageCornersAndCentre(
        rotation: DeviceRotation, u: Double, v: Double, nx: Double, ny: Double
    ) throws {
        let isLandscape = rotation == .landscape || rotation == .reverseLandscape
        let image = isLandscape ? CGSize(width: 2400, height: 1080) : CGSize(width: 1080, height: 2400)
        let view = CGSize(width: image.width / 10, height: image.height / 10)
        let point = CGPoint(x: u * view.width, y: v * view.height)
        let result = try #require(DeviceCoordinateMapper.devicePoint(
            for: point, viewSize: view, imageSize: image, deviceSize: device,
            rotation: rotation, clampOutside: false))
        let expected = CGPoint(
            x: min((nx * device.width).rounded(), device.width - 1),
            y: min((ny * device.height).rounded(), device.height - 1))
        #expect(result == expected)
    }

    @Test func zeroSizesReturnNil() {
        let ok = CGSize(width: 100, height: 200)
        for (view, image, dev) in [
            (CGSize.zero, ok, ok), (ok, CGSize.zero, ok), (ok, ok, CGSize.zero),
        ] {
            #expect(DeviceCoordinateMapper.devicePoint(
                for: CGPoint(x: 10, y: 10), viewSize: view, imageSize: image, deviceSize: dev,
                rotation: .portrait, clampOutside: true) == nil)
        }
        #expect(DeviceCoordinateMapper.fittedRect(imageSize: .zero, in: ok) == .zero)
    }
}
