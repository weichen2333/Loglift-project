import Foundation
import SwiftData
import Observation

@Observable
final class ExerciseLibraryViewModel {
    var searchText = ""
    var selectedMuscle: MuscleGroup?
    var selectedType: ExerciseType?

    func filteredExercises(_ exercises: [Exercise]) -> [Exercise] {
        exercises.filter { exercise in
            let matchesSearch = searchText.isEmpty || exercise.name.localizedCaseInsensitiveContains(searchText) || (exercise.englishName?.localizedCaseInsensitiveContains(searchText) ?? false)
            let matchesMuscle = selectedMuscle == nil || exercise.primaryMuscle == selectedMuscle
            let matchesType = selectedType == nil || exercise.type == selectedType
            return matchesSearch && matchesMuscle && matchesType
        }.sorted { $0.name < $1.name }
    }

    func addExercise(modelContext: ModelContext, name: String, muscle: MuscleGroup, type: ExerciseType) {
        let exercise = Exercise(name: name, primaryMuscle: muscle, type: type, isCustom: true)
        modelContext.insert(exercise)
        try? modelContext.save()
    }

    func deleteIfCustom(_ exercise: Exercise, modelContext: ModelContext) {
        guard exercise.isCustom else { return }
        modelContext.delete(exercise)
        try? modelContext.save()
    }
}

@Observable
final class RoutineViewModel {
    func createRoutine(name: String, note: String, modelContext: ModelContext) -> WorkoutRoutine {
        let routine = WorkoutRoutine(name: name.trimmingCharacters(in: .whitespacesAndNewlines), note: note)
        modelContext.insert(routine)
        try? modelContext.save()
        return routine
    }

    func startWorkout(from routine: WorkoutRoutine, exercises exerciseLibrary: [Exercise], modelContext: ModelContext) -> WorkoutSession {
        let workoutExercises = routine.exercises.sorted { $0.sortOrder < $1.sortOrder }.enumerated().map { index, routineExercise in
            let exercise = exerciseLibrary.first { $0.id == routineExercise.exerciseId }
            let mode = exercise?.defaultWeightMode ?? .sameWeight
            let sets = (1...routineExercise.targetSets).map { setIndex in
                SetRecord(
                    exerciseId: routineExercise.exerciseId,
                    setIndex: setIndex,
                    setType: routineExercise.enableWarmupSets && setIndex == 1 ? .warmup : .normal,
                    targetReps: routineExercise.targetReps,
                    actualReps: routineExercise.targetReps,
                    weightMode: mode,
                    weight: routineExercise.targetWeight,
                    leftWeight: mode == .leftRightSeparate ? routineExercise.targetWeight : 0,
                    rightWeight: mode == .leftRightSeparate ? routineExercise.targetWeight : 0
                )
            }
            return WorkoutExercise(
                exerciseId: routineExercise.exerciseId,
                exerciseName: routineExercise.exerciseName,
                primaryMuscle: exercise?.primaryMuscle ?? .fullBody,
                exerciseType: exercise?.type ?? .other,
                sortOrder: index,
                defaultRestSeconds: routineExercise.restSeconds,
                sets: sets
            )
        }
        let session = WorkoutSession(name: routine.name, source: .routine, status: .active, exercises: workoutExercises)
        modelContext.insert(session)
        try? modelContext.save()
        return session
    }

    func duplicate(_ routine: WorkoutRoutine, modelContext: ModelContext) {
        let copy = WorkoutRoutine(name: "\(routine.name) Copy", note: routine.note)
        copy.exercises = routine.exercises.map {
            RoutineExercise(
                exerciseId: $0.exerciseId,
                exerciseName: $0.exerciseName,
                targetSets: $0.targetSets,
                targetReps: $0.targetReps,
                targetWeight: $0.targetWeight,
                restSeconds: $0.restSeconds,
                sortOrder: $0.sortOrder,
                enableWarmupSets: $0.enableWarmupSets,
                enableRampingWeight: $0.enableRampingWeight
            )
        }
        modelContext.insert(copy)
        try? modelContext.save()
    }

    func addExercise(_ exercise: Exercise, to routine: WorkoutRoutine, modelContext: ModelContext) {
        let item = RoutineExercise(
            exerciseId: exercise.id,
            exerciseName: exercise.name,
            targetSets: 3,
            targetReps: 10,
            targetWeight: 0,
            restSeconds: 90,
            sortOrder: routine.exercises.count
        )
        routine.exercises.append(item)
        routine.updatedAt = Date()
        try? modelContext.save()
    }

    func deleteExercises(at offsets: IndexSet, from routine: WorkoutRoutine, modelContext: ModelContext) {
        let sorted = routine.exercises.sorted { $0.sortOrder < $1.sortOrder }
        for offset in offsets {
            modelContext.delete(sorted[offset])
        }
        renumber(routine)
        routine.updatedAt = Date()
        try? modelContext.save()
    }

    func moveExercises(from source: IndexSet, to destination: Int, in routine: WorkoutRoutine, modelContext: ModelContext) {
        var sorted = routine.exercises.sorted { $0.sortOrder < $1.sortOrder }
        let moving = source.map { sorted[$0] }
        for index in source.sorted(by: >) {
            sorted.remove(at: index)
        }
        let adjustedDestination = destination - source.filter { $0 < destination }.count
        sorted.insert(contentsOf: moving, at: min(max(0, adjustedDestination), sorted.count))
        for (index, exercise) in sorted.enumerated() {
            exercise.sortOrder = index
        }
        routine.updatedAt = Date()
        try? modelContext.save()
    }

    func delete(_ routine: WorkoutRoutine, modelContext: ModelContext) {
        modelContext.delete(routine)
        try? modelContext.save()
    }

    private func renumber(_ routine: WorkoutRoutine) {
        for (index, exercise) in routine.exercises.sorted(by: { $0.sortOrder < $1.sortOrder }).enumerated() {
            exercise.sortOrder = index
        }
    }
}

@Observable
final class WorkoutSessionViewModel {
    var restTimer = RestTimerManager()
    var currentWorkout: WorkoutSession?

    func startEmptyWorkout(modelContext: ModelContext) -> WorkoutSession {
        let session = WorkoutSession(name: "Quick Workout", source: .manual, status: .active)
        modelContext.insert(session)
        currentWorkout = session
        sync(session)
        try? modelContext.save()
        return session
    }

    func addExercise(_ exercise: Exercise, to session: WorkoutSession, modelContext: ModelContext) {
        let workoutExercise = WorkoutExercise(
            exerciseId: exercise.id,
            exerciseName: exercise.name,
            primaryMuscle: exercise.primaryMuscle,
            exerciseType: exercise.type,
            sortOrder: session.exercises.count,
            sets: [SetRecord(exerciseId: exercise.id, setIndex: 1, actualReps: 10, weightMode: exercise.defaultWeightMode)]
        )
        session.exercises.append(workoutExercise)
        try? modelContext.save()
        sync(session)
    }

    func addSet(to workoutExercise: WorkoutExercise, modelContext: ModelContext) {
        let sorted = workoutExercise.sets.sorted { $0.setIndex < $1.setIndex }
        let last = sorted.last
        let newSet = SetRecord(
            exerciseId: workoutExercise.exerciseId,
            setIndex: sorted.count + 1,
            setType: last?.setType ?? .normal,
            targetReps: last?.targetReps ?? 10,
            actualReps: last?.actualReps ?? 10,
            weightMode: last?.weightMode ?? WeightMode.defaultMode(for: workoutExercise.exerciseType),
            weight: last?.weight ?? 0,
            leftWeight: last?.leftWeight ?? 0,
            rightWeight: last?.rightWeight ?? 0,
            bodyweightAdditionalLoad: last?.bodyweightAdditionalLoad ?? 0,
            assistanceWeight: last?.assistanceWeight ?? 0,
            machineLevel: last?.machineLevel,
            durationSeconds: last?.durationSeconds ?? 0,
            distanceMeters: last?.distanceMeters ?? 0,
            rpe: last?.rpe
        )
        workoutExercise.sets.append(newSet)
        try? modelContext.save()
    }

    func deleteSet(_ set: SetRecord, from workoutExercise: WorkoutExercise, modelContext: ModelContext) {
        workoutExercise.sets.removeAll { $0.id == set.id }
        modelContext.delete(set)
        renumberSets(for: workoutExercise)
        try? modelContext.save()
    }

    func deleteExercise(_ workoutExercise: WorkoutExercise, from session: WorkoutSession, modelContext: ModelContext) {
        session.exercises.removeAll { $0.id == workoutExercise.id }
        modelContext.delete(workoutExercise)
        for (index, exercise) in session.exercises.sorted(by: { $0.sortOrder < $1.sortOrder }).enumerated() {
            exercise.sortOrder = index
        }
        try? modelContext.save()
        sync(session)
    }

    func complete(_ set: SetRecord, in session: WorkoutSession, restSeconds: Int, autoStartRest: Bool, modelContext: ModelContext) {
        set.toggleCompletion()
        if set.isCompleted && autoStartRest {
            restTimer.start(seconds: restSeconds)
        }
        try? modelContext.save()
        sync(session)
    }

    func completeNextSet(in session: WorkoutSession, autoStartRest: Bool, modelContext: ModelContext) {
        for exercise in session.exercises.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            if let set = exercise.sets.sorted(by: { $0.setIndex < $1.setIndex }).first(where: { !$0.isCompleted }) {
                complete(set, in: session, restSeconds: exercise.defaultRestSeconds, autoStartRest: autoStartRest, modelContext: modelContext)
                return
            }
        }
    }

    func pause(_ session: WorkoutSession, modelContext: ModelContext) {
        session.status = .paused
        try? modelContext.save()
        HealthKitManager.shared.pauseWorkout()
        sync(session)
    }

    func resume(_ session: WorkoutSession, modelContext: ModelContext) {
        session.status = .active
        try? modelContext.save()
        HealthKitManager.shared.resumeWorkout()
        sync(session)
    }

    func finish(_ session: WorkoutSession, modelContext: ModelContext, writeToHealth: Bool = true, healthKitWorkoutUUID: UUID? = nil) async {
        session.status = .completed
        session.endedAt = Date()
        let hk = HealthKitManager.shared
        if session.heartRateSamples.isEmpty {
            session.heartRateSamples = hk.liveHeartRateSamples
        }
        session.averageHeartRate = hk.averageHeartRate ?? session.averageHeartRate
        session.maxHeartRate = session.heartRateSamples.map(\.bpm).max() ?? session.maxHeartRate
        session.minHeartRate = session.heartRateSamples.map(\.bpm).min() ?? session.minHeartRate
        session.activeEnergyKcal = hk.activeEnergyKcal ?? session.activeEnergyKcal
        let endedWorkoutUUID: UUID?
        if healthKitWorkoutUUID == nil {
            endedWorkoutUUID = await hk.endWorkout()
        } else {
            endedWorkoutUUID = nil
        }
        session.healthKitWorkoutUUID = healthKitWorkoutUUID ?? endedWorkoutUUID ?? session.healthKitWorkoutUUID
        if writeToHealth && session.healthKitWorkoutUUID == nil {
            session.healthKitWorkoutUUID = await hk.saveWorkoutToHealthKit(session: session)
        }
        try? modelContext.save()
        sync(session)
    }

    func delete(_ session: WorkoutSession, modelContext: ModelContext) {
        modelContext.delete(session)
        try? modelContext.save()
    }

    func deleteAllWorkoutHistory(modelContext: ModelContext) throws {
        try modelContext.delete(model: WorkoutSession.self)
        try modelContext.save()
    }

    func importHealthWorkouts(_ workouts: [ImportedHealthWorkout], existingSessions: [WorkoutSession], modelContext: ModelContext) async -> Int {
        let existingIds = Set(existingSessions.compactMap(\.healthKitWorkoutUUID))
        var inserted = 0

        for workout in workouts where !existingIds.contains(workout.id) {
            let heartRateSamples = await HealthKitManager.shared.fetchHeartRateSamples(start: workout.startDate, end: workout.endDate)
            let session = WorkoutSession(
                name: "Apple Health Strength",
                startedAt: workout.startDate,
                endedAt: workout.endDate,
                workoutDate: workout.startDate,
                source: .importedHealthKit,
                status: .completed,
                exercises: [],
                heartRateSamples: heartRateSamples,
                averageHeartRate: AggregationManager.average(heartRateSamples.map(\.bpm)),
                maxHeartRate: heartRateSamples.map(\.bpm).max(),
                minHeartRate: heartRateSamples.map(\.bpm).min(),
                activeEnergyKcal: workout.activeEnergyKcal,
                healthKitWorkoutUUID: workout.id,
                note: "Imported from Apple Health."
            )
            modelContext.insert(session)
            inserted += 1
        }

        try? modelContext.save()
        return inserted
    }

    private func renumberSets(for workoutExercise: WorkoutExercise) {
        let sorted = workoutExercise.sets.sorted { $0.setIndex < $1.setIndex }
        for (index, set) in sorted.enumerated() {
            set.setIndex = index + 1
        }
    }

    private func sync(_ session: WorkoutSession) {
        let firstIncompleteExercise = session.exercises.sorted { $0.sortOrder < $1.sortOrder }.first { exercise in
            exercise.sets.contains { !$0.isCompleted }
        }
        let firstIncompleteSet = firstIncompleteExercise?.sets.sorted { $0.setIndex < $1.setIndex }.first { !$0.isCompleted }
        WatchConnectivityManager.shared.send(state: WorkoutSyncState(
            workoutId: session.id,
            name: session.name,
            status: session.status,
            elapsedSeconds: session.duration,
            currentExerciseName: firstIncompleteExercise?.exerciseName,
            currentSetIndex: firstIncompleteSet?.setIndex,
            completedSets: session.completedSetCount,
            currentHeartRate: HealthKitManager.shared.currentHeartRate,
            averageHeartRate: HealthKitManager.shared.averageHeartRate ?? session.averageHeartRate,
            activeEnergyKcal: HealthKitManager.shared.activeEnergyKcal ?? session.activeEnergyKcal,
            restRemainingSeconds: restTimer.remainingSeconds
        ))
    }
}

@Observable
final class CalendarViewModel {
    var selectedDate = Date()

    func sessions(on date: Date, from sessions: [WorkoutSession], calendar: Calendar = .current) -> [WorkoutSession] {
        sessions.filter { calendar.isDate($0.workoutDate, inSameDayAs: date) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func daysInDisplayedMonth(calendar: Calendar = .current) -> [Date] {
        guard let interval = calendar.dateInterval(of: .month, for: selectedDate),
              let range = calendar.range(of: .day, in: .month, for: selectedDate) else { return [] }
        return range.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: interval.start)
        }
    }

    func monthGridDays(calendar: Calendar = .current) -> [Date?] {
        let days = daysInDisplayedMonth(calendar: calendar)
        guard let first = days.first else { return [] }
        let leadingSpaces = calendar.component(.weekday, from: first) - calendar.firstWeekday
        let normalizedLeadingSpaces = (leadingSpaces + 7) % 7
        return Array(repeating: nil, count: normalizedLeadingSpaces) + days.map(Optional.some)
    }

    func sessionsInDisplayedMonth(from sessions: [WorkoutSession], calendar: Calendar = .current) -> [WorkoutSession] {
        guard let interval = calendar.dateInterval(of: .month, for: selectedDate) else { return [] }
        return AggregationManager.completedSessions(sessions)
            .filter { interval.contains($0.workoutDate) }
            .sorted { $0.workoutDate > $1.workoutDate }
    }
}

enum ProgressTimeRange: String, CaseIterable, Identifiable {
    case fourWeeks = "4W"
    case twelveWeeks = "12W"
    case sixMonths = "6M"
    case all = "All"

    var id: String { rawValue }

    var dateComponent: DateComponents? {
        switch self {
        case .fourWeeks: DateComponents(day: -28)
        case .twelveWeeks: DateComponents(day: -84)
        case .sixMonths: DateComponents(month: -6)
        case .all: nil
        }
    }
}

enum ProgressTrendMetric: String, CaseIterable, Identifiable {
    case frequency = "Frequency"
    case volume = "Volume"
    case duration = "Duration"
    case sets = "Sets"

    var id: String { rawValue }
}

@Observable
final class ProgressViewModel {
    var selectedExerciseId: UUID?
    var selectedRange: ProgressTimeRange = .twelveWeeks
    var selectedTrendMetric: ProgressTrendMetric = .volume

    func filteredSessions(_ sessions: [WorkoutSession], calendar: Calendar = .current) -> [WorkoutSession] {
        let completed = AggregationManager.completedSessions(sessions)
        guard let component = selectedRange.dateComponent,
              let start = calendar.date(byAdding: component, to: Date()) else { return completed }
        return completed.filter { $0.workoutDate >= start }
    }

    func weeklySummaries(from sessions: [WorkoutSession]) -> [WeeklySummary] {
        AggregationManager.weeklySummaries(from: filteredSessions(sessions))
    }

    func muscleVolumes(from sessions: [WorkoutSession]) -> [MuscleVolume] {
        AggregationManager.muscleGroupVolume(from: filteredSessions(sessions))
    }

    func heartRateSamples(from sessions: [WorkoutSession]) -> [HeartRateSample] {
        filteredSessions(sessions).flatMap(\.heartRateSamples).filter { $0.bpm.isFinite && $0.bpm > 0 }
    }

    func exerciseTrend(exerciseId: UUID?, sessions: [WorkoutSession]) -> [(date: Date, weight: Double, oneRM: Double, volume: Double)] {
        guard let exerciseId else { return [] }
        return filteredSessions(sessions).sorted { $0.workoutDate < $1.workoutDate }.compactMap { session in
            let sets = session.exercises.filter { $0.exerciseId == exerciseId }.flatMap(\.sets).filter(\.isCompleted)
            guard !sets.isEmpty else { return nil }
            let topWeight = sets.map { $0.weightMode == .leftRightSeparate ? $0.leftWeight + $0.rightWeight : $0.weight }.max() ?? 0
            return (session.workoutDate, topWeight, OneRepMaxCalculator.bestEstimatedOneRepMax(from: sets), sets.reduce(0) { $0 + VolumeCalculator.volume(for: $1) })
        }
    }
}
