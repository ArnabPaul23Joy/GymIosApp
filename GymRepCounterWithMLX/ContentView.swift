import SwiftUI
import PhotosUI
import AVKit

struct ContentView: View {
    @State private var viewModel = RepCounterViewModel()
    @State private var pickerItem: PhotosPickerItem?
    @State private var videoURL: URL?
    @State private var player: AVPlayer?
    @State private var showLiveCamera = false
    @State private var liveGalleryPicker: PhotosPickerItem?
    @State private var liveGalleryURL: URL?
    @State private var showLiveGallery = false
    @State private var reportItems: [ExerciseCount] = []
    @State private var reportReps: [RepRecord] = []
    @State private var showReport = false   // true once "Generate Report" is tapped
    @State private var bodyProfile = UserBodyProfile()   // personalises the calorie estimate

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if showReport {
                        // Report takes over the screen; the cancel (✕) restores the buttons/views.
                        reportCard
                        timelineCard
                    } else {
                        liveCameraButton
                        liveGalleryButton
                        videoPickerCard
                        if videoURL != nil {
                            exerciseTypeCard
                            analyzeButton
                        }
                        analysisResultCard
                    }
                }
                .padding()
            }
            .navigationTitle("Gym Rep Counter")
            .navigationBarTitleDisplayMode(.inline)
        }
        .fullScreenCover(isPresented: $showLiveCamera) {
            // Collect the body profile first, then run the live-camera workout.
            LiveCameraFlow(profile: $bodyProfile) { items, reps in
                reportItems = items
                reportReps = reps
                showReport = true
                showLiveCamera = false
            }
        }
        .fullScreenCover(isPresented: $showLiveGallery) {
            if let liveGalleryURL {
                // Collect the body profile first, then stream + count the video.
                LiveGalleryFlow(url: liveGalleryURL, profile: $bodyProfile) { items, reps in
                    // Show the report inline on this main screen, then dismiss the player.
                    reportItems = items
                    reportReps = reps
                    showReport = true
                    showLiveGallery = false
                }
            }
        }
        .onChange(of: liveGalleryPicker) { _, newItem in
            guard let newItem else { return }
            Task {
                guard let vid = try? await newItem.loadTransferable(type: VideoFile.self) else { return }
                liveGalleryURL = vid.url
                showReport = false          // clear any previous report when starting a new session
                showLiveGallery = true
                liveGalleryPicker = nil
            }
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                guard let vid = try? await newItem.loadTransferable(type: VideoFile.self) else { return }
                videoURL = vid.url
                player = AVPlayer(url: vid.url)
                viewModel.analysisState = .idle
                // Upload finished — track body points and recognise the exercise right away.
                await viewModel.analyzeUpload(url: vid.url)
            }
        }
    }

    // MARK: - Workout Report Card

    private var reportCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Workout Report", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Spacer()
                Button { showReport = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }

            if reportItems.isEmpty {
                Text("No reps counted.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(reportItems) { item in
                    HStack(spacing: 12) {
                        Image(systemName: "figure.strengthtraining.traditional")
                            .foregroundStyle(.tint)
                            .frame(width: 26)
                        Text(item.name)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(item.count) reps")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                            Text(caloriesString(item.calories) + " kcal · " + WorkoutReport.durationString(item.duration))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    Divider()
                }

                HStack {
                    Text("Total calories burnt")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(caloriesString(WorkoutReport.totalCalories(reportItems)) + " kcal")
                        .font(.headline)
                        .foregroundStyle(.tint)
                        .monospacedDigit()
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Rep Timeline Card (separate from the report)

    /// A standalone card listing every counted rep with the video time range over which it occurred
    /// (e.g. "Rep 1 · Push-up   30s – 31s"). Kept as its own card so it reads as a separate entity.
    @ViewBuilder
    private var timelineCard: some View {
        if showReport && !reportReps.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Rep Timeline", systemImage: "list.bullet.rectangle")
                    .font(.headline)

                ForEach(reportReps) { rep in
                    HStack(spacing: 10) {
                        Text("Rep \(rep.index)")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .frame(minWidth: 58, alignment: .leading)
                        Text(ExerciseTypeAnalyzer.displayName(for: rep.rawLabel))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(WorkoutReport.durationString(rep.start) + " – " + WorkoutReport.durationString(rep.end))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Divider()
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    /// Trims trailing ".0" so whole numbers read cleanly (e.g. "5" not "5.0", but "2.5" stays).
    private func caloriesString(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    // MARK: - Live Camera Button

    private var liveCameraButton: some View {
        Button {
            showLiveCamera = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "camera.viewfinder")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live Camera")
                        .fontWeight(.semibold)
                    Text("Count reps in real time")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Live from Gallery Button

    private var liveGalleryButton: some View {
        PhotosPicker(selection: $liveGalleryPicker, matching: .videos, photoLibrary: .shared()) {
            HStack(spacing: 10) {
                Image(systemName: "play.rectangle.on.rectangle")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live from Gallery")
                        .fontWeight(.semibold)
                    Text("Stream a saved video, counted live")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Video Picker Card

    private var videoPickerCard: some View {
        VStack(spacing: 12) {
            if let player {
                PoseVideoView(player: player, poses: viewModel.poseFrames)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .bottomLeading) {
                        if viewModel.isClassifyingExercise {
                            Label("Tracking body points…", systemImage: "figure.walk.motion")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.black.opacity(0.55), in: Capsule())
                                .foregroundStyle(.white)
                                .padding(8)
                        } else if !viewModel.poseFrames.isEmpty {
                            Label("Body-point tracking", systemImage: "figure.walk.motion")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.black.opacity(0.55), in: Capsule())
                                .foregroundStyle(.white)
                                .padding(8)
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary)
                    .frame(height: 130)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "video.circle")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                            Text("Select a workout video (up to 10 s)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
            }

            PhotosPicker(
                selection: $pickerItem,
                matching: .videos,
                photoLibrary: .shared()
            ) {
                Label(
                    videoURL == nil ? "Select Workout Video" : "Change Video",
                    systemImage: "video.badge.plus"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Exercise Type Card

    private var exerciseTypeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Exercise Type")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Image(systemName: "figure.strengthtraining.traditional")
                    .foregroundStyle(.tint)

                TextField("Identifying exercise…", text: $viewModel.exerciseTypeText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewModel.isClassifyingExercise)

                if viewModel.isClassifyingExercise {
                    ProgressView().controlSize(.small)
                }
            }

            if let type = viewModel.exerciseType {
                Text("\(Int((type.confidence * 100).rounded()))% confidence")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if !viewModel.isClassifyingExercise {
                Text("Couldn't identify the exercise from this video.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Analyze Button

    private var analyzeButton: some View {
        Button {
            viewModel.countReps()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "figure.strengthtraining.traditional")
                Text("Count Reps")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!viewModel.canAnalyze)
        .animation(.default, value: viewModel.canAnalyze)
    }

    // MARK: - Result Card

    @ViewBuilder
    private var analysisResultCard: some View {
        switch viewModel.analysisState {
        case .done(let count):
            VStack(spacing: 6) {
                Text("\(count)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(.tint)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.4), value: count)
                Text(count == 1 ? "repetition" : "repetitions")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("counted from body-pose geometry")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .padding(.horizontal)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))

        case .error(let msg):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .padding(.top, 1)
                Text(msg)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))

        case .counting:
            progressRow(label: "Counting reps from body points…", icon: "function")

        default:
            EmptyView()
        }
    }

    private func progressRow(label: String, icon: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Video File Transferable

struct VideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { vid in
            SentTransferredFile(vid.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mov")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return VideoFile(url: dest)
        }
    }
}

// MARK: - Live from Gallery flow (setup → player)

/// Shows the body-profile setup form first, then the live-video workout screen once the user taps
/// "Start". Keeps the picked video + profile wiring out of ContentView's body.
private struct LiveGalleryFlow: View {
    let url: URL
    @Binding var profile: UserBodyProfile
    let onGenerateReport: ([ExerciseCount], [RepRecord]) -> Void

    @State private var started = false

    var body: some View {
        if started {
            LiveVideoWorkoutView(url: url, profile: profile, onGenerateReport: onGenerateReport)
        } else {
            WorkoutSetupView(profile: $profile) { started = true }
        }
    }
}

/// Shows the body-profile setup form first, then the live-camera workout screen once the user taps
/// "Start".
private struct LiveCameraFlow: View {
    @Binding var profile: UserBodyProfile
    let onGenerateReport: ([ExerciseCount], [RepRecord]) -> Void

    @State private var started = false

    var body: some View {
        if started {
            LiveWorkoutView(profile: profile, onGenerateReport: onGenerateReport)
        } else {
            WorkoutSetupView(profile: $profile) { started = true }
        }
    }
}

// MARK: - Workout Setup (height / weight / gender)

/// Optional body-metrics form shown before the video plays. Blank fields fall back to the
/// research-based defaults in `UserBodyProfile`; the values personalise the calorie estimate.
struct WorkoutSetupView: View {
    @Binding var profile: UserBodyProfile
    let onStart: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var weightText = ""
    @State private var heightText = ""
    @State private var gender: UserBodyProfile.Gender = UserBodyProfile.defaultGender

    var body: some View {
        NavigationStack {
            Form {
                Section("Your details (optional)") {
                    LabeledContent("Weight") {
                        HStack(spacing: 6) {
                            TextField("\(Int(UserBodyProfile.defaultWeightKg))", text: $weightText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                            Text("kg").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Height") {
                        HStack(spacing: 6) {
                            TextField("\(Int(UserBodyProfile.defaultHeightCm))", text: $heightText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                            Text("cm").foregroundStyle(.secondary)
                        }
                    }
                    Picker("Gender", selection: $gender) {
                        ForEach(UserBodyProfile.Gender.allCases) { g in
                            Text(g.display).tag(g)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Text("Leave weight or height blank to use defaults (\(Int(UserBodyProfile.defaultWeightKg)) kg, \(Int(UserBodyProfile.defaultHeightCm)) cm). These values personalise your calorie estimate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Workout Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { applyAndStart() }
                }
            }
        }
    }

    /// Parse the fields (falling back to defaults when blank/invalid), store the profile, and begin.
    private func applyAndStart() {
        var p = UserBodyProfile()
        if let w = Double(weightText), w > 0 { p.weightKg = w }
        if let h = Double(heightText), h > 0 { p.heightCm = h }
        p.gender = gender
        profile = p
        onStart()
    }
}

#Preview {
    ContentView()
}
