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
    /// Cumulative active seconds per exercise this session, for the report.
    var repDurations: [String: Double] = [:]
    /// Per-rep time ranges detected during playback, for the report's rep timeline.
    var repRecords: [RepRecord] = []

    // MARK: Per-exercise totals (derived from the big on-screen counter)
    //
    // We trust the big bottom counter (`reps`) as the source of truth. For each exercise we track
    // that counter while it climbs; when it drops back to 0 (the segment ended / counter reset) we
    // bank the last non-zero value into that exercise's committed total. The live per-exercise
    // total shown in the Rep Log / report is the committed total plus the in-progress peak.
    private var committedTotals: [String: Int] = [:]
    private var trackingLabel: String?
    private var trackingPeak = 0

    /// Per-exercise totals for the Rep Log + report: banked segments plus the in-progress one.
    var repTotals: [String: Int] {
        var totals = committedTotals
        if let label = trackingLabel, trackingPeak > 0 { totals[label, default: 0] += trackingPeak }
        return totals
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
        confidence = 0
        calibrating = true
        finished = false
        currentFrame = nil
        latestPose = nil
        committedTotals = [:]
        trackingLabel = nil
        trackingPeak = 0
        repDurations = [:]
        repRecords = []
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
        trackCounter(reps: update.update.reps, label: update.update.rawLabel)
        for (exercise, seconds) in update.update.repDurations {
            repDurations[exercise] = max(repDurations[exercise] ?? 0, seconds)
        }
        // Rep records only ever grow (append-only), so keep whichever snapshot is longest.
        if update.update.repRecords.count >= repRecords.count {
            repRecords = update.update.repRecords
        }
    }

    /// Follows the big on-screen counter: track an exercise while its count is non-zero, and bank
    /// the last non-zero value when the count resets to 0 or the exercise changes.
    private func trackCounter(reps: Int, label: String?) {
        if reps > 0, let label {
            if label != trackingLabel { bankTrackedSegment(); trackingLabel = label }
            trackingPeak = max(trackingPeak, reps)
        } else {
            bankTrackedSegment()   // counter hit 0 → segment finished
        }
    }

    /// Adds the current segment's peak to its exercise total, then clears the tracking state.
    private func bankTrackedSegment() {
        if let label = trackingLabel, trackingPeak > 0 {
            committedTotals[label, default: 0] += trackingPeak
        }
        trackingLabel = nil
        trackingPeak = 0
    }
}
