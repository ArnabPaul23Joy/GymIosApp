// ExerciseTypeAnalyzer.swift
// One pass over a video that (1) recognises the exercise type with the on-device
// Bi-LSTM Core ML model and (2) collects per-frame body-pose keypoints used for the
// skeleton overlay and the geometric rep counter.
//
// Per frame: AVAssetReader → VNDetectHumanBodyPoseRequest → { PoseFeatures for the
// classifier, raw normalised joints for PoseFrame }. Classification aggregates window
// predictions by majority vote.

import AVFoundation
import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Vision

/// One frame of tracked body-pose keypoints.
/// `joints` are normalised to [0, 1] in the *upright/displayed* image space with a
/// top-left origin (y grows downward) — ready to map onto an AVPlayerLayer's videoRect.
struct PoseFrame: Sendable {
    let time: Double
    let joints: [String: CGPoint]
}

nonisolated enum ExerciseTypeAnalyzer {

    struct Result: Sendable {
        let label: String        // display name, e.g. "Squat"
        let rawLabel: String     // model class, e.g. "squat"
        let confidence: Double   // mean probability of the winning class, 0…1
    }

    /// Everything a single analysis pass produces.
    struct Analysis: Sendable {
        let type: Result?            // nil if no pose was seen clearly enough to classify
        let poses: [PoseFrame]       // per-frame keypoints for overlay + rep counting
        let orientedSize: CGSize     // displayed (upright) pixel size of the video
    }

    enum AnalyzerError: LocalizedError {
        case modelNotFound
        case noVideoTrack
        case noPoseDetected

        var errorDescription: String? {
            switch self {
            case .modelNotFound:
                return "ExerciseClassifier.mlmodelc not found in the app bundle. Confirm ExerciseClassifier.mlpackage is added to the app target."
            case .noVideoTrack:
                return "The selected file has no video track."
            case .noPoseDetected:
                return "Couldn't see a person clearly enough to identify the exercise."
            }
        }
    }

    private static let displayNames: [String: String] = [
        "pullup": "Pull-up",
        "pushup": "Push-up",
        "squat": "Squat",
        "legraise": "Toes-to-Bar",
        "skipping": "Double-unders",
        "squatpress": "Dumbbell Thrusters",
        "standing": "Standing",
        "walking": "Walking",
    ]

    static func displayName(for rawLabel: String) -> String {
        displayNames[rawLabel] ?? rawLabel.capitalized
    }

    /// - Parameters:
    ///   - stride: seconds between classifier predictions once the buffer is full.
    ///   - minCoverage: skip windows whose fraction of valid (unmasked) features is below this.
    static func analyze(url: URL, stride: Double = 0.25, minCoverage: Double = 0.5) async throws -> Analysis {
        guard let modelURL = Bundle.main.url(forResource: "ExerciseClassifier", withExtension: "mlmodelc") else {
            throw AnalyzerError.modelNotFound
        }
        let classifier = try PoseExerciseClassifier(modelURL: modelURL)
        let resampler = classifier.makeResampler()
        let poseEstimator = YOLOPoseEstimator()

        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AnalyzerError.noVideoTrack
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let orientation = cgOrientation(from: transform)
        let rotated = (orientation == .left || orientation == .right)
        let orientedSize = rotated ? CGSize(width: naturalSize.height, height: naturalSize.width) : naturalSize

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AnalyzerError.noPoseDetected }

        var poses: [PoseFrame] = []
        var votes: [String: Int] = [:]
        var probabilitySum = Array(repeating: 0.0, count: classifier.classes.count)
        var predictions = 0
        var nextPrediction = 0.0
        var firstTimestamp: Double?

        // Each iteration is wrapped in an autorelease pool — this is a tight decode loop that never
        // returns to a run loop, so otherwise every CMSampleBuffer / Vision temporary would
        // accumulate until iOS jetsam-kills the app for memory.
        var reading = true
        while reading {
            try autoreleasepool {
                guard let sample = output.copyNextSampleBuffer(),
                      let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { reading = false; return }
                let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                if firstTimestamp == nil {
                    firstTimestamp = timestamp
                    nextPrediction = timestamp + classifier.windowSeconds
                }

                // YOLO26 pose (Neural Engine), using the track's display orientation so keypoints are upright.
                let width = Double(orientedSize.width), height = Double(orientedSize.height)
                let joints = poseEstimator.joints(pixelBuffer: pixelBuffer, orientation: orientation)
                if !joints.isEmpty { poses.append(PoseFrame(time: timestamp, joints: joints)) }

                // Feed the classifier's feature pipeline (26 features, oriented pixel space).
                var pixelJoints: [String: SIMD2<Double>] = [:]
                for (name, point) in joints {
                    pixelJoints[name] = SIMD2(Double(point.x) * width, Double(point.y) * height)
                }
                let features = PoseFeatures.features(fromPixelJoints: pixelJoints,
                                                     imageWidth: width, imageHeight: height, timestamp: timestamp)
                resampler.push(features)

                if timestamp >= nextPrediction, resampler.isReady() {
                    nextPrediction += stride
                    if let window = resampler.window(), window.coverage >= minCoverage {
                        let prediction = try classifier.predict(window)
                        predictions += 1
                        votes[prediction.label, default: 0] += 1
                        for (i, p) in prediction.probabilities.enumerated() { probabilitySum[i] += p }
                    }
                }
            }
        }

        var type: Result?
        if predictions > 0, let winner = votes.max(by: { $0.value < $1.value })?.key {
            let index = classifier.classes.firstIndex(of: winner) ?? 0
            type = Result(label: displayName(for: winner), rawLabel: winner,
                          confidence: probabilitySum[index] / Double(predictions))
        }

        return Analysis(type: type, poses: poses, orientedSize: orientedSize)
    }

    // MARK: - Helpers

    /// Maps a track's preferred transform to the CGImagePropertyOrientation Vision needs
    /// so keypoints come out in the same upright space the player displays.
    private static func cgOrientation(from t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (t.a, t.b, t.c, t.d) {
        case (0, 1, -1, 0):   return .right   // portrait
        case (0, -1, 1, 0):   return .left    // portrait upside-down
        case (-1, 0, 0, -1):  return .down    // landscape (home button left)
        default:              return .up       // identity / landscape
        }
    }
}
