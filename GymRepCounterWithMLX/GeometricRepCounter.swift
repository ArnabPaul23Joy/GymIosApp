// GeometricRepCounter.swift
// Counts repetitions purely from body-point geometry — no ML inference.
//
// Each exercise maps to a 1-D "rep signal" that swings through a large arc once per rep:
//   • squat / squat-shoulder-press → knee angle    (hip → knee → ankle)
//   • push-up / pull-up            → elbow angle   (shoulder → elbow → wrist)
//   • hanging leg raise            → hip angle      (shoulder → hip → knee), torso↔legs closing
//   • skipping                     → hip vertical position (body bobs once per jump)
//   • standing / walking / unknown → no signal → count stays 0
//
// We smooth the signal, then count full cycles with a Schmitt trigger whose thresholds are
// derived from the observed range of motion (hysteresis rejects jitter). Angles are computed
// in oriented pixel space so aspect ratio doesn't distort them.

import CoreGraphics
import Foundation

/// How to derive one exercise's rep signal, and how big a swing counts as a real rep.
nonisolated struct RepSignalSpec {
    let compute: @Sendable (PoseFrame, CGSize) -> Double?
    let minRange: Double
}

nonisolated enum GeometricRepCounter {

    /// Fraction of the range used as hysteresis margin on each side of the midpoint.
    static let hysteresis = 0.30
    /// Moving-average half-window (frames) used to smooth the raw signal.
    private static let smoothingRadius = 2

    /// nil for exercises that shouldn't be counted (standing / walking / unrecognised).
    static func spec(for exercise: String) -> RepSignalSpec? {
        switch exercise {
        case "squat", "squatpress":
            return RepSignalSpec(compute: { f, s in
                avgAngle(f, s, ("left_hip", "left_knee", "left_ankle"), ("right_hip", "right_knee", "right_ankle"))
            }, minRange: 30)
        case "pushup", "pullup":
            return RepSignalSpec(compute: { f, s in
                avgAngle(f, s, ("left_shoulder", "left_elbow", "left_wrist"), ("right_shoulder", "right_elbow", "right_wrist"))
            }, minRange: 30)
        case "legraise":
            return RepSignalSpec(compute: { f, s in
                avgAngle(f, s, ("left_shoulder", "left_hip", "left_knee"), ("right_shoulder", "right_hip", "right_knee"))
            }, minRange: 35)
        case "skipping":
            return RepSignalSpec(compute: { f, _ in hipVertical(f) }, minRange: 3.0)
        default:
            return nil
        }
    }

    /// Per-exercise display offset. Squat-shoulder-press starts mid-cycle so the opening rep is
    /// missed; count it from 1 (i.e. +1).
    static func displayOffset(for exercise: String?) -> Int {
        exercise == "squatpress" ? 1 : 0
    }

    static func countReps(poses: [PoseFrame], orientedSize: CGSize, exercise: String) -> Int {
        guard !poses.isEmpty, let spec = spec(for: exercise) else { return 0 }

        // 1. Raw per-frame signal (NaN where the needed joints weren't seen).
        let raw = poses.map { spec.compute($0, orientedSize) ?? .nan }
        // 2. Fill gaps by linear interpolation.
        guard let filled = interpolateGaps(raw) else { return 0 }
        // 3. Smooth to suppress detector jitter.
        let signal = smooth(filled, radius: smoothingRadius)
        // 4. Adaptive thresholds from the range of motion.
        guard let mn = signal.min(), let mx = signal.max() else { return 0 }
        let range = mx - mn
        guard range >= spec.minRange else { return 0 }
        let low = mn + hysteresis * range
        let high = mx - hysteresis * range
        // 5. Schmitt trigger: one rep per extended → flexed → extended cycle.
        return countCycles(signal, low: low, high: high)
    }

    // MARK: - Rep signals

    /// Angle at joint `b` (vertex) for the a-b-c chain, averaged over visible sides; nil if neither seen.
    private static func avgAngle(_ frame: PoseFrame, _ size: CGSize,
                                 _ left: (String, String, String),
                                 _ right: (String, String, String)) -> Double? {
        let w = Double(size.width), h = Double(size.height)
        let l = jointAngle(frame, left, width: w, height: h)
        let r = jointAngle(frame, right, width: w, height: h)
        switch (l, r) {
        case let (l?, r?): return (l + r) / 2
        case let (l?, nil): return l
        case let (nil, r?): return r
        default:           return nil
        }
    }

    /// Body vertical position as a % of frame height (hip centre, top-left origin) — for skipping.
    private static func hipVertical(_ frame: PoseFrame) -> Double? {
        guard let l = frame.joints["left_hip"], let r = frame.joints["right_hip"] else { return nil }
        return Double(l.y + r.y) / 2 * 100
    }


    private static func jointAngle(_ frame: PoseFrame, _ names: (String, String, String),
                                   width: Double, height: Double) -> Double? {
        guard let a = frame.joints[names.0], let b = frame.joints[names.1], let c = frame.joints[names.2] else {
            return nil
        }
        // Normalised (top-left) → oriented pixel space so the angle is geometrically true.
        let pa = SIMD2(a.x * width, a.y * height)
        let pb = SIMD2(b.x * width, b.y * height)
        let pc = SIMD2(c.x * width, c.y * height)
        let ba = pa - pb, bc = pc - pb
        let denom = length(ba) * length(bc)
        guard denom > 0 else { return nil }
        let cosine = dot(ba, bc) / denom
        return acos(min(max(cosine, -1), 1)) * 180 / .pi
    }

    // MARK: - Signal processing

    /// Replaces NaN runs with linear interpolation between valid samples; nil if <2 valid samples.
    private static func interpolateGaps(_ values: [Double]) -> [Double]? {
        let valid = values.enumerated().filter { !$0.element.isNaN }
        guard valid.count >= 2 else { return nil }

        var out = values
        let first = valid.first!, last = valid.last!
        for i in 0..<first.offset { out[i] = first.element }
        for i in (last.offset + 1)..<out.count { out[i] = last.element }
        for k in 0..<(valid.count - 1) {
            let (i0, v0) = valid[k], (i1, v1) = valid[k + 1]
            guard i1 > i0 + 1 else { continue }
            for i in (i0 + 1)..<i1 {
                let t = Double(i - i0) / Double(i1 - i0)
                out[i] = v0 + t * (v1 - v0)
            }
        }
        return out
    }

    private static func smooth(_ values: [Double], radius: Int) -> [Double] {
        guard radius > 0, values.count > 2 * radius else { return values }
        return values.indices.map { i in
            let lo = max(0, i - radius), hi = min(values.count - 1, i + radius)
            var sum = 0.0
            for j in lo...hi { sum += values[j] }
            return sum / Double(hi - lo + 1)
        }
    }

    private static func countCycles(_ signal: [Double], low: Double, high: Double) -> Int {
        var reps = 0
        var extended = signal[0] >= (low + high) / 2
        for v in signal {
            if extended, v < low {
                extended = false
            } else if !extended, v > high {
                reps += 1
                extended = true
            }
        }
        return reps
    }

    private static func length(_ v: SIMD2<Double>) -> Double { (v.x * v.x + v.y * v.y).squareRoot() }
    private static func dot(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.x + a.y * b.y }
}
