// CollectDataView.swift
// Full-screen "Collect Data" screen: a picked video streamed frame-by-frame with the pose skeleton
// overlaid, extracting the Bi-LSTM's model-input windows and saving them locally. The Bi-LSTM is
// NOT run here, and there is no rep count — this only gathers the inputs the benchmark buttons use.

import CoreGraphics
import SwiftUI

@MainActor
@Observable
final class CollectDataViewModel {

    private let engine = FeatureCollectionEngine()
    private let url: URL

    var currentFrame: CGImage?
    var latestPose: PoseFrame?
    var orientedSize: CGSize = .zero
    var collectedCount = 0
    var finished = false

    private var windows: [ResampledWindow] = []
    private var saved = false

    init(url: URL) { self.url = url }

    func start() {
        finished = false
        engine.onUpdate = { [weak self] update in
            Task { @MainActor [weak self] in self?.apply(update) }
        }
        engine.onFinished = { [weak self] in
            Task { @MainActor [weak self] in self?.finish() }
        }
        engine.start(url: url)
    }

    func stop() { engine.stop() }

    /// Persist the collected windows, OVERWRITING any previous dataset. Safe to call more than once.
    func saveIfNeeded() {
        guard !saved, !windows.isEmpty else { return }
        FeatureCollectionStore.save(windows)
        saved = true
    }

    private func apply(_ update: CollectDataUpdate) {
        currentFrame = update.frame
        latestPose = update.pose
        orientedSize = update.orientedSize
        if let window = update.window {
            windows.append(window)
            collectedCount = windows.count
        }
    }

    private func finish() {
        finished = true
        saveIfNeeded()
    }
}

struct CollectDataView: View {
    @State private var viewModel: CollectDataViewModel
    @Environment(\.dismiss) private var dismiss

    init(url: URL) {
        _viewModel = State(initialValue: CollectDataViewModel(url: url))
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
        .onDisappear { viewModel.stop(); viewModel.saveIfNeeded() }
        .statusBarHidden()
    }

    private var hud: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            statusBar
        }
        .padding()
    }

    private var topBar: some View {
        HStack {
            Button {
                viewModel.stop()
                viewModel.saveIfNeeded()
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
            }
            Spacer()
            Label("Collecting features", systemImage: "square.and.arrow.down.on.square")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.black.opacity(0.4), in: Capsule())
            Spacer()
            // Balances the layout opposite the close button.
            Color.clear.frame(width: 28, height: 28)
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: viewModel.finished ? "checkmark.circle.fill" : "waveform.path.ecg")
                    .foregroundStyle(.white.opacity(0.9))
                Text(viewModel.finished ? "Saved" : "Collecting…")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(viewModel.collectedCount)")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .animation(.spring(response: 0.35), value: viewModel.collectedCount)
                    Text(viewModel.collectedCount == 1 ? "window" : "windows")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
                if viewModel.finished {
                    Button {
                        viewModel.saveIfNeeded()
                        dismiss()
                    } label: {
                        Label("Done", systemImage: "checkmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .background(.tint, in: Capsule())
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 20))
    }
}
