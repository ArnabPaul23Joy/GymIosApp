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
    /// Optional ABSOLUTE Schmitt thresholds. When set, counting uses these fixed values instead of
    /// adaptive running min/max — so there's no warm-up and the very first full rep is counted
    /// (requires a scale-invariant signal). `minRange` is then unused. Used by the thruster.
    var fixedLow: Double? = nil
    var fixedHigh: Double? = nil
}

nonisolated enum GeometricRepCounter {

    /// Fraction of the range used as hysteresis margin on each side of the midpoint.
    static let hysteresis = 0.30
    /// Moving-average half-window (frames) used to smooth the raw signal.
    private static let smoothingRadius = 2

    /// nil for exercises that shouldn't be counted (standing / walking / unrecognised).
    static func spec(for exercise: String) -> RepSignalSpec? {
        switch exercise {
        case "squat":
            return RepSignalSpec(compute: { f, s in
                avgAngle(f, s, ("left_hip", "left_knee", "left_ankle"), ("right_hip", "right_knee", "right_ankle"))
            }, minRange: 30)
        case "squatpress":
            // Dumbbell thruster: count one rep per OVERHEAD LOCKOUT — the wrists rising above the
            // head. The press is the defining feature, so this also rejects partial reps (no full
            // overhead) and naturally distinguishes a thruster from a plain squat (no press at all).
            // Signal is wrist height above the head measured in TORSO LENGTHS (scale-invariant, so
            // camera distance doesn't matter). We use ABSOLUTE thresholds: a rep is an overhead
            // lockout (> 0.4 torso above the head) after the dumbbells came back down (< 0.1). Fixed
            // thresholds mean no range warm-up, so the FIRST full press is counted (and the last).
            // Racked wrists sit ~0.25 below the head (negative), a full lockout ~0.6–0.9 above.
            return RepSignalSpec(compute: { f, _ in wristsOverhead(f) }, minRange: 0.5,
                                 fixedLow: 0.1, fixedHigh: 0.4)
        case "pushup", "pullup":
            return RepSignalSpec(compute: { f, s in
                avgAngle(f, s, ("left_shoulder", "left_elbow", "left_wrist"), ("right_shoulder", "right_elbow", "right_wrist"))
            }, minRange: 30)
        case "legraise":
            // Toes-to-bar: require a LARGE hip-closure arc so partial kips (toes only to hip height,
            // ~50–90° swing) don't count — only a near-full raise toward the bar (~120°+) does.
            // NOTE: tuned by estimate; may need on-device adjustment per athlete/camera angle.
            return RepSignalSpec(compute: { f, s in
                avgAngle(f, s, ("left_shoulder", "left_hip", "left_knee"), ("right_shoulder", "right_hip", "right_knee"))
            }, minRange: 100)
        case "skipping":
            return RepSignalSpec(compute: { f, _ in hipVertical(f) }, minRange: 3.0)
        default:
            return nil
        }
    }

    static func countReps(poses: [PoseFrame], orientedSize: CGSize, exercise: String) -> Int {
        guard !poses.isEmpty, let spec = spec(for: exercise) else { return 0 }

        // 1. Raw per-frame signal (NaN where the needed joints weren't seen).
        let raw = poses.map { spec.compute($0, orientedSize) ?? .nan }
        // 2. Fill gaps by linear interpolation.
        guard let filled = interpolateGaps(raw) else { return 0 }
        // 3. Smooth to suppress detector jitter.
        let signal = smooth(filled, radius: smoothingRadius)
        // 4. Thresholds: fixed (absolute) if the spec provides them, else adaptive from the range.
        let low: Double, high: Double
        if let fixedLow = spec.fixedLow, let fixedHigh = spec.fixedHigh {
            low = fixedLow
            high = fixedHigh
        } else {
            guard let mn = signal.min(), let mx = signal.max() else { return 0 }
            let range = mx - mn
            guard range >= spec.minRange else { return 0 }
            low = mn + hysteresis * range
            high = mx - hysteresis * range
        }
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

    /// How far the wrists are ABOVE the head, measured in TORSO LENGTHS (shoulder→hip distance), so
    /// it's invariant to how large the athlete appears in frame. Top-left origin, y grows downward:
    /// positive/large at an overhead lockout, negative when racked at the shoulders. Used for the
    /// dumbbell thruster — one up-swing per rep. nil if the head, wrists, or torso aren't visible.
    private static func wristsOverhead(_ frame: PoseFrame) -> Double? {
        let j = frame.joints
        // Head reference = the highest visible head keypoint (smallest y). Nose preferred.
        let headYs = ["nose", "left_eye", "right_eye", "left_ear", "right_ear"].compactMap { j[$0]?.y }
        guard let headY = headYs.min() else { return nil }
        let wristYs = ["left_wrist", "right_wrist"].compactMap { j[$0]?.y }
        guard !wristYs.isEmpty else { return nil }
        let wristY = wristYs.reduce(CGFloat(0), +) / CGFloat(wristYs.count)
        // Torso length (shoulder midpoint → hip midpoint) as the scale reference.
        guard let ls = j["left_shoulder"], let rs = j["right_shoulder"],
              let lh = j["left_hip"], let rh = j["right_hip"] else { return nil }
        let dx = Double((ls.x + rs.x) / 2 - (lh.x + rh.x) / 2)
        let dy = Double((ls.y + rs.y) / 2 - (lh.y + rh.y) / 2)
        let torso = (dx * dx + dy * dy).squareRoot()
        guard torso > 0.01 else { return nil }
        return Double(headY - wristY) / torso   // torso-lengths; wrists above head → positive
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
