// LiveVideoWorkoutViewModel.swift
// MainActor UI state for the "live from gallery" screen. Owns a LiveVideoExerciseEngine and
// marshals its per-frame updates onto the main actor for SwiftUI.

import CoreGraphics
import SwiftUI

@MainActor
@Observable
final class LiveVideoWorkoutViewModel {

    private let engine = LiveVideoExerciseEngine()
    private let url: URL

    var currentFrame: CGImage?
    var latestPose: PoseFrame?
    var orientedSize: CGSize = .zero
    var displayLabel = ""
    /// Raw classifier label of the ongoing exercise (key into repTotals); "" when none.
    var currentRawLabel = ""
    var confidence = 0.0
    var reps = 0
    var calibrating = true
    var finished = false
    /// Cumulative raw reps per exercise this session, for the report.
    var repTotals: [String: Int] = [:]
    /// Cumulative active seconds per exercise this session, for the report.
    var repDurations: [String: Double] = [:]
    /// Ordered exercise-type segments (time ranges) detected during playback, for the report.
    var segments: [SegmentRecord] = []

    /// Total reps counted across the whole video so far for the ongoing exercise (all its segments
    /// combined), displayed with the same offset as the live count. 0 when no exercise is active.
    var totalRepsForCurrentExercise: Int {
        guard !currentRawLabel.isEmpty else { return 0 }
        let raw = repTotals[currentRawLabel] ?? 0
        return raw + GeometricRepCounter.displayOffset(for: currentRawLabel)
    }

    init(url: URL) {
        self.url = url
    }

    func start() {
        finished = false
        engine.onUpdate = { [weak self] update in
            Task { @MainActor [weak self] in self?.apply(update) }
        }
        engine.onFinished = { [weak self] in
            Task { @MainActor [weak self] in self?.finished = true }
        }
        engine.start(url: url)
    }

    func stop() { engine.stop() }

    /// Restart playback + counting from the beginning.
    func restart() {
        engine.stop()
        reps = 0
        displayLabel = ""
        currentRawLabel = ""
        confidence = 0
        calibrating = true
        finished = false
        currentFrame = nil
        latestPose = nil
        repTotals = [:]
        repDurations = [:]
        segments = []
        engine.start(url: url)
    }

    private func apply(_ update: LiveVideoUpdate) {
        currentFrame = update.frame
        latestPose = update.update.pose
        orientedSize = update.update.orientedSize
        displayLabel = update.update.displayLabel
        currentRawLabel = update.update.rawLabel ?? ""
        confidence = update.update.confidence
        reps = update.update.reps
        calibrating = update.update.calibrating
        // Keep the peak per exercise (totals are cumulative/monotonic by design) so no stale or
        // out-of-order update can ever wipe the tally the report relies on.
        for (exercise, count) in update.update.repTotals {
            repTotals[exercise] = max(repTotals[exercise] ?? 0, count)
        }
        for (exercise, seconds) in update.update.repDurations {
            repDurations[exercise] = max(repDurations[exercise] ?? 0, seconds)
        }
        // Segments grow monotonically (only appended, never removed), so always take the latest.
        if update.update.segments.count >= segments.count {
            segments = update.update.segments
        }
    }
}
