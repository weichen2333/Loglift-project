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
}
