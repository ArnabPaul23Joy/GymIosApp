// FeatureCollection.swift
// "Collect Data" support: persistently stores the Bi-LSTM's model-input windows extracted from a
// gallery video (Apple body-pose → PoseFeatures → resampled windows), and a decode engine that
// produces them. The Bi-LSTM itself is never run here — this only gathers the inputs the four
// compute-unit benchmark buttons later run inference over.

import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import QuartzCore

// MARK: - Persistent store

/// One model-ready window, stored compactly as Float (mirrors ResampledWindow's Double arrays).
struct StoredWindow: Codable {
    let values: [[Float]]
    let mask: [[Float]]
}

struct CollectedDataset: Codable {
    var windows: [StoredWindow]
    var createdAt: Date
}

/// On-disk dataset of collected windows. Lives in Application Support, so it survives app launches.
/// A new collection OVERWRITES the previous dataset.
enum FeatureCollectionStore {

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("collected_features.json")
    }

    /// Overwrite any existing dataset with these windows.
    static func save(_ windows: [ResampledWindow]) {
        let stored = windows.map { w in
            StoredWindow(values: w.values.map { $0.map(Float.init) },
                         mask: w.mask.map { $0.map(Float.init) })
        }
        let dataset = CollectedDataset(windows: stored, createdAt: Date())
        if let data = try? JSONEncoder().encode(dataset) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Load the stored windows back as model-ready ResampledWindows (empty if none saved).
    static func load() -> [ResampledWindow] {
        guard let data = try? Data(contentsOf: fileURL),
              let dataset = try? JSONDecoder().decode(CollectedDataset.self, from: data) else { return [] }
        return dataset.windows.map { s in
            ResampledWindow(values: s.values.map { $0.map(Double.init) },
                            mask: s.mask.map { $0.map(Double.init) })
        }
    }

    /// Number of stored windows (0 if none).
    static var count: Int {
        guard let data = try? Data(contentsOf: fileURL),
              let dataset = try? JSONDecoder().decode(CollectedDataset.self, from: data) else { return 0 }
        return dataset.windows.count
    }

    static func clear() { try? FileManager.default.removeItem(at: fileURL) }
}

// MARK: - Collection engine

/// A processed frame for the collection UI: decoded image + pose (for overlay) + an optional
/// just-captured model window.
struct CollectDataUpdate: @unchecked Sendable {
    var frame: CGImage?
    var pose: PoseFrame?
    var orientedSize: CGSize
    var window: ResampledWindow?
}

/// Decodes a gallery video frame-by-frame (paced to real time, like the live-gallery engine), runs
/// the pose + feature pipeline, and emits each captured model-input window. Never runs the Bi-LSTM.
nonisolated final class FeatureCollectionEngine: @unchecked Sendable {

    private let processor = PoseStreamProcessor()
    private let queue = DispatchQueue(label: "collect.features", qos: .userInitiated)
    private let ciContext = CIContext()
    private var cancelled = false

    var onUpdate: (@Sendable (CollectDataUpdate) -> Void)?
    var onFinished: (@Sendable () -> Void)?

    func start(url: URL) {
        cancelled = false
        queue.async { [weak self] in self?.run(url: url) }
    }

    func stop() { cancelled = true }

    private func run(url: URL) {
        processor.reset()

        let asset = AVURLAsset(url: url)

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

        while !cancelled && reading {
            autoreleasepool {
                guard let sample = output.copyNextSampleBuffer() else { reading = false; return }
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
                let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))

                let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
                let orientedSize = ciImage.extent.size

                let sampleResult = processor.collect(pixelBuffer: pixelBuffer, orientation: orientation,
                                                      timestamp: pts, orientedSize: orientedSize)
                let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent)

                // Pace to the clip's real timeline.
                let now = CACurrentMediaTime()
                if startWall == nil { startWall = now; firstPTS = pts }
                let target = (startWall ?? now) + (pts - (firstPTS ?? pts))
                let delay = target - CACurrentMediaTime()
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                if cancelled { return }

                onUpdate?(CollectDataUpdate(frame: cgImage, pose: sampleResult.pose,
                                            orientedSize: orientedSize, window: sampleResult.window))
            }
        }

        if !cancelled { onFinished?() }
    }

    private func cgOrientation(from t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (t.a, t.b, t.c, t.d) {
        case (0, 1, -1, 0):   return .right
        case (0, -1, 1, 0):   return .left
        case (-1, 0, 0, -1):  return .down
        default:              return .up
        }
    }
}
