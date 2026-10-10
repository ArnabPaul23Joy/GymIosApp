// LiveWorkoutViewModel.swift
// MainActor UI state for the live-camera screen. Owns the LiveExerciseEngine, requests
// camera permission, and marshals per-frame LiveUpdates from the capture queue onto the
// main actor for SwiftUI.

import AVFoundation
import SwiftUI

@MainActor
@Observable
final class LiveWorkoutViewModel {

    enum Permission { case unknown, authorized, denied }

    let engine = LiveExerciseEngine()

    var permission: Permission = .unknown
    var latestPose: PoseFrame?
    var orientedSize: CGSize = .zero
    var displayLabel = ""
    var confidence = 0.0
    var reps = 0
    var calibrating = true
    /// When the current session (re)started — drives the on-screen elapsed timer.
    var sessionStart: Date?
    private(set) var cameraPosition: AVCaptureDevice.Position = .back
    /// Cumulative active seconds per exercise this session, for the report.
    var repDurations: [String: Double] = [:]
    /// Per-rep time ranges detected this session, for the report's rep timeline.
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

    var session: AVCaptureSession { engine.session }

    func start() async {
        permission = await requestCameraAccess() ? .authorized : .denied
        guard permission == .authorized else { return }

        engine.onUpdate = { [weak self] update in
            Task { @MainActor [weak self] in self?.apply(update) }
        }
        engine.configure(position: cameraPosition)
        engine.start()
        sessionStart = Date()
    }

    func stop() {
        engine.stop()
    }

    func resetReps() {
        engine.resetSession()
        clearSessionTotals()
    }

    func flipCamera() {
        cameraPosition = (cameraPosition == .back) ? .front : .back
        latestPose = nil
        clearSessionTotals()
        engine.configure(position: cameraPosition)   // reconfigure also fully resets the pipeline
    }

    /// Clears the live count + all report accumulators and restarts the timer (new session).
    private func clearSessionTotals() {
        reps = 0
        committedTotals = [:]
        trackingLabel = nil
        trackingPeak = 0
        repDurations = [:]
        repRecords = []
        sessionStart = Date()
    }

    private func apply(_ update: LiveUpdate) {
        latestPose = update.pose
        orientedSize = update.orientedSize
        displayLabel = update.displayLabel
        confidence = update.confidence
        reps = update.reps
        calibrating = update.calibrating
        trackCounter(reps: update.reps, label: update.rawLabel)
        for (exercise, seconds) in update.repDurations {
            repDurations[exercise] = max(repDurations[exercise] ?? 0, seconds)
        }
        // Rep records only ever grow (append-only), so keep whichever snapshot is longest.
        if update.repRecords.count >= repRecords.count {
            repRecords = update.repRecords
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

    private func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }
}
