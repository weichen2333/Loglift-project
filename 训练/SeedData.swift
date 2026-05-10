import Foundation
import SwiftData

enum SeedData {
    static func ensureSeeded(modelContext: ModelContext) {
        do {
            let exerciseCount = try modelContext.fetchCount(FetchDescriptor<Exercise>())
            if exerciseCount == 0 {
                seedExercises(modelContext: modelContext)
            }
            let exercises = try modelContext.fetch(FetchDescriptor<Exercise>())
            applyPresetDefaults(to: exercises)

            let routineCount = try modelContext.fetchCount(FetchDescriptor<WorkoutRoutine>())
            if routineCount == 0 {
                seedRoutines(modelContext: modelContext, exercises: exercises)
            }

            let settingsCount = try modelContext.fetchCount(FetchDescriptor<UserSettings>())
            if settingsCount == 0 {
                modelContext.insert(UserSettings())
            }

            let workoutCount = try modelContext.fetchCount(FetchDescriptor<WorkoutSession>())
            if workoutCount == 0 {
                seedWorkoutHistory(modelContext: modelContext, exercises: exercises)
            }
            try modelContext.save()
        } catch {
            assertionFailure("Seed failed: \(error)")
        }
    }

    static func presetExercises() -> [Exercise] {
        [
            // Chest
            Exercise(name: "Bench Press", primaryMuscle: .chest, secondaryMuscles: [.shoulders, .arms], type: .barbell, instructions: "Keep shoulder blades retracted and press from a stable base."),
            Exercise(name: "Incline Dumbbell Press", primaryMuscle: .chest, secondaryMuscles: [.shoulders], type: .dumbbell),
            Exercise(name: "Push Up", primaryMuscle: .chest, secondaryMuscles: [.arms, .core], type: .bodyweight),
            Exercise(name: "Cable Crossover", primaryMuscle: .chest, type: .cable),
            Exercise(name: "Machine Chest Press", primaryMuscle: .chest, secondaryMuscles: [.shoulders, .arms], type: .machine),
            Exercise(name: "Dumbbell Fly", primaryMuscle: .chest, type: .dumbbell),

            // Back
            Exercise(name: "Deadlift", primaryMuscle: .back, secondaryMuscles: [.legs, .core], type: .barbell),
            Exercise(name: "Lat Pulldown", primaryMuscle: .back, secondaryMuscles: [.arms], type: .cable),
            Exercise(name: "Seated Row", primaryMuscle: .back, secondaryMuscles: [.arms], type: .machine),
            Exercise(name: "Pull Up", primaryMuscle: .back, secondaryMuscles: [.arms], type: .bodyweight),
            Exercise(name: "Barbell Row", primaryMuscle: .back, secondaryMuscles: [.arms], type: .barbell),
            Exercise(name: "Dumbbell Row", primaryMuscle: .back, secondaryMuscles: [.arms], type: .dumbbell),
            Exercise(name: "Face Pull", primaryMuscle: .back, secondaryMuscles: [.shoulders], type: .cable),

            // Legs
            Exercise(name: "Squat", primaryMuscle: .legs, secondaryMuscles: [.core], type: .barbell),
            Exercise(name: "Leg Press", primaryMuscle: .legs, type: .plateLoaded),
            Exercise(name: "Romanian Deadlift", primaryMuscle: .legs, secondaryMuscles: [.back], type: .barbell),
            Exercise(name: "Leg Extension", primaryMuscle: .legs, type: .machine),
            Exercise(name: "Leg Curl", primaryMuscle: .legs, type: .machine),
            Exercise(name: "Calf Raise", primaryMuscle: .legs, type: .machine),
            Exercise(name: "Bulgarian Split Squat", primaryMuscle: .legs, type: .dumbbell),
            Exercise(name: "Hip Thrust", primaryMuscle: .legs, type: .barbell),

            // Shoulders / Push
            Exercise(name: "Shoulder Press", primaryMuscle: .shoulders, secondaryMuscles: [.arms], type: .dumbbell),
            Exercise(name: "Overhead Press", primaryMuscle: .shoulders, secondaryMuscles: [.arms, .core], type: .barbell),
            Exercise(name: "Lateral Raise", primaryMuscle: .shoulders, type: .dumbbell),
            Exercise(name: "Front Raise", primaryMuscle: .shoulders, type: .dumbbell),
            Exercise(name: "Triceps Pushdown", primaryMuscle: .arms, type: .cable),
            Exercise(name: "Overhead Triceps Extension", primaryMuscle: .arms, type: .dumbbell),
            Exercise(name: "Dips", primaryMuscle: .arms, secondaryMuscles: [.chest, .shoulders], type: .bodyweight),

            // Arms (Pull/Curl)
            Exercise(name: "Dumbbell Curl", primaryMuscle: .arms, type: .dumbbell),
            Exercise(name: "Barbell Curl", primaryMuscle: .arms, type: .barbell),
            Exercise(name: "Hammer Curl", primaryMuscle: .arms, type: .dumbbell),
            Exercise(name: "Cable Curl", primaryMuscle: .arms, type: .cable),

            // Core
            Exercise(name: "Plank", primaryMuscle: .core, type: .bodyweight, defaultWeightMode: .timeBased),
            Exercise(name: "Crunch", primaryMuscle: .core, type: .bodyweight),
            Exercise(name: "Leg Raise", primaryMuscle: .core, type: .bodyweight),
            Exercise(name: "Russian Twist", primaryMuscle: .core, type: .bodyweight),
            Exercise(name: "Ab Wheel Rollout", primaryMuscle: .core, type: .bodyweight),
            Exercise(name: "Cable Woodchopper", primaryMuscle: .core, type: .cable)
        ]
    }

    private static func seedExercises(modelContext: ModelContext) {
        presetExercises().forEach(modelContext.insert)
    }

    private static func applyPresetDefaults(to exercises: [Exercise]) {
        let leftRightNames: Set<String> = [
            "Incline Dumbbell Press",
            "Dumbbell Fly",
            "Dumbbell Row",
            "Bulgarian Split Squat",
            "Shoulder Press",
            "Lateral Raise",
            "Front Raise",
            "Overhead Triceps Extension",
            "Dumbbell Curl",
            "Hammer Curl"
        ]

        for exercise in exercises where !exercise.isCustom {
            let tracksLeftRight = leftRightNames.contains(exercise.name) || exercise.type == .dumbbell || exercise.type == .kettlebell || exercise.type == .unilateral
            let mode: WeightMode
            switch exercise.name {
            case "Plank":
                mode = .timeBased
            default:
                mode = WeightMode.defaultMode(for: exercise.type, isUnilateral: tracksLeftRight)
            }
            exercise.tracksLeftRightSeparately = tracksLeftRight
            exercise.defaultWeightMode = mode
        }
    }

    private static func seedRoutines(modelContext: ModelContext, exercises: [Exercise]) {
        func lookup(_ name: String) -> Exercise? { exercises.first { $0.name == name } }

        let legs = WorkoutRoutine(name: "Legs", note: "Lower body strength and hypertrophy")
        legs.exercises = [
            routineExercise(lookup("Squat"), sets: 4, reps: 6, weight: 80, order: 0),
            routineExercise(lookup("Leg Press"), sets: 3, reps: 10, weight: 140, order: 1),
            routineExercise(lookup("Romanian Deadlift"), sets: 3, reps: 8, weight: 70, order: 2),
            routineExercise(lookup("Leg Extension"), sets: 3, reps: 12, weight: 40, order: 3),
            routineExercise(lookup("Calf Raise"), sets: 4, reps: 15, weight: 60, order: 4)
        ].compactMap { $0 }

        let chest = WorkoutRoutine(name: "Chest", note: "Chest focused workout")
        chest.exercises = [
            routineExercise(lookup("Bench Press"), sets: 4, reps: 6, weight: 60, order: 0),
            routineExercise(lookup("Incline Dumbbell Press"), sets: 3, reps: 8, weight: 22.5, order: 1),
            routineExercise(lookup("Machine Chest Press"), sets: 3, reps: 10, weight: 40, order: 2),
            routineExercise(lookup("Cable Crossover"), sets: 3, reps: 12, weight: 15, order: 3),
            routineExercise(lookup("Push Up"), sets: 3, reps: 15, weight: 0, order: 4)
        ].compactMap { $0 }

        let back = WorkoutRoutine(name: "Back", note: "Back thickness and width")
        back.exercises = [
            routineExercise(lookup("Deadlift"), sets: 3, reps: 5, weight: 100, order: 0),
            routineExercise(lookup("Pull Up"), sets: 3, reps: 8, weight: 0, order: 1),
            routineExercise(lookup("Barbell Row"), sets: 3, reps: 8, weight: 60, order: 2),
            routineExercise(lookup("Lat Pulldown"), sets: 3, reps: 10, weight: 50, order: 3),
            routineExercise(lookup("Face Pull"), sets: 3, reps: 15, weight: 20, order: 4)
        ].compactMap { $0 }

        let core = WorkoutRoutine(name: "Core", note: "Abdominal strength and stability")
        core.exercises = [
            routineExercise(lookup("Plank"), sets: 3, reps: 0, weight: 0, order: 0, rest: 60),
            routineExercise(lookup("Crunch"), sets: 3, reps: 20, weight: 0, order: 1, rest: 60),
            routineExercise(lookup("Leg Raise"), sets: 3, reps: 15, weight: 0, order: 2, rest: 60),
            routineExercise(lookup("Russian Twist"), sets: 3, reps: 20, weight: 0, order: 3, rest: 60),
            routineExercise(lookup("Cable Woodchopper"), sets: 3, reps: 12, weight: 15, order: 4, rest: 60)
        ].compactMap { $0 }

        [legs, chest, back, core].forEach(modelContext.insert)
    }

    private static func routineExercise(_ exercise: Exercise?, sets: Int, reps: Int, weight: Double, order: Int, rest: Int = 90) -> RoutineExercise? {
        guard let exercise else { return nil }
        return RoutineExercise(
            exerciseId: exercise.id,
            exerciseName: exercise.name,
            targetSets: sets,
            targetReps: reps,
            targetWeight: weight,
            restSeconds: rest,
            sortOrder: order,
            enableWarmupSets: order == 0,
            enableRampingWeight: order == 0
        )
    }

    private static func seedWorkoutHistory(modelContext: ModelContext, exercises: [Exercise]) {
        let calendar = Calendar.current
        let names = ["Push Day", "Pull Day", "Leg Day", "Upper Body"]
        for offset in stride(from: 28, through: 3, by: -5) {
            let date = calendar.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
            let selected = Array(exercises.shuffled().prefix(4))
            let workoutExercises = selected.enumerated().map { index, exercise in
                let mode = exercise.defaultWeightMode
                let sets = (1...3).map { setIndex in
                    SetRecord(
                        exerciseId: exercise.id,
                        setIndex: setIndex,
                        targetReps: mode == .timeBased ? 0 : 10,
                        actualReps: mode == .timeBased ? 0 : 8 + setIndex,
                        weightMode: mode,
                        weight: mode == .timeBased ? 0 : Double(30 + index * 10 + setIndex * 2),
                        leftWeight: mode == .leftRightSeparate ? Double(10 + setIndex) : 0,
                        rightWeight: mode == .leftRightSeparate ? Double(10 + setIndex) : 0,
                        durationSeconds: mode == .timeBased ? 45 + setIndex * 10 : 0,
                        rpe: Double(6 + setIndex),
                        isCompleted: true,
                        completedAt: date.addingTimeInterval(Double(index * 900 + setIndex * 120))
                    )
                }
                return WorkoutExercise(exerciseId: exercise.id, exerciseName: exercise.name, primaryMuscle: exercise.primaryMuscle, exerciseType: exercise.type, sortOrder: index, sets: sets)
            }
            let session = WorkoutSession(
                name: names.randomElement() ?? "Workout",
                startedAt: date,
                endedAt: date.addingTimeInterval(3600 + Double(offset * 20)),
                workoutDate: date,
                source: .routine,
                status: .completed,
                exercises: workoutExercises,
                heartRateSamples: heartSamples(start: date),
                averageHeartRate: Double(118 + offset % 12),
                maxHeartRate: Double(150 + offset % 20),
                minHeartRate: 88,
                activeEnergyKcal: Double(220 + offset * 3)
            )
            modelContext.insert(session)
        }
    }

    private static func heartSamples(start: Date) -> [HeartRateSample] {
        stride(from: 0, through: 3600, by: 300).map { second in
            let wave = sin(Double(second) / 600) * 18
            return HeartRateSample(timestamp: start.addingTimeInterval(Double(second)), bpm: 118 + wave + Double(second / 600))
        }
    }
}
