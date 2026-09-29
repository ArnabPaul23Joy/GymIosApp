// ReportView.swift
// Workout report model + builder. The report is shown inline on the main screen
// (ContentView.reportCard); there is no separate report screen.

import SwiftUI

struct ExerciseCount: Identifiable {
    let id = UUID()
    let name: String
    let count: Int
}

enum WorkoutReport {
    /// The exercises we report on, in display order (standing/walking are never counted).
    static let tracked = ["pushup", "pullup", "squat", "skipping", "legraise", "squatpress"]

    /// Builds the report rows from cumulative raw reps, applying the squat-press display offset
    /// and dropping any exercise with a zero displayed count.
    static func items(from totals: [String: Int]) -> [ExerciseCount] {
        tracked.compactMap { raw in
            // A key exists only for exercises that were actually detected this session (the offset
            // for squat-press must survive even when its raw count is 0).
            guard let rawCount = totals[raw] else { return nil }
            let count = rawCount + GeometricRepCounter.displayOffset(for: raw)
            guard count > 0 else { return nil }   // detected but no completed reps → don't list
            return ExerciseCount(name: ExerciseTypeAnalyzer.displayName(for: raw), count: count)
        }
    }
}
