import SwiftUI
import Foundation
import Combine
import HealthKit
import WatchConnectivity
import WatchKit

enum WatchWorkoutStatus: String, Codable {
    case planned
    case active
    case paused
    case completed
    case cancelled
}

struct WatchWorkoutSyncState: Codable {
    var workoutId: UUID?
    var name: String
    var status: WatchWorkoutStatus
    var elapsedSeconds: TimeInterval
    var currentWorkoutExerciseId: UUID?
    var currentSetId: UUID?
    var currentExerciseName: String?
    var currentSetIndex: Int?
    var completedSets: Int
    var currentHeartRate: Double?
    var averageHeartRate: Double?
    var activeEnergyKcal: Double?
    var restRemainingSeconds: Int?
    var availableRoutines: [WatchRoutineSummary]?
    var workoutExercises: [WatchWorkoutExerciseSnapshot]?
}

struct WatchRoutineSummary: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var exerciseCount: Int
    var targetSetCount: Int
}

struct WatchWorkoutExerciseSnapshot: Codable, Identifiable, Hashable {
    var id: UUID
    var exerciseId: UUID
    var name: String
    var sortOrder: Int
    var completedSets: Int
    var totalSets: Int
    var sets: [WatchSetSnapshot]
}

struct WatchSetSnapshot: Codable, Identifiable, Hashable {
    var id: UUID
    var setIndex: Int
    var setType: String
    var targetReps: Int
    var actualReps: Int
    var weightMode: String
    var weight: Double
    var leftWeight: Double
    var rightWeight: Double
    var bodyweightAdditionalLoad: Double
    var assistanceWeight: Double
    var durationSeconds: Int
    var distanceMeters: Double
    var rpe: Double?
    var isCompleted: Bool

    var loadText: String {
        if durationSeconds > 0 && weight <= 0 && leftWeight <= 0 && rightWeight <= 0 {
            return "\(durationSeconds)s"
        }
        if distanceMeters > 0 && weight <= 0 {
            return "\(Int(distanceMeters))m"
        }
        if leftWeight > 0 || rightWeight > 0 {
            return "\(trim(leftWeight + rightWeight)) kg"
        }
        if assistanceWeight > 0 {
            return "-\(trim(assistanceWeight)) kg"
        }
        let load = max(weight, bodyweightAdditionalLoad)
        return load > 0 ? "\(trim(load)) kg" : "BW"
    }

    var repsText: String {
        actualReps > 0 ? "x\(actualReps)" : "\(durationSeconds)s"
    }

    private func trim(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value))" : String(format: "%.1f", value)
    }
}

struct WatchHeartRateSamplePayload: Codable, Hashable {
    var timestamp: Date
    var bpm: Double
}

struct WatchWorkoutMetricsPayload: Codable, Hashable {
    var currentHeartRate: Double?
    var averageHeartRate: Double?
    var activeEnergyKcal: Double?
    var heartRateSamples: [WatchHeartRateSamplePayload]
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
    @ObservedObject private var sessionManager = WatchSessionManager.shared

    private var shouldShowActiveWorkout: Bool {
        isActive || sessionManager.lastReceivedState?.status == .active || sessionManager.lastReceivedState?.status == .paused
    }

    var body: some View {
        if shouldShowActiveWorkout {
            ActiveWatchWorkoutView(isActive: $isActive)
        } else {
            StartWorkoutView(isActive: $isActive)
        }
    }
}

struct StartWorkoutView: View {
    @Binding var isActive: Bool
    @State private var pendingStartName: String?
    @ObservedObject private var sessionManager = WatchSessionManager.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("LiftLog")
                            .font(.headline)
                        StatusPill(text: sessionManager.statusText, systemImage: sessionManager.isReachable ? "iphone.radiowaves.left.and.right" : "iphone")
                        Spacer(minLength: 0)
                    }

                    Button {
                        sessionManager.requestCurrentState()
                        WKInterfaceDevice.current().play(.click)
                    } label: {
                        Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        requestStart(name: "Quick Workout", routineId: nil, isQuickStart: true)
                    } label: {
                        HStack {
                            Image(systemName: "bolt.fill")
                            Text("Quick")
                                .font(.headline)
                            Spacer()
                            if pendingStartName == "Quick Workout" {
                                ProgressView()
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(pendingStartName != nil)

                    if sessionManager.availableRoutines.isEmpty {
                        Text("No templates")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    }

                    ForEach(sessionManager.availableRoutines) { routine in
                        Button {
                            requestStart(name: routine.name, routineId: routine.id, isQuickStart: false)
                        } label: {
                            HStack {
                                Image(systemName: "list.bullet.rectangle")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(routine.name)
                                        .lineLimit(1)
                                    Text("\(routine.exerciseCount) ex · \(routine.targetSetCount) sets")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if pendingStartName == routine.name {
                                    ProgressView()
                                } else {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(pendingStartName != nil)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 2)
            }
            .navigationTitle("Start")
            .onAppear {
                sessionManager.requestCurrentState()
            }
            .onChange(of: sessionManager.lastReceivedState?.status) { _, status in
                if status == .active || status == .paused {
                    pendingStartName = nil
                    isActive = true
                }
            }
        }
    }

    private func requestStart(name: String, routineId: UUID?, isQuickStart: Bool) {
        pendingStartName = name
        sessionManager.sendStartWorkout(name: name, routineId: routineId, isQuickStart: isQuickStart)
        WKInterfaceDevice.current().play(.click)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            sessionManager.requestCurrentState()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if pendingStartName == name {
                pendingStartName = nil
            }
        }
    }
}

private enum WatchWorkoutPage: Hashable {
    case overview
    case controls
    case plan
    case pause
}

struct ActiveWatchWorkoutView: View {
    @Binding var isActive: Bool
    @State private var previousRestRemaining: Int?
    @State private var currentTime = Date()
    @State private var showRestReadyBanner = false
    @State private var sentCompletionMetricsForWorkoutId: UUID?
    @State private var selectedPage: WatchWorkoutPage = .overview
    @ObservedObject private var sessionManager = WatchSessionManager.shared
    @ObservedObject private var healthKit = WatchHealthKitManager.shared

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var state: WatchWorkoutSyncState? { sessionManager.lastReceivedState }
    private var displayElapsed: TimeInterval {
        guard let state else { return 0 }
        guard state.status == .active else { return state.elapsedSeconds }
        return state.elapsedSeconds + max(0, currentTime.timeIntervalSince(sessionManager.lastReceivedAt))
    }
    private var liveHeartRate: Double? { healthKit.currentHeartRate ?? state?.currentHeartRate }
    private var liveAverageHeartRate: Double? { healthKit.averageHeartRate ?? state?.averageHeartRate }
    private var liveEnergy: Double? { healthKit.activeEnergyKcal ?? state?.activeEnergyKcal }
    private var displayRestSeconds: Int {
        guard let rest = state?.restRemainingSeconds, rest > 0 else { return 0 }
        guard state?.status == .active else { return rest }
        let elapsedSinceSync = max(0, Int(currentTime.timeIntervalSince(sessionManager.lastReceivedAt)))
        return max(0, rest - elapsedSinceSync)
    }

    var body: some View {
        TabView(selection: $selectedPage) {
            WorkoutOverviewPage(
                state: state,
                elapsed: displayElapsed,
                heartRate: liveHeartRate,
                averageHeartRate: liveAverageHeartRate,
                activeEnergy: liveEnergy
            )
            .tag(WatchWorkoutPage.overview)
            SetControlView(state: state, restSeconds: displayRestSeconds)
                .tag(WatchWorkoutPage.controls)
            WorkoutPlanPage(state: state)
                .tag(WatchWorkoutPage.plan)
            PauseEndView(isActive: $isActive, state: state)
                .tag(WatchWorkoutPage.pause)
        }
        .tabViewStyle(.verticalPage)
        .overlay(alignment: .top) {
            if showRestReadyBanner {
                WatchRestReadyBanner(state: state)
                    .padding(.horizontal, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onReceive(ticker) { date in
            currentTime = date
            handleRestRemainingChange(to: displayRestSeconds)
        }
        .onAppear {
            handleStatusChange(state?.status)
        }
        .onChange(of: state?.workoutId) { _, _ in
            handleStatusChange(state?.status)
        }
        .onChange(of: state?.restRemainingSeconds) { _, newValue in
            handleRestRemainingChange(to: newValue ?? 0)
        }
        .onChange(of: state?.status) { _, status in
            handleStatusChange(status)
        }
    }

    private func handleRestRemainingChange(to rest: Int) {
        guard state?.status == .active else {
            previousRestRemaining = rest
            return
        }
        if let previousRestRemaining, previousRestRemaining > 0, rest == 0 {
            if sessionManager.suppressNextRestReadyAlert {
                sessionManager.suppressNextRestReadyAlert = false
            } else {
                WKInterfaceDevice.current().play(.notification)
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    showRestReadyBanner = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showRestReadyBanner = false
                    }
                }
            }
        }
        previousRestRemaining = rest
    }

    private func handleStatusChange(_ status: WatchWorkoutStatus?) {
        guard let status else { return }
        switch status {
        case .active:
            if selectedPage == .pause {
                selectedPage = .overview
            }
            reconcileHealthKit(with: state)
        case .paused:
            selectedPage = .pause
            reconcileHealthKit(with: state)
        case .completed:
            finishFromCompanion()
        case .cancelled:
            cancelFromCompanion()
        case .planned:
            sessionManager.clearWorkoutState()
            isActive = false
        }
    }

    private func finishFromCompanion() {
        let completedWorkoutId = state?.workoutId
        guard completedWorkoutId == nil || sentCompletionMetricsForWorkoutId != completedWorkoutId else { return }
        sentCompletionMetricsForWorkoutId = completedWorkoutId
        Task {
            let uuid = await healthKit.endWorkout()
            sessionManager.sendEndedWorkout(
                uuid: uuid,
                workoutId: completedWorkoutId,
                metrics: healthKit.metricsPayload()
            )
            WKInterfaceDevice.current().play(.success)
            sessionManager.clearWorkoutState()
            isActive = false
        }
    }

    private func cancelFromCompanion() {
        Task {
            await healthKit.discardWorkout()
            WKInterfaceDevice.current().play(.stop)
            sessionManager.clearWorkoutState()
            isActive = false
        }
    }

    private func reconcileHealthKit(with state: WatchWorkoutSyncState?) {
        guard let state, state.workoutId != nil else { return }
        switch state.status {
        case .active:
            Task {
                await healthKit.requestAuthorization()
                if healthKit.isWorkoutRunning {
                    healthKit.resumeWorkout()
                } else {
                    await healthKit.startWorkout()
                }
            }
        case .paused:
            if healthKit.isWorkoutRunning {
                healthKit.pauseWorkout()
            }
        case .completed:
            Task {
                _ = await healthKit.endWorkout()
            }
        case .cancelled:
            Task {
                await healthKit.discardWorkout()
            }
        case .planned:
            break
        }
    }
}

struct WorkoutOverviewPage: View {
    let state: WatchWorkoutSyncState?
    let elapsed: TimeInterval
    let heartRate: Double?
    let averageHeartRate: Double?
    let activeEnergy: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state?.name ?? "Workout")
                        .font(.headline)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: state?.status == .paused ? "pause.circle.fill" : "figure.strengthtraining.traditional")
                    .foregroundStyle(state?.status == .paused ? .orange : .green)
            }

            Text(elapsed.shortDurationText)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                MetricBadge(title: "HR", value: heartRate.map { "\(Int($0))" } ?? "--", systemImage: "heart.fill")
                MetricBadge(title: "Avg", value: averageHeartRate.map { "\(Int($0))" } ?? "--", systemImage: "waveform.path.ecg")
                MetricBadge(title: "Sets", value: "\(state?.completedSets ?? 0)", systemImage: "checkmark.circle.fill")
                MetricBadge(title: "kcal", value: activeEnergy.map { "\(Int($0))" } ?? "--", systemImage: "flame.fill")
            }
        }
        .padding(.horizontal)
    }
}

struct SetControlView: View {
    let state: WatchWorkoutSyncState?
    let restSeconds: Int
    private var hasNextSet: Bool { state?.workoutId != nil && state?.currentSetIndex != nil }
    private var currentSet: WatchSetSnapshot? {
        if let currentSetId = state?.currentSetId {
            return state?.workoutExercises?
                .flatMap(\.sets)
                .first { $0.id == currentSetId }
        }
        guard let currentExerciseName = state?.currentExerciseName,
              let currentSetIndex = state?.currentSetIndex else { return nil }
        return state?.workoutExercises?
            .first { $0.name == currentExerciseName }?
            .sets
            .first { $0.setIndex == currentSetIndex }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if restSeconds > 0 {
                RestCountdownCard(restSeconds: restSeconds, workoutId: state?.workoutId)
            } else {
                Text(state?.currentExerciseName ?? "No exercise selected")
                    .font(.headline)
                    .lineLimit(2)
                if let currentSet {
                    HStack(spacing: 8) {
                        Text("Set \(currentSet.setIndex)")
                        Text(currentSet.loadText)
                        Text(currentSet.repsText)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                } else {
                    Text(hasNextSet ? "Set \(state?.currentSetIndex ?? 0)" : "No set")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                if restSeconds > 0 {
                    WatchSessionManager.shared.suppressNextRestReadyAlert = true
                    WatchSessionManager.shared.sendCommand("skipRest", workoutId: state?.workoutId)
                } else {
                    WatchSessionManager.shared.sendCompleteCurrentSet(workoutId: state?.workoutId)
                }
                WKInterfaceDevice.current().play(.click)
            } label: {
                Label(restSeconds > 0 ? "Skip Rest" : "Done", systemImage: restSeconds > 0 ? "forward.fill" : "checkmark.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasNextSet)
        }
        .padding(.horizontal)
    }
}

struct WorkoutPlanPage: View {
    let state: WatchWorkoutSyncState?

    private var exercises: [WatchWorkoutExerciseSnapshot] {
        (state?.workoutExercises ?? []).sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Plan")
                        .font(.headline)
                    Spacer()
                    Text("\(state?.completedSets ?? 0)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if exercises.isEmpty {
                    Text("Add on iPhone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                } else {
                    ForEach(exercises) { exercise in
                            WatchExercisePlanRow(exercise: exercise, isCurrent: exercise.id == state?.currentWorkoutExerciseId || exercise.name == state?.currentExerciseName)
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

struct WatchExercisePlanRow: View {
    let exercise: WatchWorkoutExerciseSnapshot
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: isCurrent ? "scope" : "dumbbell")
                    .font(.caption2)
                    .foregroundStyle(isCurrent ? .green : .secondary)
                Text(exercise.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text("\(exercise.completedSets)/\(exercise.totalSets)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                ForEach(exercise.sets.prefix(6)) { set in
                    Text("\(set.setIndex)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .frame(width: 20, height: 18)
                        .background(set.isCompleted ? Color.green.opacity(0.35) : Color.secondary.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(set.isCompleted ? .green : .secondary)
                }
                if exercise.sets.count > 6 {
                    Text("+\(exercise.sets.count - 6)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let firstOpen = exercise.sets.first(where: { !$0.isCompleted }) ?? exercise.sets.last {
                Text("\(firstOpen.loadText) \(firstOpen.repsText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(isCurrent ? Color.green.opacity(0.12) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PauseEndView: View {
    @Binding var isActive: Bool
    let state: WatchWorkoutSyncState?
    @State private var showingFinishConfirmation = false
    @State private var showingDiscardConfirmation = false
    private var isPaused: Bool { state?.status == .paused }

    var body: some View {
        VStack(spacing: 10) {
            Button {
                if isPaused {
                    WatchHealthKitManager.shared.resumeWorkout()
                    WatchSessionManager.shared.sendCommand("resumeWorkout", workoutId: state?.workoutId)
                    WKInterfaceDevice.current().play(.start)
                } else {
                    WatchHealthKitManager.shared.pauseWorkout()
                    WatchSessionManager.shared.sendCommand("pauseWorkout", workoutId: state?.workoutId)
                    WKInterfaceDevice.current().play(.stop)
                }
            } label: {
                Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(isPaused ? .green : .orange)

            Button {
                showingFinishConfirmation = true
            } label: {
                Label("Finish", systemImage: "flag.checkered")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button(role: .destructive) {
                showingDiscardConfirmation = true
            } label: {
                Label("Discard", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .confirmationDialog("Finish workout?", isPresented: $showingFinishConfirmation, titleVisibility: .visible) {
            Button("Save Workout") {
                finishWorkout()
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Discard workout?", isPresented: $showingDiscardConfirmation, titleVisibility: .visible) {
            Button("Discard Workout", role: .destructive) {
                discardWorkout()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func finishWorkout() {
        Task {
            let uuid = await WatchHealthKitManager.shared.endWorkout()
            WatchSessionManager.shared.sendEndedWorkout(
                uuid: uuid,
                workoutId: state?.workoutId,
                metrics: WatchHealthKitManager.shared.metricsPayload()
            )
            WKInterfaceDevice.current().play(.success)
            WatchSessionManager.shared.clearWorkoutState()
            isActive = false
        }
    }

    private func discardWorkout() {
        Task {
            await WatchHealthKitManager.shared.discardWorkout()
            WatchSessionManager.shared.sendCommand("cancelWorkout", workoutId: state?.workoutId)
            WKInterfaceDevice.current().play(.stop)
            WatchSessionManager.shared.clearWorkoutState()
            isActive = false
        }
    }
}

struct MetricBadge: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline)
                .monospacedDigit()
            Label(title, systemImage: systemImage)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .padding(7)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct RestCountdownCard: View {
    let restSeconds: Int
    let workoutId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(TimeInterval(restSeconds).shortDurationText)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
            HStack {
                Button("-30") {
                    WatchSessionManager.shared.sendCommand("reduceRest", workoutId: workoutId)
                    WKInterfaceDevice.current().play(.click)
                }
                Button("Skip") {
                    WatchSessionManager.shared.sendCommand("skipRest", workoutId: workoutId)
                    WKInterfaceDevice.current().play(.click)
                }
                Button("+30") {
                    WatchSessionManager.shared.sendCommand("extendRest", workoutId: workoutId)
                    WKInterfaceDevice.current().play(.click)
                }
            }
            .buttonStyle(.bordered)
            .font(.caption)
        }
        .padding(9)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct WatchRestReadyBanner: View {
    let state: WatchWorkoutSyncState?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.badge.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Next set")
                    .font(.caption.weight(.semibold))
                Text(detailText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var detailText: String {
        if let name = state?.currentExerciseName, let set = state?.currentSetIndex {
            return "\(name) · Set \(set)"
        }
        return "Ready"
    }
}

struct StatusPill: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule())
    }
}

@MainActor
final class WatchHealthKitManager: NSObject, ObservableObject {
    static let shared = WatchHealthKitManager()

    @Published private(set) var currentHeartRate: Double?
    @Published private(set) var averageHeartRate: Double?
    @Published private(set) var activeEnergyKcal: Double?
    @Published private(set) var isWorkoutRunning = false
    @Published private(set) var liveHeartRateSamples: [WatchHeartRateSamplePayload] = []

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
        guard !isWorkoutRunning else { return }
        guard HKHealthStore.isHealthDataAvailable() else { return }
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
            liveHeartRateSamples.removeAll()
            currentHeartRate = nil
            averageHeartRate = nil
            activeEnergyKcal = nil
            let start = Date()
            session.startActivity(with: start)
            try await builder.beginCollection(at: start)
            isWorkoutRunning = true
        } catch {
            self.session = nil
            self.builder = nil
            isWorkoutRunning = false
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
        guard let builder else {
            isWorkoutRunning = false
            return nil
        }
        do {
            try await builder.endCollection(at: Date())
            guard let workout = try await builder.finishWorkout() else {
                self.builder = nil
                self.session = nil
                isWorkoutRunning = false
                return nil
            }
            self.builder = nil
            self.session = nil
            isWorkoutRunning = false
            return workout.uuid
        } catch {
            self.builder = nil
            self.session = nil
            isWorkoutRunning = false
            return nil
        }
    }

    func discardWorkout() async {
        session?.end()
        guard let builder else {
            self.session = nil
            isWorkoutRunning = false
            return
        }
        do {
            try await builder.endCollection(at: Date())
        } catch {}
        builder.discardWorkout()
        self.builder = nil
        self.session = nil
        isWorkoutRunning = false
    }

    func metricsPayload() -> WatchWorkoutMetricsPayload {
        WatchWorkoutMetricsPayload(
            currentHeartRate: currentHeartRate,
            averageHeartRate: averageHeartRate,
            activeEnergyKcal: activeEnergyKcal,
            heartRateSamples: liveHeartRateSamples
        )
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
                        let now = Date()
                        if let lastSample = liveHeartRateSamples.last, now.timeIntervalSince(lastSample.timestamp) < 1 {
                            liveHeartRateSamples[liveHeartRateSamples.count - 1] = WatchHeartRateSamplePayload(timestamp: now, bpm: bpm)
                        } else {
                            liveHeartRateSamples.append(WatchHeartRateSamplePayload(timestamp: now, bpm: bpm))
                        }
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
    @Published private(set) var lastReceivedAt = Date()
    @Published private(set) var availableRoutines: [WatchRoutineSummary] = []
    @Published private(set) var isCompanionAppInstalled = false
    @Published private(set) var isReachable = false
    @Published private(set) var activationStateText = "Inactive"
    var suppressNextRestReadyAlert = false

    var statusText: String {
        guard WCSession.isSupported() else { return "Unsupported" }
        guard activationStateText == "Activated" else { return activationStateText }
        guard isCompanionAppInstalled else { return "iPhone app missing" }
        return isReachable ? "Reachable" : "Background"
    }

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

    func clearWorkoutState() {
        lastReceivedState = nil
        lastReceivedAt = Date()
        suppressNextRestReadyAlert = false
    }

    func requestCurrentState() {
        guard canSendToCompanion else { return }
        sendPayload(["command": "requestState"], queued: true)
    }

    func sendStartWorkout(name: String, routineId: UUID?, isQuickStart: Bool) {
        guard canSendToCompanion else { return }
        var payload: [String: Any] = [
            "command": "startWorkout",
            "workoutName": name,
            "isQuickStart": isQuickStart
        ]
        if let routineId {
            payload["routineId"] = routineId.uuidString
        }
        sendPayload(payload, queued: true)
    }

    func sendCompleteCurrentSet(workoutId: UUID?) {
        guard canSendToCompanion else { return }
        sendPayload(["command": "completeCurrentSet", "workoutId": workoutId?.uuidString ?? ""], queued: true)
    }

    func sendEndedWorkout(uuid: UUID?, workoutId: UUID?, metrics: WatchWorkoutMetricsPayload?) {
        guard canSendToCompanion else { return }
        var payload: [String: Any] = [
            "command": "endedWorkout",
            "healthKitUUID": uuid?.uuidString ?? "",
            "workoutId": workoutId?.uuidString ?? ""
        ]
        if let metrics, let data = try? JSONEncoder().encode(metrics) {
            payload["workoutMetrics"] = data
        }
        sendPayload(payload, queued: true)
    }

    func sendCommand(_ command: String, workoutId: UUID? = nil) {
        guard canSendToCompanion else { return }
        var payload: [String: Any] = ["command": command]
        if let workoutId {
            payload["workoutId"] = workoutId.uuidString
        }
        sendPayload(payload, queued: true)
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
            isReachable = false
            activationStateText = WCSession.default.activationState.statusText
            return
        }
        activationStateText = WCSession.default.activationState.statusText
        isCompanionAppInstalled = WCSession.default.isCompanionAppInstalled
        isReachable = WCSession.default.isReachable
    }

    private func sendPayload(_ payload: [String: Any], queued: Bool = false) {
        guard !payload.isEmpty else { return }
        refreshAvailability()
        guard isCompanionAppInstalled, WCSession.default.activationState == .activated else { return }
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(payload, replyHandler: nil) { _ in
                if queued {
                    WCSession.default.transferUserInfo(payload)
                } else {
                    try? WCSession.default.updateApplicationContext(payload)
                }
            }
        } else if queued {
            WCSession.default.transferUserInfo(payload)
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

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        handle(userInfo)
    }

    private nonisolated func handle(_ message: [String: Any]) {
        guard let data = message["workoutState"] as? Data else { return }
        Task { @MainActor in
            guard let state = try? JSONDecoder().decode(WatchWorkoutSyncState.self, from: data) else { return }
            lastReceivedState = state
            lastReceivedAt = Date()
            if let routines = state.availableRoutines {
                availableRoutines = routines
            }
        }
    }
}

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
