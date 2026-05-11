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
            // Pure bodyweight reps with no added load still produce work — fall back to bodyweight when not configured.
            let effective = load > 0 ? load : (includeBodyweight ? 0 : bodyweightKg)
            return max(0, effective) * reps
        case .assistedBodyweight:
            return max(0, bodyweightKg + set.bodyweightAdditionalLoad - set.assistanceWeight) * reps
        case .timeBased, .distanceBased:
            return 0
        }
    }
}

enum OneRepMaxFormula: String, CaseIterable, Identifiable, Codable {
    case epley
    case brzycki
    case lombardi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .epley: "Epley 公式"
        case .brzycki: "Brzycki 公式"
        case .lombardi: "Lombardi 公式"
        }
    }

    var subtitle: String {
        switch self {
        case .epley: "重量 × (1 + 次数/30)"
        case .brzycki: "重量 × 36 / (37 − 次数)"
        case .lombardi: "重量 × 次数^0.10"
        }
    }
}

struct OneRepMaxCalculator {
    static let highRepThreshold = 25

    static func epley(weight: Double, reps: Int) -> Double {
        guard weight > 0, reps > 0 else { return 0 }
        return weight * (1 + Double(reps) / 30)
    }

    static func brzycki(weight: Double, reps: Int) -> Double {
        guard weight > 0, reps > 0, reps < 37 else { return 0 }
        return weight * 36.0 / (37.0 - Double(reps))
    }

    static func lombardi(weight: Double, reps: Int) -> Double {
        guard weight > 0, reps > 0 else { return 0 }
        return weight * pow(Double(reps), 0.10)
    }

    static func estimate(weight: Double, reps: Int, formula: OneRepMaxFormula = .epley) -> Double {
        guard reps <= highRepThreshold else { return 0 }
        switch formula {
        case .epley: return epley(weight: weight, reps: reps)
        case .brzycki: return brzycki(weight: weight, reps: reps)
        case .lombardi: return lombardi(weight: weight, reps: reps)
        }
    }

    static func bestEstimatedOneRepMax(from sets: [SetRecord], formula: OneRepMaxFormula = .epley) -> Double {
        sets.filter(\.isCompleted).map { set in
            estimate(weight: TrainingInsights.workingWeight(for: set), reps: set.actualReps, formula: formula)
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

struct LastSetSummary: Hashable {
    let date: Date
    let workingWeight: Double
    let reps: Int
    let weightMode: WeightMode
    let leftWeight: Double
    let rightWeight: Double
    let bodyweightAdditionalLoad: Double
    let assistanceWeight: Double
    let estimatedOneRepMax: Double
    let topVolume: Double

    var headlineText: String {
        switch weightMode {
        case .leftRightSeparate:
            return "\(formatted(leftWeight))/\(formatted(rightWeight)) × \(reps)"
        case .bodyweight:
            return bodyweightAdditionalLoad > 0 ? "自重+\(formatted(bodyweightAdditionalLoad)) × \(reps)" : "自重 × \(reps)"
        case .assistedBodyweight:
            return "助力 \(formatted(assistanceWeight)) × \(reps)"
        case .timeBased:
            return "\(reps)秒"
        case .distanceBased:
            return "\(formatted(workingWeight))米"
        default:
            return "\(formatted(workingWeight)) × \(reps)"
        }
    }

    private func formatted(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(value))" : String(format: "%.1f", value)
    }
}

struct MuscleBalanceInsight: Identifiable, Hashable {
    let id = UUID()
    let muscle: MuscleGroup
    let weeklySetCount: Int
    let weeklyVolume: Double
    let recommendation: String
    let severity: Severity

    enum Severity: String, Hashable {
        case ok
        case warning
        case critical
    }
}

struct WeeklyGoalProgress: Hashable {
    let frequencyTarget: Int
    let frequencyActual: Int
    let volumeTarget: Double
    let volumeActual: Double

    var frequencyRatio: Double {
        guard frequencyTarget > 0 else { return 0 }
        return min(1, Double(frequencyActual) / Double(frequencyTarget))
    }

    var volumeRatio: Double {
        guard volumeTarget > 0 else { return 0 }
        return min(1, volumeActual / volumeTarget)
    }
}

struct BodyWeightPoint: Identifiable, Hashable {
    let id = UUID()
    let date: Date
    let kilograms: Double
}

struct PRCandidate: Hashable {
    enum Kind: Hashable {
        case maxWeight
        case oneRepMax
        case totalVolume
    }
    let exerciseId: UUID
    let exerciseName: String
    let kind: Kind
    let value: Double
    let previousValue: Double
    let reps: Int

    var deltaText: String {
        let delta = value - previousValue
        guard delta > 0 else { return "" }
        return "+\(format(delta))"
    }

    private func format(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(value))" : String(format: "%.1f", value)
    }
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
            ("Z1·热身", 0, 0.60 * maxHR),
            ("Z2·燃脂", 0.60 * maxHR, 0.70 * maxHR),
            ("Z3·有氧", 0.70 * maxHR, 0.80 * maxHR),
            ("Z4·阈值", 0.80 * maxHR, 0.90 * maxHR),
            ("Z5·极限", 0.90 * maxHR, nil)
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

    static func nextSet(in session: WorkoutSession) -> SetTarget? {
        for exercise in session.exercises.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            if let set = exercise.sets.sorted(by: { $0.setIndex < $1.setIndex }).first(where: { !$0.isCompleted }) {
                return SetTarget(
                    workoutExerciseId: exercise.id,
                    exerciseName: exercise.exerciseName,
                    setIndex: set.setIndex,
                    setType: set.setType,
                    reps: set.actualReps,
                    weightText: displayWeight(for: set)
                )
            }
        }
        return nil
    }

    static func lastSet(for exerciseId: UUID, in sessions: [WorkoutSession], excluding sessionId: UUID? = nil, formula: OneRepMaxFormula = .epley) -> LastSetSummary? {
        let candidates = AggregationManager.completedSessions(sessions)
            .filter { sessionId == nil || $0.id != sessionId }
            .sorted { $0.workoutDate > $1.workoutDate }

        for session in candidates {
            let matching = session.exercises.filter { $0.exerciseId == exerciseId }
            let completedSets = matching.flatMap(\.sets).filter(\.isCompleted)
            guard !completedSets.isEmpty else { continue }
            let topSet = completedSets.max(by: { workingWeight(for: $0) < workingWeight(for: $1) }) ?? completedSets[0]
            let oneRM = OneRepMaxCalculator.estimate(weight: workingWeight(for: topSet), reps: topSet.actualReps, formula: formula)
            let topVolume = completedSets.reduce(0) { $0 + VolumeCalculator.volume(for: $1) }
            return LastSetSummary(
                date: session.workoutDate,
                workingWeight: workingWeight(for: topSet),
                reps: topSet.actualReps,
                weightMode: topSet.weightMode,
                leftWeight: topSet.leftWeight,
                rightWeight: topSet.rightWeight,
                bodyweightAdditionalLoad: topSet.bodyweightAdditionalLoad,
                assistanceWeight: topSet.assistanceWeight,
                estimatedOneRepMax: oneRM,
                topVolume: topVolume
            )
        }
        return nil
    }

    static func detectPersonalRecord(forCompleting set: SetRecord, exerciseId: UUID, exerciseName: String, in sessions: [WorkoutSession], excluding sessionId: UUID?, formula: OneRepMaxFormula = .epley) -> PRCandidate? {
        let history = AggregationManager.completedSessions(sessions).filter { sessionId == nil || $0.id != sessionId }
        let priorSets = history.flatMap(\.exercises).filter { $0.exerciseId == exerciseId }.flatMap(\.sets).filter(\.isCompleted)
        let priorBestWeight = priorSets.map { workingWeight(for: $0) }.max() ?? 0
        let priorBestOneRM = priorSets.map { OneRepMaxCalculator.estimate(weight: workingWeight(for: $0), reps: $0.actualReps, formula: formula) }.max() ?? 0

        let currentWeight = workingWeight(for: set)
        let currentOneRM = OneRepMaxCalculator.estimate(weight: currentWeight, reps: set.actualReps, formula: formula)

        if currentOneRM > priorBestOneRM, currentOneRM > 0 {
            return PRCandidate(exerciseId: exerciseId, exerciseName: exerciseName, kind: .oneRepMax, value: currentOneRM, previousValue: priorBestOneRM, reps: set.actualReps)
        }
        if currentWeight > priorBestWeight, currentWeight > 0 {
            return PRCandidate(exerciseId: exerciseId, exerciseName: exerciseName, kind: .maxWeight, value: currentWeight, previousValue: priorBestWeight, reps: set.actualReps)
        }
        return nil
    }

    static func weeklyGoalProgress(target frequencyTarget: Int, volumeTarget: Double, sessions: [WorkoutSession], reference: Date = Date(), calendar: Calendar = .current) -> WeeklyGoalProgress {
        let interval = calendar.dateInterval(of: .weekOfYear, for: reference) ?? DateInterval(start: reference, duration: 7 * 24 * 3600)
        let weekSessions = AggregationManager.completedSessions(sessions).filter { interval.contains($0.workoutDate) }
        let actualVolume = weekSessions.reduce(0) { $0 + $1.totalVolume }
        return WeeklyGoalProgress(
            frequencyTarget: frequencyTarget,
            frequencyActual: weekSessions.count,
            volumeTarget: volumeTarget,
            volumeActual: actualVolume
        )
    }

    static func muscleBalanceInsights(from sessions: [WorkoutSession], referenceDate: Date = Date(), calendar: Calendar = .current) -> [MuscleBalanceInsight] {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: referenceDate) else { return [] }
        let weekSessions = AggregationManager.completedSessions(sessions).filter { interval.contains($0.workoutDate) }
        var muscleSets: [MuscleGroup: Int] = [:]
        var muscleVolume: [MuscleGroup: Double] = [:]
        for exercise in weekSessions.flatMap(\.exercises) {
            let completed = exercise.sets.filter(\.isCompleted)
            muscleSets[exercise.primaryMuscle, default: 0] += completed.count
            muscleVolume[exercise.primaryMuscle, default: 0] += completed.reduce(0) { $0 + VolumeCalculator.volume(for: $1) }
        }
        let monitored: [MuscleGroup] = [.chest, .back, .legs, .shoulders, .arms, .core]
        return monitored.map { muscle in
            let count = muscleSets[muscle] ?? 0
            let volume = muscleVolume[muscle] ?? 0
            let severity: MuscleBalanceInsight.Severity
            let recommendation: String
            switch count {
            case 0:
                severity = .warning
                recommendation = "本周尚未训练，建议尽快安排"
            case 1...3:
                severity = .ok
                recommendation = "训练量较低，仍有发挥空间"
            case 4...12:
                severity = .ok
                recommendation = "训练量均衡，状态良好"
            default:
                severity = .warning
                recommendation = "训练量偏高，注意恢复"
            }
            return MuscleBalanceInsight(muscle: muscle, weeklySetCount: count, weeklyVolume: volume, recommendation: recommendation, severity: severity)
        }
    }

    static func bodyWeightTrend(from measurements: [BodyMeasurement], range: ProgressTimeRange = .twelveWeeks, calendar: Calendar = .current) -> [BodyWeightPoint] {
        let cutoff: Date? = {
            guard let component = range.dateComponent else { return nil }
            return calendar.date(byAdding: component, to: Date())
        }()
        return measurements
            .filter { cutoff == nil || $0.date >= cutoff! }
            .sorted { $0.date < $1.date }
            .map { BodyWeightPoint(date: $0.date, kilograms: $0.bodyMassKg) }
    }

    static func strengthGain(for exerciseId: UUID, in sessions: [WorkoutSession], windowWeeks: Int = 8, formula: OneRepMaxFormula = .epley, calendar: Calendar = .current) -> Double? {
        guard let cutoff = calendar.date(byAdding: .weekOfYear, value: -windowWeeks, to: Date()) else { return nil }
        let completed = AggregationManager.completedSessions(sessions)
        let priorSets = completed.filter { $0.workoutDate < cutoff }.flatMap(\.exercises).filter { $0.exerciseId == exerciseId }.flatMap(\.sets).filter(\.isCompleted)
        let recentSets = completed.filter { $0.workoutDate >= cutoff }.flatMap(\.exercises).filter { $0.exerciseId == exerciseId }.flatMap(\.sets).filter(\.isCompleted)
        guard !priorSets.isEmpty, !recentSets.isEmpty else { return nil }
        let priorBest = priorSets.map { OneRepMaxCalculator.estimate(weight: workingWeight(for: $0), reps: $0.actualReps, formula: formula) }.max() ?? 0
        let recentBest = recentSets.map { OneRepMaxCalculator.estimate(weight: workingWeight(for: $0), reps: $0.actualReps, formula: formula) }.max() ?? 0
        guard priorBest > 0 else { return nil }
        return ((recentBest - priorBest) / priorBest) * 100
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

    static func displayWeight(for set: SetRecord) -> String {
        switch set.weightMode {
        case .leftRightSeparate:
            "\(Int(set.leftWeight))/\(Int(set.rightWeight))"
        case .timeBased:
            "\(set.durationSeconds)秒"
        case .distanceBased:
            "\(Int(set.distanceMeters))米"
        case .bodyweight:
            set.bodyweightAdditionalLoad > 0 ? "+\(Int(set.bodyweightAdditionalLoad))" : "自重"
        case .assistedBodyweight:
            "助力 \(Int(set.assistanceWeight))"
        default:
            "\(Int(set.weight))"
        }
    }
}

@MainActor
@Observable
final class RestTimerManager {
    private(set) var endDate: Date?
    private(set) var remainingSeconds: Int = 0
    private(set) var totalSeconds: Int = 0
    var onFinish: (() -> Void)?
    /// Fires when start/adjust/skip changes the timer state, so the active workout can
    /// re-broadcast its sync state to the watch (the second-by-second tick is not
    /// considered a state change here — the watch extrapolates from `endDate`).
    var onChange: (() -> Void)?

    var progress: Double {
        guard totalSeconds > 0 else { return 0 }
        return min(1, max(0, 1 - Double(remainingSeconds) / Double(totalSeconds)))
    }

    var isRunning: Bool { endDate != nil && remainingSeconds > 0 }

    func start(seconds: Int) {
        let clamped = max(0, seconds)
        totalSeconds = clamped
        remainingSeconds = clamped
        endDate = clamped > 0 ? Date().addingTimeInterval(TimeInterval(clamped)) : nil
        scheduleNotification(after: clamped)
        onChange?()
    }

    func skip() {
        remainingSeconds = 0
        endDate = nil
        totalSeconds = 0
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["rest-finished"])
        onChange?()
    }

    func adjust(by seconds: Int) {
        let new = max(0, remainingSeconds + seconds)
        remainingSeconds = new
        totalSeconds = max(totalSeconds, new)
        endDate = new > 0 ? Date().addingTimeInterval(TimeInterval(new)) : nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["rest-finished"])
        scheduleNotification(after: new)
        onChange?()
    }

    func tick() {
        guard let endDate else { return }
        let was = remainingSeconds
        remainingSeconds = max(0, Int(endDate.timeIntervalSinceNow.rounded()))
        if remainingSeconds == 0 {
            self.endDate = nil
            if was > 0 { onFinish?() }
        }
    }

    private func scheduleNotification(after seconds: Int) {
        guard seconds > 0 else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "休息结束"
        content.body = "开始下一组训练吧。"
        content.sound = .default
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
        if hours > 0 { return "\(hours)小时\(minutes)分" }
        return "\(minutes)分"
    }
}

extension Date {
    var dayKey: Date {
        Calendar.current.startOfDay(for: self)
    }
}
