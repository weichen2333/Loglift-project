import SwiftUI
import SwiftData
import Charts
import Combine
#if canImport(UIKit)
import UIKit
#endif

enum LiftLogTab: Hashable {
    case dashboard
    case train
    case calendar
    case progress
    case settings
}

enum TrainLaunchIntent: Equatable {
    case none
    case addExercise(workoutId: UUID)
}

private enum AppLayout {
    static let screenHorizontalPadding: CGFloat = 16
    static let screenTopPadding: CGFloat = 8
    static let screenBottomPadding: CGFloat = 20
    static let screenSpacing: CGFloat = 16
    static let sectionSpacing: CGFloat = 12
    static let compactSpacing: CGFloat = 10
    static let cardCornerRadius: CGFloat = 8
}

struct ScreenContent<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        LazyVStack(alignment: .leading, spacing: AppLayout.screenSpacing) {
            content
        }
        .padding(.horizontal, AppLayout.screenHorizontalPadding)
        .padding(.top, AppLayout.screenTopPadding)
        .padding(.bottom, AppLayout.screenBottomPadding)
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutSession.workoutDate, order: .reverse) private var sessions: [WorkoutSession]
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @Query(sort: \WorkoutRoutine.name) private var routines: [WorkoutRoutine]
    @Query private var settings: [UserSettings]
    @State private var selectedTab: LiftLogTab = .dashboard
    @State private var trainLaunchIntent: TrainLaunchIntent = .none
    @State private var workoutVM = WorkoutSessionViewModel()
    @State private var routineVM = RoutineViewModel()
    @State private var completedSessionForSummary: WorkoutSession?
    @State private var watchCommandTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var activeSession: WorkoutSession? {
        sessions.first { $0.status == .active || $0.status == .paused }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(sessions: sessions, exercises: exercises, routines: routines, settings: settings.first, selectedTab: $selectedTab, trainLaunchIntent: $trainLaunchIntent, workoutVM: workoutVM, routineVM: routineVM)
                .tabItem { Label("Dashboard", systemImage: "house") }
                .tag(LiftLogTab.dashboard)
            TrainView(exercises: exercises, routines: routines, settings: settings.first, trainLaunchIntent: $trainLaunchIntent, workoutVM: workoutVM, routineVM: routineVM) { session in
                completedSessionForSummary = session
            }
                .tabItem { Label("Train", systemImage: "figure.strengthtraining.traditional") }
                .tag(LiftLogTab.train)
            WorkoutCalendarView(sessions: sessions, settings: settings.first)
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(LiftLogTab.calendar)
            ProgressAnalyticsView(sessions: sessions, exercises: exercises, settings: settings.first)
                .tabItem { Label("Progress", systemImage: "chart.xyaxis.line") }
                .tag(LiftLogTab.progress)
            SettingsView(settings: settings.first, sessions: sessions, exercises: exercises, routines: routines)
                .tabItem { Label("Setting", systemImage: "gearshape") }
                .tag(LiftLogTab.settings)
        }
        .preferredColorScheme(settings.first?.theme.preferredColorScheme)
        .tint(settings.first?.accentColor.swiftUIColor ?? .pink)
        .task {
            SeedData.ensureSeeded(modelContext: modelContext)
        }
        .onReceive(watchCommandTimer) { _ in
            handleWatchCommands(refreshStatus: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .watchConnectivityCommandReceived)) { _ in
            handleWatchCommands()
        }
        .sheet(item: $completedSessionForSummary) { session in
            WorkoutDetailView(session: session, settings: settings.first)
        }
    }

    private func handleWatchCommands(refreshStatus: Bool = false) {
        let connectivity = WatchConnectivityManager.shared
        if refreshStatus {
            connectivity.refreshStatus()
        }

        if connectivity.consumeStateRequest() {
            sendAuthoritativeWatchState(for: activeSession, force: true)
        }

        if let startRequest = connectivity.consumeStartWorkoutCommand() {
            let session: WorkoutSession
            if let activeSession {
                session = activeSession
            } else if !startRequest.isQuickStart,
                      let routine = routine(for: startRequest) {
                session = routineVM.startWorkout(from: routine, exercises: exercises, modelContext: modelContext)
            } else {
                session = workoutVM.startEmptyWorkout(modelContext: modelContext)
                session.name = startRequest.name.isEmpty ? "Quick Workout" : startRequest.name
                try? modelContext.save()
            }
            selectedTab = .train
            workoutVM.currentWorkout = session
            sendAuthoritativeWatchState(for: session, force: true)
        }

        if let activeSession {
            workoutVM.tickRestTimer(for: activeSession)
            if connectivity.consumeCompleteCurrentSetCommand(for: activeSession.id) {
                workoutVM.completeNextSet(in: activeSession, autoStartRest: settings.first?.autoStartRestTimer ?? true, unit: settings.first?.weightUnit ?? .kg, modelContext: modelContext)
            }
            if connectivity.consumeSkipRestCommand(for: activeSession.id) {
                workoutVM.skipRest(in: activeSession)
            }
            if connectivity.consumeExtendRestCommand(for: activeSession.id) {
                workoutVM.adjustRest(by: 30, in: activeSession)
            }
            if connectivity.consumeReduceRestCommand(for: activeSession.id) {
                workoutVM.adjustRest(by: -30, in: activeSession)
            }
            if connectivity.consumePauseWorkoutCommand(for: activeSession.id), activeSession.status == .active {
                workoutVM.pause(activeSession, modelContext: modelContext)
            }
            if connectivity.consumeResumeWorkoutCommand(for: activeSession.id), activeSession.status == .paused {
                workoutVM.resume(activeSession, unit: settings.first?.weightUnit ?? .kg, modelContext: modelContext)
            }
        }

        let endedCommand = connectivity.consumeEndedWorkoutCommand()
        if endedCommand.requested {
            let targetSession = endedCommand.workoutId.flatMap { id in
                sessions.first { $0.id == id }
            } ?? activeSession
            if let targetSession, targetSession.status == .active || targetSession.status == .paused {
                Task {
                    await workoutVM.finish(targetSession, modelContext: modelContext, writeToHealth: false, healthKitWorkoutUUID: endedCommand.healthKitUUID, watchMetrics: endedCommand.metrics)
                    selectedTab = .train
                    completedSessionForSummary = targetSession
                }
            } else if let targetSession {
                workoutVM.applyWatchMetrics(endedCommand.metrics, healthKitWorkoutUUID: endedCommand.healthKitUUID, to: targetSession, modelContext: modelContext)
                selectedTab = .train
                completedSessionForSummary = targetSession
            }
        }
    }

    private func routine(for request: WatchStartWorkoutRequest) -> WorkoutRoutine? {
        if let routineId = request.routineId,
           let routine = routines.first(where: { $0.id == routineId }) {
            return routine
        }
        return routines.first { $0.name.localizedCaseInsensitiveCompare(request.name) == .orderedSame }
    }

    private func sendAuthoritativeWatchState(for session: WorkoutSession?, force: Bool = false) {
        WatchConnectivityManager.shared.send(state: makeWatchState(for: session), force: force)
    }

    private func makeWatchState(for session: WorkoutSession?) -> WorkoutSyncState {
        let summaries = routines
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { routine in
                WatchRoutineSummary(
                    id: routine.id,
                    name: routine.name,
                    exerciseCount: routine.exercises.count,
                    targetSetCount: routine.exercises.reduce(0) { $0 + $1.targetSets }
                )
            }

        guard let session else {
            return WorkoutSyncState(
                workoutId: nil,
                name: "No Active Workout",
                status: .planned,
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
                availableRoutines: summaries,
                workoutExercises: []
            )
        }

        let firstIncompleteExercise = session.exercises.sorted { $0.sortOrder < $1.sortOrder }.first { exercise in
            exercise.sets.contains { !$0.isCompleted }
        }
        let firstIncompleteSet = firstIncompleteExercise?.sets.sorted { $0.setIndex < $1.setIndex }.first { !$0.isCompleted }
        return WorkoutSyncState(
            workoutId: session.id,
            name: session.name,
            status: session.status,
            elapsedSeconds: session.duration,
            currentWorkoutExerciseId: firstIncompleteExercise?.id,
            currentSetId: firstIncompleteSet?.id,
            currentExerciseName: firstIncompleteExercise?.exerciseName,
            currentSetIndex: firstIncompleteSet?.setIndex,
            completedSets: session.completedSetCount,
            currentHeartRate: HealthKitManager.shared.currentHeartRate,
            averageHeartRate: HealthKitManager.shared.averageHeartRate ?? session.averageHeartRate,
            activeEnergyKcal: HealthKitManager.shared.activeEnergyKcal ?? session.activeEnergyKcal,
            restRemainingSeconds: workoutVM.restTimer.remainingSeconds,
            availableRoutines: summaries,
            workoutExercises: session.watchWorkoutSnapshots
        )
    }
}

struct DashboardView: View {
    let sessions: [WorkoutSession]
    let exercises: [Exercise]
    let routines: [WorkoutRoutine]
    let settings: UserSettings?
    @Binding var selectedTab: LiftLogTab
    @Binding var trainLaunchIntent: TrainLaunchIntent
    @Bindable var workoutVM: WorkoutSessionViewModel
    @Bindable var routineVM: RoutineViewModel
    @Environment(\.modelContext) private var modelContext
    @State private var selectedSession: WorkoutSession?

    private var todaySession: WorkoutSession? {
        sessions.first { Calendar.current.isDateInToday($0.workoutDate) && $0.status == .completed }
    }

    private var activeSession: WorkoutSession? {
        sessions.first { $0.status == .active || $0.status == .paused }
    }

    private var lastCompleted: WorkoutSession? {
        sessions.first { $0.status == .completed }
    }

    private var weekSummary: WeeklySummary? {
        AggregationManager.weeklySummaries(from: sessions).last
    }

    private var completedSessions: [WorkoutSession] {
        AggregationManager.completedSessions(sessions)
    }

    private var streak: Int {
        TrainingInsights.currentStreak(from: sessions)
    }

    private var recentRecords: [PersonalRecord] {
        TrainingInsights.recentPersonalRecords(from: sessions, limit: 3)
    }

    private var todayProgress: CGFloat {
        guard let activeSession else { return todaySession == nil ? 0 : 1 }
        guard activeSession.totalSetCount > 0 else { return 0 }
        let value = Double(activeSession.completedSetCount) / Double(activeSession.totalSetCount)
        guard value.isFinite else { return 0 }
        return CGFloat(min(1, max(0, value)))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                ScreenContent {
                    quickActions
                    statusCard
                    weekStats
                    if !recentRecords.isEmpty {
                        personalRecordsCard
                    }
                    latestWorkoutSection
                }
            }
            .navigationTitle("LiftLog")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selectedSession) { session in
                WorkoutDetailView(session: session, settings: settings)
            }
        }
    }

    private var statusCard: some View {
        LiftCard {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(Color.accentColor.opacity(0.16), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: todayProgress)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: activeSession != nil ? "flame.fill" : (todaySession == nil ? "moon.zzz.fill" : "checkmark"))
                        .foregroundStyle(.tint)
                        .font(.title2.bold())
                }
                .frame(width: 64, height: 64)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Today")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(activeSession != nil ? "Workout in progress" : (todaySession == nil ? "Ready to train" : "Training complete"))
                        .font(.title2.bold())
                    if let activeSession {
                        Text("\(activeSession.completedSetCount)/\(activeSession.totalSetCount) sets completed")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(streak) day streak · \(completedSessions.count) total workouts")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
    }

    private var weekStats: some View {
        VStack(alignment: .leading, spacing: AppLayout.compactSpacing) {
            SectionHeader(title: "This Week", systemImage: "calendar.badge.clock")
            HStack(spacing: AppLayout.compactSpacing) {
                StatTile(title: "Sessions", value: "\(weekSummary?.workoutCount ?? 0)", subtitle: "workouts", systemImage: "figure.strengthtraining.traditional")
                StatTile(title: "Volume", value: "\(Int(weekSummary?.volume ?? 0))", subtitle: settings?.weightUnit.rawValue ?? "kg", systemImage: "scalemass")
                StatTile(title: "Time", value: (weekSummary?.duration ?? 0).shortDurationText, subtitle: "logged", systemImage: "timer")
            }
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
            SectionHeader(title: activeSession == nil ? "Quick Start" : "Current Workout", systemImage: "bolt.fill")
            if let activeSession {
                LiftCard {
                    VStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(activeSession.name)
                                    .font(.headline)
                                Text("\(activeSession.completedSetCount)/\(activeSession.totalSetCount) sets · \(activeSession.duration.shortDurationText)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(activeSession.status == .paused ? "Paused" : "Live")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(activeSession.status == .paused ? .orange : .green)
                        }
                        if let next = TrainingInsights.nextSet(in: activeSession, unit: settings?.weightUnit ?? .kg) {
                            Text("Next: \(next.exerciseName) · Set \(next.setIndex) · \(next.weightText) x \(next.reps)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: AppLayout.compactSpacing) {
                            Button {
                                continueWorkout()
                            } label: {
                                Label("Continue", systemImage: "play.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                addExerciseFromDashboard(to: activeSession)
                            } label: {
                                Label("Add", systemImage: "plus.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            } else {
                LiftCard {
                    HStack(spacing: AppLayout.compactSpacing) {
                        Button {
                            startQuickWorkout()
                        } label: {
                            DashboardQuickActionLabel(title: "Quick Workout", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)

                        Menu {
                            if routines.isEmpty {
                                Button("No templates available") {}
                                    .disabled(true)
                            } else {
                                ForEach(routines.sorted { $0.name < $1.name }) { routine in
                                    Button {
                                        startRoutineWorkout(routine)
                                    } label: {
                                        Label(routine.name, systemImage: "play.fill")
                                    }
                                }
                            }
                        } label: {
                            DashboardQuickActionLabel(title: "Template", systemImage: "list.bullet.rectangle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func continueWorkout() {
        trainLaunchIntent = .none
        selectedTab = .train
    }

    private func addExerciseFromDashboard(to session: WorkoutSession) {
        trainLaunchIntent = .addExercise(workoutId: session.id)
        selectedTab = .train
    }

    private func startQuickWorkout() {
        if let activeSession {
            addExerciseFromDashboard(to: activeSession)
            return
        }
        let session = workoutVM.startEmptyWorkout(modelContext: modelContext)
        trainLaunchIntent = .addExercise(workoutId: session.id)
        selectedTab = .train
    }

    private func startRoutineWorkout(_ routine: WorkoutRoutine) {
        if activeSession != nil {
            continueWorkout()
            return
        }
        let session = routineVM.startWorkout(from: routine, exercises: exercises, modelContext: modelContext)
        workoutVM.publishState(for: session)
        trainLaunchIntent = .none
        selectedTab = .train
    }

    @ViewBuilder
    private var latestWorkoutSection: some View {
        VStack(alignment: .leading, spacing: AppLayout.compactSpacing) {
            SectionHeader(title: "Latest Workout", systemImage: "clock.arrow.circlepath")
            if let lastCompleted {
                Button { selectedSession = lastCompleted } label: {
                    WorkoutSummaryCard(session: lastCompleted)
                }
                .buttonStyle(.plain)
            } else {
                LiftCard {
                    EmptyStateView(title: "No workout history", message: "Start a quick workout or use a routine to create your first log.")
                }
            }
        }
    }

    private var personalRecordsCard: some View {
        VStack(alignment: .leading, spacing: AppLayout.compactSpacing) {
            SectionHeader(title: "Recent PRs", systemImage: "trophy.fill")
            LiftCard {
                VStack(spacing: AppLayout.compactSpacing) {
                    ForEach(Array(recentRecords.enumerated()), id: \.element.id) { index, record in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.exerciseName)
                                    .font(.subheadline.weight(.semibold))
                                Text(record.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(Int(record.bestOneRepMax)) e1RM")
                                    .font(.headline)
                                Text("\(Int(record.bestWeight)) x \(record.reps)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if index < recentRecords.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

struct DashboardQuickActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.headline)
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .allowsTightening(true)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .contentShape(Rectangle())
    }
}

struct TrainView: View {
    let exercises: [Exercise]
    let routines: [WorkoutRoutine]
    let settings: UserSettings?
    @Binding var trainLaunchIntent: TrainLaunchIntent
    @Bindable var workoutVM: WorkoutSessionViewModel
    @Bindable var routineVM: RoutineViewModel
    let onWorkoutCompleted: (WorkoutSession) -> Void
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutSession.startedAt, order: .reverse) private var sessions: [WorkoutSession]
    @State private var showingExercisePicker = false
    @State private var shouldPromptForFirstExercise = false

    private var activeSession: WorkoutSession? {
        sessions.first { $0.status == .active || $0.status == .paused }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let activeSession {
                    ActiveWorkoutView(session: activeSession, exercises: exercises, settings: settings, workoutVM: workoutVM, showingExercisePicker: $showingExercisePicker, onWorkoutCompleted: onWorkoutCompleted)
                } else {
                    startPanel
                }
            }
            .navigationTitle(activeSession == nil ? "Train" : "Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if activeSession != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingExercisePicker = true } label: {
                            Label("Add Exercise", systemImage: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingExercisePicker) {
                if let activeSession {
                    ExercisePickerView(exercises: exercises) { exercise in
                        workoutVM.addExercise(exercise, to: activeSession, modelContext: modelContext)
                        showingExercisePicker = false
                    }
                }
            }
            .onChange(of: activeSession?.id) { _, _ in
                handlePendingLaunchIntent()
            }
            .onChange(of: trainLaunchIntent) { _, _ in
                handlePendingLaunchIntent()
            }
            .onAppear {
                handlePendingLaunchIntent()
            }
        }
    }

    private func handlePendingLaunchIntent() {
        guard let activeSession else { return }
        switch trainLaunchIntent {
        case .none:
            if shouldPromptForFirstExercise && activeSession.exercises.isEmpty {
                shouldPromptForFirstExercise = false
                showingExercisePicker = true
            }
        case .addExercise(let workoutId):
            guard workoutId == activeSession.id else { return }
            trainLaunchIntent = .none
            shouldPromptForFirstExercise = false
            showingExercisePicker = true
        }
    }

    private var startPanel: some View {
        ScrollView {
            ScreenContent {
                LiftCard {
                    VStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
                        Label("Quick Workout", systemImage: "bolt.fill")
                            .font(.title3.bold())
                        Text("Unplanned session for today's lifts.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button {
                            shouldPromptForFirstExercise = true
                            let session = workoutVM.startEmptyWorkout(modelContext: modelContext)
                            workoutVM.publishState(for: session)
                        } label: {
                            Label("Start and Add Exercise", systemImage: "plus.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }

                VStack(alignment: .leading, spacing: AppLayout.compactSpacing) {
                    HStack {
                        SectionHeader(title: "Templates", systemImage: "list.bullet.rectangle")
                        Spacer()
                        NavigationLink {
                            RoutineManagerView(routines: routines, exercises: exercises, settings: settings)
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .buttonStyle(.bordered)
                    }

                    if routines.isEmpty {
                        LiftCard {
                            EmptyStateView(title: "No templates", message: "Create Push, Pull, Legs, or your own routine to start faster next time.")
                        }
                    } else {
                        ForEach(routines.sorted { $0.name < $1.name }) { routine in
                            RoutineStartCard(routine: routine) {
                                let session = routineVM.startWorkout(from: routine, exercises: exercises, modelContext: modelContext)
                                workoutVM.publishState(for: session)
                            } onDuplicate: {
                                routineVM.duplicate(routine, modelContext: modelContext)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct RoutineStartCard: View {
    let routine: WorkoutRoutine
    let onStart: () -> Void
    let onDuplicate: () -> Void

    private var estimatedSets: Int {
        routine.exercises.reduce(0) { $0 + $1.targetSets }
    }

    var body: some View {
        LiftCard {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(routine.name)
                        .font(.headline)
                    Text(routine.note.isEmpty ? "\(routine.exercises.count) exercises · \(estimatedSets) target sets" : routine.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Label("\(routine.exercises.count)", systemImage: "dumbbell")
                        Label("\(estimatedSets)", systemImage: "checklist")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(spacing: 8) {
                    Button(action: onStart) {
                        Image(systemName: "play.fill")
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.borderedProminent)
                    Menu {
                        Button(action: onDuplicate) {
                            Label("Duplicate", systemImage: "doc.on.doc")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }
}

struct ActiveWorkoutView: View {
    @Environment(\.modelContext) private var modelContext
    let session: WorkoutSession
    let exercises: [Exercise]
    let settings: UserSettings?
    @Bindable var workoutVM: WorkoutSessionViewModel
    @Binding var showingExercisePicker: Bool
    let onWorkoutCompleted: (WorkoutSession) -> Void
    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var showingFinishConfirmation = false
    @State private var showingCancelConfirmation = false
    @State private var currentTime = Date()
    @State private var restFinishedTarget: SetTarget?
    @State private var suppressNextRestReadyBanner = false

    private var progress: Double {
        guard session.totalSetCount > 0 else { return 0 }
        let value = Double(session.completedSetCount) / Double(session.totalSetCount)
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    var body: some View {
        List {
            Section {
                activeHeader
                if workoutVM.restTimer.remainingSeconds > 0 {
                    RestTimerView(
                        restTimer: workoutVM.restTimer,
                        onAdjust: { workoutVM.adjustRest(by: $0, in: session) },
                        onSkip: {
                            suppressNextRestReadyBanner = true
                            workoutVM.skipRest(in: session)
                        }
                    )
                }
                if let next = TrainingInsights.nextSet(in: session, unit: settings?.weightUnit ?? .kg) {
                    NextSetCard(target: next)
                }
            }

            if session.exercises.isEmpty {
                Section {
                    ActiveWorkoutEmptyState {
                        showingExercisePicker = true
                    }
                }
            } else {
                ForEach(session.exercises.sorted { $0.sortOrder < $1.sortOrder }) { workoutExercise in
                    Section {
                        ForEach(workoutExercise.sets.sorted { $0.setIndex < $1.setIndex }) { set in
                            SetRowView(set: set, restSeconds: workoutExercise.defaultRestSeconds, session: session, workoutVM: workoutVM, settings: settings)
                        }
                        .onDelete { offsets in
                            let sorted = workoutExercise.sets.sorted { $0.setIndex < $1.setIndex }
                            for offset in offsets {
                                workoutVM.deleteSet(sorted[offset], from: workoutExercise, modelContext: modelContext)
                            }
                            workoutVM.publishState(for: session)
                        }
                        Button {
                            workoutVM.addSet(to: workoutExercise, in: session, modelContext: modelContext)
                        } label: {
                            Label("Add Set", systemImage: "plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    } header: {
                        HStack {
                            Text(workoutExercise.exerciseName)
                            Spacer()
                            Text("\(workoutExercise.sets.filter(\.isCompleted).count)/\(workoutExercise.sets.count)")
                            Menu {
                                Button {
                                    workoutVM.addSet(to: workoutExercise, in: session, modelContext: modelContext)
                                } label: {
                                    Label("Add Set", systemImage: "plus")
                                }
                                Button(role: .destructive) {
                                    workoutVM.deleteExercise(workoutExercise, from: session, modelContext: modelContext)
                                } label: {
                                    Label("Remove Exercise", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                        }
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .dismissKeyboardOnTap()
        .safeAreaInset(edge: .bottom) {
            activeCommandBar
        }
        .overlay(alignment: .top) {
            if let restFinishedTarget {
                RestFinishedBanner(target: restFinishedTarget)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    showingCancelConfirmation = true
                }
                .foregroundStyle(.red)
            }
        }
        .onReceive(timer) { _ in
            currentTime = Date()
        }
        .onChange(of: workoutVM.restTimer.remainingSeconds) { oldValue, newValue in
            handleRestTimerChange(from: oldValue, to: newValue)
        }
        .confirmationDialog("Finish this workout?", isPresented: $showingFinishConfirmation, titleVisibility: .visible) {
            Button("Finish Workout") {
                finishWorkout()
            }
            Button("Discard Workout", role: .destructive) {
                discardWorkout()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Completed sets will be saved to history, or discard to delete it without saving.")
        }
        .confirmationDialog("Cancel this workout?", isPresented: $showingCancelConfirmation, titleVisibility: .visible) {
            Button("Discard Workout", role: .destructive) {
                discardWorkout()
            }
            Button("Resume Training", role: .cancel) {}
        } message: {
            Text("The workout and all recorded sets will be permanently deleted.")
        }
    }

    private var activeHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.name)
                        .font(.title3.bold())
                    Label(elapsedDuration.shortClockText, systemImage: "timer")
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.tint)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(session.completedSetCount)/\(session.totalSetCount)")
                        .font(.title3.bold())
                    Text("sets")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: progress)
                .tint(.accentColor)
            HStack(spacing: 8) {
                MetricPill(title: "Volume", value: "\(Int(session.totalVolume)) \(settings?.weightUnit.rawValue ?? "kg")")
                MetricPill(title: "Reps", value: "\(session.totalReps)")
                MetricPill(title: "Status", value: session.status == .paused ? "Paused" : "Active")
            }
        }
        .padding(.vertical, 4)
    }

    private var elapsedDuration: TimeInterval {
        let end = session.endedAt ?? currentTime
        return max(0, end.timeIntervalSince(session.startedAt))
    }

    private var activeCommandBar: some View {
        HStack(spacing: AppLayout.compactSpacing) {
            Button {
                Keyboard.dismiss()
                workoutVM.completeNextSet(in: session, autoStartRest: settings?.autoStartRestTimer ?? true, unit: settings?.weightUnit ?? .kg, modelContext: modelContext)
            } label: {
                Label("Done Set", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(TrainingInsights.nextSet(in: session, unit: settings?.weightUnit ?? .kg) == nil)

            Button {
                Keyboard.dismiss()
                if session.status == .paused {
                    workoutVM.resume(session, unit: settings?.weightUnit ?? .kg, modelContext: modelContext)
                } else {
                    workoutVM.pause(session, modelContext: modelContext)
                }
            } label: {
                Label(session.status == .paused ? "Resume" : "Pause", systemImage: session.status == .paused ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                Keyboard.dismiss()
                showingFinishConfirmation = true
            } label: {
                Image(systemName: "flag.checkered")
                    .frame(width: 42)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func handleRestTimerChange(from oldValue: Int, to newValue: Int) {
        guard oldValue > 0, newValue == 0 else { return }
        if suppressNextRestReadyBanner {
            suppressNextRestReadyBanner = false
            return
        }
        guard let next = TrainingInsights.nextSet(in: session, unit: settings?.weightUnit ?? .kg) else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            restFinishedTarget = next
        }
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            withAnimation(.easeOut(duration: 0.2)) {
                if restFinishedTarget?.id == next.id {
                    restFinishedTarget = nil
                }
            }
        }
    }

    private func finishWorkout() {
        Task {
            await workoutVM.finish(session, modelContext: modelContext, writeToHealth: settings?.writesWorkoutsToHealth ?? true)
            onWorkoutCompleted(session)
        }
    }

    private func discardWorkout() {
        workoutVM.discard(session, modelContext: modelContext)
    }
}

struct ActiveWorkoutEmptyState: View {
    let onAddExercise: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
            Label("Build today's workout", systemImage: "plus.circle.fill")
                .font(.title3.bold())
            Text("Choose the first lift for this session.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(action: onAddExercise) {
                Label("Add First Exercise", systemImage: "dumbbell.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.vertical, 6)
    }
}

struct SetRowView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var set: SetRecord
    let restSeconds: Int
    let session: WorkoutSession
    @Bindable var workoutVM: WorkoutSessionViewModel
    let settings: UserSettings?

    private var weightUnit: WeightUnit {
        settings?.weightUnit ?? .kg
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Set \(set.setIndex)")
                    .font(.headline)
                    .frame(width: 56, alignment: .leading)
                Picker("Type", selection: $set.setTypeRaw) {
                    ForEach(SetType.allCases) { type in
                        Text(type.title).tag(type.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Picker("Input", selection: $set.weightModeRaw) {
                    ForEach(WeightMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Spacer()
                Button {
                    workoutVM.complete(set, in: session, restSeconds: restSeconds, autoStartRest: settings?.autoStartRestTimer ?? true, unit: settings?.weightUnit ?? .kg, modelContext: modelContext)
                } label: {
                    Image(systemName: set.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(set.isCompleted ? .green : .secondary)
                }
                .buttonStyle(.plain)
            }
            HStack {
                metricFields
                if settings?.usesRPE ?? true {
                    SelectAllOptionalDoubleField(title: "RPE", value: $set.rpe)
                        .frame(width: 62)
                }
            }
        }
        .onChange(of: set.weight) { _, newValue in
            set.weight = max(0, newValue)
            workoutVM.publishState(for: session, debounced: true)
        }
        .onChange(of: set.leftWeight) { _, newValue in
            set.leftWeight = max(0, newValue)
            workoutVM.publishState(for: session, debounced: true)
        }
        .onChange(of: set.rightWeight) { _, newValue in
            set.rightWeight = max(0, newValue)
            workoutVM.publishState(for: session, debounced: true)
        }
        .onChange(of: set.bodyweightAdditionalLoad) { _, newValue in
            set.bodyweightAdditionalLoad = max(0, newValue)
            workoutVM.publishState(for: session, debounced: true)
        }
        .onChange(of: set.assistanceWeight) { _, newValue in
            set.assistanceWeight = max(0, newValue)
            workoutVM.publishState(for: session, debounced: true)
        }
        .onChange(of: set.actualReps) { _, newValue in
            set.actualReps = max(0, newValue)
            workoutVM.publishState(for: session, debounced: true)
        }
        .onChange(of: set.durationSeconds) { _, newValue in
            set.durationSeconds = max(0, newValue)
            workoutVM.publishState(for: session, debounced: true)
        }
        .onChange(of: set.distanceMeters) { _, newValue in
            set.distanceMeters = max(0, newValue)
            workoutVM.publishState(for: session, debounced: true)
        }
        .onChange(of: set.rpe) { _, newValue in
            if let newValue {
                set.rpe = min(10, max(1, newValue))
            }
            workoutVM.publishState(for: session, debounced: true)
        }
        .onChange(of: set.setTypeRaw) { _, _ in workoutVM.publishState(for: session, debounced: true) }
        .onChange(of: set.weightModeRaw) { _, _ in
            normalizeMetricsForSelectedMode()
            workoutVM.publishState(for: session)
        }
        .submitLabel(.done)
        .onSubmit {
            Keyboard.dismiss()
        }
    }

    @ViewBuilder
    private var metricFields: some View {
        switch set.weightMode {
        case .leftRightSeparate:
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    UnitNumberField(title: "Left", value: $set.leftWeight, unit: weightUnit.fieldSuffix)
                    UnitNumberField(title: "Right", value: $set.rightWeight, unit: weightUnit.fieldSuffix)
                }
                Stepper("Reps \(set.actualReps)", value: $set.actualReps, in: 0...100)
            }
        case .timeBased:
            Stepper("\(set.durationSeconds)s", value: $set.durationSeconds, in: 0...3600, step: 5)
            SelectAllIntField(title: "sec", value: $set.durationSeconds, keyboardType: .numberPad)
                .frame(width: 70)
        case .distanceBased:
            SelectAllDoubleField(title: "m", value: $set.distanceMeters)
            SelectAllIntField(title: "sec", value: $set.durationSeconds, keyboardType: .numberPad)
        case .bodyweight:
            Stepper("\(set.actualReps) reps", value: $set.actualReps, in: 0...100)
            UnitNumberField(title: "Added", value: $set.bodyweightAdditionalLoad, unit: weightUnit.fieldSuffix, width: 104)
        case .assistedBodyweight:
            Stepper("\(set.actualReps) reps", value: $set.actualReps, in: 0...100)
            UnitNumberField(title: "Assist", value: $set.assistanceWeight, unit: weightUnit.fieldSuffix, width: 104)
        default:
            UnitNumberField(title: "Weight", value: $set.weight, unit: weightUnit.fieldSuffix)
            Stepper("\(set.actualReps)", value: $set.actualReps, in: 0...100)
                .labelsHidden()
        }
    }

    private func normalizeMetricsForSelectedMode() {
        switch set.weightMode {
        case .leftRightSeparate:
            if set.leftWeight == 0 && set.rightWeight == 0 && set.weight > 0 {
                set.leftWeight = set.weight
                set.rightWeight = set.weight
            }
        case .sameWeight, .machineStack, .plateLoaded, .cable:
            if set.weight == 0 {
                let combined = set.leftWeight + set.rightWeight
                set.weight = combined > 0 ? combined : max(set.bodyweightAdditionalLoad, set.assistanceWeight)
            }
        case .bodyweight:
            set.assistanceWeight = 0
        case .assistedBodyweight:
            set.bodyweightAdditionalLoad = max(0, set.bodyweightAdditionalLoad)
        case .timeBased:
            if set.durationSeconds == 0 {
                set.durationSeconds = 45
            }
        case .distanceBased:
            if set.durationSeconds == 0 {
                set.durationSeconds = 300
            }
        }
    }
}

struct ExercisePickerView: View {
    let exercises: [Exercise]
    let onSelect: (Exercise) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var filtered: [Exercise] {
        exercises.filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { exercise in
                Button {
                    onSelect(exercise)
                    dismiss()
                } label: {
                    Label(exercise.name, systemImage: exercise.imageName ?? "dumbbell")
                }
            }
            .searchable(text: $searchText)
            .navigationTitle("Add Exercise")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct ExerciseLibraryView: View {
    let exercises: [Exercise]
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = ExerciseLibraryViewModel()
    @State private var showingAdd = false

    var body: some View {
        ScrollView {
            ScreenContent {
                LiftCard {
                    VStack(spacing: 8) {
                        HStack {
                            Text("Muscle")
                            Spacer()
                            Picker("Muscle", selection: $viewModel.selectedMuscle) {
                                Text("All").tag(MuscleGroup?.none)
                                ForEach(MuscleGroup.allCases) { Text($0.rawValue).tag(Optional($0)) }
                            }
                            .pickerStyle(.menu)
                        }
                        Divider()
                        HStack {
                            Text("Type")
                            Spacer()
                            Picker("Type", selection: $viewModel.selectedType) {
                                Text("All").tag(ExerciseType?.none)
                                ForEach(ExerciseType.allCases) { Text($0.title).tag(Optional($0)) }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                }

                ForEach(viewModel.filteredExercises(exercises)) { exercise in
                    NavigationLink {
                        ExerciseEditorView(exercise: exercise)
                    } label: {
                        LiftCard {
                            HStack {
                                Image(systemName: exercise.imageName ?? "dumbbell")
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading) {
                                    Text(exercise.name)
                                        .foregroundStyle(.primary)
                                        .font(.headline)
                                    Text("\(exercise.primaryMuscle.rawValue) · \(exercise.type.title)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if exercise.isCustom {
                            Button(role: .destructive) {
                                viewModel.deleteIfCustom(exercise, modelContext: modelContext)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $viewModel.searchText)
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { showingAdd = true } label: { Label("Add", systemImage: "plus") }
        }
        .sheet(isPresented: $showingAdd) {
            AddExerciseView(viewModel: viewModel)
        }
    }
}

struct AddExerciseView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: ExerciseLibraryViewModel
    @State private var name = ""
    @State private var englishName = ""
    @State private var muscle: MuscleGroup = .chest
    @State private var secondaryMuscles: Set<MuscleGroup> = []
    @State private var type: ExerciseType = .barbell
    @State private var tracksLeftRightSeparately = false
    @State private var defaultWeightMode: WeightMode = .sameWeight
    @State private var userSelectedInputMode = false
    @State private var instructions = ""
    @State private var cautions = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Basics") {
                    TextField("Name", text: $name)
                    TextField("English name", text: $englishName)
                    Picker("Primary muscle", selection: $muscle) {
                        ForEach(MuscleGroup.allCases) { Text($0.rawValue).tag($0) }
                    }
                    DisclosureGroup("Secondary muscles") {
                        ForEach(MuscleGroup.allCases.filter { $0 != muscle }) { group in
                            Toggle(group.rawValue, isOn: secondaryBinding(for: group))
                        }
                    }
                }

                Section("Tracking") {
                    Picker("Equipment", selection: $type) {
                        ForEach(ExerciseType.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Track left/right separately", isOn: $tracksLeftRightSeparately)
                    Picker("Default input", selection: Binding(
                        get: { defaultWeightMode },
                        set: {
                            userSelectedInputMode = true
                            defaultWeightMode = $0
                        }
                    )) {
                        ForEach(WeightMode.recommendedModes(for: type, isUnilateral: tracksLeftRightSeparately)) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Text(defaultWeightMode.setupHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Notes") {
                    TextField("Instructions", text: $instructions, axis: .vertical)
                    TextField("Cautions", text: $cautions, axis: .vertical)
                }
            }
            .navigationTitle("New Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: type) { _, _ in updateRecommendedInputMode() }
            .onChange(of: tracksLeftRightSeparately) { _, _ in updateRecommendedInputMode() }
            .onChange(of: muscle) { _, newValue in
                secondaryMuscles.remove(newValue)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        viewModel.addExercise(
                            modelContext: modelContext,
                            name: name,
                            englishName: englishName,
                            muscle: muscle,
                            secondaryMuscles: secondaryMuscles.filter { $0 != muscle }.sorted { $0.rawValue < $1.rawValue },
                            type: type,
                            defaultWeightMode: defaultWeightMode,
                            tracksLeftRightSeparately: tracksLeftRightSeparately,
                            instructions: instructions,
                            cautions: cautions
                        )
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func secondaryBinding(for group: MuscleGroup) -> Binding<Bool> {
        Binding(
            get: { secondaryMuscles.contains(group) },
            set: { isSelected in
                if isSelected {
                    secondaryMuscles.insert(group)
                } else {
                    secondaryMuscles.remove(group)
                }
            }
        )
    }

    private func updateRecommendedInputMode() {
        guard !userSelectedInputMode else { return }
        defaultWeightMode = WeightMode.defaultMode(for: type, isUnilateral: tracksLeftRightSeparately)
    }
}

struct ExerciseEditorView: View {
    @Bindable var exercise: Exercise

    var body: some View {
        Form {
            TextField("Name", text: $exercise.name)
            TextField("English name", text: Binding($exercise.englishName, replacingNilWith: ""))
            Picker("Primary muscle", selection: $exercise.primaryMuscleRaw) {
                ForEach(MuscleGroup.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            Picker("Equipment", selection: $exercise.typeRaw) {
                ForEach(ExerciseType.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Picker("Default input", selection: $exercise.defaultWeightModeRaw) {
                ForEach(WeightMode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Toggle("Track left/right separately", isOn: $exercise.tracksLeftRightSeparately)
            Text(exercise.defaultWeightMode.setupHint)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                exercise.defaultWeightMode = WeightMode.defaultMode(for: exercise.type, isUnilateral: exercise.tracksLeftRightSeparately)
            } label: {
                Label("Use Recommended Input", systemImage: "wand.and.stars")
            }
            TextField("Instructions", text: $exercise.instructions, axis: .vertical)
            TextField("Cautions", text: $exercise.cautions, axis: .vertical)
        }
        .navigationTitle(exercise.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct RoutineManagerView: View {
    let routines: [WorkoutRoutine]
    let exercises: [Exercise]
    let settings: UserSettings?
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = RoutineViewModel()
    @State private var showingCreate = false
    @State private var routineToDelete: WorkoutRoutine?

    var body: some View {
        List {
            if routines.isEmpty {
                EmptyStateView(title: "No templates", message: "Create reusable routines for push, pull, legs, or full-body training.")
            } else {
                ForEach(routines.sorted { $0.name < $1.name }) { routine in
                    NavigationLink {
                        RoutineEditorView(routine: routine, exercises: exercises, settings: settings, viewModel: viewModel)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(routine.name)
                                .font(.headline)
                            Text("\(routine.exercises.count) exercises · \(routine.note)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .swipeActions {
                        Button {
                            viewModel.duplicate(routine, modelContext: modelContext)
                        } label: {
                            Label("Duplicate", systemImage: "doc.on.doc")
                        }
                        .tint(.accentColor)
                        Button(role: .destructive) {
                            routineToDelete = routine
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("Templates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { showingCreate = true } label: {
                Label("New Template", systemImage: "plus")
            }
        }
        .sheet(isPresented: $showingCreate) {
            NewRoutineView(viewModel: viewModel)
        }
        .confirmationDialog("Delete this template?", isPresented: Binding(
            get: { routineToDelete != nil },
            set: { if !$0 { routineToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete Template", role: .destructive) {
                if let routineToDelete {
                    viewModel.delete(routineToDelete, modelContext: modelContext)
                }
                routineToDelete = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(routineToDelete?.name ?? "This template") will be removed. Existing workout history stays unchanged.")
        }
    }
}

struct NewRoutineView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: RoutineViewModel
    @State private var name = ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Notes", text: $note, axis: .vertical)
            }
            .navigationTitle("New Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        _ = viewModel.createRoutine(name: name, note: note, modelContext: modelContext)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct RoutineEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var routine: WorkoutRoutine
    let exercises: [Exercise]
    let settings: UserSettings?
    @Bindable var viewModel: RoutineViewModel
    @State private var showingExercisePicker = false

    var body: some View {
        Form {
            Section("Template") {
                TextField("Name", text: $routine.name)
                TextField("Notes", text: $routine.note, axis: .vertical)
            }
            Section("Exercises") {
                let sortedExercises = routine.exercises.sorted { $0.sortOrder < $1.sortOrder }
                if sortedExercises.isEmpty {
                    EmptyStateView(title: "No exercises", message: "Add exercises to make this template startable.")
                } else {
                    ForEach(sortedExercises) { item in
                        RoutineExerciseRow(
                            item: item,
                            exercise: exercises.first { $0.id == item.exerciseId },
                            unit: settings?.weightUnit ?? .kg
                        )
                    }
                    .onDelete { offsets in
                        viewModel.deleteExercises(at: offsets, from: routine, modelContext: modelContext)
                    }
                    .onMove { source, destination in
                        viewModel.moveExercises(from: source, to: destination, in: routine, modelContext: modelContext)
                    }
                }
                Button {
                    showingExercisePicker = true
                } label: {
                    Label("Add Exercise", systemImage: "plus")
                }
            }
        }
        .navigationTitle(routine.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditButton()
        }
        .sheet(isPresented: $showingExercisePicker) {
            ExercisePickerView(exercises: exercises) { exercise in
                viewModel.addExercise(exercise, to: routine, modelContext: modelContext)
                showingExercisePicker = false
            }
        }
        .onDisappear {
            routine.updatedAt = Date()
            try? modelContext.save()
        }
    }
}

struct RoutineExerciseRow: View {
    @Bindable var item: RoutineExercise
    let exercise: Exercise?
    let unit: WeightUnit

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.compactSpacing) {
            Text(item.exerciseName)
                .font(.headline)
            if let exercise {
                HStack(spacing: 8) {
                    Label(exercise.defaultWeightMode.title, systemImage: exercise.tracksLeftRightSeparately ? "arrow.left.arrow.right" : "scalemass")
                    Text(exercise.type.title)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Stepper("Sets: \(item.targetSets)", value: $item.targetSets, in: 1...12)
            Stepper("Reps: \(item.targetReps)", value: $item.targetReps, in: 0...100)
            HStack {
                Text(targetWeightTitle)
                Spacer()
                UnitNumberField(title: "Weight", value: $item.targetWeight, unit: unit.fieldSuffix, width: 124)
            }
            Stepper("Rest: \(item.restSeconds)s", value: $item.restSeconds, in: 0...600, step: 15)
            Toggle("Warm-up first set", isOn: $item.enableWarmupSets)
            Toggle("Ramping weight", isOn: $item.enableRampingWeight)
        }
        .onChange(of: item.targetWeight) { _, newValue in item.targetWeight = max(0, newValue) }
        .onChange(of: item.targetSets) { _, newValue in item.targetSets = max(1, newValue) }
        .onChange(of: item.targetReps) { _, newValue in item.targetReps = max(0, newValue) }
        .onChange(of: item.restSeconds) { _, newValue in item.restSeconds = max(0, newValue) }
    }

    private var targetWeightTitle: String {
        switch exercise?.defaultWeightMode {
        case .leftRightSeparate:
            "Target per side"
        case .bodyweight:
            "Added load"
        case .assistedBodyweight:
            "Assistance"
        case .timeBased:
            "Target load"
        case .distanceBased:
            "Target load"
        default:
            "Target weight"
        }
    }
}

struct WorkoutCalendarView: View {
    @Environment(\.modelContext) private var modelContext
    let sessions: [WorkoutSession]
    let settings: UserSettings?
    @State private var viewModel = CalendarViewModel()
    @State private var selectedSession: WorkoutSession?

    var body: some View {
        NavigationStack {
            ScrollView {
                ScreenContent {
                    let monthSessions = viewModel.sessionsInDisplayedMonth(from: sessions)
                    HStack(spacing: AppLayout.compactSpacing) {
                        StatTile(title: "Month", value: "\(monthSessions.count)", subtitle: "workouts", systemImage: "calendar")
                        StatTile(title: "Volume", value: "\(Int(monthSessions.reduce(0) { $0 + $1.totalVolume }))", subtitle: settings?.weightUnit.rawValue ?? "kg", systemImage: "scalemass")
                        StatTile(title: "Time", value: monthSessions.reduce(0) { $0 + $1.duration }.shortDurationText, subtitle: "logged", systemImage: "timer")
                    }

                    LiftCard {
                        VStack(spacing: AppLayout.sectionSpacing) {
                            monthHeader
                            HStack {
                                ForEach(Calendar.current.shortWeekdaySymbols, id: \.self) { symbol in
                                    Text(symbol)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: AppLayout.compactSpacing) {
                                ForEach(Array(viewModel.monthGridDays().enumerated()), id: \.offset) { _, day in
                                    if let day {
                                        let count = viewModel.sessions(on: day, from: sessions).count
                                        Button {
                                            viewModel.selectedDate = day
                                        } label: {
                                            VStack(spacing: 4) {
                                                Text(day.formatted(.dateTime.day()))
                                                    .font(.subheadline.weight(Calendar.current.isDateInToday(day) ? .bold : .regular))
                                                    .frame(width: 34, height: 30)
                                                    .background(Calendar.current.isDate(day, inSameDayAs: viewModel.selectedDate) ? Color.accentColor.opacity(0.2) : .clear, in: Circle())
                                                Circle()
                                                    .fill(count > 0 ? .green : .clear)
                                                    .frame(width: 6, height: 6)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        Color.clear.frame(height: 40)
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: AppLayout.compactSpacing) {
                        SectionHeader(title: viewModel.selectedDate.formatted(date: .abbreviated, time: .omitted), systemImage: "list.bullet.clipboard")

                        let daySessions = viewModel.sessions(on: viewModel.selectedDate, from: sessions)
                        if daySessions.isEmpty {
                            LiftCard {
                                EmptyStateView(title: "No workouts", message: "Training days will appear here.")
                            }
                        } else {
                            ForEach(daySessions) { session in
                                Button { selectedSession = session } label: {
                                    WorkoutSummaryCard(session: session)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        modelContext.delete(session)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selectedSession) { WorkoutDetailView(session: $0, settings: settings) }
        }
    }

    private var monthHeader: some View {
        HStack {
            Button { viewModel.selectedDate = Calendar.current.date(byAdding: .month, value: -1, to: viewModel.selectedDate) ?? viewModel.selectedDate } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(viewModel.selectedDate.formatted(.dateTime.month(.wide).year()))
            Spacer()
            Button { viewModel.selectedDate = Calendar.current.date(byAdding: .month, value: 1, to: viewModel.selectedDate) ?? viewModel.selectedDate } label: { Image(systemName: "chevron.right") }
        }
    }
}

struct ProgressAnalyticsView: View {
    let sessions: [WorkoutSession]
    let exercises: [Exercise]
    let settings: UserSettings?
    @State private var viewModel = ProgressViewModel()

    private var filteredSessions: [WorkoutSession] {
        viewModel.filteredSessions(sessions)
    }

    private var weeklySummaries: [WeeklySummary] {
        viewModel.weeklySummaries(from: sessions)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                ScreenContent {
                    controls
                    overviewSection
                    trendSection
                    exerciseSection
                    muscleSection
                    heartRateSection
                }
            }
            .navigationTitle("Progress")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: chooseDefaultExercise)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: AppLayout.compactSpacing) {
            Picker("Range", selection: $viewModel.selectedRange) {
                ForEach(ProgressTimeRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)

            Picker("Metric", selection: $viewModel.selectedTrendMetric) {
                ForEach(ProgressTrendMetric.allCases) { metric in
                    Text(metric.rawValue).tag(metric)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var overviewSection: some View {
        let volume = filteredSessions.reduce(0) { $0 + $1.totalVolume }
        let duration = filteredSessions.reduce(0) { $0 + $1.duration }
        let sets = filteredSessions.reduce(0) { $0 + $1.completedSetCount }
        let records = TrainingInsights.personalRecords(from: filteredSessions)

        return VStack(alignment: .leading, spacing: AppLayout.compactSpacing) {
            SectionHeader(title: "Overview", systemImage: "chart.line.uptrend.xyaxis")
            HStack(spacing: AppLayout.compactSpacing) {
                StatTile(title: "Workouts", value: "\(filteredSessions.count)", subtitle: viewModel.selectedRange.rawValue, systemImage: "calendar")
                StatTile(title: "Volume", value: "\(Int(volume))", subtitle: settings?.weightUnit.rawValue ?? "kg", systemImage: "scalemass")
                StatTile(title: "Time", value: duration.shortDurationText, subtitle: "trained", systemImage: "timer")
            }
            HStack(spacing: AppLayout.compactSpacing) {
                StatTile(title: "Sets", value: "\(sets)", subtitle: "completed", systemImage: "checklist")
                StatTile(title: "PRs", value: "\(records.count)", subtitle: "tracked", systemImage: "trophy")
                StatTile(title: "Streak", value: "\(TrainingInsights.currentStreak(from: sessions))", subtitle: "days", systemImage: "flame")
            }
        }
    }

    private var trendSection: some View {
        ChartCard(title: "Weekly Trend") {
            if weeklySummaries.isEmpty {
                EmptyStateView(title: "No weekly data", message: "Complete workouts to build weekly trends.")
            } else {
                Chart(weeklySummaries) { summary in
                    switch viewModel.selectedTrendMetric {
                    case .frequency:
                        BarMark(x: .value("Week", summary.weekStart, unit: .weekOfYear), y: .value("Workouts", summary.workoutCount))
                    case .volume:
                        LineMark(x: .value("Week", summary.weekStart, unit: .weekOfYear), y: .value("Volume", summary.volume))
                        PointMark(x: .value("Week", summary.weekStart, unit: .weekOfYear), y: .value("Volume", summary.volume))
                    case .duration:
                        BarMark(x: .value("Week", summary.weekStart, unit: .weekOfYear), y: .value("Minutes", summary.duration / 60))
                    case .sets:
                        BarMark(x: .value("Week", summary.weekStart, unit: .weekOfYear), y: .value("Sets", summary.completedSets))
                    }
                }
            }
        }
    }

    private var exerciseSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Exercise", systemImage: "dumbbell")
            Picker("Exercise", selection: $viewModel.selectedExerciseId) {
                Text("Select exercise").tag(UUID?.none)
                ForEach(exercises) { exercise in
                    Text(exercise.name).tag(Optional(exercise.id))
                }
            }
            .pickerStyle(.menu)

            let trend = viewModel.exerciseTrend(exerciseId: viewModel.selectedExerciseId, sessions: sessions)
            if trend.isEmpty {
                LiftCard {
                    EmptyStateView(title: "No exercise trend", message: "Pick an exercise with completed sets to see strength and volume changes.")
                }
            } else {
                HStack(spacing: AppLayout.compactSpacing) {
                    StatTile(title: "Best", value: "\(Int(trend.map(\.weight).max() ?? 0))", subtitle: settings?.weightUnit.rawValue ?? "kg", systemImage: "arrow.up")
                    StatTile(title: "Best 1RM", value: "\(Int(trend.map(\.oneRM).max() ?? 0))", subtitle: "Epley", systemImage: "bolt")
                    StatTile(title: "Sessions", value: "\(trend.count)", subtitle: "logged", systemImage: "number")
                }
                ChartCard(title: "Strength Trend") {
                    Chart(trend, id: \.date) { item in
                        LineMark(x: .value("Date", item.date), y: .value("Top Weight", item.weight))
                        LineMark(x: .value("Date", item.date), y: .value("Estimated 1RM", item.oneRM))
                            .foregroundStyle(.orange)
                    }
                }
                ChartCard(title: "Exercise Volume") {
                    Chart(trend, id: \.date) { item in
                        BarMark(x: .value("Date", item.date, unit: .day), y: .value("Volume", item.volume))
                    }
                }
            }
        }
    }

    private var muscleSection: some View {
        ChartCard(title: "Muscle Volume") {
            let volumes = viewModel.muscleVolumes(from: sessions).filter { $0.volume.isFinite && $0.volume > 0 }
            if volumes.isEmpty {
                EmptyStateView(title: "No muscle volume", message: "Completed weighted sets will appear here.")
            } else {
                Chart(volumes) { item in
                    BarMark(x: .value("Volume", item.volume), y: .value("Muscle", item.muscle))
                        .foregroundStyle(by: .value("Muscle", item.muscle))
                }
            }
        }
    }

    private var heartRateSection: some View {
        let samples = viewModel.heartRateSamples(from: sessions)
        let zones = AggregationManager.heartRateZones(samples: samples, maxHeartRate: settings?.maxHeartRate ?? 190)
        return ChartCard(title: "Heart Rate Zones") {
            if samples.isEmpty {
                EmptyStateView(title: "No heart rate data", message: "Apple Watch workouts will populate heart rate analysis.")
            } else {
                Chart(zones) { zone in
                    BarMark(x: .value("Zone", zone.name), y: .value("Samples", zone.sampleCount))
                        .foregroundStyle(.red.gradient)
                }
            }
        }
    }

    private func chooseDefaultExercise() {
        guard viewModel.selectedExerciseId == nil else { return }
        let loggedExerciseIds = Set(filteredSessions.flatMap { $0.exercises.map(\.exerciseId) })
        viewModel.selectedExerciseId = exercises.first { loggedExerciseIds.contains($0.id) }?.id ?? exercises.first?.id
    }
}

struct WorkoutDetailView: View {
    let session: WorkoutSession
    let settings: UserSettings?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var workoutVM = WorkoutSessionViewModel()
    @State private var showingDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            StatTile(title: "Duration", value: session.duration.shortDurationText, subtitle: "total")
                            StatTile(title: "Volume", value: "\(Int(session.totalVolume))", subtitle: settings?.weightUnit.rawValue ?? "kg")
                            StatTile(title: "Sets", value: "\(session.completedSetCount)", subtitle: "completed")
                            StatTile(title: "Avg HR", value: session.averageHeartRate.map { "\(Int($0))" } ?? "--", subtitle: "bpm")
                            StatTile(title: "Energy", value: session.activeEnergyKcal.map { "\(Int($0))" } ?? "--", subtitle: "kcal")
                        }
                        .padding(.vertical, 8)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                }
                if !session.heartRateSamples.isEmpty {
                    Section("Heart Rate") {
                        Chart(session.heartRateSamples.sorted { $0.timestamp < $1.timestamp }) { sample in
                            LineMark(x: .value("Time", sample.timestamp), y: .value("BPM", sample.bpm))
                        }
                        .frame(height: 180)
                        Chart(AggregationManager.heartRateZones(samples: session.heartRateSamples, maxHeartRate: settings?.maxHeartRate ?? 190)) { zone in
                            BarMark(x: .value("Zone", zone.name), y: .value("Samples", zone.sampleCount))
                        }
                        .frame(height: 160)
                    }
                }
                ForEach(session.exercises.sorted { $0.sortOrder < $1.sortOrder }) { exercise in
                    Section(exercise.exerciseName) {
                        ForEach(exercise.sets.sorted { $0.setIndex < $1.setIndex }) { set in
                            HStack {
                                Text("Set \(set.setIndex) \(set.setType.title)")
                                Spacer()
                                Text(setSummary(set))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !session.note.isEmpty {
                    Section("Notes") { Text(session.note) }
                }
                
                Section {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete Workout", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    }
                }
            }
            .navigationTitle(session.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .confirmationDialog("Delete this workout?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete Workout", role: .destructive) {
                    workoutVM.delete(session, modelContext: modelContext)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the workout from LiftLog history.")
            }
        }
    }

    private func setSummary(_ set: SetRecord) -> String {
        let unit = settings?.weightUnit.fieldSuffix ?? "kg"
        switch set.weightMode {
        case .leftRightSeparate:
            return "\(formatWeight(set.leftWeight))/\(formatWeight(set.rightWeight)) \(unit) x \(set.actualReps)"
        case .timeBased:
            return "\(set.durationSeconds)s"
        case .distanceBased:
            return "\(Int(set.distanceMeters))m / \(set.durationSeconds)s"
        case .bodyweight:
            return set.bodyweightAdditionalLoad > 0 ? "+\(formatWeight(set.bodyweightAdditionalLoad)) \(unit) x \(set.actualReps)" : "BW x \(set.actualReps)"
        case .assistedBodyweight:
            return "Assist \(formatWeight(set.assistanceWeight)) \(unit) x \(set.actualReps)"
        default:
            return "\(formatWeight(set.weight)) \(unit) x \(set.actualReps)"
        }
    }

    private func formatWeight(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value))" : String(format: "%.1f", value)
    }
}

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    let settings: UserSettings?
    let sessions: [WorkoutSession]
    let exercises: [Exercise]
    let routines: [WorkoutRoutine]
    @State private var workoutVM = WorkoutSessionViewModel()
    @State private var exportPreview = ""
    @State private var exportURL: URL?
    @State private var statusMessage = ""
    @State private var healthStatus = HealthKitManager.shared.authorizationState.rawValue
    @State private var watchStatus = "Checking"
    @State private var showingClearHistoryConfirmation = false
    @State private var showingResetSamplesConfirmation = false

    private var completedWorkoutCount: Int {
        sessions.filter { $0.status == .completed }.count
    }

    private var totalVolume: Double {
        sessions.filter { $0.status == .completed }.reduce(0) { $0 + $1.totalVolume }
    }

    private var watchConnectivityStatus: String {
        let manager = WatchConnectivityManager.shared
        guard manager.isSupported else { return "Unavailable" }
        guard manager.activationStateDescription == "Activated" else { return manager.activationStateDescription }
        guard manager.isCounterpartAppInstalled else { return "Watch app not installed" }
        return manager.isReachable ? "Reachable" : "Not reachable"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                ScreenContent {
                    LiftCard {
                        MoreStatusHeader(
                            workouts: completedWorkoutCount,
                            exercises: exercises.count,
                            routines: routines.count,
                            volume: totalVolume,
                            unit: settings?.weightUnit.rawValue ?? "kg"
                        )
                    }
                    if let settings {
                        EditableSettingsSection(settings: settings, healthStatus: healthStatus)
                    } else {
                        SectionHeader(title: "Preferences", systemImage: "gearshape")
                        LiftCard {
                            EmptyStateView(title: "Settings unavailable", message: "LiftLog will create default settings on next launch.")
                        }
                    }

                    SectionHeader(title: "Library", systemImage: "book.pages")
                    LiftCard {
                        NavigationLink {
                            ExerciseLibraryView(exercises: exercises)
                        } label: {
                            HStack {
                                Label("Exercise Library", systemImage: "dumbbell")
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    SectionHeader(title: "Health & Watch", systemImage: "heart")
                    LiftCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Text("HealthKit"); Spacer(); Text(healthStatus == "unknown" ? "Not Requested" : healthStatus.capitalized).foregroundStyle(.secondary) }
                            Divider()
                            HStack { Text("Apple Watch"); Spacer(); Text(watchStatus).foregroundStyle(.secondary) }
                            Divider()
                            Button {
                                Task {
                                    await HealthKitManager.shared.requestAuthorization()
                                    healthStatus = HealthKitManager.shared.authorizationState.rawValue
                                }
                            } label: {
                                Label("Update Health Permissions", systemImage: "heart.fill")
                            }
                            Divider()
                            Button {
                                Task { await importRecentHealthWorkouts() }
                            } label: {
                                Label("Import Recent Health Workouts", systemImage: "heart.text.square")
                            }
                        }
                    }

                    SectionHeader(title: "Data Export", systemImage: "square.and.arrow.up")
                    LiftCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Button {
                                createExport(.workoutHistory)
                            } label: {
                                SettingsActionRowLabel(title: "Export Workout CSV", systemImage: "tablecells")
                            }
                            Divider()
                            Button {
                                createExport(.exerciseLibrary)
                            } label: {
                                SettingsActionRowLabel(title: "Export Exercise CSV", systemImage: "list.bullet.rectangle")
                            }
                            Divider()
                            Button {
                                createExport(.allData)
                            } label: {
                                SettingsActionRowLabel(title: "Export All Data JSON", systemImage: "doc.text")
                            }
                            if let exportURL {
                                Divider()
                                ShareLink(item: exportURL) {
                                    Label("Share Latest Export", systemImage: "square.and.arrow.up")
                                }
                            }
                            if !exportPreview.isEmpty {
                                Divider()
                                Text(exportPreview)
                                    .font(.caption.monospaced())
                                    .lineLimit(12)
                            }
                        }
                    }

                    SectionHeader(title: "Data Management", systemImage: "externaldrive")
                    LiftCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Button(role: .destructive) {
                                showingClearHistoryConfirmation = true
                            } label: {
                                Label("Clear Workout History", systemImage: "trash").foregroundStyle(.red)
                            }
                            .disabled(sessions.isEmpty)
                            Divider()
                            Button {
                                showingResetSamplesConfirmation = true
                            } label: {
                                Label("Restore Sample Data", systemImage: "arrow.clockwise")
                            }
                            Divider()
                            Text("Clearing history removes saved workouts, sets, and heart-rate samples. It keeps your exercise library, templates, and preferences.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    SectionHeader(title: "About LiftLog", systemImage: "info.circle")
                    LiftCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Text("Version"); Spacer(); Text("1.0").foregroundStyle(.secondary) }
                            Divider()
                            HStack { Text("Storage"); Spacer(); Text("Local SwiftData").foregroundStyle(.secondary) }
                            Divider()
                            HStack { Text("Sync"); Spacer(); Text("Local first").foregroundStyle(.secondary) }
                            if !statusMessage.isEmpty {
                                Divider()
                                Text(statusMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .dismissKeyboardOnTap()
            .navigationTitle("Setting")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Clear all workout history?", isPresented: $showingClearHistoryConfirmation, titleVisibility: .visible) {
                Button("Clear History", role: .destructive) {
                    clearWorkoutHistory()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone. Exercise library, routines, and settings will remain.")
            }
            .confirmationDialog("Restore sample data?", isPresented: $showingResetSamplesConfirmation, titleVisibility: .visible) {
                Button("Restore Samples") {
                    SeedData.ensureSeeded(modelContext: modelContext)
                    statusMessage = "Sample data checked and restored where needed."
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Missing preset exercises, templates, settings, and sample history will be inserted.")
            }
            .onAppear {
                healthStatus = HealthKitManager.shared.authorizationState.rawValue
                updateWatchStatus()
            }
        }
    }

    private func createExport(_ kind: ExportManager.ExportKind) {
        do {
            let url = try ExportManager.writeExportFile(kind: kind, sessions: sessions, exercises: exercises, routines: routines)
            exportURL = url
            statusMessage = "Export ready: \(url.lastPathComponent)"
            switch kind {
            case .workoutHistory:
                exportPreview = ExportManager.workoutHistoryCSV(sessions: sessions)
            case .exerciseLibrary:
                exportPreview = ExportManager.exerciseCSV(exercises: exercises)
            case .allData:
                exportPreview = String(data: ExportManager.allDataJSON(sessions: sessions, exercises: exercises, routines: routines) ?? Data(), encoding: .utf8) ?? ""
            }
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func clearWorkoutHistory() {
        do {
            try workoutVM.deleteAllWorkoutHistory(modelContext: modelContext)
            exportPreview = ""
            exportURL = nil
            statusMessage = "Workout history cleared."
        } catch {
            statusMessage = "Clear failed: \(error.localizedDescription)"
        }
    }

    private func updateWatchStatus() {
        WatchConnectivityManager.shared.refreshStatus()
        watchStatus = watchConnectivityStatus
    }

    private func importRecentHealthWorkouts() async {
        await HealthKitManager.shared.requestAuthorization()
        healthStatus = HealthKitManager.shared.authorizationState.rawValue
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -90, to: end) ?? end
        let workouts = await HealthKitManager.shared.fetchStrengthWorkouts(start: start, end: end)
        let count = await workoutVM.importHealthWorkouts(workouts, existingSessions: sessions, modelContext: modelContext)
        statusMessage = count == 0 ? "No new Health workouts found." : "Imported \(count) Health workout\(count == 1 ? "" : "s")."
    }
}

struct EditableSettingsSection: View {
    @Bindable var settings: UserSettings
    let healthStatus: String

    var body: some View {
        SectionHeader(title: "Appearance", systemImage: "paintpalette")
        LiftCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Theme")
                    Spacer()
                    Picker("Theme", selection: $settings.themeRaw) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Divider()
                HStack {
                    Text("Accent")
                    Spacer()
                    Picker("Accent", selection: $settings.accentColorRaw) {
                        ForEach(AccentColorPreset.allCases) { preset in
                            Label(preset.displayName, systemImage: "circle.fill")
                                .tag(preset.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Divider()
                HStack(spacing: AppLayout.compactSpacing) {
                    ForEach(AccentColorPreset.allCases) { preset in
                        Button {
                            settings.accentColor = preset
                        } label: {
                            Circle()
                                .fill(preset.swiftUIColor)
                                .frame(width: 28, height: 28)
                                .overlay {
                                    if settings.accentColor == preset {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(preset.displayName)
                    }
                }
            }
        }

        SectionHeader(title: "Training", systemImage: "dumbbell")
        LiftCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Unit")
                    Spacer()
                    Picker("Unit", selection: $settings.weightUnitRaw) {
                        ForEach(WeightUnit.allCases) { unit in
                            Text(unit.rawValue.uppercased()).tag(unit.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Divider()
                Stepper("Default rest: \(settings.defaultRestSeconds)s", value: $settings.defaultRestSeconds, in: 0...600, step: 15)
                Divider()
                Toggle("Auto start rest timer", isOn: $settings.autoStartRestTimer)
                Divider()
                Toggle("Use RPE", isOn: $settings.usesRPE)
                Divider()
                Toggle("Show warm-up sets", isOn: $settings.showsWarmupSets)
                Divider()
                Toggle("Use bodyweight in bodyweight volume", isOn: $settings.usesBodyweightForBodyweightVolume)
            }
        }

        SectionHeader(title: "Body & Heart Rate", systemImage: "figure.walk")
        LiftCard {
            VStack(alignment: .leading, spacing: 12) {
                Stepper("Age: \(settings.age)", value: $settings.age, in: 12...100)
                Divider()
                HStack {
                    Text("Body Weight")
                    Spacer(minLength: 12)
                    HStack(spacing: 8) {
                        SelectAllDoubleField(title: "Body Weight", value: $settings.bodyweightKg, textAlignment: .center)
                            .frame(width: 72, height: 36)
                        Text("kg")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, alignment: .leading)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                Divider()
                Toggle("Custom max heart rate", isOn: Binding(
                    get: { settings.customMaxHeartRate != nil },
                    set: { enabled in
                        settings.customMaxHeartRate = enabled ? settings.maxHeartRate : nil
                    }
                ))
                Divider()
                if settings.customMaxHeartRate != nil {
                    Stepper("Max HR: \(settings.customMaxHeartRate ?? settings.maxHeartRate)", value: Binding(
                        get: { settings.customMaxHeartRate ?? settings.maxHeartRate },
                        set: { settings.customMaxHeartRate = min(230, max(120, $0)) }
                    ), in: 120...230)
                } else {
                    HStack { Text("Estimated Max HR"); Spacer(); Text("\(settings.maxHeartRate) bpm").foregroundStyle(.secondary) }
                }
            }
        }

        SectionHeader(title: "Apple Health", systemImage: "cross.case")
        LiftCard {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Write workouts to Apple Health", isOn: $settings.writesWorkoutsToHealth)
                Divider()
                Text(healthStatus == "authorized" ? "Health permissions are active." : "Health data requires permission before heart rate, energy, and workout writes are available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct MoreStatusHeader: View {
    let workouts: Int
    let exercises: Int
    let routines: Int
    let volume: Double
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LiftLog")
                        .font(.title2.bold())
                    Text("Local-first strength training log")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            HStack(spacing: AppLayout.compactSpacing) {
                StatTile(title: "History", value: "\(workouts)", subtitle: "workouts", systemImage: "clock.arrow.circlepath")
                StatTile(title: "Library", value: "\(exercises)", subtitle: "exercises", systemImage: "dumbbell")
                StatTile(title: "Volume", value: "\(Int(volume))", subtitle: unit, systemImage: "scalemass")
            }
            HStack {
                Label("\(routines) templates", systemImage: "square.stack.3d.up")
                Spacer()
                Label("No login required", systemImage: "lock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

struct RestTimerView: View {
    @Bindable var restTimer: RestTimerManager
    let onAdjust: (Int) -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rest \(restTimer.remainingSeconds)s")
                .font(.title3.bold())
            HStack {
                Button("-30") { onAdjust(-30) }
                Button("Skip") { onSkip() }
                Button("+30") { onAdjust(30) }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
}

struct WorkoutSummaryCard: View {
    let session: WorkoutSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(session.name).font(.headline)
                Spacer()
                Text(session.workoutDate.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Label(session.duration.shortDurationText, systemImage: "clock")
                Label("\(Int(session.totalVolume))", systemImage: "scalemass")
                Label("\(session.completedSetCount)", systemImage: "checkmark.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Text("Avg HR \(session.averageHeartRate.map { String(Int($0)) } ?? "--")")
                Text("Energy \(session.activeEnergyKcal.map { String(Int($0)) } ?? "--") kcal")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppLayout.cardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: AppLayout.cardCornerRadius)
                .stroke(.quaternary, lineWidth: 1)
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let subtitle: String
    var systemImage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppLayout.cardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: AppLayout.cardCornerRadius)
                .stroke(.quaternary, lineWidth: 1)
        }
    }
}

struct ChartCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content.frame(height: 220)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppLayout.cardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: AppLayout.cardCornerRadius)
                .stroke(.quaternary, lineWidth: 1)
        }
    }
}

struct LiftCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppLayout.cardCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: AppLayout.cardCornerRadius)
                    .stroke(.quaternary, lineWidth: 1)
            }
    }
}

struct SectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(.primary)
    }
}

struct SettingsActionRowLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 28, alignment: .center)
            Text(title)
                .font(.body)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .allowsTightening(true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct MetricPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct UnitNumberField: View {
    let title: String
    @Binding var value: Double
    let unit: String
    var width: CGFloat? = nil

    var body: some View {
        HStack(spacing: 4) {
            SelectAllDoubleField(title: title, value: $value)
            Text(unit)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, alignment: .leading)
        }
        .frame(width: width)
    }
}

struct SelectAllDoubleField: View {
    let title: String
    @Binding var value: Double
    var keyboardType: UIKeyboardType = .decimalPad
    var textAlignment: NSTextAlignment = .natural

    var body: some View {
        SelectAllNumberTextField(
            title: title,
            value: $value,
            keyboardType: keyboardType,
            textAlignment: textAlignment,
            formatter: editableDoubleText,
            parser: { text, _ in Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        )
    }
}

struct SelectAllOptionalDoubleField: View {
    let title: String
    @Binding var value: Double?
    var keyboardType: UIKeyboardType = .decimalPad
    var textAlignment: NSTextAlignment = .natural

    var body: some View {
        SelectAllNumberTextField(
            title: title,
            value: $value,
            keyboardType: keyboardType,
            textAlignment: textAlignment,
            formatter: { value in value.map(editableDoubleText) ?? "" },
            parser: { text, _ in
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : Double(trimmed)
            }
        )
    }
}

struct SelectAllIntField: View {
    let title: String
    @Binding var value: Int
    var keyboardType: UIKeyboardType = .numberPad
    var textAlignment: NSTextAlignment = .natural

    var body: some View {
        SelectAllNumberTextField(
            title: title,
            value: $value,
            keyboardType: keyboardType,
            textAlignment: textAlignment,
            formatter: { "\($0)" },
            parser: { text, _ in Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        )
    }
}

private func editableDoubleText(_ value: Double) -> String {
    guard value.isFinite else { return "" }
    return value.rounded() == value ? "\(Int(value))" : String(format: "%g", value)
}

#if canImport(UIKit)
struct SelectAllNumberTextField<Value>: UIViewRepresentable {
    let title: String
    @Binding var value: Value
    var keyboardType: UIKeyboardType
    var textAlignment: NSTextAlignment
    var formatter: (Value) -> String
    var parser: (String, Value) -> Value

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField(frame: .zero)
        textField.borderStyle = .roundedRect
        textField.placeholder = title
        textField.keyboardType = keyboardType
        textField.textAlignment = textAlignment
        textField.contentVerticalAlignment = .center
        textField.adjustsFontSizeToFitWidth = true
        textField.minimumFontSize = 10
        textField.clipsToBounds = true
        textField.delegate = context.coordinator
        textField.addAction(UIAction { [weak coordinator = context.coordinator, weak textField] _ in
            guard let textField else { return }
            coordinator?.editingChanged(textField)
        }, for: .editingChanged)
        textField.text = formatter(value)
        return textField
    }

    func updateUIView(_ textField: UITextField, context: Context) {
        context.coordinator.parent = self
        textField.placeholder = title
        textField.keyboardType = keyboardType
        textField.textAlignment = textAlignment
        textField.contentVerticalAlignment = .center
        let updatedText = formatter(value)
        if !textField.isFirstResponder, textField.text != updatedText {
            textField.text = updatedText
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SelectAllNumberTextField

        init(_ parent: SelectAllNumberTextField) {
            self.parent = parent
        }

        func editingChanged(_ textField: UITextField) {
            parent.value = parent.parser(textField.text ?? "", parent.value)
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            DispatchQueue.main.async {
                textField.selectAll(nil)
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            textField.text = parent.formatter(parent.value)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }
    }
}
#endif

struct RestFinishedBanner: View {
    let target: SetTarget

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.badge.fill")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Next set ready")
                    .font(.subheadline.weight(.semibold))
                Text("\(target.exerciseName) · Set \(target.setIndex) · \(target.weightText) x \(target.reps)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppLayout.cardCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: AppLayout.cardCornerRadius)
                .stroke(.quaternary, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
    }
}

struct NextSetCard: View {
    let target: SetTarget

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "target")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text("Next Set")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(target.exerciseName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("Set \(target.setIndex) · \(target.setType.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(target.weightText) x \(target.reps)")
                    .font(.headline)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: AppLayout.cardCornerRadius))
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
}

extension Binding where Value == String {
    init(_ source: Binding<String?>, replacingNilWith fallback: String) {
        self.init(
            get: { source.wrappedValue ?? fallback },
            set: { source.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}

enum Keyboard {
    static func dismiss() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}

extension View {
    func dismissKeyboardOnTap() -> some View {
        background(KeyboardDismissTapInstaller())
    }
}

#if canImport(UIKit)
private struct KeyboardDismissTapInstaller: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            context.coordinator.installIfNeeded(from: view)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.installIfNeeded(from: uiView)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var installedWindow: UIWindow?
        private weak var recognizer: UITapGestureRecognizer?

        deinit {
            if let recognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
        }

        func installIfNeeded(from view: UIView) {
            guard let window = view.window, installedWindow !== window else { return }
            if let recognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            window.addGestureRecognizer(recognizer)
            self.recognizer = recognizer
            installedWindow = window
        }

        @objc private func handleTap() {
            Keyboard.dismiss()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView {
                    return false
                }
                view = current.superview
            }
            return true
        }
    }
}
#else
private struct KeyboardDismissTapInstaller: View {
    var body: some View {
        EmptyView()
    }
}
#endif

extension AppTheme {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }

    var displayName: String {
        switch self {
        case .light: "Day"
        case .dark: "Night"
        case .system: "System"
        }
    }
}

extension AccentColorPreset {
    var swiftUIColor: Color {
        switch self {
        case .pink: .pink
        case .blue: .blue
        case .green: .green
        case .orange: .orange
        case .purple: .purple
        case .red: .red
        }
    }

    var displayName: String {
        switch self {
        case .pink: "Pink"
        case .blue: "Blue"
        case .green: "Green"
        case .orange: "Orange"
        case .purple: "Purple"
        case .red: "Red"
        }
    }
}

extension TimeInterval {
    var shortClockText: String {
        let total = max(0, Int(self))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", seconds))"
        }
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Exercise.self, WorkoutRoutine.self, RoutineExercise.self, WorkoutSession.self, WorkoutExercise.self, SetRecord.self, HeartRateSample.self, UserSettings.self, BodyMeasurement.self], inMemory: true)
}
