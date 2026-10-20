// StreamingRepCounter.swift
// Live (online) version of GeometricRepCounter: fed one PoseFrame per camera/video frame,
// it counts reps incrementally using the same per-exercise RepSignalSpec as the batch counter.
//
//   • EMA-smooth the incoming signal (live pose is jittier than decoded video).
//   • Track a running min/max to derive adaptive low/high thresholds (hysteresis).
//   • One rep per extended → flexed → extended cycle.
// Thresholds only "arm" once the observed range exceeds the exercise's minimum, so idle jitter
// and the warm-up period don't produce phantom reps. Standing/walking have no spec → count stays 0.
// Resets when the exercise changes.

import CoreGraphics
import Foundation

nonisolated final class StreamingRepCounter {

    private let emaAlpha = 0.35              // weight of the newest sample

    private(set) var reps = 0
    private var exercise: String?
    private var spec: RepSignalSpec?
    private var smoothed: Double?
    private var minValue = Double.greatestFiniteMagnitude
    private var maxValue = -Double.greatestFiniteMagnitude
    private var extended = true
    private var armed = false                // true once the range first exceeds minRange

    /// Switches the tracked exercise; a change restarts counting from zero.
    /// A nil spec (standing / walking / unrecognised) means no counting.
    func setExercise(_ newExercise: String?) {
        guard newExercise != exercise else { return }
        exercise = newExercise
        spec = newExercise.flatMap { GeometricRepCounter.spec(for: $0) }
        reset()
    }

    func reset() {
        reps = 0
        smoothed = nil
        minValue = .greatestFiniteMagnitude
        maxValue = -.greatestFiniteMagnitude
        extended = true
        armed = false
    }

    /// Credit `value` reps immediately (e.g. to recover an opening rep performed before this
    /// exercise was recognised). Call right after `setExercise`; counting continues from here.
    func seed(_ value: Int) {
        reps = value
    }

    /// Feed one frame; no-op when the exercise isn't counted or the signal joints are missing.
    func update(pose: PoseFrame, orientedSize: CGSize) {
        guard let spec, let value = spec.compute(pose, orientedSize) else { return }

        let s = smoothed.map { $0 * (1 - emaAlpha) + value * emaAlpha } ?? value
        smoothed = s

        let low: Double, high: Double
        if let fixedLow = spec.fixedLow, let fixedHigh = spec.fixedHigh {
            // Absolute thresholds (scale-invariant signal): no warm-up gate, so the first full rep
            // counts immediately and a segment's last rep is never lost to range-building.
            low = fixedLow
            high = fixedHigh
        } else {
            minValue = min(minValue, s)
            maxValue = max(maxValue, s)
            let range = maxValue - minValue
            guard range >= spec.minRange else { return }   // adaptive thresholds arm after enough motion
            low = minValue + GeometricRepCounter.hysteresis * range
            high = maxValue - GeometricRepCounter.hysteresis * range
        }

        // Seed the phase from the first usable sample so the OPENING rep isn't dropped. If counting
        // begins while the athlete is already mid-movement (not fully extended), start "flexed" so
        // the imminent return to full extension counts as rep 1. (Replaces the old hardcoded
        // extended = true, which silently lost the first rep when counting started mid-rep — the
        // reason squat-press needed a +1 fudge.)
        if !armed {
            armed = true
            extended = s >= high
        }

        if extended, s < low {
            extended = false                 // reached the LOW extreme (e.g. jump apex)
            if spec.countOnLow { reps += 1 } // count on the way up (bottom→up) for skipping
        } else if !extended, s > high {
            extended = true                  // returned to the HIGH extreme
            if !spec.countOnLow { reps += 1 }// default: count on the return (angles, press lockout)
        }
    }
}
