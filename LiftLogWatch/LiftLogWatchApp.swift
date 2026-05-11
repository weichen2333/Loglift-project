import SwiftUI
import Foundation
import Combine
import HealthKit
import WatchConnectivity
import WatchKit

// MARK: - Shared sync types (mirrors iOS WorkoutSyncState)

enum WatchWorkoutStatus: String, Codable {
    case planned
    case active
    case paused
    case completed
    case cancelled
}

struct WatchExerciseSnapshot: Codable, Hashable, Identifiable {
    var id: UUID { workoutExerciseId }
    var workoutExerciseId: UUID
    var exerciseName: String
    var totalSets: Int
    var completedSets: Int
    var currentSetIndex: Int?
    var targetReps: Int?
    var weightText: String?
    var lastWeightText: String?
    var lastReps: Int?
}

struct WatchRoutineSnapshot: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var exerciseCount: Int
    var estimatedSets: Int
}

struct WatchWorkoutSyncState: Codable {
    var workoutId: UUID?
    var name: String
    var status: WatchWorkoutStatus
    var elapsedSeconds: TimeInterval
    var currentExerciseId: UUID?
    var currentExerciseName: String?
    var currentSetId: UUID?
    var currentSetIndex: Int?
    var completedSets: Int
    var totalSets: Int = 0
    var currentHeartRate: Double?
    var averageHeartRate: Double?
    var activeEnergyKcal: Double?
    var restRemainingSeconds: Int?
    var restTotalSeconds: Int?
    /// Wall-clock time the rest period ends. The watch counts down against this
    /// instead of holding the snapshotted `restRemainingSeconds`.
    var restEndsAt: Date?
    var sequence: Int = 0
    var generatedAt: Date = Date()
    var exercises: [WatchExerciseSnapshot] = []
    var routines: [WatchRoutineSnapshot] = []
    var hapticOnRestComplete: Bool = true
    var weightUnit: String = "kg"
}

// MARK: - App entry point

@main
struct LiftLogWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchRootView()
        }
    }
}

struct WatchRootView: View {
    @StateObject private var session = WatchSessionManager.shared
    @State private var isActive = false

    var body: some View {
        Group {
            if isActive || session.lastReceivedState?.status == .active || session.lastReceivedState?.status == .paused {
                ActiveWatchWorkoutView(isActive: $isActive)
            } else {
                StartWorkoutView(isActive: $isActive)
            }
        }
        .task {
            await WatchHealthKitManager.shared.requestAuthorization()
            WatchSessionManager.shared.requestStateFromCompanion()
        }
        .onChange(of: session.lastReceivedState?.status) { _, newStatus in
            // iOS finished or discarded the workout — leave the active screen even if the
            // watch was the one that started it locally.
            if newStatus == .completed || newStatus == .cancelled {
                isActive = false
            }
        }
    }
}

// MARK: - Start

struct StartWorkoutView: View {
    @Binding var isActive: Bool
    @ObservedObject private var session = WatchSessionManager.shared

    private var routines: [WatchRoutineSnapshot] {
        session.lastReceivedState?.routines ?? []
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { await startQuickWorkout() }
                    } label: {
                        Label("快速训练", systemImage: "bolt.fill")
                    }
                }
                if !routines.isEmpty {
                    Section("训练模板") {
                        ForEach(routines) { routine in
                            Button {
                                Task { await startRoutine(routine) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(routine.name).font(.body)
                                    Text("\(routine.exerciseCount) 个动作 · \(routine.estimatedSets) 组")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    Section {
                        Text("从 iPhone 同步后将显示模板。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("训练")
        }
    }

    private func startQuickWorkout() async {
        await WatchHealthKitManager.shared.requestAuthorization()
        await WatchHealthKitManager.shared.startWorkout()
        WatchSessionManager.shared.sendCommand("startQuickWorkout")
        WatchKit.WKInterfaceDevice.current().play(.start)
        isActive = true
    }

    private func startRoutine(_ routine: WatchRoutineSnapshot) async {
        await WatchHealthKitManager.shared.requestAuthorization()
        await WatchHealthKitManager.shared.startWorkout()
        WatchSessionManager.shared.sendCommand("startRoutineWorkout", payload: ["routineId": routine.id.uuidString])
        WatchKit.WKInterfaceDevice.current().play(.start)
        isActive = true
    }
}

// MARK: - Active workout

struct ActiveWatchWorkoutView: View {
    @Binding var isActive: Bool
    @ObservedObject private var session = WatchSessionManager.shared
    @ObservedObject private var health = WatchHealthKitManager.shared
    @State private var startedAt = Date()
    @State private var elapsed: TimeInterval = 0
    @State private var lastRestSeconds: Int = 0
    @State private var liveRestRemaining: Int = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var state: WatchWorkoutSyncState? { session.lastReceivedState }

    /// Seconds remaining in the current rest period, recomputed every tick from
    /// `restEndsAt` so the watch shows a live countdown instead of the value frozen at
    /// the last sync. Falls back to the snapshotted `restRemainingSeconds` when the
    /// phone hasn't sent an end date.
    private func computedRestRemaining() -> Int {
        if let endsAt = state?.restEndsAt {
            return max(0, Int(endsAt.timeIntervalSinceNow.rounded()))
        }
        return state?.restRemainingSeconds ?? 0
    }

    var body: some View {
        TabView {
            metricsPage
            currentSetPage
            exerciseListPage
            controlPage
        }
        .tabViewStyle(.verticalPage)
        .onReceive(timer) { _ in
            if let state, state.status == .active {
                elapsed = state.elapsedSeconds + Date().timeIntervalSince(state.generatedAt)
            } else if let state {
                elapsed = state.elapsedSeconds
            }
            liveRestRemaining = computedRestRemaining()
            handleRestCompletion()
        }
    }

    private var metricsPage: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text(state?.name ?? "训练").font(.headline).lineLimit(1)
                Text(elapsed.shortDurationText).font(.title2.bold())
                HStack {
                    MetricBadge(title: "心率", value: health.currentHeartRate.map { "\(Int($0))" } ?? "--")
                    MetricBadge(title: "平均", value: health.averageHeartRate.map { "\(Int($0))" } ?? "--")
                }
                HStack {
                    MetricBadge(title: "组数", value: "\(state?.completedSets ?? 0)/\(state?.totalSets ?? 0)")
                    MetricBadge(title: "千卡", value: health.activeEnergyKcal.map { "\(Int($0))" } ?? "--")
                }
                if liveRestRemaining > 0 {
                    RestRing(remaining: liveRestRemaining, total: state?.restTotalSeconds ?? liveRestRemaining)
                        .frame(height: 56)
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var currentSetPage: some View {
        VStack(spacing: 10) {
            Text(state?.currentExerciseName ?? "暂无动作")
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let setIndex = state?.currentSetIndex {
                Text("第 \(setIndex) 组")
                    .foregroundStyle(.secondary)
                if let reps = state?.exercises.first(where: { $0.workoutExerciseId == state?.currentExerciseId })?.targetReps {
                    Text("目标 \(reps) 次")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tint)
                }
            }
            if let snapshot = state?.exercises.first(where: { $0.workoutExerciseId == state?.currentExerciseId }),
               let last = snapshot.lastWeightText {
                Text("上次：\(last)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button {
                WatchKit.WKInterfaceDevice.current().play(.success)
                WatchSessionManager.shared.sendCompleteCurrentSet(workoutId: state?.workoutId, setId: state?.currentSetId)
            } label: {
                Label("完成本组", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(state?.currentSetId == nil)
            if liveRestRemaining > 0 {
                Text("休息 \(liveRestRemaining) 秒")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tint)
            }
        }
        .padding()
    }

    private var exerciseListPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("动作列表")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(state?.exercises ?? []) { exercise in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(exercise.exerciseName)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Text("\(exercise.completedSets)/\(exercise.totalSets) 组")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if let last = exercise.lastWeightText {
                                Text("上次：\(last)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        if exercise.workoutExerciseId == state?.currentExerciseId {
                            Image(systemName: "arrow.right.circle.fill").foregroundStyle(.tint)
                        }
                    }
                    .padding(.vertical, 2)
                    Divider()
                }
                if state?.exercises.isEmpty ?? true {
                    Text("动作将从 iPhone 同步。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var controlPage: some View {
        VStack(spacing: 10) {
            Button(state?.status == .paused ? "继续" : "暂停") {
                WatchKit.WKInterfaceDevice.current().play(.click)
                if state?.status == .paused {
                    WatchHealthKitManager.shared.resumeWorkout()
                    WatchSessionManager.shared.sendCommand("resumeWorkout")
                } else {
                    WatchHealthKitManager.shared.pauseWorkout()
                    WatchSessionManager.shared.sendCommand("pauseWorkout")
                }
            }
            Button("结束", role: .destructive) {
                Task {
                    let uuid = await WatchHealthKitManager.shared.endWorkout()
                    WatchSessionManager.shared.sendEndedWorkout(uuid: uuid)
                    WatchKit.WKInterfaceDevice.current().play(.stop)
                    isActive = false
                }
            }
            .tint(.red)
        }
        .padding()
    }

    private func handleRestCompletion() {
        let rest = liveRestRemaining
        if lastRestSeconds > 0 && rest == 0, state?.hapticOnRestComplete ?? true {
            WatchKit.WKInterfaceDevice.current().play(.notification)
        }
        lastRestSeconds = rest
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value)")
    }
}

struct RestRing: View {
    let remaining: Int
    let total: Int

    private var progress: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, 1 - Double(remaining) / Double(total)))
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.accentColor.opacity(0.2), lineWidth: 5)
            Circle()
                .trim(from: 0, to: CGFloat(progress))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(remaining)").font(.headline.monospacedDigit())
                Text("休息").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - HealthKit (watch)

@MainActor
final class WatchHealthKitManager: NSObject, ObservableObject {
    static let shared = WatchHealthKitManager()

    @Published private(set) var currentHeartRate: Double?
    @Published private(set) var averageHeartRate: Double?
    @Published private(set) var activeEnergyKcal: Double?

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

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
                    }
                    // Time-weighted average from HK rather than manual sample averaging.
                    if let avg = statistics?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())) {
                        averageHeartRate = avg
                    }
                } else if quantityType == HKQuantityType(.activeEnergyBurned) {
                    activeEnergyKcal = statistics?.sumQuantity()?.doubleValue(for: .kilocalorie())
                }
            }
        }
    }
}

// MARK: - WatchConnectivity

@MainActor
final class WatchSessionManager: NSObject, ObservableObject {
    static let shared = WatchSessionManager()

    @Published private(set) var lastReceivedState: WatchWorkoutSyncState?
    @Published private(set) var isCompanionAppInstalled = false
    @Published private(set) var isReachable = false
    @Published private(set) var lastSyncReceivedAt: Date?
    private var processedCommandIds: Set<UUID> = []

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

    func sendCompleteCurrentSet(workoutId: UUID?, setId: UUID?) {
        guard canSendToCompanion else { return }
        sendPayload([
            "command": "completeCurrentSet",
            "commandId": UUID().uuidString,
            "workoutId": workoutId?.uuidString ?? "",
            "setId": setId?.uuidString ?? ""
        ])
    }

    func sendEndedWorkout(uuid: UUID?) {
        guard canSendToCompanion else { return }
        sendPayload([
            "command": "endedWorkout",
            "commandId": UUID().uuidString,
            "healthKitUUID": uuid?.uuidString ?? ""
        ])
    }

    func sendCommand(_ command: String, payload: [String: Any] = [:]) {
        guard canSendToCompanion else { return }
        var merged: [String: Any] = ["command": command, "commandId": UUID().uuidString]
        for (k, v) in payload { merged[k] = v }
        sendPayload(merged)
    }

    func requestStateFromCompanion() {
        sendCommand("requestState")
    }

    private func sendAcknowledgement(sequence: Int) {
        sendPayload(["command": "acknowledge", "ackSequence": sequence])
    }

    private var canSendToCompanion: Bool {
        guard WCSession.isSupported() else { return false }
        refreshAvailability()
        return isCompanionAppInstalled && WCSession.default.activationState == .activated
    }

    private func refreshAvailability() {
        guard WCSession.isSupported() else {
            isCompanionAppInstalled = false
            isReachable = false
            return
        }
        guard WCSession.default.activationState == .activated else {
            isCompanionAppInstalled = false
            isReachable = false
            return
        }
        isCompanionAppInstalled = WCSession.default.isCompanionAppInstalled
        isReachable = WCSession.default.isReachable
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
            if activationState == .activated {
                requestStateFromCompanion()
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            refreshAvailability()
            if WCSession.default.isReachable {
                requestStateFromCompanion()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handle(applicationContext)
    }

    private nonisolated func handle(_ message: [String: Any]) {
        if let data = message["workoutState"] as? Data {
            Task { @MainActor in
                guard let state = try? JSONDecoder().decode(WatchWorkoutSyncState.self, from: data) else { return }
                lastReceivedState = state
                lastSyncReceivedAt = Date()
                if state.sequence > 0 {
                    sendAcknowledgement(sequence: state.sequence)
                }
            }
            return
        }
        // Drop stray commands targeted at iPhone (we only care about state on watch side).
        if let commandIdString = message["commandId"] as? String,
           let commandId = UUID(uuidString: commandIdString) {
            Task { @MainActor in
                if processedCommandIds.contains(commandId) { return }
                processedCommandIds.insert(commandId)
                if processedCommandIds.count > 200 {
                    processedCommandIds = Set(processedCommandIds.suffix(100))
                }
            }
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
