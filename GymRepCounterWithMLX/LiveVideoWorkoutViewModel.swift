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
    var confidence = 0.0
    var reps = 0
    var calibrating = true
    var finished = false
    /// Cumulative raw reps per exercise this session, for the report.
    var repTotals: [String: Int] = [:]

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
        confidence = 0
        calibrating = true
        finished = false
        currentFrame = nil
        latestPose = nil
        repTotals = [:]
        engine.start(url: url)
    }

    private func apply(_ update: LiveVideoUpdate) {
        currentFrame = update.frame
        latestPose = update.update.pose
        orientedSize = update.update.orientedSize
        displayLabel = update.update.displayLabel
        confidence = update.update.confidence
        reps = update.update.reps
        calibrating = update.update.calibrating
        // Keep the peak per exercise (totals are cumulative/monotonic by design) so no stale or
        // out-of-order update can ever wipe the tally the report relies on.
        for (exercise, count) in update.update.repTotals {
            repTotals[exercise] = max(repTotals[exercise] ?? 0, count)
        }
    }
}
