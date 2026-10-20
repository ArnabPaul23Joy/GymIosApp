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
    /// Per-exercise totals for the Rep Log + report. Sourced from the engine, which authoritatively
    /// commits each exercise's finished reps at the moment the exercise changes (so a segment's last
    /// rep is never lost). Merged with `max` so an out-of-order update can't shrink the tally.
    var repTotals: [String: Int] = [:]
    /// Cumulative active seconds per exercise this session, for the report.
    var repDurations: [String: Double] = [:]
    /// Per-rep time ranges detected this session, for the report's rep timeline.
    var repRecords: [RepRecord] = []

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
        repTotals = [:]
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
        // Totals/durations are cumulative + monotonic by design; keep the peak so a stale or
        // out-of-order update can't wipe the tally the Rep Log / report rely on.
        for (exercise, count) in update.repTotals {
            repTotals[exercise] = max(repTotals[exercise] ?? 0, count)
        }
        for (exercise, seconds) in update.repDurations {
            repDurations[exercise] = max(repDurations[exercise] ?? 0, seconds)
        }
        // Rep records only ever grow (append-only), so keep whichever snapshot is longest.
        if update.repRecords.count >= repRecords.count {
            repRecords = update.repRecords
        }
    }

    private func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }
}
