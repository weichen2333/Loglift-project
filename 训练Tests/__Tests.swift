import Foundation
import Testing
@testable import 训练

@Suite("LiftLog Core Logic")
struct LiftLogCoreTests {
    @Test("Volume uses total weight times reps")
    func volumeCalculatorSameWeight() {
        let set = SetRecord(exerciseId: UUID(), setIndex: 1, actualReps: 8, weightMode: .sameWeight, weight: 100, isCompleted: true)
        #expect(VolumeCalculator.volume(for: set) == 800)
    }

    @Test("Volume uses left plus right for dumbbells")
    func volumeCalculatorLeftRight() {
        let set = SetRecord(exerciseId: UUID(), setIndex: 1, actualReps: 10, weightMode: .leftRightSeparate, leftWeight: 20, rightWeight: 20, isCompleted: true)
        #expect(VolumeCalculator.volume(for: set) == 400)
    }

    @Test("Incomplete sets do not count toward volume")
    func setCompletionFiltersVolume() {
        let set = SetRecord(exerciseId: UUID(), setIndex: 1, actualReps: 10, weightMode: .sameWeight, weight: 50, isCompleted: false)
        #expect(VolumeCalculator.volume(for: set) == 0)
    }

    @Test("Epley estimated one rep max")
    func oneRepMaxCalculator() {
        let value = OneRepMaxCalculator.epley(weight: 100, reps: 10)
        #expect(abs(value - 133.333) < 0.01)
    }

    @Test("Weekly aggregation counts completed workouts")
    func weeklyAggregation() {
        let exerciseId = UUID()
        let completedSet = SetRecord(exerciseId: exerciseId, setIndex: 1, actualReps: 10, weightMode: .sameWeight, weight: 50, isCompleted: true)
        let workoutExercise = WorkoutExercise(exerciseId: exerciseId, exerciseName: "Bench", primaryMuscle: .chest, exerciseType: .barbell, sets: [completedSet])
        let session = WorkoutSession(name: "Workout", endedAt: Date(), status: .completed, exercises: [workoutExercise])
        let cancelled = WorkoutSession(name: "Cancelled", status: .cancelled)
        let summaries = AggregationManager.weeklySummaries(from: [session, cancelled])
        #expect(summaries.last?.workoutCount == 1)
        #expect(summaries.last?.volume == 500)
        #expect(summaries.last?.completedSets == 1)
    }

    @Test("Unit conversion kg and lb")
    func unitConversion() {
        let pounds = UnitConversionManager.kilogramsToPounds(100)
        #expect(abs(pounds - 220.462) < 0.01)
        let kilograms = UnitConversionManager.poundsToKilograms(pounds)
        #expect(abs(kilograms - 100) < 0.01)
    }

    @Test("Set completion toggles timestamp")
    func setCompletionToggle() {
        let set = SetRecord(exerciseId: UUID(), setIndex: 1)
        set.toggleCompletion()
        #expect(set.isCompleted)
        #expect(set.completedAt != nil)
        set.toggleCompletion()
        #expect(!set.isCompleted)
        #expect(set.completedAt == nil)
    }

    @Test("Brzycki estimate falls back at 37 reps")
    func brzyckiEdgeCase() {
        #expect(OneRepMaxCalculator.brzycki(weight: 100, reps: 5) > 100)
        #expect(OneRepMaxCalculator.brzycki(weight: 100, reps: 37) == 0)
    }

    @Test("Estimate skips high-rep sets to avoid distortion")
    func estimateHighRepGuard() {
        #expect(OneRepMaxCalculator.estimate(weight: 100, reps: 30, formula: .epley) == 0)
        #expect(OneRepMaxCalculator.estimate(weight: 100, reps: 5, formula: .brzycki) > 100)
    }

    @Test("Lombardi formula returns positive estimate")
    func lombardiFormula() {
        let value = OneRepMaxCalculator.lombardi(weight: 100, reps: 8)
        #expect(value > 100)
    }

    @Test("Volume guards against negative assistance")
    func assistedBodyweightGuard() {
        let set = SetRecord(exerciseId: UUID(), setIndex: 1, actualReps: 5, weightMode: .assistedBodyweight, bodyweightAdditionalLoad: 0, assistanceWeight: 1000, isCompleted: true)
        #expect(VolumeCalculator.volume(for: set, bodyweightKg: 75) == 0)
    }

    @Test("Pure bodyweight reps still produce volume")
    func bodyweightVolumeFallback() {
        let set = SetRecord(exerciseId: UUID(), setIndex: 1, actualReps: 10, weightMode: .bodyweight, bodyweightAdditionalLoad: 0, isCompleted: true)
        let volume = VolumeCalculator.volume(for: set, bodyweightKg: 75)
        #expect(volume == 750)
    }

    @Test("PR detection identifies new estimated 1RM")
    func prDetection() {
        let exerciseId = UUID()
        let priorSet = SetRecord(exerciseId: exerciseId, setIndex: 1, actualReps: 5, weightMode: .sameWeight, weight: 100, isCompleted: true)
        let priorExercise = WorkoutExercise(exerciseId: exerciseId, exerciseName: "Bench", primaryMuscle: .chest, exerciseType: .barbell, sets: [priorSet])
        let priorSession = WorkoutSession(name: "Prior", endedAt: Date().addingTimeInterval(-86400), workoutDate: Date().addingTimeInterval(-86400), source: .manual, status: .completed, exercises: [priorExercise])

        let newSet = SetRecord(exerciseId: exerciseId, setIndex: 1, actualReps: 5, weightMode: .sameWeight, weight: 110, isCompleted: true)
        let pr = TrainingInsights.detectPersonalRecord(forCompleting: newSet, exerciseId: exerciseId, exerciseName: "Bench", in: [priorSession], excluding: nil)
        #expect(pr != nil)
        #expect(pr?.kind == .oneRepMax || pr?.kind == .maxWeight)
    }

    @Test("Last set lookup returns most recent completed working set")
    func lastSetLookup() {
        let exerciseId = UUID()
        let setA = SetRecord(exerciseId: exerciseId, setIndex: 1, actualReps: 8, weightMode: .sameWeight, weight: 80, isCompleted: true)
        let setB = SetRecord(exerciseId: exerciseId, setIndex: 1, actualReps: 5, weightMode: .sameWeight, weight: 100, isCompleted: true)
        let exA = WorkoutExercise(exerciseId: exerciseId, exerciseName: "Bench", primaryMuscle: .chest, exerciseType: .barbell, sets: [setA])
        let exB = WorkoutExercise(exerciseId: exerciseId, exerciseName: "Bench", primaryMuscle: .chest, exerciseType: .barbell, sets: [setB])
        let dayA = Date().addingTimeInterval(-86400 * 5)
        let dayB = Date().addingTimeInterval(-86400 * 1)
        let sessionA = WorkoutSession(name: "Old", endedAt: dayA, workoutDate: dayA, source: .manual, status: .completed, exercises: [exA])
        let sessionB = WorkoutSession(name: "New", endedAt: dayB, workoutDate: dayB, source: .manual, status: .completed, exercises: [exB])
        let last = TrainingInsights.lastSet(for: exerciseId, in: [sessionA, sessionB])
        #expect(last != nil)
        #expect(last?.workingWeight == 100)
        #expect(last?.reps == 5)
    }

    @Test("Weekly goal progress clamps at 100%")
    func weeklyGoalProgress() {
        let exerciseId = UUID()
        var sessions: [WorkoutSession] = []
        for _ in 0..<6 {
            let set = SetRecord(exerciseId: exerciseId, setIndex: 1, actualReps: 10, weightMode: .sameWeight, weight: 100, isCompleted: true)
            let we = WorkoutExercise(exerciseId: exerciseId, exerciseName: "Bench", primaryMuscle: .chest, exerciseType: .barbell, sets: [set])
            sessions.append(WorkoutSession(name: "Workout", endedAt: Date(), status: .completed, exercises: [we]))
        }
        let progress = TrainingInsights.weeklyGoalProgress(target: 3, volumeTarget: 1000, sessions: sessions)
        #expect(progress.frequencyRatio == 1.0)
        #expect(progress.volumeRatio == 1.0)
    }

    @Test("Validation requires reps and weight before completing")
    func validationGuards() {
        let viewModel = WorkoutSessionViewModel()
        let zeroReps = SetRecord(exerciseId: UUID(), setIndex: 1, actualReps: 0, weightMode: .sameWeight, weight: 100)
        #expect(viewModel.validation(for: zeroReps) != nil)

        let zeroWeight = SetRecord(exerciseId: UUID(), setIndex: 1, actualReps: 5, weightMode: .sameWeight, weight: 0)
        #expect(viewModel.validation(for: zeroWeight) != nil)

        let valid = SetRecord(exerciseId: UUID(), setIndex: 1, actualReps: 5, weightMode: .sameWeight, weight: 100)
        #expect(viewModel.validation(for: valid) == nil)
    }
}
