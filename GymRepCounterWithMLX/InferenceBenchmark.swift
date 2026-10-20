// InferenceBenchmark.swift
// Runs the Bi-LSTM (ExerciseClassifier) over the collected model-input windows under a chosen
// MLComputeUnits configuration, measuring ONLY the neural-network forward pass:
//   • total inference time (sum of per-window model.prediction calls)
//   • inference count + average ms
//   • CPU time of the inference thread (thread_info)
//   • peak resident memory growth during inference (task_vm_info phys_footprint)
//
// Input marshaling (feature providers) and model load/warm-up are done OUTSIDE the timed region,
// so the numbers reflect inference alone. GPU / NPU / power are not included: iOS exposes no public
// per-process API for them (see CalorieModelSources.txt / earlier notes).

import CoreML
import Darwin
import Foundation

/// The four compute-unit cases offered on the home screen.
enum InferenceComputeOption: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case cpuOnly = "CPU Only"
    case cpuAndGPU = "CPU + GPU"
    case cpuAndNeuralEngine = "CPU + Neural Engine"

    var id: String { rawValue }

    var units: MLComputeUnits {
        switch self {
        case .all:                 return .all
        case .cpuOnly:             return .cpuOnly
        case .cpuAndGPU:           return .cpuAndGPU
        case .cpuAndNeuralEngine:  return .cpuAndNeuralEngine
        }
    }
}

struct InferenceBenchmarkResult: Identifiable, Sendable {
    let id = UUID()
    let configName: String
    let inferenceCount: Int
    let totalSeconds: Double
    let cpuSeconds: Double
    let peakMemoryBytes: Int64

    var avgMillis: Double { inferenceCount > 0 ? totalSeconds / Double(inferenceCount) * 1000 : 0 }
}

enum InferenceBenchmark {

    enum BenchmarkError: LocalizedError {
        case noModel, noData
        var errorDescription: String? {
            switch self {
            case .noModel: return "ExerciseClassifier.mlmodelc not found in the app bundle."
            case .noData:  return "No collected data. Use \u{201C}Collect Data\u{201D} first."
            }
        }
    }

    /// Run inference over `windows` with the given compute-unit option. Synchronous and CPU-bound;
    /// call it off the main thread.
    static func run(option: InferenceComputeOption, windows: [ResampledWindow]) throws -> InferenceBenchmarkResult {
        guard !windows.isEmpty else { throw BenchmarkError.noData }
        guard let url = Bundle.main.url(forResource: "ExerciseClassifier", withExtension: "mlmodelc") else {
            throw BenchmarkError.noModel
        }
        let classifier = try PoseExerciseClassifier(modelURL: url, computeUnits: option.units)

        // Marshal every input up front — excluded from the timed region.
        let providers = try windows.map { try classifier.featureProvider(for: $0) }

        // Warm up (weight load / first-run graph compilation) — excluded from timing.
        if let first = providers.first { _ = try classifier.rawPredict(first) }

        let cpuStart = threadCPUSeconds()
        let footprintBaseline = footprintBytes()
        var peakFootprint = footprintBaseline
        var totalNanos: UInt64 = 0

        for provider in providers {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = try classifier.rawPredict(provider)
            let t1 = DispatchTime.now().uptimeNanoseconds
            totalNanos &+= (t1 &- t0)
            let footprint = footprintBytes()
            if footprint > peakFootprint { peakFootprint = footprint }
        }

        let cpuEnd = threadCPUSeconds()

        return InferenceBenchmarkResult(
            configName: option.rawValue,
            inferenceCount: providers.count,
            totalSeconds: Double(totalNanos) / 1_000_000_000,
            cpuSeconds: max(0, cpuEnd - cpuStart),
            peakMemoryBytes: max(0, peakFootprint - footprintBaseline)
        )
    }

    // MARK: - mach measurement helpers

    /// CPU time (user + system) consumed by the calling thread, in seconds.
    private static func threadCPUSeconds() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
        let system = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
        return user + system
    }

    /// Current resident memory footprint of the process, in bytes.
    private static func footprintBytes() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
}
