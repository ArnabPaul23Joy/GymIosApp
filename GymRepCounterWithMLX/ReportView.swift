// ReportView.swift
// Workout report model + builder. The report is shown inline on the main screen
// (ContentView.reportCard); there is no separate report screen.

import SwiftUI

struct ExerciseCount: Identifiable {
    let id = UUID()
    let name: String
    let count: Int
    let calories: Double   // total kcal burnt for this exercise (count × per-rep kcal)
    let duration: Double   // total seconds this exercise was active in the video
}

enum WorkoutReport {
    /// The exercises we report on, in display order (standing/walking are never counted).
    static let tracked = ["pushup", "pullup", "squat", "skipping", "legraise", "squatpress"]

    /// kcal burnt per rep, per exercise (provided values).
    static let kcalPerRep: [String: Double] = [
        "pushup": 0.3, "pullup": 1.0, "squat": 0.5,
        "legraise": 1.4, "skipping": 0.1, "squatpress": 1.8,
    ]

    /// Builds the report rows from cumulative raw reps + per-exercise active durations. Applies the
    /// squat-press display offset, computes calories from the displayed count, and drops zero-count
    /// exercises.
    static func items(from totals: [String: Int], durations: [String: Double]) -> [ExerciseCount] {
        tracked.compactMap { raw in
            // A key exists only for exercises that were actually detected this session (the offset
            // for squat-press must survive even when its raw count is 0).
            guard let rawCount = totals[raw] else { return nil }
            let count = rawCount + GeometricRepCounter.displayOffset(for: raw)
            guard count > 0 else { return nil }   // detected but no completed reps → don't list
            let calories = Double(count) * (kcalPerRep[raw] ?? 0)
            return ExerciseCount(name: ExerciseTypeAnalyzer.displayName(for: raw),
                                 count: count, calories: calories, duration: durations[raw] ?? 0)
        }
    }

    /// Sum of all per-exercise calories.
    static func totalCalories(_ items: [ExerciseCount]) -> Double {
        items.reduce(0) { $0 + $1.calories }
    }

    /// Duration with units, e.g. "45s" or "1m 05s".
    static func durationString(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        let m = t / 60, s = t % 60
        return m > 0 ? String(format: "%dm %02ds", m, s) : "\(s)s"
    }
}
