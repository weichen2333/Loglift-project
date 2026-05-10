import Foundation
import Observation
import UserNotifications

struct VolumeCalculator {
    static func volume(for set: SetRecord, bodyweightKg: Double = 75, includeBodyweight: Bool = false) -> Double {
        guard set.isCompleted else { return 0 }
        let reps = Double(max(0, set.actualReps))

        switch set.weightMode {
        case .sameWeight, .machineStack, .plateLoaded, .cable:
            return max(0, set.weight) * reps
        case .leftRightSeparate:
            return (max(0, set.leftWeight) + max(0, set.rightWeight)) * reps
        case .bodyweight:
            let load = includeBodyweight ? bodyweightKg + set.bodyweightAdditionalLoad : set.bodyweightAdditionalLoad
            return max(0, load) * reps
        case .assistedBodyweight:
            return max(0, bodyweightKg + set.bodyweightAdditionalLoad - set.assistanceWeight) * reps
        case .timeBased, .distanceBased:
            return 0
        }
    }
}

struct OneRepMaxCalculator {
    static func epley(weight: Double, reps: Int) -> Double {
        guard weight > 0, reps > 0 else { return 0 }
        return weight * (1 + Double(reps) / 30)
    }

    static func bestEstimatedOneRepMax(from sets: [SetRecord]) -> Double {
        sets.filter(\.isCompleted).map { set in
            let workingWeight: Double
            switch set.weightMode {
            case .leftRightSeparate:
                workingWeight = set.leftWeight + set.rightWeight
            default:
                workingWeight = set.weight
            }
            return epley(weight: workingWeight, reps: set.actualReps)
        }.max() ?? 0
    }
}

struct UnitConversionManager {
    static let poundsPerKilogram = 2.2046226218

    static func kilogramsToPounds(_ kg: Double) -> Double {
        kg * poundsPerKilogram
    }

    static func poundsToKilograms(_ lb: Double) -> Double {
        lb / poundsPerKilogram
    }

    static func convert(_ value: Double, from source: WeightUnit, to target: WeightUnit) -> Double {
        guard source != target else { return value }
        return source == .kg ? kilogramsToPounds(value) : poundsToKilograms(value)
    }

    static func displayWeight(_ kg: Double, unit: WeightUnit) -> Double {
        unit == .kg ? kg : kilogramsToPounds(kg)
    }
}

struct WeeklySummary: Identifiable, Hashable {
    let id = UUID()
    let weekStart: Date
    let workoutCount: Int
    let volume: Double
    let duration: TimeInterval
    let completedSets: Int
    let averageHeartRate: Double?
    let activeEnergyKcal: Double
}

struct MonthlySummary: Identifiable, Hashable {
    let id = UUID()
    let monthStart: Date
    let workoutCount: Int
    let volume: Double
    let duration: TimeInterval
    let completedSets: Int
    let averageHeartRate: Double?
    let activeEnergyKcal: Double
}

struct MuscleVolume: Identifiable, Hashable {
    let id = UUID()
    let muscle: String
    let volume: Double
}

struct HeartRateZone: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let lowerBound: Double
    let upperBound: Double?
    let sampleCount: Int
}

struct PersonalRecord: Identifiable, Hashable {
    let id = UUID()
    let exerciseId: UUID
    let exerciseName: String
    let date: Date
    let bestWeight: Double
    let bestOneRepMax: Double
    let reps: Int
}

struct SetTarget: Identifiable, Hashable {
    let id = UUID()
    let workoutExerciseId: UUID
    let exerciseName: String
    let setIndex: Int
    let setType: SetType
    let reps: Int
    let weightText: String
}

struct AggregationManager {
    static func weeklySummaries(from sessions: [WorkoutSession], calendar: Calendar = .current) -> [WeeklySummary] {
        let grouped = Dictionary(grouping: completedSessions(sessions)) { session in
            calendar.dateInterval(of: .weekOfYear, for: session.workoutDate)?.start ?? calendar.startOfDay(for: session.workoutDate)
        }
        return grouped.map { weekStart, sessions in
            WeeklySummary(
                weekStart: weekStart,
                workoutCount: sessions.count,
                volume: sessions.reduce(0) { $0 + $1.totalVolume },
                duration: sessions.reduce(0) { $0 + $1.duration },
                completedSets: sessions.reduce(0) { $0 + $1.completedSetCount },
                averageHeartRate: average(sessions.compactMap(\.averageHeartRate)),
                activeEnergyKcal: sessions.compactMap(\.activeEnergyKcal).reduce(0, +)
            )
        }.sorted { $0.weekStart < $1.weekStart }
    }

    static func monthlySummaries(from sessions: [WorkoutSession], calendar: Calendar = .current) -> [MonthlySummary] {
        let grouped = Dictionary(grouping: completedSessions(sessions)) { session in
            calendar.dateInterval(of: .month, for: session.workoutDate)?.start ?? calendar.startOfDay(for: session.workoutDate)
        }
        return grouped.map { monthStart, sessions in
            MonthlySummary(
                monthStart: monthStart,
                workoutCount: sessions.count,
                volume: sessions.reduce(0) { $0 + $1.totalVolume },
                duration: sessions.reduce(0) { $0 + $1.duration },
                completedSets: sessions.reduce(0) { $0 + $1.completedSetCount },
                averageHeartRate: average(sessions.compactMap(\.averageHeartRate)),
                activeEnergyKcal: sessions.compactMap(\.activeEnergyKcal).reduce(0, +)
            )
        }.sorted { $0.monthStart < $1.monthStart }
    }

    static func muscleGroupVolume(from sessions: [WorkoutSession]) -> [MuscleVolume] {
        var totals: [String: Double] = [:]
        for workoutExercise in completedSessions(sessions).flatMap(\.exercises) {
            let volume = workoutExercise.sets.reduce(0) { $0 + VolumeCalculator.volume(for: $1) }
            totals[workoutExercise.primaryMuscle.rawValue, default: 0] += volume
        }
        return totals.map { MuscleVolume(muscle: $0.key, volume: $0.value) }
            .sorted { $0.volume > $1.volume }
    }

    static func heartRateZones(samples: [HeartRateSample], maxHeartRate: Int) -> [HeartRateZone] {
        let maxHR = Double(maxHeartRate)
        let definitions: [(String, Double, Double?)] = [
            ("Zone 1", 0, 0.60 * maxHR),
            ("Zone 2", 0.60 * maxHR, 0.70 * maxHR),
            ("Zone 3", 0.70 * maxHR, 0.80 * maxHR),
            ("Zone 4", 0.80 * maxHR, 0.90 * maxHR),
            ("Zone 5", 0.90 * maxHR, nil)
        ]
        return definitions.map { name, lower, upper in
            let count = samples.filter { sample in
                if let upper {
                    return sample.bpm >= lower && sample.bpm < upper
                }
                return sample.bpm >= lower
            }.count
            return HeartRateZone(name: name, lowerBound: lower, upperBound: upper, sampleCount: count)
        }
    }

    static func completedSessions(_ sessions: [WorkoutSession]) -> [WorkoutSession] {
        sessions.filter { $0.status == .completed }
    }

    static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

struct TrainingInsights {
    static func currentStreak(from sessions: [WorkoutSession], calendar: Calendar = .current) -> Int {
        let trainingDays = Set(AggregationManager.completedSessions(sessions).map { calendar.startOfDay(for: $0.workoutDate) })
        guard !trainingDays.isEmpty else { return 0 }

        var cursor = calendar.startOfDay(for: Date())
        if !trainingDays.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor),
                  trainingDays.contains(yesterday) else { return 0 }
            cursor = yesterday
        }

        var streak = 0
        while trainingDays.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    static func personalRecords(from sessions: [WorkoutSession]) -> [PersonalRecord] {
        var records: [UUID: PersonalRecord] = [:]
        for session in AggregationManager.completedSessions(sessions) {
            for workoutExercise in session.exercises {
                for set in workoutExercise.sets where set.isCompleted {
                    let weight = workingWeight(for: set)
                    let oneRM = OneRepMaxCalculator.epley(weight: weight, reps: set.actualReps)
                    guard weight > 0 || oneRM > 0 else { continue }
                    let candidate = PersonalRecord(
                        exerciseId: workoutExercise.exerciseId,
                        exerciseName: workoutExercise.exerciseName,
                        date: session.workoutDate,
                        bestWeight: weight,
                        bestOneRepMax: oneRM,
                        reps: set.actualReps
                    )
                    if let current = records[workoutExercise.exerciseId] {
                        if candidate.bestOneRepMax > current.bestOneRepMax {
                            records[workoutExercise.exerciseId] = candidate
                        }
                    } else {
                        records[workoutExercise.exerciseId] = candidate
                    }
                }
            }
        }
        return records.values.sorted { $0.bestOneRepMax > $1.bestOneRepMax }
    }

    static func recentPersonalRecords(from sessions: [WorkoutSession], limit: Int = 5) -> [PersonalRecord] {
        personalRecords(from: sessions)
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { $0 }
    }

    static func nextSet(in session: WorkoutSession, unit: WeightUnit = .kg) -> SetTarget? {
        for exercise in session.exercises.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            if let set = exercise.sets.sorted(by: { $0.setIndex < $1.setIndex }).first(where: { !$0.isCompleted }) {
                return SetTarget(
                    workoutExerciseId: exercise.id,
                    exerciseName: exercise.exerciseName,
                    setIndex: set.setIndex,
                    setType: set.setType,
                    reps: set.actualReps,
                    weightText: displayWeight(for: set, unit: unit)
                )
            }
        }
        return nil
    }

    static func workingWeight(for set: SetRecord) -> Double {
        switch set.weightMode {
        case .leftRightSeparate:
            set.leftWeight + set.rightWeight
        case .bodyweight:
            set.bodyweightAdditionalLoad
        case .assistedBodyweight:
            max(0, set.bodyweightAdditionalLoad - set.assistanceWeight)
        case .timeBased, .distanceBased:
            0
        default:
            set.weight
        }
    }

    static func displayWeight(for set: SetRecord, unit: WeightUnit = .kg) -> String {
        let suffix = unit.fieldSuffix
        return switch set.weightMode {
        case .leftRightSeparate:
            "\(format(set.leftWeight))/\(format(set.rightWeight)) \(suffix)"
        case .timeBased:
            "\(set.durationSeconds)s"
        case .distanceBased:
            "\(Int(set.distanceMeters))m"
        case .bodyweight:
            set.bodyweightAdditionalLoad > 0 ? "+\(format(set.bodyweightAdditionalLoad)) \(suffix)" : "BW"
        case .assistedBodyweight:
            "Assist \(format(set.assistanceWeight)) \(suffix)"
        default:
            "\(format(set.weight)) \(suffix)"
        }
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value))" : String(format: "%.1f", value)
    }
}

@MainActor
@Observable
final class RestTimerManager {
    private(set) var endDate: Date?
    private(set) var remainingSeconds: Int = 0

    func start(seconds: Int, nextSet: SetTarget? = nil) {
        let clamped = max(0, seconds)
        remainingSeconds = clamped
        endDate = Date().addingTimeInterval(TimeInterval(clamped))
        scheduleNotification(after: clamped, nextSet: nextSet)
    }

    func skip() {
        remainingSeconds = 0
        endDate = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["rest-finished"])
    }

    func pause() {
        tick()
        guard remainingSeconds > 0 else {
            endDate = nil
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["rest-finished"])
            return
        }
        endDate = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["rest-finished"])
    }

    func resume(nextSet: SetTarget? = nil) {
        guard remainingSeconds > 0, endDate == nil else { return }
        endDate = Date().addingTimeInterval(TimeInterval(remainingSeconds))
        scheduleNotification(after: remainingSeconds, nextSet: nextSet)
    }

    func adjust(by seconds: Int) {
        remainingSeconds = max(0, remainingSeconds + seconds)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["rest-finished"])
        if remainingSeconds > 0 {
            endDate = Date().addingTimeInterval(TimeInterval(remainingSeconds))
            scheduleNotification(after: remainingSeconds, nextSet: nil)
        } else {
            endDate = nil
        }
    }

    func tick() {
        guard let endDate else { return }
        remainingSeconds = max(0, Int(endDate.timeIntervalSinceNow.rounded()))
        if remainingSeconds == 0 { self.endDate = nil }
    }

    private func scheduleNotification(after seconds: Int, nextSet: SetTarget?) {
        guard seconds > 0 else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "Next set ready"
        if let nextSet {
            content.body = "\(nextSet.exerciseName) · Set \(nextSet.setIndex) · \(nextSet.weightText) x \(nextSet.reps)"
        } else {
            content.body = "Start your next set."
        }
        content.sound = .default
        content.threadIdentifier = "workout-rest"
        content.categoryIdentifier = "REST_FINISHED"
        if #available(iOS 15.0, watchOS 8.0, macOS 12.0, *) {
            content.interruptionLevel = .timeSensitive
        }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: false)
        let request = UNNotificationRequest(identifier: "rest-finished", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
}

extension TimeInterval {
    var shortDurationText: String {
        let total = max(0, Int(self))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

extension Date {
    var dayKey: Date {
        Calendar.current.startOfDay(for: self)
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
