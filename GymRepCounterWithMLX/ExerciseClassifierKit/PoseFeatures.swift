// PoseFeatures.swift
// Turns one VNHumanBodyPoseObservation into the 26 features the model was trained on.
// Mirrors build_features.py: hip-centred, torso-scaled joints -> 7 angles + 16 distances,
// plus 3 global features (hip_x, hip_y, torso_rel) that retain absolute position/scale.

import Foundation
import Vision

/// One frame of features. `values[i]` is NaN when the joints behind feature i were not detected.
nonisolated struct FrameFeatures {
    let timestamp: Double
    let values: [Double]
}

nonisolated enum PoseFeatures {
    /// Same joint order and naming as build_features.JOINTS.
    static let joints: [(name: String, vision: VNHumanBodyPoseObservation.JointName)] = [
        ("nose", .nose), ("left_eye", .leftEye), ("right_eye", .rightEye),
        ("left_ear", .leftEar), ("right_ear", .rightEar),
        ("left_shoulder", .leftShoulder), ("right_shoulder", .rightShoulder),
        ("left_elbow", .leftElbow), ("right_elbow", .rightElbow),
        ("left_wrist", .leftWrist), ("right_wrist", .rightWrist),
        ("left_hip", .leftHip), ("right_hip", .rightHip),
        ("left_knee", .leftKnee), ("right_knee", .rightKnee),
        ("left_ankle", .leftAnkle), ("right_ankle", .rightAnkle),
    ]

    static let angles: [(String, String, String)] = [
        ("right_elbow", "right_shoulder", "right_hip"),
        ("left_elbow", "left_shoulder", "left_hip"),
        ("right_knee", "mid_hip", "left_knee"),
        ("right_hip", "right_knee", "right_ankle"),
        ("left_hip", "left_knee", "left_ankle"),
        ("right_wrist", "right_elbow", "right_shoulder"),
        ("left_wrist", "left_elbow", "left_shoulder"),
    ]

    static let distances: [(String, String)] = [
        ("left_shoulder", "left_wrist"), ("right_shoulder", "right_wrist"),
        ("left_hip", "left_ankle"), ("right_hip", "right_ankle"),
        ("left_hip", "left_wrist"), ("right_hip", "right_wrist"),
        ("left_shoulder", "left_ankle"), ("right_shoulder", "right_ankle"),
        ("left_hip", "right_wrist"), ("right_hip", "left_wrist"),
        ("left_elbow", "right_elbow"), ("left_knee", "right_knee"),
        ("left_wrist", "right_wrist"), ("left_ankle", "right_ankle"),
        ("left_hip", "avg_left_wrist_left_ankle"), ("right_hip", "avg_right_wrist_right_ankle"),
    ]

    static let torsoMultiplier = 2.5

    /// Global (non-hip-centred) features appended after the angles/distances: absolute hip
    /// position and relative torso length. These give the model the location/scale cues that
    /// hip-centring + torso-scaling remove — what distinguishes standing/walking/skipping.
    static let globalFeatureNames = ["hip_x", "hip_y", "torso_rel"]

    /// Orientation features (appended after the globals): limb tilts from vertical (degrees) and
    /// signed vertical offsets in the hip-centred/torso-scaled ×100 space. These capture body
    /// orientation the angle/distance features miss (e.g. lying vs standing, arms up vs down).
    static let orientationFeatureNames = ["torso_tilt", "thigh_tilt", "leg_tilt",
                                          "wrists_above_shoulders", "wrists_above_hips", "nose_above_hips"]

    static var featureCount: Int {
        angles.count + distances.count + globalFeatureNames.count + orientationFeatureNames.count
    }

    /// Feature names in model order, for cross-checking against the model metadata.
    static var featureNames: [String] {
        angles.map { "\($0.0)_\($0.1)_\($0.2)" } + distances.map { "\($0.0)_\($0.1)" }
            + globalFeatureNames + orientationFeatureNames
    }

    /// Picks the person CLOSEST to the camera — the observation whose confident keypoints span
    /// the largest bounding box in the frame. Vision can return several skeletons when multiple
    /// people are visible; using the biggest avoids letting a distant bystander drive the features
    /// (which wrecks the global hip position/scale channels).
    static func closestObservation(_ results: [VNHumanBodyPoseObservation]?) -> VNHumanBodyPoseObservation? {
        guard let results, results.count > 1 else { return results?.first }

        func spanSquared(_ observation: VNHumanBodyPoseObservation) -> Double {
            guard let points = try? observation.recognizedPoints(.all) else { return 0 }
            let visible = points.values.filter { $0.confidence > 0.1 }.map { $0.location }
            guard visible.count >= 2 else { return 0 }
            let xs = visible.map { $0.x }, ys = visible.map { $0.y }
            let w = (xs.max()! - xs.min()!), h = (ys.max()! - ys.min()!)
            return Double(w * w + h * h)   // squared diagonal of the keypoint bounding box (normalised)
        }
        return results.max { spanSquared($0) < spanSquared($1) }
    }

    /// Extract pixel-space joints (top-left origin) from an observation.
    static func pixelJoints(from observation: VNHumanBodyPoseObservation,
                            imageWidth: Double, imageHeight: Double) -> [String: SIMD2<Double>] {
        guard let points = try? observation.recognizedPoints(.all) else { return [:] }
        var result: [String: SIMD2<Double>] = [:]
        for joint in joints {
            guard let point = points[joint.vision], point.confidence > 0 else { continue }
            result[joint.name] = SIMD2(Double(point.location.x) * imageWidth,
                                       (1.0 - Double(point.location.y)) * imageHeight)
        }
        return result
    }

    /// Full pipeline for one frame from an observation.
    static func features(from observation: VNHumanBodyPoseObservation?,
                         imageWidth: Double, imageHeight: Double, timestamp: Double) -> FrameFeatures {
        guard let observation else {
            return FrameFeatures(timestamp: timestamp, values: Array(repeating: .nan, count: featureCount))
        }
        let raw = pixelJoints(from: observation, imageWidth: imageWidth, imageHeight: imageHeight)
        return features(fromPixelJoints: raw, imageWidth: imageWidth, imageHeight: imageHeight, timestamp: timestamp)
    }

    /// Shared pipeline used by both the batch (observation) and live (pre-extracted joints) paths:
    /// pixel joints -> hip-centred/torso-scaled angles+distances (23) + global features (3) = 26.
    /// `raw` joints are pixel-space, top-left origin.
    static func features(fromPixelJoints raw: [String: SIMD2<Double>],
                         imageWidth: Double, imageHeight: Double, timestamp: Double) -> FrameFeatures {
        let normalised = normalise(raw)
        var values = compute(normalised)
        values.append(contentsOf: globalFeatures(raw, imageWidth: imageWidth, imageHeight: imageHeight))
        values.append(contentsOf: orientationFeatures(normalised))
        return FrameFeatures(timestamp: timestamp, values: values)
    }

    /// 6 orientation features, computed in the hip-centred, torso-scaled ×100 space (top-left,
    /// y grows downward). Tilts are the segment's angle from the vertical axis in degrees
    /// (unsigned); the `*_above_*` features are signed vertical offsets (positive = higher on
    /// screen). NaN where the joints are missing. NOTE: definitions inferred from the model's
    /// baked mean/std — pending confirmation against build_features.py.
    static func orientationFeatures(_ n: [String: SIMD2<Double>]) -> [Double] {
        func mid(_ a: String, _ b: String) -> SIMD2<Double>? {
            guard let x = n[a], let y = n[b] else { return nil }
            return (x + y) / 2
        }
        // angle of a segment vector from the vertical axis (0° = perfectly vertical)
        func tiltFromVertical(_ v: SIMD2<Double>) -> Double { atan2(abs(v.x), abs(v.y)) * 180 / .pi }
        // average a per-side segment tilt over whichever sides are visible
        func segTilt(_ aL: String, _ bL: String, _ aR: String, _ bR: String) -> Double {
            let l = (n[aL] != nil && n[bL] != nil) ? tiltFromVertical(n[bL]! - n[aL]!) : Double.nan
            let r = (n[aR] != nil && n[bR] != nil) ? tiltFromVertical(n[bR]! - n[aR]!) : Double.nan
            switch (l.isNaN, r.isNaN) {
            case (false, false): return (l + r) / 2
            case (false, true):  return l
            case (true, false):  return r
            default:             return .nan
            }
        }

        let hipMid = mid("left_hip", "right_hip")
        let shoulderMid = mid("left_shoulder", "right_shoulder")
        let wristMid = mid("left_wrist", "right_wrist")

        let torsoTilt: Double = (shoulderMid != nil && hipMid != nil) ? tiltFromVertical(shoulderMid! - hipMid!) : .nan
        let thighTilt = segTilt("left_hip", "left_knee", "right_hip", "right_knee")
        let legTilt = segTilt("left_knee", "left_ankle", "right_knee", "right_ankle")

        // y grows downward, so "a above b" (higher on screen) = b.y − a.y (positive when a is higher).
        let wristsAboveShoulders: Double = (wristMid != nil && shoulderMid != nil) ? shoulderMid!.y - wristMid!.y : .nan
        let wristsAboveHips: Double = (wristMid != nil && hipMid != nil) ? hipMid!.y - wristMid!.y : .nan
        let noseAboveHips: Double = (n["nose"] != nil && hipMid != nil) ? hipMid!.y - n["nose"]!.y : .nan

        return [torsoTilt, thighTilt, legTilt, wristsAboveShoulders, wristsAboveHips, noseAboveHips]
    }

    /// hip_x = midHip.x / width, hip_y = midHip.y / height (top-left, 0..1),
    /// torso_rel = ‖midShoulder − midHip‖ (pixels) / height. NaN where the joints are missing.
    static func globalFeatures(_ raw: [String: SIMD2<Double>], imageWidth: Double, imageHeight: Double) -> [Double] {
        guard let leftHip = raw["left_hip"], let rightHip = raw["right_hip"], imageWidth > 0, imageHeight > 0 else {
            return [.nan, .nan, .nan]
        }
        let hips = (leftHip + rightHip) / 2
        let hipX = hips.x / imageWidth
        let hipY = hips.y / imageHeight
        var torsoRel = Double.nan
        if let leftShoulder = raw["left_shoulder"], let rightShoulder = raw["right_shoulder"] {
            torsoRel = length((leftShoulder + rightShoulder) / 2 - hips) / imageHeight
        }
        return [hipX, hipY, torsoRel]
    }

    /// Hip-centre, then scale by max(2.5 * torso, max distance from hips) * 100 — the dataset convention.
    static func normalise(_ joints: [String: SIMD2<Double>]) -> [String: SIMD2<Double>] {
        guard let leftHip = joints["left_hip"], let rightHip = joints["right_hip"] else {
            return [:]  // without hips nothing can be normalised (matches the NaN rows in the CSV)
        }
        let hips = (leftHip + rightHip) / 2
        let maxDist = joints.values.map { length($0 - hips) }.max() ?? 0
        var size = maxDist
        if let leftShoulder = joints["left_shoulder"], let rightShoulder = joints["right_shoulder"] {
            let torso = length((leftShoulder + rightShoulder) / 2 - hips)
            size = max(torso * torsoMultiplier, maxDist)
        }
        guard size > 0 else { return [:] }
        return joints.mapValues { ($0 - hips) / size * 100 }
    }

    static func compute(_ joints: [String: SIMD2<Double>]) -> [Double] {
        func point(_ name: String) -> SIMD2<Double>? {
            if name == "mid_hip" {
                guard let l = joints["left_hip"], let r = joints["right_hip"] else { return nil }
                return (l + r) / 2
            }
            if name.hasPrefix("avg_") {   // avg_left_wrist_left_ankle -> mean of left_wrist and left_ankle
                let parts = name.dropFirst(4).split(separator: "_")
                guard parts.count == 4,
                      let a = joints["\(parts[0])_\(parts[1])"], let b = joints["\(parts[2])_\(parts[3])"] else { return nil }
                return (a + b) / 2
            }
            return joints[name]
        }
        var values: [Double] = []
        values.reserveCapacity(angles.count + distances.count)
        for (a, b, c) in angles {
            guard let pa = point(a), let pb = point(b), let pc = point(c) else { values.append(.nan); continue }
            let ba = pa - pb, bc = pc - pb
            let cosine = dot(ba, bc) / (length(ba) * length(bc))
            values.append(acos(min(max(cosine, -1), 1)) * 180 / .pi)
        }
        for (a, b) in distances {
            guard let pa = point(a), let pb = point(b) else { values.append(.nan); continue }
            values.append(length(pb - pa))
        }
        return values
    }

    private static func length(_ v: SIMD2<Double>) -> Double { (v.x * v.x + v.y * v.y).squareRoot() }
    private static func dot(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.x + a.y * b.y }
}
