// LiveExerciseEngine.swift
// Live-camera source for the shared PoseStreamProcessor (defined below in this file). Owns the
// AVCaptureSession and feeds each camera frame (in native landscape) to the processor with the
// correct Vision orientation so coordinates come out upright.
//
// PoseStreamProcessor is the shared per-frame streaming pipeline used by BOTH the live camera
// and the "live from gallery" modes:
//   Vision body-pose → keypoint EMA smoothing → PoseFeatures (26) → WindowResampler →
//   Core ML classification (stride + confidence + vote gating) → geometric StreamingRepCounter.
//
// TRAIN/INFERENCE MISMATCH COMPENSATION (model trained on video files, not a live stream):
//   1. WindowResampler puts the stream onto the model's exact 15 Hz / 2 s (30-step) grid with
//      validity masks — identical temporal footing to training, independent of frame rate.
//   2. Per-keypoint EMA smoothing tames live jitter toward the cleaner decoded-video profile.
//   3. PoseFeatures is hip-centred + torso-scaled (distance-invariant) and reflection-invariant.
//   4. Confidence + coverage + majority-vote gating reject noisy/unsure/flickering predictions.
//   5. Warm-up ("Calibrating…") until a full 2 s window exists.

import AVFoundation
import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import ImageIO
import Vision

/// A snapshot pushed to the UI on every processed frame.
struct LiveUpdate: Sendable {
    var pose: PoseFrame?
    var orientedSize: CGSize      // upright image size the joints are normalised against
    var rawLabel: String?
    var displayLabel: String
    var confidence: Double
    var reps: Int
    var calibrating: Bool
    var repTotals: [String: Int]        // cumulative raw reps per exercise this session
    var repDurations: [String: Double]  // cumulative active seconds per exercise (for the report)
}

nonisolated final class LiveExerciseEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "live.session")
    private let sampleQueue = DispatchQueue(label: "live.samples")
    private let output = AVCaptureVideoDataOutput()
    private let processor = PoseStreamProcessor()

    /// Delivered on the main actor by the view model (see LiveWorkoutViewModel).
    var onUpdate: (@Sendable (LiveUpdate) -> Void)?

    private var position: AVCaptureDevice.Position = .back

    // MARK: - Session setup

    func configure(position: AVCaptureDevice.Position) {
        sessionQueue.async { [self] in
            self.position = position
            session.beginConfiguration()
            session.sessionPreset = .high

            session.inputs.forEach { session.removeInput($0) }
            if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
            }

            if !session.outputs.contains(output) {
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: sampleQueue)
                if session.canAddOutput(output) { session.addOutput(output) }
            }

            // NB: we deliberately do NOT rotate/mirror the connection. Buffers stay in the
            // camera's native landscape orientation; instead we hand Vision the correct
            // CGImagePropertyOrientation per frame so its coordinates come out upright.
            session.commitConfiguration()

            // Fresh pipeline for this camera/framing (on the pipeline's own queue).
            sampleQueue.async { self.processor.reset() }
        }
    }

    func start() { sessionQueue.async { [self] in if !session.isRunning { session.startRunning() } } }
    func stop()  { sessionQueue.async { [self] in if session.isRunning { session.stopRunning() } } }

    func resetCounter() { sampleQueue.async { [self] in processor.resetCounter() } }

    // MARK: - Per-frame (runs on sampleQueue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

        // Native landscape buffer → upright via Vision orientation. .right for back; .leftMirrored
        // for front (matches its auto-mirrored preview). A 90° orientation swaps width/height.
        let orientation: CGImagePropertyOrientation = (position == .front) ? .leftMirrored : .right
        let orientedSize = CGSize(width: Double(CVPixelBufferGetHeight(pixelBuffer)),
                                  height: Double(CVPixelBufferGetWidth(pixelBuffer)))

        let update = processor.process(pixelBuffer: pixelBuffer, orientation: orientation,
                                       timestamp: timestamp, orientedSize: orientedSize)
        onUpdate?(update)
    }
}

// MARK: - Shared streaming pipeline

nonisolated final class PoseStreamProcessor {

    // Tunables
    private let predictionStride = 0.25       // seconds between classifier predictions
    private let minCoverage = 0.35            // skip only very low-visibility windows
    private let keypointAlpha = 0.5           // EMA weight for keypoint smoothing
    private let minKeypointConfidence: Float = 0.1

    private let classifier: PoseExerciseClassifier?
    private var resampler: WindowResampler?
    private let smoother = LabelSmoother(size: 12)
    private let counter = StreamingRepCounter()
    private var emaJoints: [String: CGPoint] = [:]
    private var nextPrediction = 0.0
    private var firstTimestamp: Double?
    private var currentRawLabel: String?
    private var currentConfidence = 0.0
    private var exerciseTotals: [String: Int] = [:]      // committed reps from finished segments
    private var exerciseDurations: [String: Double] = [:] // cumulative active seconds per exercise
    private var previousTimestamp: Double?                 // for per-frame duration deltas

    init() {
        if let url = Bundle.main.url(forResource: "ExerciseClassifier", withExtension: "mlmodelc") {
            classifier = try? PoseExerciseClassifier(modelURL: url)
        } else {
            classifier = nil
        }
        resampler = classifier?.makeResampler()
    }

    /// Full reset (new session/video): clears history, votes, and the counter.
    func reset() {
        resampler = classifier?.makeResampler()
        emaJoints = [:]
        nextPrediction = 0
        firstTimestamp = nil
        currentRawLabel = nil
        currentConfidence = 0
        exerciseTotals = [:]
        exerciseDurations = [:]
        previousTimestamp = nil
        counter.reset()
    }

    /// Cumulative raw reps per exercise: committed finished segments plus the in-progress one.
    private func repTotals() -> [String: Int] {
        var totals = exerciseTotals
        if let current = currentRawLabel { totals[current, default: 0] += counter.reps }
        return totals
    }

    /// Reset just the rep tally (keeps the current label/history).
    func resetCounter() {
        counter.reset()
    }

    /// Process one frame and return the UI snapshot.
    func process(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                 timestamp: Double, orientedSize: CGSize) -> LiveUpdate {
        let width = Double(orientedSize.width), height = Double(orientedSize.height)

        let request = VNDetectHumanBodyPoseRequest()
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation).perform([request])
        let observation = PoseFeatures.closestObservation(request.results)

        // (1) raw keypoints → (2) EMA smoothing.
        let raw = normalisedJoints(from: observation)
        let smoothedJoints = smoothKeypoints(raw)
        let pose = PoseFrame(time: timestamp, joints: smoothedJoints)

        // 26 features from the smoothed joints (pixel space).
        var pixelJoints: [String: SIMD2<Double>] = [:]
        for (name, point) in smoothedJoints {
            pixelJoints[name] = SIMD2(Double(point.x) * width, Double(point.y) * height)
        }
        let features = PoseFeatures.features(fromPixelJoints: pixelJoints,
                                             imageWidth: width, imageHeight: height, timestamp: timestamp)

        var calibrating = true
        if let resampler {
            resampler.push(features)
            if firstTimestamp == nil {
                firstTimestamp = timestamp
                nextPrediction = timestamp + resampler.windowSeconds
            }
            calibrating = !resampler.isReady()

            if timestamp >= nextPrediction, resampler.isReady(), let classifier {
                nextPrediction += predictionStride
                if let window = resampler.window(), window.coverage >= minCoverage,
                   let prediction = try? classifier.predict(window) {
                    // Commit the best-guess label every stride (like the batch path's majority vote);
                    // the LabelSmoother stabilises it. Below 30% confidence we treat it as "walking"
                    // — except squat-shoulder-press, which is kept even when unsure.
                    let label = (prediction.confidence < 0.30 && prediction.label != "squatpress")
                        ? "walking" : prediction.label
                    let stable = smoother.push(label)
                    currentConfidence = prediction.confidence
                    if stable != currentRawLabel {
                        // Commit the finished segment's reps before the counter resets for the new exercise.
                        if let previous = currentRawLabel { exerciseTotals[previous, default: 0] += counter.reps }
                        currentRawLabel = stable
                    }
                    counter.setExercise(stable)
                }
            }
        }

        // Geometric rep counting every frame once we know the exercise (no-op for standing/walking).
        if currentRawLabel != nil {
            counter.update(pose: pose, orientedSize: orientedSize)
        }

        // Accrue this frame's elapsed time to the current exercise (label change = clock start/stop).
        if let previous = previousTimestamp, let current = currentRawLabel {
            let dt = timestamp - previous
            if dt > 0, dt < 1.0 { exerciseDurations[current, default: 0] += dt }  // ignore seeks/gaps
        }
        previousTimestamp = timestamp

        return LiveUpdate(
            pose: pose,
            orientedSize: orientedSize,
            rawLabel: currentRawLabel,
            displayLabel: currentRawLabel.map { ExerciseTypeAnalyzer.displayName(for: $0) } ?? "",
            confidence: currentConfidence,
            reps: counter.reps + GeometricRepCounter.displayOffset(for: currentRawLabel),
            calibrating: calibrating,
            repTotals: repTotals(),
            repDurations: exerciseDurations
        )
    }

    // MARK: - Helpers

    /// Normalised joint locations in upright space, top-left origin (y down).
    private func normalisedJoints(from observation: VNHumanBodyPoseObservation?) -> [String: CGPoint] {
        guard let observation, let points = try? observation.recognizedPoints(.all) else { return [:] }
        var result: [String: CGPoint] = [:]
        for joint in PoseFeatures.joints {
            guard let point = points[joint.vision], point.confidence > minKeypointConfidence else { continue }
            result[joint.name] = CGPoint(x: point.location.x, y: 1 - point.location.y)
        }
        return result
    }

    /// Per-joint EMA; joints missing this frame are dropped (so the resampler masks them,
    /// matching training) but their last value is retained for reuse.
    private func smoothKeypoints(_ current: [String: CGPoint]) -> [String: CGPoint] {
        var out: [String: CGPoint] = [:]
        for (name, point) in current {
            if let prev = emaJoints[name] {
                let blended = CGPoint(x: prev.x * (1 - keypointAlpha) + point.x * keypointAlpha,
                                      y: prev.y * (1 - keypointAlpha) + point.y * keypointAlpha)
                out[name] = blended
                emaJoints[name] = blended
            } else {
                out[name] = point
                emaJoints[name] = point
            }
        }
        return out
    }
}
