import Foundation
import SwiftData

#if canImport(HealthKit)
import HealthKit
#endif

#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

struct WorkoutSyncState: Codable {
    var workoutId: UUID?
    var name: String
    var status: WorkoutStatus
    var elapsedSeconds: TimeInterval
    var currentExerciseName: String?
    var currentSetIndex: Int?
    var completedSets: Int
    var currentHeartRate: Double?
    var averageHeartRate: Double?
    var activeEnergyKcal: Double?
    var restRemainingSeconds: Int?
}

enum WatchCommand: String {
    case completeCurrentSet
    case endedWorkout
    case pauseWorkout
    case resumeWorkout
}

enum HealthKitAuthorizationState: String {
    case unknown
    case unavailable
    case denied
    case authorized
}

struct ImportedHealthWorkout: Identifiable, Hashable {
    let id: UUID
    let startDate: Date
    let endDate: Date
    let duration: TimeInterval
    let activeEnergyKcal: Double?
}

@MainActor
final class HealthKitManager: NSObject {
    static let shared = HealthKitManager()

    private(set) var authorizationState: HealthKitAuthorizationState = .unknown
    private(set) var currentHeartRate: Double?
    private(set) var averageHeartRate: Double?
    private(set) var activeEnergyKcal: Double?
    private(set) var liveHeartRateSamples: [HeartRateSample] = []
    private var heartRateTotal: Double = 0

    #if canImport(HealthKit)
    private let healthStore = HKHealthStore()
    #endif

    #if os(watchOS) && canImport(HealthKit)
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    #endif

    override init() {
        super.init()
        checkStatus()
    }

    private func checkStatus() {
        #if canImport(HealthKit)
        if !HKHealthStore.isHealthDataAvailable() {
            authorizationState = .unavailable
        }
        // Cannot reliably read real authorization status without requesting it,
        // so we leave it as unknown or trigger a silent check if possible.
        // We will default to showing "Not Requested" instead of "Unknown" if it's the initial state.
        #else
        authorizationState = .unavailable
        #endif
    }

    func requestAuthorization() async {
        #if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable() else {
            authorizationState = .unavailable
            return
        }

        let readTypes: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKObjectType.workoutType(),
            HKQuantityType(.bodyMass)
        ]
        let writeTypes: Set<HKSampleType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.activeEnergyBurned)
        ]

        do {
            try await healthStore.requestAuthorization(toShare: writeTypes, read: readTypes)
            authorizationState = .authorized
        } catch {
            authorizationState = .denied
        }
        #else
        authorizationState = .unavailable
        #endif
    }

    func startWorkout(activityType: HKWorkoutActivityType = .traditionalStrengthTraining) async {
        #if os(watchOS) && canImport(HealthKit)
        guard authorizationState == .authorized else { await requestAuthorization(); return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activityType
        configuration.locationType = .indoor

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            liveHeartRateSamples.removeAll()
            heartRateTotal = 0
            currentHeartRate = nil
            averageHeartRate = nil
            activeEnergyKcal = nil
            let start = Date()
            session.startActivity(with: start)
            try await builder.beginCollection(at: start)
        } catch {
            authorizationState = .denied
        }
        #else
        await requestAuthorization()
        #endif
    }

    func pauseWorkout() {
        #if os(watchOS) && canImport(HealthKit)
        session?.pause()
        #endif
    }

    func resumeWorkout() {
        #if os(watchOS) && canImport(HealthKit)
        session?.resume()
        #endif
    }

    func endWorkout() async -> UUID? {
        #if os(watchOS) && canImport(HealthKit)
        session?.end()
        guard let builder else { return nil }
        do {
            let endDate = Date()
            try await builder.endCollection(at: endDate)
            let workout = try await builder.finishWorkout()
            self.builder = nil
            self.session = nil
            return workout.uuid
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    func observeHeartRate() {
        // Live heart rate is delivered by HKLiveWorkoutBuilder on Apple Watch.
    }

    func observeActiveEnergy() {
        // Live active energy is delivered by HKLiveWorkoutBuilder on Apple Watch.
    }

    func saveWorkoutToHealthKit(session: WorkoutSession) async -> UUID? {
        #if canImport(HealthKit)
        guard authorizationState == .authorized else { return nil }
        let end = session.endedAt ?? Date()
        let energy = HKQuantity(unit: .kilocalorie(), doubleValue: session.activeEnergyKcal ?? 0)
        let workout = HKWorkout(
            activityType: .traditionalStrengthTraining,
            start: session.startedAt,
            end: end,
            workoutEvents: nil,
            totalEnergyBurned: energy,
            totalDistance: nil,
            metadata: [HKMetadataKeyWorkoutBrandName: "LiftLog"]
        )
        do {
            try await healthStore.save(workout)
            return workout.uuid
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    func fetchHeartRateSamples(start: Date, end: Date) async -> [HeartRateSample] {
        #if canImport(HealthKit)
        guard authorizationState == .authorized else { return [] }
        let type = HKQuantityType(.heartRate)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(predicates: [.quantitySample(type: type, predicate: predicate)], sortDescriptors: [SortDescriptor(\.startDate)])
        do {
            let samples = try await descriptor.result(for: healthStore)
            return samples.map { sample in
                HeartRateSample(timestamp: sample.startDate, bpm: sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())))
            }
        } catch {
            return []
        }
        #else
        return []
        #endif
    }

    func fetchActiveEnergy(start: Date, end: Date) async -> Double? {
        #if canImport(HealthKit)
        guard authorizationState == .authorized else { return nil }
        let type = HKQuantityType(.activeEnergyBurned)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKStatisticsQueryDescriptor(predicate: .quantitySample(type: type, predicate: predicate), options: .cumulativeSum)
        do {
            let result = try await descriptor.result(for: healthStore)
            return result?.sumQuantity()?.doubleValue(for: .kilocalorie())
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    func fetchStrengthWorkouts(start: Date, end: Date) async -> [ImportedHealthWorkout] {
        #if canImport(HealthKit)
        guard authorizationState == .authorized else { return [] }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate),
            HKQuery.predicateForWorkouts(with: .traditionalStrengthTraining)
        ])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)]
        )
        do {
            let samples = try await descriptor.result(for: healthStore)
            return samples.map { workout in
                ImportedHealthWorkout(
                    id: workout.uuid,
                    startDate: workout.startDate,
                    endDate: workout.endDate,
                    duration: workout.duration,
                    activeEnergyKcal: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())
                )
            }
        } catch {
            return []
        }
        #else
        return []
        #endif
    }
}

#if os(watchOS) && canImport(HealthKit)
extension HealthKitManager: HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {}

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {}

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        Task { @MainActor in
            for type in collectedTypes {
                guard let quantityType = type as? HKQuantityType else { continue }
                let statistics = workoutBuilder.statistics(for: quantityType)
                if quantityType == HKQuantityType(.heartRate) {
                    let unit = HKUnit.count().unitDivided(by: .minute())
                    if let bpm = statistics?.mostRecentQuantity()?.doubleValue(for: unit) {
                        currentHeartRate = bpm
                        liveHeartRateSamples.append(HeartRateSample(timestamp: Date(), bpm: bpm))
                        heartRateTotal += bpm
                        averageHeartRate = heartRateTotal / Double(max(1, liveHeartRateSamples.count))
                    }
                } else if quantityType == HKQuantityType(.activeEnergyBurned) {
                    activeEnergyKcal = statistics?.sumQuantity()?.doubleValue(for: .kilocalorie())
                }
            }
        }
    }
}
#endif

@MainActor
final class WatchConnectivityManager: NSObject {
    static let shared = WatchConnectivityManager()

    private(set) var isSupported: Bool = false
    private(set) var isReachable: Bool = false
    private(set) var isCounterpartAppInstalled: Bool = false
    private(set) var activationStateDescription: String = "Inactive"
    private(set) var lastReceivedState: WorkoutSyncState?
    private var pendingCompleteCurrentSetRequested = false
    private var pendingCompleteCurrentSetWorkoutId: UUID?
    private var pendingEndedWorkoutRequested = false
    private var pendingEndedHealthKitUUID: UUID?
    private var pendingPauseWorkoutRequested = false
    private var pendingResumeWorkoutRequested = false

    override init() {
        super.init()
        activate()
    }

    func activate() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else {
            isSupported = false
            return
        }
        isSupported = true
        WCSession.default.delegate = self
        WCSession.default.activate()
        #endif
    }

    func refreshStatus() {
        #if canImport(WatchConnectivity)
        refreshAvailability()
        #endif
    }

    func send(state: WorkoutSyncState) {
        #if canImport(WatchConnectivity)
        guard canSendToCounterpart else { return }
        do {
            let data = try JSONEncoder().encode(state)
            sendPayload(["workoutState": data])
        } catch {}
        #endif
    }

    func sendCompleteCurrentSet(workoutId: UUID?) {
        #if canImport(WatchConnectivity)
        guard canSendToCounterpart else { return }
        sendPayload(["command": "completeCurrentSet", "workoutId": workoutId?.uuidString ?? ""])
        #endif
    }

    func sendEndedWorkout(uuid: UUID?) {
        #if canImport(WatchConnectivity)
        guard canSendToCounterpart else { return }
        sendPayload(["command": "endedWorkout", "healthKitUUID": uuid?.uuidString ?? ""])
        #endif
    }

    func sendCommand(_ command: WatchCommand) {
        #if canImport(WatchConnectivity)
        guard canSendToCounterpart else { return }
        sendPayload(["command": command.rawValue])
        #endif
    }

    func consumeCompleteCurrentSetCommand(for workoutId: UUID) -> Bool {
        guard pendingCompleteCurrentSetRequested else { return false }
        guard pendingCompleteCurrentSetWorkoutId == nil || pendingCompleteCurrentSetWorkoutId == workoutId else { return false }
        pendingCompleteCurrentSetRequested = false
        pendingCompleteCurrentSetWorkoutId = nil
        return true
    }

    func consumeEndedWorkoutCommand() -> (requested: Bool, healthKitUUID: UUID?) {
        guard pendingEndedWorkoutRequested else { return (false, nil) }
        pendingEndedWorkoutRequested = false
        defer { pendingEndedHealthKitUUID = nil }
        return (true, pendingEndedHealthKitUUID)
    }

    func consumePauseWorkoutCommand() -> Bool {
        guard pendingPauseWorkoutRequested else { return false }
        pendingPauseWorkoutRequested = false
        return true
    }

    func consumeResumeWorkoutCommand() -> Bool {
        guard pendingResumeWorkoutRequested else { return false }
        pendingResumeWorkoutRequested = false
        return true
    }

    #if canImport(WatchConnectivity)
    private var canSendToCounterpart: Bool {
        guard WCSession.isSupported() else { return false }
        refreshAvailability()
        guard isCounterpartAppInstalled else { return false }
        return WCSession.default.activationState == .activated
    }

    private func refreshAvailability() {
        guard WCSession.isSupported() else {
            isSupported = false
            isReachable = false
            isCounterpartAppInstalled = false
            activationStateDescription = "Unsupported"
            return
        }

        isSupported = true
        activationStateDescription = WCSession.default.activationState.statusText
        guard WCSession.default.activationState == .activated else {
            isReachable = false
            isCounterpartAppInstalled = false
            return
        }
        isReachable = WCSession.default.isReachable
        #if os(iOS)
        isCounterpartAppInstalled = WCSession.default.isPaired && WCSession.default.isWatchAppInstalled
        #elseif os(watchOS)
        isCounterpartAppInstalled = WCSession.default.isCompanionAppInstalled
        #else
        isCounterpartAppInstalled = false
        #endif
    }

    private func sendPayload(_ payload: [String: Any]) {
        guard !payload.isEmpty else { return }
        refreshAvailability()
        guard isCounterpartAppInstalled, WCSession.default.activationState == .activated else { return }
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(payload, replyHandler: nil) { _ in }
        } else {
            do {
                try WCSession.default.updateApplicationContext(payload)
            } catch {
                refreshAvailability()
            }
        }
    }
    #endif
}

#if canImport(WatchConnectivity)
extension WatchConnectivityManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            refreshAvailability()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            refreshAvailability()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message: message)
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handle(message: applicationContext)
    }

    private nonisolated func handle(message: [String: Any]) {
        if let data = message["workoutState"] as? Data {
            Task { @MainActor in
                guard let state = try? JSONDecoder().decode(WorkoutSyncState.self, from: data) else { return }
                lastReceivedState = state
            }
            return
        }

        guard let commandRaw = message["command"] as? String,
              let command = WatchCommand(rawValue: commandRaw) else { return }

        Task { @MainActor in
            switch command {
            case .completeCurrentSet:
                pendingCompleteCurrentSetRequested = true
                if let rawId = message["workoutId"] as? String, let id = UUID(uuidString: rawId) {
                    pendingCompleteCurrentSetWorkoutId = id
                } else {
                    pendingCompleteCurrentSetWorkoutId = nil
                }
            case .endedWorkout:
                pendingEndedWorkoutRequested = true
                if let rawId = message["healthKitUUID"] as? String, let id = UUID(uuidString: rawId) {
                    pendingEndedHealthKitUUID = id
                } else {
                    pendingEndedHealthKitUUID = nil
                }
            case .pauseWorkout:
                pendingPauseWorkoutRequested = true
            case .resumeWorkout:
                pendingResumeWorkoutRequested = true
            }
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif
}
#endif

#if canImport(WatchConnectivity)
extension WCSessionActivationState {
    var statusText: String {
        switch self {
        case .notActivated: "Not activated"
        case .inactive: "Inactive"
        case .activated: "Activated"
        @unknown default: "Unknown"
        }
    }
}
#endif

struct ExportManager {
    enum ExportKind: String {
        case workoutHistory = "workout-history"
        case exerciseLibrary = "exercise-library"
        case allData = "liftlog-data"
    }

    static func writeExportFile(kind: ExportKind, sessions: [WorkoutSession], exercises: [Exercise], routines: [WorkoutRoutine]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url: URL
        let data: Data

        switch kind {
        case .workoutHistory:
            url = directory.appendingPathComponent("\(kind.rawValue)-\(timestamp).csv")
            data = Data(workoutHistoryCSV(sessions: sessions).utf8)
        case .exerciseLibrary:
            url = directory.appendingPathComponent("\(kind.rawValue)-\(timestamp).csv")
            data = Data(exerciseCSV(exercises: exercises).utf8)
        case .allData:
            url = directory.appendingPathComponent("\(kind.rawValue)-\(timestamp).json")
            data = allDataJSON(sessions: sessions, exercises: exercises, routines: routines) ?? Data("{}".utf8)
        }

        try data.write(to: url, options: [.atomic])
        return url
    }

    static func workoutHistoryCSV(sessions: [WorkoutSession]) -> String {
        var lines = ["workout_date,workout_name,exercise_name,set_index,set_type,reps,weight,left_weight,right_weight,rpe,completed_at,volume,notes"]
        let formatter = ISO8601DateFormatter()
        for session in sessions.sorted(by: { $0.workoutDate < $1.workoutDate }) {
            for exercise in session.exercises.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                for set in exercise.sets.sorted(by: { $0.setIndex < $1.setIndex }) {
                    let fields: [String] = [
                        formatter.string(from: session.workoutDate),
                        session.name,
                        exercise.exerciseName,
                        String(set.setIndex),
                        set.setType.rawValue,
                        String(set.actualReps),
                        String(set.weight),
                        String(set.leftWeight),
                        String(set.rightWeight),
                        set.rpe.map { String($0) } ?? "",
                        set.completedAt.map { formatter.string(from: $0) } ?? "",
                        String(VolumeCalculator.volume(for: set)),
                        set.note
                    ]
                    lines.append(fields.map(escapeCSV).joined(separator: ","))
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func exerciseCSV(exercises: [Exercise]) -> String {
        var lines = ["id,name,english_name,primary_muscle,type,is_custom,created_at,updated_at"]
        let formatter = ISO8601DateFormatter()
        for exercise in exercises.sorted(by: { $0.name < $1.name }) {
            let fields = [
                exercise.id.uuidString,
                exercise.name,
                exercise.englishName ?? "",
                exercise.primaryMuscle.rawValue,
                exercise.type.rawValue,
                String(exercise.isCustom),
                formatter.string(from: exercise.createdAt),
                formatter.string(from: exercise.updatedAt)
            ]
            lines.append(fields.map(escapeCSV).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    static func allDataJSON(sessions: [WorkoutSession], exercises: [Exercise], routines: [WorkoutRoutine]) -> Data? {
        let payload = ExportPayload(
            generatedAt: Date(),
            exercises: exercises.map { ExportExercise(id: $0.id, name: $0.name, primaryMuscle: $0.primaryMuscle.rawValue, type: $0.type.rawValue) },
            routines: routines.map { ExportRoutine(id: $0.id, name: $0.name, exerciseCount: $0.exercises.count) },
            workouts: sessions.map { ExportWorkout(id: $0.id, name: $0.name, date: $0.workoutDate, volume: $0.totalVolume, completedSets: $0.completedSetCount) }
        )
        return try? JSONEncoder().encode(payload)
    }

    nonisolated private static func escapeCSV(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}

private struct ExportPayload: Codable {
    let generatedAt: Date
    let exercises: [ExportExercise]
    let routines: [ExportRoutine]
    let workouts: [ExportWorkout]
}

private struct ExportExercise: Codable {
    let id: UUID
    let name: String
    let primaryMuscle: String
    let type: String
}

private struct ExportRoutine: Codable {
    let id: UUID
    let name: String
    let exerciseCount: Int
}

private struct ExportWorkout: Codable {
    let id: UUID
    let name: String
    let date: Date
    let volume: Double
    let completedSets: Int
}
