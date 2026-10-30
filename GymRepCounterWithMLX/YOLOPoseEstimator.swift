// YOLOPoseEstimator.swift
// Body-pose keypoint estimator backed by the YOLO26n-pose Core ML model, replacing Apple's
// VNDetectHumanBodyPoseRequest. The model is an end-to-end (NMS-free) pose head: for a 640×640
// RGB input it emits [1, 300, 57] — up to 300 person candidates, each
//   [x1, y1, x2, y2, score, class, (kx, ky, visibility) × 17]
// in 640-pixel coordinates. The 17 keypoints are in the SAME order and with the SAME names as the
// Apple joints the rest of the app already uses (see PoseFeatures.joints), so no remapping is needed.
//
// We run inference through Vision's VNCoreMLRequest purely for its image handling: it applies the
// requested CGImagePropertyOrientation (so coordinates come out upright) and scaleFill-resizes the
// frame to the model's 640×640 input. Because scaleFill stretches the whole image per-axis,
// dividing a keypoint by 640 yields its normalized position in the upright image — exactly the
// top-left-origin, y-down [0,1] convention PoseFrame/PoseFeatures expect (Vision used 1 - y; YOLO is
// already y-down, so no flip).
//
// The model is loaded with computeUnits = .cpuAndNeuralEngine so inference runs on the Neural Engine.

import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Vision

nonisolated final class YOLOPoseEstimator {

    static let inputSize = 640.0       // model input is 640×640; keypoints are in this pixel space
    static let scoreThreshold = 0.25   // minimum person detection score to consider
    static let keypointConfidence = 0.2 // minimum per-keypoint visibility to keep a joint

    /// Keypoint names in the model's output order — identical to Apple's joint set/order.
    private static let names = PoseFeatures.joints.map(\.name)

    private let vnModel: VNCoreMLModel?

    init() {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU   // run on the CPU
        if let url = Bundle.main.url(forResource: "yolo26n-pose", withExtension: "mlmodelc"),
           let model = try? MLModel(contentsOf: url, configuration: config),
           let vn = try? VNCoreMLModel(for: model) {
            vnModel = vn
        } else {
            vnModel = nil
        }
    }

    /// Normalised joint locations (top-left origin, y down, [0,1]) for the most prominent person in
    /// the frame, or an empty dictionary if the model is unavailable or no person is found. `pixelBuffer`
    /// is handed to the model with `orientation` so the returned coordinates are in upright space.
    func joints(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> [String: CGPoint] {
        guard let vnModel else { return [:] }
        let request = VNCoreMLRequest(model: vnModel)
        request.imageCropAndScaleOption = .scaleFill   // stretch whole frame → normalized coords stay valid
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation).perform([request])
        } catch {
            return [:]
        }
        guard let observation = request.results?.first as? VNCoreMLFeatureValueObservation,
              let array = observation.featureValue.multiArrayValue else { return [:] }
        return Self.decode(array)
    }

    /// Picks the highest-area person above the score threshold and returns its visible keypoints,
    /// normalised by the model's input size.
    private static func decode(_ array: MLMultiArray) -> [String: CGPoint] {
        // Expect [1, N, C] with C ≥ 6 + 17*3 and float32 storage.
        guard array.shape.count == 3,
              array.dataType == .float32,
              array.shape[2].intValue >= 6 + names.count * 3 else { return [:] }
        let n = array.shape[1].intValue
        let rowStride = array.strides[1].intValue
        let colStride = array.strides[2].intValue
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        func value(_ row: Int, _ col: Int) -> Float { ptr[row * rowStride + col * colStride] }

        // Choose the largest bounding box among confident person detections (≈ closest person).
        var bestRow = -1
        var bestArea: Float = 0
        for row in 0..<n {
            guard value(row, 4) >= Float(scoreThreshold) else { continue }
            let w = value(row, 2) - value(row, 0)
            let h = value(row, 3) - value(row, 1)
            let area = max(0, w) * max(0, h)
            if area > bestArea { bestArea = area; bestRow = row }
        }
        guard bestRow >= 0 else { return [:] }

        var result: [String: CGPoint] = [:]
        for (i, name) in names.enumerated() {
            let base = 6 + i * 3
            let visibility = value(bestRow, base + 2)
            guard visibility >= Float(keypointConfidence) else { continue }
            let x = Double(value(bestRow, base)) / inputSize
            let y = Double(value(bestRow, base + 1)) / inputSize
            result[name] = CGPoint(x: x, y: y)
        }
        return result
    }
}
