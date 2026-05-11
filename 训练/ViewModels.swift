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
        saveOrLog(modelContext)
    }

    func deleteIfCustom(_ exercise: Exercise, modelContext: ModelContext) {
        guard exercise.isCustom else { return }
        modelContext.delete(exercise)
        saveOrLog(modelContext)
    }
}

@Observable
final class RoutineViewModel {
    func createRoutine(name: String, note: String, modelContext: ModelContext) -> WorkoutRoutine {
        let routine = WorkoutRoutine(name: name.trimmingCharacters(in: .whitespacesAndNewlines), note: note)
        modelContext.insert(routine)
        saveOrLog(modelContext)
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
        saveOrLog(modelContext)
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
        saveOrLog(modelContext)
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
        saveOrLog(modelContext)
    }

    func deleteExercises(at offsets: IndexSet, from routine: WorkoutRoutine, modelContext: ModelContext) {
        let sorted = routine.exercises.sorted { $0.sortOrder < $1.sortOrder }
        for offset in offsets {
            modelContext.delete(sorted[offset])
        }
        renumber(routine)
        routine.updatedAt = Date()
        saveOrLog(modelContext)
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
        saveOrLog(modelContext)
    }

    func delete(_ routine: WorkoutRoutine, modelContext: ModelContext) {
        modelContext.delete(routine)
        saveOrLog(modelContext)
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
    var pendingPRCelebration: PRCandidate?
    var pendingValidationWarning: String?
    /// Surface for save-path failures on user-visible operations (finish / discard).
    /// Cleared via `clearSaveError()` from the UI alert button.
    var pendingSaveErrorMessage: String?
    private(set) var availableSessionsCache: [WorkoutSession] = []
    private(set) var availableRoutinesCache: [WorkoutRoutine] = []
    private(set) var oneRepMaxFormula: OneRepMaxFormula = .epley
    private(set) var hapticOnRestComplete: Bool = true
    private(set) var weightUnit: WeightUnit = .kg

    func attachContext(sessions: [WorkoutSession], routines: [WorkoutRoutine], settings: UserSettings?) {
        availableSessionsCache = sessions
        availableRoutinesCache = routines
        oneRepMaxFormula = settings?.oneRepMaxFormula ?? .epley
        hapticOnRestComplete = settings?.watchHapticOnRestComplete ?? true
        weightUnit = settings?.weightUnit ?? .kg
        if currentWorkout == nil {
            currentWorkout = sessions.first { $0.status == .active || $0.status == .paused }
        }
        if let session = currentWorkout {
            sync(session)
        }
    }

    func startEmptyWorkout(modelContext: ModelContext) -> WorkoutSession {
        let session = WorkoutSession(name: "快速训练", source: .manual, status: .active)
        modelContext.insert(session)
        currentWorkout = session
        sync(session)
        saveOrLog(modelContext)
        return session
    }

    /// Track a session created elsewhere (e.g. by `RoutineViewModel.startWorkout`) and push
    /// the initial state to the watch so the template's exercises show up immediately
    /// rather than only after the first set is completed.
    func register(activeSession session: WorkoutSession) {
        currentWorkout = session
        sync(session)
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
        saveOrLog(modelContext)
        sync(session)
    }

    func addSet(to workoutExercise: WorkoutExercise, in session: WorkoutSession, modelContext: ModelContext) {
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
        saveOrLog(modelContext)
        sync(session)
    }

    func deleteSet(_ set: SetRecord, from workoutExercise: WorkoutExercise, in session: WorkoutSession, modelContext: ModelContext) {
        workoutExercise.sets.removeAll { $0.id == set.id }
        modelContext.delete(set)
        renumberSets(for: workoutExercise)
        saveOrLog(modelContext)
        sync(session)
    }

    func deleteExercise(_ workoutExercise: WorkoutExercise, from session: WorkoutSession, modelContext: ModelContext) {
        session.exercises.removeAll { $0.id == workoutExercise.id }
        modelContext.delete(workoutExercise)
        for (index, exercise) in session.exercises.sorted(by: { $0.sortOrder < $1.sortOrder }).enumerated() {
            exercise.sortOrder = index
        }
        saveOrLog(modelContext)
        sync(session)
    }

    @discardableResult
    func complete(_ set: SetRecord, in session: WorkoutSession, restSeconds: Int, autoStartRest: Bool, modelContext: ModelContext, allowPRCelebration: Bool = true) -> PRCandidate? {
        let willComplete = !set.isCompleted
        if willComplete, let warning = validation(for: set) {
            pendingValidationWarning = warning
            return nil
        }
        set.toggleCompletion()
        var pr: PRCandidate?
        if set.isCompleted, allowPRCelebration {
            let parent = session.exercises.first { $0.sets.contains(where: { $0.id == set.id }) }
            if let parent {
                pr = TrainingInsights.detectPersonalRecord(
                    forCompleting: set,
                    exerciseId: parent.exerciseId,
                    exerciseName: parent.exerciseName,
                    in: availableSessionsCache,
                    excluding: session.id,
                    formula: oneRepMaxFormula
                )
                pendingPRCelebration = pr
            }
        }
        if set.isCompleted && autoStartRest {
            restTimer.start(seconds: restSeconds)
        }
        saveOrLog(modelContext)
        sync(session)
        return pr
    }

    func completeNextSet(in session: WorkoutSession, autoStartRest: Bool, modelContext: ModelContext) {
        for exercise in session.exercises.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            if let set = exercise.sets.sorted(by: { $0.setIndex < $1.setIndex }).first(where: { !$0.isCompleted }) {
                _ = complete(set, in: session, restSeconds: exercise.defaultRestSeconds, autoStartRest: autoStartRest, modelContext: modelContext)
                return
            }
        }
    }

    func completeSpecificSet(setId: UUID, in session: WorkoutSession, autoStartRest: Bool, modelContext: ModelContext) {
        for exercise in session.exercises {
            if let set = exercise.sets.first(where: { $0.id == setId }), !set.isCompleted {
                _ = complete(set, in: session, restSeconds: exercise.defaultRestSeconds, autoStartRest: autoStartRest, modelContext: modelContext)
                return
            }
        }
    }

    func swapExercise(_ workoutExercise: WorkoutExercise, with replacement: Exercise, in session: WorkoutSession, modelContext: ModelContext) {
        workoutExercise.exerciseId = replacement.id
        workoutExercise.exerciseName = replacement.name
        workoutExercise.primaryMuscle = replacement.primaryMuscle
        workoutExercise.exerciseType = replacement.type
        for set in workoutExercise.sets {
            set.weightMode = replacement.defaultWeightMode
        }
        saveOrLog(modelContext)
        sync(session)
    }

    func duplicate(_ session: WorkoutSession, modelContext: ModelContext) -> WorkoutSession {
        let copy = WorkoutSession(name: session.name, source: .manual, status: .active)
        copy.exercises = session.exercises.sorted { $0.sortOrder < $1.sortOrder }.enumerated().map { index, original in
            let mode = original.sets.first?.weightMode ?? WeightMode.defaultMode(for: original.exerciseType)
            let sets = original.sets.sorted { $0.setIndex < $1.setIndex }.enumerated().map { setIndex, src in
                SetRecord(
                    exerciseId: original.exerciseId,
                    setIndex: setIndex + 1,
                    setType: src.setType == .warmup ? .warmup : .normal,
                    targetReps: src.targetReps,
                    actualReps: src.actualReps,
                    weightMode: mode,
                    weight: src.weight,
                    leftWeight: src.leftWeight,
                    rightWeight: src.rightWeight,
                    bodyweightAdditionalLoad: src.bodyweightAdditionalLoad,
                    assistanceWeight: src.assistanceWeight,
                    machineLevel: src.machineLevel,
                    durationSeconds: src.durationSeconds,
                    distanceMeters: src.distanceMeters,
                    rpe: src.rpe,
                    isCompleted: false
                )
            }
            return WorkoutExercise(
                exerciseId: original.exerciseId,
                exerciseName: original.exerciseName,
                primaryMuscle: original.primaryMuscle,
                exerciseType: original.exerciseType,
                sortOrder: index,
                defaultRestSeconds: original.defaultRestSeconds,
                sets: sets
            )
        }
        modelContext.insert(copy)
        saveOrLog(modelContext)
        currentWorkout = copy
        sync(copy)
        return copy
    }

    func validation(for set: SetRecord) -> String? {
        switch set.weightMode {
        case .timeBased:
            if set.durationSeconds <= 0 {
                return "请先填写持续时间再完成此组。"
            }
        case .distanceBased:
            if set.distanceMeters <= 0 && set.durationSeconds <= 0 {
                return "请先填写距离或时间再完成此组。"
            }
        case .bodyweight, .assistedBodyweight:
            if set.actualReps <= 0 {
                return "请填写次数后再完成此组。"
            }
        case .leftRightSeparate:
            if set.actualReps <= 0 {
                return "请填写次数后再完成此组。"
            }
            if set.leftWeight + set.rightWeight <= 0 {
                return "至少填写一侧的重量。"
            }
        case .sameWeight, .machineStack, .plateLoaded, .cable:
            if set.actualReps <= 0 {
                return "请填写次数后再完成此组。"
            }
            if set.weight <= 0 {
                return "请填写大于零的重量。"
            }
        }
        return nil
    }

    func clearValidationWarning() { pendingValidationWarning = nil }
    func clearPRCelebration() { pendingPRCelebration = nil }
    func clearSaveError() { pendingSaveErrorMessage = nil }

    func pause(_ session: WorkoutSession, modelContext: ModelContext) {
        guard session.status != .paused else { return }
        session.status = .paused
        if session.pausedAt == nil {
            session.pausedAt = Date()
        }
        saveOrLog(modelContext)
        HealthKitManager.shared.pauseWorkout()
        sync(session)
    }

    func resume(_ session: WorkoutSession, modelContext: ModelContext) {
        if let pausedAt = session.pausedAt {
            session.accumulatedPausedSeconds += Date().timeIntervalSince(pausedAt)
            session.pausedAt = nil
        }
        session.status = .active
        saveOrLog(modelContext)
        HealthKitManager.shared.resumeWorkout()
        sync(session)
    }

    func discard(_ session: WorkoutSession, modelContext: ModelContext, routines: [WorkoutRoutine], hapticOnRestComplete: Bool, weightUnit: WeightUnit) {
        // Tell the watch the workout is gone before we delete the model — otherwise
        // the watch keeps showing the active screen and gets stuck.
        session.status = .cancelled
        session.endedAt = Date()
        if let pausedAt = session.pausedAt {
            session.accumulatedPausedSeconds += Date().timeIntervalSince(pausedAt)
            session.pausedAt = nil
        }
        sync(session)
        HealthKitManager.shared.pauseWorkout()
        HealthKitManager.shared.resetLiveCounters()
        if currentWorkout?.id == session.id { currentWorkout = nil }
        modelContext.delete(session)
        saveOrLog(modelContext, label: "discard workout") { [weak self] error in
            self?.pendingSaveErrorMessage = "放弃训练时未能完成保存：\(error.localizedDescription)"
        }
        broadcastIdleSnapshot(routines: routines, hapticOnRestComplete: hapticOnRestComplete, weightUnit: weightUnit)
    }

    func finish(_ session: WorkoutSession, modelContext: ModelContext, writeToHealth: Bool = true, healthKitWorkoutUUID: UUID? = nil) async {
        if let pausedAt = session.pausedAt {
            session.accumulatedPausedSeconds += Date().timeIntervalSince(pausedAt)
            session.pausedAt = nil
        }
        session.status = .completed
        session.endedAt = Date()
        let hk = HealthKitManager.shared

        // Close the watch's HKWorkoutSession first when it's still ours to close, so
        // any final samples land in HealthKit before we query it back for this session.
        let endedWorkoutUUID: UUID?
        if healthKitWorkoutUUID == nil {
            endedWorkoutUUID = await hk.endWorkout()
        } else {
            endedWorkoutUUID = nil
        }
        session.healthKitWorkoutUUID = healthKitWorkoutUUID ?? endedWorkoutUUID ?? session.healthKitWorkoutUUID

        // HealthKit is now the source of truth. Pull HR + active energy for the
        // session's time window instead of reading the in-memory singleton (which on
        // iOS is always nil because the watch is the one driving the workout).
        let windowEnd = session.endedAt ?? Date()
        if session.heartRateSamples.isEmpty {
            let samples = await hk.fetchHeartRateSamples(start: session.startedAt, end: windowEnd)
            if !samples.isEmpty {
                session.heartRateSamples = samples
            }
        }
        let bpms = session.heartRateSamples.map(\.bpm).filter { $0.isFinite && $0 > 0 }
        if !bpms.isEmpty {
            session.averageHeartRate = AggregationManager.average(bpms)
            session.maxHeartRate = bpms.max()
            session.minHeartRate = bpms.min()
        }
        if session.activeEnergyKcal == nil {
            session.activeEnergyKcal = await hk.fetchActiveEnergy(start: session.startedAt, end: windowEnd)
        }

        if writeToHealth && session.healthKitWorkoutUUID == nil {
            session.healthKitWorkoutUUID = await hk.saveWorkoutToHealthKit(session: session)
        }

        // Cleared regardless: we don't want the next workout inheriting stale state.
        hk.resetLiveCounters()

        saveOrLog(modelContext, label: "finish workout") { [weak self] error in
            self?.pendingSaveErrorMessage = "保存训练失败：\(error.localizedDescription)"
        }
        sync(session)
    }

    func delete(_ session: WorkoutSession, modelContext: ModelContext) {
        modelContext.delete(session)
        saveOrLog(modelContext)
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
                name: "健康力量训练",
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
                note: "从 Apple 健康导入。"
            )
            modelContext.insert(session)
            inserted += 1
        }

        saveOrLog(modelContext)
        return inserted
    }

    private func renumberSets(for workoutExercise: WorkoutExercise) {
        let sorted = workoutExercise.sets.sorted { $0.setIndex < $1.setIndex }
        for (index, set) in sorted.enumerated() {
            set.setIndex = index + 1
        }
    }

    func sync(_ session: WorkoutSession) {
        let sortedExercises = session.exercises.sorted { $0.sortOrder < $1.sortOrder }
        let firstIncompleteExercise = sortedExercises.first { exercise in
            exercise.sets.contains { !$0.isCompleted }
        }
        let firstIncompleteSet = firstIncompleteExercise?.sets.sorted { $0.setIndex < $1.setIndex }.first { !$0.isCompleted }
        let exerciseSnapshots: [WatchExerciseSnapshot] = sortedExercises.map { exercise in
            let sortedSets = exercise.sets.sorted { $0.setIndex < $1.setIndex }
            let nextSet = sortedSets.first(where: { !$0.isCompleted })
            let last = TrainingInsights.lastSet(for: exercise.exerciseId, in: availableSessionsCache, excluding: session.id, formula: oneRepMaxFormula)
            return WatchExerciseSnapshot(
                workoutExerciseId: exercise.id,
                exerciseName: exercise.exerciseName,
                totalSets: sortedSets.count,
                completedSets: sortedSets.filter(\.isCompleted).count,
                currentSetIndex: nextSet?.setIndex,
                targetReps: nextSet?.actualReps,
                weightText: nextSet.map { TrainingInsights.displayWeight(for: $0) },
                lastWeightText: last?.headlineText,
                lastReps: last?.reps
            )
        }
        let routineSnapshots = availableRoutinesCache.sorted { $0.name < $1.name }.map {
            WatchRoutineSnapshot(id: $0.id, name: $0.name, exerciseCount: $0.exercises.count, estimatedSets: $0.exercises.reduce(0) { $0 + $1.targetSets })
        }
        // HR / active energy during a live workout are the watch's responsibility —
        // it owns the HKWorkoutSession and the HKLiveWorkoutBuilder, and reads
        // straight from WatchHealthKitManager for the UI. The phone only carries
        // values that have been persisted onto the session itself.
        let state = WorkoutSyncState(
            workoutId: session.id,
            name: session.name,
            status: session.status,
            elapsedSeconds: session.duration,
            currentExerciseId: firstIncompleteExercise?.id,
            currentExerciseName: firstIncompleteExercise?.exerciseName,
            currentSetId: firstIncompleteSet?.id,
            currentSetIndex: firstIncompleteSet?.setIndex,
            completedSets: session.completedSetCount,
            totalSets: session.totalSetCount,
            currentHeartRate: nil,
            averageHeartRate: session.averageHeartRate,
            activeEnergyKcal: session.activeEnergyKcal,
            restRemainingSeconds: restTimer.remainingSeconds,
            restTotalSeconds: restTimer.totalSeconds,
            restEndsAt: restTimer.endDate,
            sequence: 0,
            generatedAt: Date(),
            exercises: exerciseSnapshots,
            routines: routineSnapshots,
            hapticOnRestComplete: hapticOnRestComplete,
            weightUnit: weightUnit.rawValue
        )
        WatchConnectivityManager.shared.send(state: state)
    }

    func broadcastIdleSnapshot(routines: [WorkoutRoutine], hapticOnRestComplete: Bool, weightUnit: WeightUnit) {
        let routineSnapshots = routines.sorted { $0.name < $1.name }.map {
            WatchRoutineSnapshot(id: $0.id, name: $0.name, exerciseCount: $0.exercises.count, estimatedSets: $0.exercises.reduce(0) { $0 + $1.targetSets })
        }
        let idle = WorkoutSyncState(
            workoutId: nil,
            name: "",
            status: .planned,
            elapsedSeconds: 0,
            currentExerciseId: nil,
            currentExerciseName: nil,
            currentSetId: nil,
            currentSetIndex: nil,
            completedSets: 0,
            totalSets: 0,
            currentHeartRate: nil,
            averageHeartRate: nil,
            activeEnergyKcal: nil,
            restRemainingSeconds: nil,
            restTotalSeconds: nil,
            restEndsAt: nil,
            sequence: 0,
            generatedAt: Date(),
            exercises: [],
            routines: routineSnapshots,
            hapticOnRestComplete: hapticOnRestComplete,
            weightUnit: weightUnit.rawValue
        )
        WatchConnectivityManager.shared.send(state: idle, force: true)
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

@Observable
final class DashboardViewModel {
    func recentRecords(from sessions: [WorkoutSession], limit: Int = 3) -> [PersonalRecord] {
        TrainingInsights.recentPersonalRecords(from: sessions, limit: limit)
    }

    func currentStreak(from sessions: [WorkoutSession]) -> Int {
        TrainingInsights.currentStreak(from: sessions)
    }

    func weekSummary(from sessions: [WorkoutSession]) -> WeeklySummary? {
        AggregationManager.weeklySummaries(from: sessions).last
    }

    func goalProgress(settings: UserSettings?, sessions: [WorkoutSession]) -> WeeklyGoalProgress {
        let frequency = max(1, settings?.weeklyFrequencyGoal ?? 3)
        let volume = max(0, settings?.weeklyVolumeGoal ?? 10000)
        return TrainingInsights.weeklyGoalProgress(target: frequency, volumeTarget: volume, sessions: sessions)
    }

    func muscleBalanceInsights(from sessions: [WorkoutSession], settings: UserSettings?) -> [MuscleBalanceInsight] {
        guard settings?.enableMuscleBalanceAlerts ?? true else { return [] }
        return TrainingInsights.muscleBalanceInsights(from: sessions)
    }

    func bodyWeightTrend(from measurements: [BodyMeasurement]) -> [BodyWeightPoint] {
        TrainingInsights.bodyWeightTrend(from: measurements)
    }
}

@Observable
final class BodyMeasurementViewModel {
    func record(kilograms: Double, note: String = "", modelContext: ModelContext) {
        let measurement = BodyMeasurement(date: Date(), bodyMassKg: kilograms, note: note)
        modelContext.insert(measurement)
        saveOrLog(modelContext)
    }

    func delete(_ measurement: BodyMeasurement, modelContext: ModelContext) {
        modelContext.delete(measurement)
        saveOrLog(modelContext)
    }

    func latest(from measurements: [BodyMeasurement]) -> BodyMeasurement? {
        measurements.sorted { $0.date > $1.date }.first
    }
}

@Observable
final class SettingsViewModel {
    var statusMessage: String = ""
    var isImportingHealth: Bool = false

    func resetSamples(modelContext: ModelContext) {
        SeedData.ensureSeeded(modelContext: modelContext)
        statusMessage = "已恢复缺失的示例数据。"
    }

    @MainActor
    func importRecentHealthWorkouts(into sessions: [WorkoutSession], workoutVM: WorkoutSessionViewModel, modelContext: ModelContext, daysBack: Int = 90) async {
        isImportingHealth = true
        defer { isImportingHealth = false }
        await HealthKitManager.shared.requestAuthorization()
        guard HealthKitManager.shared.authorizationState == .authorized else {
            statusMessage = "健康权限未授权。"
            return
        }
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -daysBack, to: end) ?? end
        let workouts = await HealthKitManager.shared.fetchStrengthWorkouts(start: start, end: end)
        let count = await workoutVM.importHealthWorkouts(workouts, existingSessions: sessions, modelContext: modelContext)
        statusMessage = count == 0 ? "没有发现新的健康训练记录。" : "已导入 \(count) 条健康训练记录。"
    }
}

enum ProgressTimeRange: String, CaseIterable, Identifiable {
    case fourWeeks = "4周"
    case twelveWeeks = "12周"
    case sixMonths = "6月"
    case all = "全部"

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
    case frequency = "频次"
    case volume = "容量"
    case duration = "时长"
    case sets = "组数"

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

    func exerciseTrend(exerciseId: UUID?, sessions: [WorkoutSession], formula: OneRepMaxFormula = .epley) -> [(date: Date, weight: Double, oneRM: Double, volume: Double)] {
        guard let exerciseId else { return [] }
        return filteredSessions(sessions).sorted { $0.workoutDate < $1.workoutDate }.compactMap { session in
            let sets = session.exercises.filter { $0.exerciseId == exerciseId }.flatMap(\.sets).filter(\.isCompleted)
            guard !sets.isEmpty else { return nil }
            let topWeight = sets.map { TrainingInsights.workingWeight(for: $0) }.max() ?? 0
            return (session.workoutDate, topWeight, OneRepMaxCalculator.bestEstimatedOneRepMax(from: sets, formula: formula), sets.reduce(0) { $0 + VolumeCalculator.volume(for: $1) })
        }
    }
}
