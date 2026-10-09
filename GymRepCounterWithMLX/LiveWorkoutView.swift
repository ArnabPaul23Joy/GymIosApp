// LiveWorkoutView.swift
// Full-screen live-camera workout screen: camera preview + pose skeleton overlay, with a
// HUD showing the live exercise type, confidence, and rep count.

import SwiftUI

struct LiveWorkoutView: View {
    @State private var viewModel = LiveWorkoutViewModel()
    @Environment(\.dismiss) private var dismiss

    /// Body metrics used to personalise the calorie estimate in the generated report.
    let profile: UserBodyProfile
    /// Called when the user taps "Finish" — hands back the per-exercise rows and the per-rep timeline.
    let onGenerateReport: ([ExerciseCount], [RepRecord]) -> Void

    init(profile: UserBodyProfile,
         onGenerateReport: @escaping ([ExerciseCount], [RepRecord]) -> Void) {
        self.profile = profile
        self.onGenerateReport = onGenerateReport
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch viewModel.permission {
            case .denied:
                permissionDeniedView
            case .unknown:
                ProgressView().tint(.white)
            case .authorized:
                LiveCameraView(session: viewModel.session, pose: viewModel.latestPose,
                               orientedSize: viewModel.orientedSize)
                    .ignoresSafeArea()
                hud
            }
        }
        .task { await viewModel.start() }
        .onDisappear { viewModel.stop() }
        .statusBarHidden()
    }

    // MARK: - HUD

    private var hud: some View {
        VStack(spacing: 0) {
            topBar
            // Rep log on the left, elapsed-time pill on the right.
            HStack(alignment: .top) {
                if !loggedExercises.isEmpty { exerciseLog }
                Spacer()
                timerPill
            }
            .padding(.top, 10)
            Spacer()
            if viewModel.calibrating {
                calibratingBanner
            }
            generateReportButton
            repCountBar
        }
        .padding()
        // A gentle tap on every counted rep, so reps register without watching the screen.
        .sensoryFeedback(.increase, trigger: viewModel.repRecords.count)
    }

    // MARK: - Elapsed-time pill

    private var timerPill: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = viewModel.sessionStart.map { max(0, context.date.timeIntervalSince($0)) } ?? 0
            Label(elapsedString(elapsed), systemImage: "stopwatch")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.black.opacity(0.5), in: Capsule())
        }
    }

    private func elapsedString(_ seconds: TimeInterval) -> String {
        let t = Int(seconds)
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    // MARK: - Per-exercise rep count log (overlay)

    /// Each tracked exercise detected so far, with its running rep count (display offset applied),
    /// in the report's display order.
    private var loggedExercises: [(raw: String, name: String, count: Int)] {
        WorkoutReport.tracked.compactMap { raw in
            guard let rawCount = viewModel.repTotals[raw] else { return nil }
            let count = rawCount + GeometricRepCounter.displayOffset(for: raw)
            guard count > 0 else { return nil }
            return (raw, ExerciseTypeAnalyzer.displayName(for: raw), count)
        }
    }

    private var exerciseLog: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Rep Log")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            ForEach(loggedExercises, id: \.raw) { entry in
                HStack(spacing: 10) {
                    Text(entry.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                    Spacer(minLength: 12)
                    Text("\(entry.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Finish / Generate Report

    private var generateReportButton: some View {
        Button {
            viewModel.stop()
            onGenerateReport(
                WorkoutReport.items(from: viewModel.repTotals, durations: viewModel.repDurations,
                                    profile: profile),
                viewModel.repRecords
            )
        } label: {
            Label("Finish & Generate Report", systemImage: "doc.text.magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.tint, in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(.bottom, 8)
    }

    private var topBar: some View {
        HStack {
            Button {
                viewModel.stop()
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
            }

            Spacer()

            VStack(spacing: 2) {
                Text(viewModel.displayLabel.isEmpty ? "—" : viewModel.displayLabel)
                    .font(.headline)
                    .foregroundStyle(.white)
                if !viewModel.displayLabel.isEmpty {
                    Text("\(Int((viewModel.confidence * 100).rounded()))% confidence")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.black.opacity(0.4), in: Capsule())

            Spacer()

            Button {
                viewModel.flipCamera()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
        }
    }

    private var calibratingBanner: some View {
        Label("Calibrating… hold steady in frame", systemImage: "timer")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.black.opacity(0.5), in: Capsule())
            .padding(.bottom, 12)
    }

    private var repCountBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(viewModel.reps)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.35), value: viewModel.reps)
                Text(viewModel.reps == 1 ? "rep" : "reps")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.8))
            }
            Spacer()
            Button {
                viewModel.resetReps()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.white.opacity(0.18), in: Capsule())
            }
        }
        .padding()
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Permission

    private var permissionDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.8))
            Text("Camera access is off")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("Enable camera access in Settings to use live rep counting.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.75))
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            Button("Close") { dismiss() }
                .foregroundStyle(.white)
        }
        .padding(32)
    }
}
