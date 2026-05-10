import SwiftUI

#if os(watchOS)
import HealthKit

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
    @State private var routines = ["Quick Workout", "Push Day", "Pull Day", "Leg Day"]

    var body: some View {
        NavigationStack {
            List {
                ForEach(routines, id: \.self) { routine in
                    Button(routine) {
                        Task {
                            await HealthKitManager.shared.requestAuthorization()
                            await HealthKitManager.shared.startWorkout(activityType: .traditionalStrengthTraining)
                            WatchConnectivityManager.shared.send(state: WorkoutSyncState(
                                workoutId: nil,
                                name: routine,
                                status: .active,
                                elapsedSeconds: 0,
                                currentWorkoutExerciseId: nil,
                                currentSetId: nil,
                                currentExerciseName: nil,
                                currentSetIndex: nil,
                                completedSets: 0,
                                currentHeartRate: nil,
                                averageHeartRate: nil,
                                activeEnergyKcal: nil,
                                restRemainingSeconds: nil,
                                availableRoutines: nil,
                                workoutExercises: nil
                            ))
                            isActive = true
                        }
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
    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var state: WorkoutSyncState? { WatchConnectivityManager.shared.lastReceivedState }

    var body: some View {
        TabView {
            VStack(spacing: 8) {
                Text(state?.name ?? "Workout")
                    .font(.headline)
                    .lineLimit(1)
                Text(elapsed.shortDurationText)
                    .font(.title2.bold())
                HStack {
                    MetricBadge(title: "HR", value: HealthKitManager.shared.currentHeartRate.map { "\(Int($0))" } ?? "--")
                    MetricBadge(title: "Avg", value: HealthKitManager.shared.averageHeartRate.map { "\(Int($0))" } ?? "--")
                }
                HStack {
                    MetricBadge(title: "Sets", value: "\(state?.completedSets ?? 0)")
                    MetricBadge(title: "kcal", value: HealthKitManager.shared.activeEnergyKcal.map { "\(Int($0))" } ?? "--")
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
    let state: WorkoutSyncState?

    var body: some View {
        VStack(spacing: 10) {
            Text(state?.currentExerciseName ?? "No exercise")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Set \(state?.currentSetIndex ?? 0)")
                .foregroundStyle(.secondary)
            Button {
                WatchConnectivityManager.shared.sendCompleteCurrentSet(workoutId: state?.workoutId)
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
                    HealthKitManager.shared.pauseWorkout()
                    WatchConnectivityManager.shared.sendCommand(.pauseWorkout)
                } else {
                    HealthKitManager.shared.resumeWorkout()
                    WatchConnectivityManager.shared.sendCommand(.resumeWorkout)
                }
            }
            Button("End") {
                Task {
                    let uuid = await HealthKitManager.shared.endWorkout()
                    WatchConnectivityManager.shared.sendEndedWorkout(uuid: uuid)
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
#endif
