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
    }

    /// Feed one frame; no-op when the exercise isn't counted or the signal joints are missing.
    func update(pose: PoseFrame, orientedSize: CGSize) {
        guard let spec, let value = spec.compute(pose, orientedSize) else { return }

        let s = smoothed.map { $0 * (1 - emaAlpha) + value * emaAlpha } ?? value
        smoothed = s
        minValue = min(minValue, s)
        maxValue = max(maxValue, s)

        let range = maxValue - minValue
        guard range >= spec.minRange else { return }
        let low = minValue + GeometricRepCounter.hysteresis * range
        let high = maxValue - GeometricRepCounter.hysteresis * range

        if extended, s < low {
            extended = false                 // entered the flexed/contracted phase
        } else if !extended, s > high {
            reps += 1                        // returned to extended → one full rep
            extended = true
        }
    }
}
