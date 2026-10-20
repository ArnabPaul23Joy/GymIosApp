// LiveVideoWorkoutView.swift
// Full-screen "live from gallery" screen: a picked video streamed frame-by-frame (paced to real
// time) with the pose skeleton overlaid and a live exercise-type + rep-count HUD.

import SwiftUI

struct LiveVideoWorkoutView: View {
    @State private var viewModel: LiveVideoWorkoutViewModel
    @Environment(\.dismiss) private var dismiss

    /// Body metrics used to personalise the calorie estimate in the generated report.
    let profile: UserBodyProfile
    /// Called when the user taps "Generate Report" — hands back the per-exercise rows and the per-rep timeline.
    let onGenerateReport: ([ExerciseCount], [RepRecord]) -> Void

    init(url: URL, profile: UserBodyProfile,
         onGenerateReport: @escaping ([ExerciseCount], [RepRecord]) -> Void) {
        _viewModel = State(initialValue: LiveVideoWorkoutViewModel(url: url))
        self.profile = profile
        self.onGenerateReport = onGenerateReport
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            LiveVideoPlayerView(image: viewModel.currentFrame, pose: viewModel.latestPose,
                                orientedSize: viewModel.orientedSize)
                .ignoresSafeArea()

            hud
        }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .statusBarHidden()
    }

    private var hud: some View {
        VStack(spacing: 0) {
            topBar
            if !loggedExercises.isEmpty {
                HStack {
                    exerciseLog
                    Spacer()
                }
                .padding(.top, 10)
            }
            Spacer()
            if viewModel.calibrating && !viewModel.finished {
                banner("Calibrating…", systemImage: "timer")
            } else if viewModel.finished {
                banner("Finished", systemImage: "checkmark.circle")
            }
            generateReportButton
            repCountBar
        }
        .padding()
    }

    // MARK: - Per-exercise rep count log (overlay)

    /// Each tracked exercise detected so far, with its running rep count (display offset applied),
    /// in the report's display order.
    private var loggedExercises: [(raw: String, name: String, count: Int)] {
        WorkoutReport.tracked.compactMap { raw in
            guard let count = viewModel.repTotals[raw], count > 0 else { return nil }
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

    private var generateReportButton: some View {
        Button {
            viewModel.stop()
            onGenerateReport(
                WorkoutReport.items(from: viewModel.repTotals, durations: viewModel.repDurations,
                                    profile: profile),
                viewModel.repRecords
            )
        } label: {
            Label("Generate Report", systemImage: "doc.text.magnifyingglass")
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

            Button {
                viewModel.restart()
            } label: {
                Image(systemName: "gobackward")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
        }
    }

    private func banner(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.black.opacity(0.5), in: Capsule())
            .padding(.bottom, 12)
    }

    private var repCountBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Exercise type, styled like the count so it's just as visible.
            HStack(spacing: 8) {
                Image(systemName: "figure.strengthtraining.traditional")
                    .foregroundStyle(.white.opacity(0.9))
                Text(viewModel.displayLabel.isEmpty ? "Identifying…" : viewModel.displayLabel)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                if !viewModel.displayLabel.isEmpty {
                    Text("· \(Int((viewModel.confidence * 100).rounded()))%")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
            }

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
                    viewModel.restart()
                } label: {
                    Label("Replay", systemImage: "arrow.counterclockwise")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.white.opacity(0.18), in: Capsule())
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 20))
    }
}
