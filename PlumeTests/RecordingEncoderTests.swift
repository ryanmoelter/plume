import AVFoundation
import CoreGraphics
import Foundation
import Testing

@testable import Plume

/// The control server's recording: parameter clamping, output sizing, and an
/// encode of synthetic frames read back as a real video file.
struct RecordingEncoderTests {
    @Test func paramsClampToTheLimits() throws {
        let decoded = try JSONDecoder().decode(RecordStartParams.self, from: Data(#"{"fps":500,"maxSeconds":99999}"#.utf8))
        #expect(decoded.fps == 60)
        #expect(decoded.maxSeconds == RecordStartParams.secondsLimit)

        let low = try JSONDecoder().decode(RecordStartParams.self, from: Data(#"{"fps":0,"maxSeconds":-3}"#.utf8))
        #expect(low.fps == 1)
        #expect(low.maxSeconds > 0)

        let defaults = try JSONDecoder().decode(RecordStartParams.self, from: Data("{}".utf8))
        #expect(defaults.fps == 30)
        #expect(defaults.maxSeconds == 30)
    }

    @Test func outputSizeIsEvenAndFitsTheEncoder() {
        #expect(RecordingEncoder.outputSize(width: 1001, height: 601) == (1000, 600))
        let large = RecordingEncoder.outputSize(width: 6000, height: 3000)
        #expect(large.width == 4096)
        #expect(large.height == 2048)
        #expect(RecordingEncoder.outputSize(width: 1, height: 1) == (2, 2))
    }

    @Test func aspectFitCentersOnTheLongerAxis() {
        let rect = RecordingEncoder.aspectFit(CGSize(width: 100, height: 50), in: CGSize(width: 200, height: 200))
        #expect(rect == CGRect(x: 0, y: 50, width: 200, height: 100))
    }

    @Test func fileTypeFollowsTheExtension() {
        #expect(RecordingEncoder.fileType(for: URL(fileURLWithPath: "/x/a.mov")) == .mov)
        #expect(RecordingEncoder.fileType(for: URL(fileURLWithPath: "/x/a.mp4")) == .mp4)
    }

    @Test func encodesFramesIntoAPlayableVideo() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "recording-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = try RecordingEncoder(url: url, width: 64, height: 48, fps: 20)
        var appended = 0
        for index in 0..<5 {
            let image = try #require(Self.solid(gray: Double(index) / 4, width: 64, height: 48))
            if encoder.queue.sync(execute: { encoder.append(image) }) { appended += 1 }
            try await Task.sleep(for: .milliseconds(50))
        }
        let summary = try await encoder.finish()
        #expect(appended == 5)
        #expect(summary.frames == 5)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - summary.duration) < 0.01)
        #expect(duration >= 0.2)

        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 64, height: 48))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var samples = 0
        while let buffer = output.copyNextSampleBuffer() {
            samples += CMSampleBufferGetNumSamples(buffer)
        }
        #expect(samples == 5)
    }

    @Test func finishingWithNoFramesThrows() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "recording-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = try RecordingEncoder(url: url, width: 64, height: 48, fps: 20)
        await #expect(throws: ControlError.self) { try await encoder.finish() }
    }

    private static func solid(gray: Double, width: Int, height: Int) -> CGImage? {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(gray: gray, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage()
    }
}
