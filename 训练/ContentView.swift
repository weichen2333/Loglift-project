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

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(sessions: sessions, exercises: exercises, routines: routines, settings: settings.first, selectedTab: $selectedTab, trainLaunchIntent: $trainLaunchIntent, workoutVM: workoutVM, routineVM: routineVM)
                .tabItem { Label("Dashboard", systemImage: "house") }
                .tag(LiftLogTab.dashboard)
            TrainView(exercises: exercises, routines: routines, settings: settings.first, trainLaunchIntent: $trainLaunchIntent, workoutVM: workoutVM, routineVM: routineVM)
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
                VStack(alignment: .leading, spacing: 14) {
                    statusCard
                    weekStats
                    if !recentRecords.isEmpty {
                        personalRecordsCard
                    }
                    if let lastCompleted {
                        SectionHeader(title: "Latest Workout", systemImage: "clock.arrow.circlepath")
                        Button { selectedSession = lastCompleted } label: {
                            WorkoutSummaryCard(session: lastCompleted)
                        }
                        .buttonStyle(.plain)
                    } else {
                        EmptyStateView(title: "No workout history", message: "Start a quick workout or use a routine to create your first log.")
                    }
                    quickActions
                }
                .padding(.horizontal)
                .padding(.bottom)
                .padding(.top, 4)
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
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "This Week", systemImage: "calendar.badge.clock")
            HStack(spacing: 10) {
                StatTile(title: "Sessions", value: "\(weekSummary?.workoutCount ?? 0)", subtitle: "workouts", systemImage: "figure.strengthtraining.traditional")
                StatTile(title: "Volume", value: "\(Int(weekSummary?.volume ?? 0))", subtitle: settings?.weightUnit.rawValue ?? "kg", systemImage: "scalemass")
                StatTile(title: "Time", value: (weekSummary?.duration ?? 0).shortDurationText, subtitle: "logged", systemImage: "timer")
            }
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: activeSession == nil ? "Quick Start" : "Current Workout", systemImage: "bolt.fill")
            if let activeSession {
                LiftCard {
                    VStack(alignment: .leading, spacing: 12) {
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
                        if let next = TrainingInsights.nextSet(in: activeSession) {
                            Text("Next: \(next.exerciseName) #\(next.setIndex) · \(next.weightText) x \(next.reps)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
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
                HStack(spacing: 10) {
                    Button {
                        startQuickWorkout()
                    } label: {
                        Label("Quick Workout", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

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
                        Label("Template", systemImage: "list.bullet.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
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
        _ = routineVM.startWorkout(from: routine, exercises: exercises, modelContext: modelContext)
        trainLaunchIntent = .none
        selectedTab = .train
    }

    private var personalRecordsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Recent PRs", systemImage: "trophy.fill")
            LiftCard {
                VStack(spacing: 10) {
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

struct TrainView: View {
    let exercises: [Exercise]
    let routines: [WorkoutRoutine]
    let settings: UserSettings?
    @Binding var trainLaunchIntent: TrainLaunchIntent
    @Bindable var workoutVM: WorkoutSessionViewModel
    @Bindable var routineVM: RoutineViewModel
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
                    ActiveWorkoutView(session: activeSession, exercises: exercises, settings: settings, workoutVM: workoutVM, showingExercisePicker: $showingExercisePicker)
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
            VStack(alignment: .leading, spacing: 14) {
                LiftCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Quick Workout", systemImage: "bolt.fill")
                            .font(.title3.bold())
                        Text("Unplanned session for today's lifts.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button {
                            shouldPromptForFirstExercise = true
                            _ = workoutVM.startEmptyWorkout(modelContext: modelContext)
                        } label: {
                            Label("Start and Add Exercise", systemImage: "plus.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionHeader(title: "Templates", systemImage: "list.bullet.rectangle")
                        Spacer()
                        NavigationLink {
                            RoutineManagerView(routines: routines, exercises: exercises)
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
                                _ = routineVM.startWorkout(from: routine, exercises: exercises, modelContext: modelContext)
                            } onDuplicate: {
                                routineVM.duplicate(routine, modelContext: modelContext)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
            .padding(.top, 4)
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
    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var showingFinishConfirmation = false
    @State private var showingCancelConfirmation = false
    @State private var currentTime = Date()

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
                    RestTimerView(restTimer: workoutVM.restTimer)
                }
                if let next = TrainingInsights.nextSet(in: session) {
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
                        }
                        Button {
                            workoutVM.addSet(to: workoutExercise, modelContext: modelContext)
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
                                    workoutVM.addSet(to: workoutExercise, modelContext: modelContext)
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
        .safeAreaInset(edge: .bottom) {
            activeCommandBar
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    showingCancelConfirmation = true
                }
                .foregroundStyle(.red)
            }
            #if os(iOS)
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    Keyboard.dismiss()
                }
            }
            #endif
        }
        .onReceive(timer) { _ in
            currentTime = Date()
            workoutVM.restTimer.tick()
            let connectivity = WatchConnectivityManager.shared
            if connectivity.consumeCompleteCurrentSetCommand(for: session.id) {
                workoutVM.completeNextSet(in: session, autoStartRest: settings?.autoStartRestTimer ?? true, modelContext: modelContext)
            }
            if connectivity.consumePauseWorkoutCommand(), session.status == .active {
                workoutVM.pause(session, modelContext: modelContext)
            }
            if connectivity.consumeResumeWorkoutCommand(), session.status == .paused {
                workoutVM.resume(session, modelContext: modelContext)
            }
            let endedCommand = connectivity.consumeEndedWorkoutCommand()
            if endedCommand.requested {
                Task {
                    await workoutVM.finish(session, modelContext: modelContext, writeToHealth: false, healthKitWorkoutUUID: endedCommand.healthKitUUID)
                }
            }
        }
        .confirmationDialog("Finish this workout?", isPresented: $showingFinishConfirmation, titleVisibility: .visible) {
            Button("Finish Workout") {
                Task { await workoutVM.finish(session, modelContext: modelContext, writeToHealth: settings?.writesWorkoutsToHealth ?? true) }
            }
            Button("Discard Workout", role: .destructive) {
                modelContext.delete(session)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Completed sets will be saved to history, or discard to delete it without saving.")
        }
        .confirmationDialog("Cancel this workout?", isPresented: $showingCancelConfirmation, titleVisibility: .visible) {
            Button("Discard Workout", role: .destructive) {
                modelContext.delete(session)
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
                MetricPill(title: "Volume", value: "\(Int(session.totalVolume))")
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
        HStack(spacing: 10) {
            Button {
                workoutVM.completeNextSet(in: session, autoStartRest: settings?.autoStartRestTimer ?? true, modelContext: modelContext)
            } label: {
                Label("Done Set", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(TrainingInsights.nextSet(in: session) == nil)

            Button {
                if session.status == .paused {
                    workoutVM.resume(session, modelContext: modelContext)
                } else {
                    workoutVM.pause(session, modelContext: modelContext)
                }
            } label: {
                Label(session.status == .paused ? "Resume" : "Pause", systemImage: session.status == .paused ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
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
}

struct ActiveWorkoutEmptyState: View {
    let onAddExercise: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("#\(set.setIndex)")
                    .font(.headline)
                    .frame(width: 34, alignment: .leading)
                Picker("Type", selection: $set.setTypeRaw) {
                    ForEach(SetType.allCases) { type in
                        Text(type.title).tag(type.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Spacer()
                Button {
                    workoutVM.complete(set, in: session, restSeconds: restSeconds, autoStartRest: settings?.autoStartRestTimer ?? true, modelContext: modelContext)
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
                    TextField("RPE", value: $set.rpe, format: .number.precision(.fractionLength(1)))
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 62)
                }
            }
        }
        .onChange(of: set.weight) { _, newValue in set.weight = max(0, newValue) }
        .onChange(of: set.actualReps) { _, newValue in set.actualReps = max(0, newValue) }
        .submitLabel(.done)
        .onSubmit {
            Keyboard.dismiss()
        }
    }

    @ViewBuilder
    private var metricFields: some View {
        switch set.weightMode {
        case .leftRightSeparate:
            TextField("L", value: $set.leftWeight, format: .number)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
            TextField("R", value: $set.rightWeight, format: .number)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
            Stepper("\(set.actualReps) reps", value: $set.actualReps, in: 0...100)
                .labelsHidden()
        case .timeBased:
            Stepper("\(set.durationSeconds)s", value: $set.durationSeconds, in: 0...3600, step: 5)
            TextField("sec", value: $set.durationSeconds, format: .number)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
        case .distanceBased:
            TextField("m", value: $set.distanceMeters, format: .number)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
            TextField("sec", value: $set.durationSeconds, format: .number)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
        case .bodyweight:
            Stepper("\(set.actualReps) reps", value: $set.actualReps, in: 0...100)
            TextField("load", value: $set.bodyweightAdditionalLoad, format: .number)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .frame(width: 76)
        case .assistedBodyweight:
            Stepper("\(set.actualReps) reps", value: $set.actualReps, in: 0...100)
            TextField("assist", value: $set.assistanceWeight, format: .number)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .frame(width: 76)
        default:
            TextField(settings?.weightUnit.rawValue ?? "kg", value: $set.weight, format: .number)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
            Stepper("\(set.actualReps)", value: $set.actualReps, in: 0...100)
                .labelsHidden()
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
            LazyVStack(alignment: .leading, spacing: 14) {
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
            .padding(.horizontal)
            .padding(.bottom)
            .padding(.top, 4)
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
    @State private var muscle: MuscleGroup = .chest
    @State private var type: ExerciseType = .barbell

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Primary muscle", selection: $muscle) {
                    ForEach(MuscleGroup.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Equipment", selection: $type) {
                    ForEach(ExerciseType.allCases) { Text($0.title).tag($0) }
                }
            }
            .navigationTitle("New Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        viewModel.addExercise(modelContext: modelContext, name: name, muscle: muscle, type: type)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
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
                        RoutineEditorView(routine: routine, exercises: exercises, viewModel: viewModel)
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
                        RoutineExerciseRow(item: item)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.exerciseName)
                .font(.headline)
            Stepper("Sets: \(item.targetSets)", value: $item.targetSets, in: 1...12)
            Stepper("Reps: \(item.targetReps)", value: $item.targetReps, in: 0...100)
            TextField("Target weight", value: $item.targetWeight, format: .number)
                .keyboardType(.decimalPad)
            Stepper("Rest: \(item.restSeconds)s", value: $item.restSeconds, in: 0...600, step: 15)
            Toggle("Warm-up first set", isOn: $item.enableWarmupSets)
            Toggle("Ramping weight", isOn: $item.enableRampingWeight)
        }
        .onChange(of: item.targetWeight) { _, newValue in item.targetWeight = max(0, newValue) }
        .onChange(of: item.targetSets) { _, newValue in item.targetSets = max(1, newValue) }
        .onChange(of: item.targetReps) { _, newValue in item.targetReps = max(0, newValue) }
        .onChange(of: item.restSeconds) { _, newValue in item.restSeconds = max(0, newValue) }
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
                LazyVStack(alignment: .leading, spacing: 14) {
                    let monthSessions = viewModel.sessionsInDisplayedMonth(from: sessions)
                    HStack(spacing: 10) {
                        StatTile(title: "Month", value: "\(monthSessions.count)", subtitle: "workouts", systemImage: "calendar")
                        StatTile(title: "Volume", value: "\(Int(monthSessions.reduce(0) { $0 + $1.totalVolume }))", subtitle: settings?.weightUnit.rawValue ?? "kg", systemImage: "scalemass")
                        StatTile(title: "Time", value: monthSessions.reduce(0) { $0 + $1.duration }.shortDurationText, subtitle: "logged", systemImage: "timer")
                    }

                    LiftCard {
                        VStack(spacing: 14) {
                            monthHeader
                            HStack {
                                ForEach(Calendar.current.shortWeekdaySymbols, id: \.self) { symbol in
                                    Text(symbol)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 10) {
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
                .padding(.horizontal)
                .padding(.bottom)
                .padding(.top, 4)
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
                VStack(alignment: .leading, spacing: 14) {
                    controls
                    overviewSection
                    trendSection
                    exerciseSection
                    muscleSection
                    heartRateSection
                }
                .padding(.horizontal)
                .padding(.bottom)
                .padding(.top, 4)
            }
            .navigationTitle("Progress")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: chooseDefaultExercise)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
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

        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Overview", systemImage: "chart.line.uptrend.xyaxis")
            HStack(spacing: 10) {
                StatTile(title: "Workouts", value: "\(filteredSessions.count)", subtitle: viewModel.selectedRange.rawValue, systemImage: "calendar")
                StatTile(title: "Volume", value: "\(Int(volume))", subtitle: settings?.weightUnit.rawValue ?? "kg", systemImage: "scalemass")
                StatTile(title: "Time", value: duration.shortDurationText, subtitle: "trained", systemImage: "timer")
            }
            HStack(spacing: 10) {
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
                HStack(spacing: 10) {
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
                                Text("#\(set.setIndex) \(set.setType.title)")
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
        switch set.weightMode {
        case .leftRightSeparate:
            return "\(Int(set.leftWeight))/\(Int(set.rightWeight)) x \(set.actualReps)"
        case .timeBased:
            return "\(set.durationSeconds)s"
        case .distanceBased:
            return "\(Int(set.distanceMeters))m / \(set.durationSeconds)s"
        default:
            return "\(Int(set.weight)) x \(set.actualReps)"
        }
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
                VStack(alignment: .leading, spacing: 14) {
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
                                Label("Export Workout CSV", systemImage: "tablecells")
                            }
                            Divider()
                            Button {
                                createExport(.exerciseLibrary)
                            } label: {
                                Label("Export Exercise CSV", systemImage: "list.bullet.rectangle")
                            }
                            Divider()
                            Button {
                                createExport(.allData)
                            } label: {
                                Label("Export All Data JSON", systemImage: "doc.text")
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
                .padding(.horizontal)
                .padding(.bottom)
                .padding(.top, 4)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Setting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        Keyboard.dismiss()
                    }
                }
                #endif
            }
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
                HStack(spacing: 10) {
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
                    Text("Bodyweight kg")
                    Spacer()
                    TextField("Bodyweight kg", value: $settings.bodyweightKg, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
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
            HStack(spacing: 10) {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rest \(restTimer.remainingSeconds)s")
                .font(.title3.bold())
            HStack {
                Button("-30") { restTimer.adjust(by: -30) }
                Button("Skip") { restTimer.skip() }
                Button("+30") { restTimer.adjust(by: 30) }
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
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
                Text("#\(target.setIndex) · \(target.setType.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(target.weightText) x \(target.reps)")
                    .font(.headline)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
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
