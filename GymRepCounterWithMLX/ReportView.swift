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

/// The person's body metrics used to personalise the calorie estimate. All fields have research-
/// based defaults so a value is always available even when the user leaves the setup form blank.
struct UserBodyProfile: Equatable {
    enum Gender: String, CaseIterable, Identifiable {
        case male, female
        var id: String { rawValue }
        var display: String { self == .male ? "Male" : "Female" }
    }

    // Defaults ≈ global adult reference: the classic 70 kg "reference man", ~170 cm average adult
    // height, male (the Mifflin-St Jeor +5 baseline). Used whenever an input is missing.
    static let defaultWeightKg = 70.0
    static let defaultHeightCm = 170.0
    static let defaultGender: Gender = .male

    var weightKg: Double = defaultWeightKg
    var heightCm: Double = defaultHeightCm
    var gender: Gender = defaultGender
}

enum WorkoutReport {
    /// The exercises we report on, in display order (standing/walking are never counted).
    static let tracked = ["pushup", "pullup", "squat", "skipping", "legraise", "squatpress"]

    // MARK: - Calorie model
    //
    // Energy is estimated with the ACSM/Compendium MET model, but with the fixed 3.5 ml/kg/min
    // resting term replaced by a *personalised* resting metabolic rate so the result depends on the
    // person's weight, height and sex (not weight alone):
    //
    //     kcal(exercise) = reps × MET(exercise) × RMR(kcal/min) × repDuration(min)
    //     RMR(kcal/min)  = MifflinStJeorBMR(weight, height, sex, age) / 1440
    //
    // MET values are from the 2024 Compendium of Physical Activities; per-rep durations are tempo
    // approximations; age is fixed at an adult default (not collected from the user).

    /// MET (metabolic equivalent) per exercise — 2024 Compendium of Physical Activities.
    static let met: [String: Double] = [
        "pushup": 7.5,      // calisthenics, vigorous effort
        "pullup": 8.0,      // calisthenics, vigorous (upper-body, demanding)
        "squat": 5.0,       // resistance training, squats
        "skipping": 11.0,   // rope skipping, general
        "legraise": 6.5,    // body-weight resistance, high intensity (core)
        "squatpress": 6.0,  // body-weight circuit / compound movement
    ]

    /// Approximate time to perform one rep of each exercise, in seconds (tempo assumption).
    static let secondsPerRep: [String: Double] = [
        "pushup": 2.0, "pullup": 3.0, "squat": 3.0,
        "skipping": 0.5, "legraise": 3.0, "squatpress": 3.5,
    ]

    /// Age assumed for the resting-rate estimate (not collected from the user).
    static let assumedAge = 30.0

    /// Resting energy expenditure in kcal/min from the Mifflin-St Jeor BMR equation — this is what
    /// brings height and sex (and weight) into the estimate.
    static func restingKcalPerMinute(_ p: UserBodyProfile) -> Double {
        let sexConstant = p.gender == .male ? 5.0 : -161.0
        let bmrPerDay = 10 * p.weightKg + 6.25 * p.heightCm - 5 * assumedAge + sexConstant
        return bmrPerDay / 1440   // 1440 minutes per day
    }

    /// kcal burnt for a single rep of `raw`, given the person's body profile.
    static func kcalPerRep(_ raw: String, profile: UserBodyProfile) -> Double {
        let metValue = met[raw] ?? 0
        let repMinutes = (secondsPerRep[raw] ?? 0) / 60
        return metValue * restingKcalPerMinute(profile) * repMinutes
    }

    /// Builds the report rows from the per-exercise display counts (`totals` is derived from the
    /// big on-screen counter in the view models) + per-exercise active durations. Computes calories
    /// from the displayed count via the personalised MET model, and drops zero-count exercises.
    static func items(from totals: [String: Int], durations: [String: Double],
                      profile: UserBodyProfile) -> [ExerciseCount] {
        tracked.compactMap { raw in
            // A key exists only for exercises actually detected this session; drop any with no
            // completed reps (squat-press's offset keeps it at ≥1 once detected).
            guard let count = totals[raw], count > 0 else { return nil }
            let calories = Double(count) * kcalPerRep(raw, profile: profile)
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
