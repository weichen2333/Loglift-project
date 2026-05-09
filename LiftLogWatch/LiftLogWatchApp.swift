import SwiftUI
import Foundation
import Combine
import HealthKit
import WatchConnectivity

enum WatchWorkoutStatus: String, Codable {
    case active
    case paused
    case completed
}

struct WatchWorkoutSyncState: Codable {
    var workoutId: UUID?
    var name: String
    var status: WatchWorkoutStatus
    var elapsedSeconds: TimeInterval
    var currentExerciseName: String?
    var currentSetIndex: Int?
    var completedSets: Int
    var currentHeartRate: Double?
    var averageHeartRate: Double?
    var activeEnergyKcal: Double?
    var restRemainingSeconds: Int?
}

@main
struct LiftLogWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchRootView()
        }
    }
}

struct WatchRootView: View {
    @State private var isActive = false

    var body: some View {
        if isActive {
            ActiveWatchWorkoutView(isActive: $isActive)
        } else {
            StartWorkoutView(isActive: $isActive)
        }
    }
}

struct StartWorkoutView: View {
    @Binding var isActive: Bool
    private let routines = ["Quick Workout", "Push Day", "Pull Day", "Leg Day"]

    var body: some View {
        NavigationStack {
            List(routines, id: \.self) { routine in
                Button(routine) {
                    Task {
                        await WatchHealthKitManager.shared.requestAuthorization()
                        await WatchHealthKitManager.shared.startWorkout()
                        WatchSessionManager.shared.send(state: WatchWorkoutSyncState(
                            workoutId: nil,
                            name: routine,
                            status: .active,
                            elapsedSeconds: 0,
                            currentExerciseName: nil,
                            currentSetIndex: nil,
                            completedSets: 0,
                            currentHeartRate: nil,
                            averageHeartRate: nil,
                            activeEnergyKcal: nil,
                            restRemainingSeconds: nil
                        ))
                        isActive = true
                    }
                }
            }
            .navigationTitle("LiftLog")
        }
    }
}

struct ActiveWatchWorkoutView: View {
    @Binding var isActive: Bool
    @State private var startedAt = Date()
    @State private var elapsed: TimeInterval = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var state: WatchWorkoutSyncState? { WatchSessionManager.shared.lastReceivedState }

    var body: some View {
        TabView {
            VStack(spacing: 8) {
                Text(state?.name ?? "Workout")
                    .font(.headline)
                    .lineLimit(1)
                Text(elapsed.shortDurationText)
                    .font(.title2.bold())
                HStack {
                    MetricBadge(title: "HR", value: WatchHealthKitManager.shared.currentHeartRate.map { "\(Int($0))" } ?? "--")
                    MetricBadge(title: "Avg", value: WatchHealthKitManager.shared.averageHeartRate.map { "\(Int($0))" } ?? "--")
                }
                HStack {
                    MetricBadge(title: "Sets", value: "\(state?.completedSets ?? 0)")
                    MetricBadge(title: "kcal", value: WatchHealthKitManager.shared.activeEnergyKcal.map { "\(Int($0))" } ?? "--")
                }
            }
            SetControlView(state: state)
            PauseEndView(isActive: $isActive)
        }
        .tabViewStyle(.verticalPage)
        .onReceive(timer) { _ in elapsed = Date().timeIntervalSince(startedAt) }
    }
}

struct SetControlView: View {
    let state: WatchWorkoutSyncState?

    var body: some View {
        VStack(spacing: 10) {
            Text(state?.currentExerciseName ?? "No exercise")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Set \(state?.currentSetIndex ?? 0)")
                .foregroundStyle(.secondary)
            Button {
                WatchSessionManager.shared.sendCompleteCurrentSet(workoutId: state?.workoutId)
            } label: {
                Label("Done", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            if let rest = state?.restRemainingSeconds, rest > 0 {
                Text("Rest \(rest)s")
                    .font(.caption)
            }
        }
        .padding()
    }
}

struct PauseEndView: View {
    @Binding var isActive: Bool
    @State private var paused = false

    var body: some View {
        VStack(spacing: 10) {
            Button(paused ? "Resume" : "Pause") {
                paused.toggle()
                if paused {
                    WatchHealthKitManager.shared.pauseWorkout()
                    WatchSessionManager.shared.sendCommand("pauseWorkout")
                } else {
                    WatchHealthKitManager.shared.resumeWorkout()
                    WatchSessionManager.shared.sendCommand("resumeWorkout")
                }
            }
            Button("End") {
                Task {
                    let uuid = await WatchHealthKitManager.shared.endWorkout()
                    WatchSessionManager.shared.sendEndedWorkout(uuid: uuid)
                    isActive = false
                }
            }
            .tint(.red)
        }
    }
}

struct MetricBadge: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.headline)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

@MainActor
final class WatchHealthKitManager: NSObject, ObservableObject {
    static let shared = WatchHealthKitManager()

    @Published private(set) var currentHeartRate: Double?
    @Published private(set) var averageHeartRate: Double?
    @Published private(set) var activeEnergyKcal: Double?

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var heartRateTotal: Double = 0
    private var heartRateCount: Int = 0

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let readTypes: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKObjectType.workoutType()
        ]
        let writeTypes: Set<HKSampleType> = [
            HKObjectType.workoutType(),
            HKQuantityType(.activeEnergyBurned)
        ]
        try? await healthStore.requestAuthorization(toShare: writeTypes, read: readTypes)
    }

    func startWorkout() async {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            heartRateTotal = 0
            heartRateCount = 0
            currentHeartRate = nil
            averageHeartRate = nil
            activeEnergyKcal = nil
            let start = Date()
            session.startActivity(with: start)
            try await builder.beginCollection(at: start)
        } catch {
            self.session = nil
            self.builder = nil
        }
    }

    func pauseWorkout() {
        session?.pause()
    }

    func resumeWorkout() {
        session?.resume()
    }

    func endWorkout() async -> UUID? {
        session?.end()
        guard let builder else { return nil }
        do {
            try await builder.endCollection(at: Date())
            guard let workout = try await builder.finishWorkout() else {
                self.builder = nil
                self.session = nil
                return nil
            }
            self.builder = nil
            self.session = nil
            return workout.uuid
        } catch {
            return nil
        }
    }
}

extension WatchHealthKitManager: HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
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
                        heartRateTotal += bpm
                        heartRateCount += 1
                        averageHeartRate = heartRateTotal / Double(max(1, heartRateCount))
                    }
                } else if quantityType == HKQuantityType(.activeEnergyBurned) {
                    activeEnergyKcal = statistics?.sumQuantity()?.doubleValue(for: .kilocalorie())
                }
            }
        }
    }
}

@MainActor
final class WatchSessionManager: NSObject, ObservableObject {
    static let shared = WatchSessionManager()

    @Published private(set) var lastReceivedState: WatchWorkoutSyncState?
    @Published private(set) var isCompanionAppInstalled = false

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func send(state: WatchWorkoutSyncState) {
        guard canSendToCompanion, let data = try? JSONEncoder().encode(state) else { return }
        sendPayload(["workoutState": data])
    }

    func sendCompleteCurrentSet(workoutId: UUID?) {
        guard canSendToCompanion else { return }
        sendPayload(["command": "completeCurrentSet", "workoutId": workoutId?.uuidString ?? ""])
    }

    func sendEndedWorkout(uuid: UUID?) {
        guard canSendToCompanion else { return }
        sendPayload(["command": "endedWorkout", "healthKitUUID": uuid?.uuidString ?? ""])
    }

    func sendCommand(_ command: String) {
        guard canSendToCompanion else { return }
        sendPayload(["command": command])
    }

    private var canSendToCompanion: Bool {
        guard WCSession.isSupported() else { return false }
        refreshAvailability()
        return isCompanionAppInstalled && WCSession.default.activationState == .activated
    }

    private func refreshAvailability() {
        guard WCSession.isSupported() else {
            isCompanionAppInstalled = false
            return
        }
        guard WCSession.default.activationState == .activated else {
            isCompanionAppInstalled = false
            return
        }
        isCompanionAppInstalled = WCSession.default.isCompanionAppInstalled
    }

    private func sendPayload(_ payload: [String: Any]) {
        guard !payload.isEmpty else { return }
        refreshAvailability()
        guard isCompanionAppInstalled, WCSession.default.activationState == .activated else { return }
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
}

extension WatchSessionManager: WCSessionDelegate {
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
        handle(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handle(applicationContext)
    }

    private nonisolated func handle(_ message: [String: Any]) {
        guard let data = message["workoutState"] as? Data else { return }
        Task { @MainActor in
            guard let state = try? JSONDecoder().decode(WatchWorkoutSyncState.self, from: data) else { return }
            lastReceivedState = state
        }
    }
}

extension TimeInterval {
    var shortDurationText: String {
        let total = max(0, Int(self))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}
