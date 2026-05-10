import Foundation
import SwiftData

enum SeedData {
    static func ensureSeeded(modelContext: ModelContext) {
        do {
            let exerciseCount = try modelContext.fetchCount(FetchDescriptor<Exercise>())
            if exerciseCount == 0 {
                seedExercises(modelContext: modelContext)
            }

            let routineCount = try modelContext.fetchCount(FetchDescriptor<WorkoutRoutine>())
            if routineCount == 0 {
                let exercises = try modelContext.fetch(FetchDescriptor<Exercise>())
                seedRoutines(modelContext: modelContext, exercises: exercises)
            }

            let settingsCount = try modelContext.fetchCount(FetchDescriptor<UserSettings>())
            if settingsCount == 0 {
                modelContext.insert(UserSettings())
            }

            let workoutCount = try modelContext.fetchCount(FetchDescriptor<WorkoutSession>())
            if workoutCount == 0 {
                let exercises = try modelContext.fetch(FetchDescriptor<Exercise>())
                seedWorkoutHistory(modelContext: modelContext, exercises: exercises)
            }
            try modelContext.save()
        } catch {
            assertionFailure("Seed failed: \(error)")
        }
    }

    static func presetExercises() -> [Exercise] {
        [
            // 胸
            Exercise(name: "杠铃卧推", englishName: "Bench Press", primaryMuscle: .chest, secondaryMuscles: [.shoulders, .arms], type: .barbell, instructions: "保持肩胛骨回缩与稳定，从坚实支撑发力下压再推起。"),
            Exercise(name: "上斜哑铃卧推", englishName: "Incline Dumbbell Press", primaryMuscle: .chest, secondaryMuscles: [.shoulders], type: .dumbbell),
            Exercise(name: "俯卧撑", englishName: "Push Up", primaryMuscle: .chest, secondaryMuscles: [.arms, .core], type: .bodyweight),
            Exercise(name: "拉索夹胸", englishName: "Cable Crossover", primaryMuscle: .chest, type: .cable),
            Exercise(name: "坐姿器械推胸", englishName: "Machine Chest Press", primaryMuscle: .chest, secondaryMuscles: [.shoulders, .arms], type: .machine),
            Exercise(name: "哑铃飞鸟", englishName: "Dumbbell Fly", primaryMuscle: .chest, type: .dumbbell),

            // 背
            Exercise(name: "硬拉", englishName: "Deadlift", primaryMuscle: .back, secondaryMuscles: [.legs, .core], type: .barbell),
            Exercise(name: "高位下拉", englishName: "Lat Pulldown", primaryMuscle: .back, secondaryMuscles: [.arms], type: .cable),
            Exercise(name: "坐姿划船", englishName: "Seated Row", primaryMuscle: .back, secondaryMuscles: [.arms], type: .machine),
            Exercise(name: "引体向上", englishName: "Pull Up", primaryMuscle: .back, secondaryMuscles: [.arms], type: .bodyweight),
            Exercise(name: "杠铃划船", englishName: "Barbell Row", primaryMuscle: .back, secondaryMuscles: [.arms], type: .barbell),
            Exercise(name: "单臂哑铃划船", englishName: "Dumbbell Row", primaryMuscle: .back, secondaryMuscles: [.arms], type: .dumbbell),
            Exercise(name: "面拉", englishName: "Face Pull", primaryMuscle: .back, secondaryMuscles: [.shoulders], type: .cable),

            // 腿
            Exercise(name: "深蹲", englishName: "Squat", primaryMuscle: .legs, secondaryMuscles: [.core], type: .barbell),
            Exercise(name: "腿举", englishName: "Leg Press", primaryMuscle: .legs, type: .plateLoaded),
            Exercise(name: "罗马尼亚硬拉", englishName: "Romanian Deadlift", primaryMuscle: .legs, secondaryMuscles: [.back], type: .barbell),
            Exercise(name: "腿屈伸", englishName: "Leg Extension", primaryMuscle: .legs, type: .machine),
            Exercise(name: "腿弯举", englishName: "Leg Curl", primaryMuscle: .legs, type: .machine),
            Exercise(name: "提踵", englishName: "Calf Raise", primaryMuscle: .legs, type: .machine),
            Exercise(name: "保加利亚分腿蹲", englishName: "Bulgarian Split Squat", primaryMuscle: .legs, type: .dumbbell),
            Exercise(name: "臀推", englishName: "Hip Thrust", primaryMuscle: .legs, type: .barbell),

            // 肩 / 推
            Exercise(name: "哑铃肩推", englishName: "Shoulder Press", primaryMuscle: .shoulders, secondaryMuscles: [.arms], type: .dumbbell),
            Exercise(name: "杠铃推举", englishName: "Overhead Press", primaryMuscle: .shoulders, secondaryMuscles: [.arms, .core], type: .barbell),
            Exercise(name: "侧平举", englishName: "Lateral Raise", primaryMuscle: .shoulders, type: .dumbbell),
            Exercise(name: "前平举", englishName: "Front Raise", primaryMuscle: .shoulders, type: .dumbbell),
            Exercise(name: "三头下压", englishName: "Triceps Pushdown", primaryMuscle: .arms, type: .cable),
            Exercise(name: "颈后臂屈伸", englishName: "Overhead Triceps Extension", primaryMuscle: .arms, type: .dumbbell),
            Exercise(name: "双杠臂屈伸", englishName: "Dips", primaryMuscle: .arms, secondaryMuscles: [.chest, .shoulders], type: .bodyweight),

            // 手臂（拉/弯举）
            Exercise(name: "哑铃弯举", englishName: "Dumbbell Curl", primaryMuscle: .arms, type: .dumbbell),
            Exercise(name: "杠铃弯举", englishName: "Barbell Curl", primaryMuscle: .arms, type: .barbell),
            Exercise(name: "锤式弯举", englishName: "Hammer Curl", primaryMuscle: .arms, type: .dumbbell),
            Exercise(name: "拉索弯举", englishName: "Cable Curl", primaryMuscle: .arms, type: .cable),

            // 核心
            Exercise(name: "平板支撑", englishName: "Plank", primaryMuscle: .core, type: .bodyweight, defaultWeightMode: .timeBased),
            Exercise(name: "卷腹", englishName: "Crunch", primaryMuscle: .core, type: .bodyweight),
            Exercise(name: "举腿", englishName: "Leg Raise", primaryMuscle: .core, type: .bodyweight),
            Exercise(name: "俄罗斯转体", englishName: "Russian Twist", primaryMuscle: .core, type: .bodyweight),
            Exercise(name: "腹轮", englishName: "Ab Wheel Rollout", primaryMuscle: .core, type: .bodyweight),
            Exercise(name: "拉索砍木", englishName: "Cable Woodchopper", primaryMuscle: .core, type: .cable)
        ]
    }

    private static func seedExercises(modelContext: ModelContext) {
        presetExercises().forEach(modelContext.insert)
    }

    private static func seedRoutines(modelContext: ModelContext, exercises: [Exercise]) {
        func lookup(_ name: String) -> Exercise? { exercises.first { $0.name == name } }

        let legs = WorkoutRoutine(name: "腿部训练", note: "下肢力量与维度训练")
        legs.exercises = [
            routineExercise(lookup("深蹲"), sets: 4, reps: 6, weight: 80, order: 0),
            routineExercise(lookup("腿举"), sets: 3, reps: 10, weight: 140, order: 1),
            routineExercise(lookup("罗马尼亚硬拉"), sets: 3, reps: 8, weight: 70, order: 2),
            routineExercise(lookup("腿屈伸"), sets: 3, reps: 12, weight: 40, order: 3),
            routineExercise(lookup("提踵"), sets: 4, reps: 15, weight: 60, order: 4)
        ].compactMap { $0 }

        let chest = WorkoutRoutine(name: "胸部训练", note: "胸部主导训练日")
        chest.exercises = [
            routineExercise(lookup("杠铃卧推"), sets: 4, reps: 6, weight: 60, order: 0),
            routineExercise(lookup("上斜哑铃卧推"), sets: 3, reps: 8, weight: 22.5, order: 1),
            routineExercise(lookup("坐姿器械推胸"), sets: 3, reps: 10, weight: 40, order: 2),
            routineExercise(lookup("拉索夹胸"), sets: 3, reps: 12, weight: 15, order: 3),
            routineExercise(lookup("俯卧撑"), sets: 3, reps: 15, weight: 0, order: 4)
        ].compactMap { $0 }

        let back = WorkoutRoutine(name: "背部训练", note: "背部厚度与宽度")
        back.exercises = [
            routineExercise(lookup("硬拉"), sets: 3, reps: 5, weight: 100, order: 0),
            routineExercise(lookup("引体向上"), sets: 3, reps: 8, weight: 0, order: 1),
            routineExercise(lookup("杠铃划船"), sets: 3, reps: 8, weight: 60, order: 2),
            routineExercise(lookup("高位下拉"), sets: 3, reps: 10, weight: 50, order: 3),
            routineExercise(lookup("面拉"), sets: 3, reps: 15, weight: 20, order: 4)
        ].compactMap { $0 }

        let core = WorkoutRoutine(name: "核心训练", note: "腹部力量与稳定性")
        core.exercises = [
            routineExercise(lookup("平板支撑"), sets: 3, reps: 0, weight: 0, order: 0, rest: 60),
            routineExercise(lookup("卷腹"), sets: 3, reps: 20, weight: 0, order: 1, rest: 60),
            routineExercise(lookup("举腿"), sets: 3, reps: 15, weight: 0, order: 2, rest: 60),
            routineExercise(lookup("俄罗斯转体"), sets: 3, reps: 20, weight: 0, order: 3, rest: 60),
            routineExercise(lookup("拉索砍木"), sets: 3, reps: 12, weight: 15, order: 4, rest: 60)
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
        let names = ["推日", "拉日", "腿日", "上肢训练"]
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
                name: names.randomElement() ?? "训练",
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
