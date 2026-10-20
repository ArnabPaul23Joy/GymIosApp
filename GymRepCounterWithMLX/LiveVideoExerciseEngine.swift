// LiveVideoExerciseEngine.swift
// "Live from gallery" source for the shared PoseStreamProcessor. Instead of analysing a whole
// video at once, it decodes a gallery video frame-by-frame with AVAssetReader, PACED TO REAL
// TIME, and runs each frame through the exact same streaming pipeline the live camera uses —
// so the exercise type and rep count evolve live as the clip plays.

import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import QuartzCore

/// A processed frame for the gallery-live UI: the decoded image plus the pipeline snapshot.
struct LiveVideoUpdate: @unchecked Sendable {
    var frame: CGImage?
    var update: LiveUpdate
}

nonisolated final class LiveVideoExerciseEngine: @unchecked Sendable {

    private let processor = PoseStreamProcessor()
    private let queue = DispatchQueue(label: "gallery.live", qos: .userInitiated)
    private let ciContext = CIContext()
    private var cancelled = false

    var onUpdate: (@Sendable (LiveVideoUpdate) -> Void)?
    var onFinished: (@Sendable () -> Void)?

    /// Begins streaming the video from the start (fresh pipeline).
    func start(url: URL) {
        cancelled = false
        queue.async { [weak self] in self?.run(url: url) }
    }

    func stop() { cancelled = true }

    // MARK: - Streaming loop (runs on `queue`)

    private func run(url: URL) {
        processor.reset()

        let asset = AVURLAsset(url: url)

        // Bridge the async track loading onto this serial queue via a Sendable box.
        final class LoadBox: @unchecked Sendable {
            var track: AVAssetTrack?
            var transform = CGAffineTransform.identity
        }
        let box = LoadBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            let track = try? await asset.loadTracks(withMediaType: .video).first
            box.track = track
            if let track { box.transform = (try? await track.load(.preferredTransform)) ?? .identity }
            semaphore.signal()
        }
        semaphore.wait()

        guard let track = box.track,
              let reader = try? AVAssetReader(asset: asset) else { onFinished?(); return }
        let transform = box.transform

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { onFinished?(); return }

        let orientation = cgOrientation(from: transform)
        var startWall: Double?
        var firstPTS: Double?
        var reading = true

        // Each iteration is wrapped in an autorelease pool: this is a tight decode loop that never
        // returns to a run loop, so without draining, every CMSampleBuffer / CIImage / CGImage /
        // Vision temporary would accumulate until iOS jetsam-kills the app for memory.
        while !cancelled && reading {
            autoreleasepool {
                guard let sample = output.copyNextSampleBuffer() else { reading = false; return }
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
                let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))

                // Orient the frame upright for both display and Vision (same orientation → aligned).
                let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
                let orientedSize = ciImage.extent.size

                let update = processor.process(pixelBuffer: pixelBuffer, orientation: orientation,
                                               timestamp: pts, orientedSize: orientedSize)
                let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent)

                // Pace to the clip's real timeline (processing time counts against the budget).
                let now = CACurrentMediaTime()
                if startWall == nil { startWall = now; firstPTS = pts }
                let target = (startWall ?? now) + (pts - (firstPTS ?? pts))
                let delay = target - CACurrentMediaTime()
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                if cancelled { return }

                onUpdate?(LiveVideoUpdate(frame: cgImage, update: update))
            }
        }

        if !cancelled { onFinished?() }
    }

    /// Maps a track's preferred transform to the orientation that makes coordinates upright.
    private func cgOrientation(from t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (t.a, t.b, t.c, t.d) {
        case (0, 1, -1, 0):   return .right
        case (0, -1, 1, 0):   return .left
        case (-1, 0, 0, -1):  return .down
        default:              return .up
        }
    }
}
