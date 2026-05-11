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
    case startRoutine(routineId: UUID)
    case startQuick
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WorkoutSession.workoutDate, order: .reverse) private var sessions: [WorkoutSession]
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @Query(sort: \WorkoutRoutine.name) private var routines: [WorkoutRoutine]
    @Query private var settings: [UserSettings]
    @Query(sort: \BodyMeasurement.date) private var bodyMeasurements: [BodyMeasurement]
    @State private var selectedTab: LiftLogTab = .dashboard
    @State private var trainLaunchIntent: TrainLaunchIntent = .none
    @State private var workoutVM = WorkoutSessionViewModel()
    @State private var routineVM = RoutineViewModel()

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(sessions: sessions, exercises: exercises, routines: routines, settings: settings.first, bodyMeasurements: bodyMeasurements, selectedTab: $selectedTab, trainLaunchIntent: $trainLaunchIntent, workoutVM: workoutVM, routineVM: routineVM)
                .tabItem { Label("概览", systemImage: "house") }
                .tag(LiftLogTab.dashboard)
            TrainView(exercises: exercises, routines: routines, settings: settings.first, trainLaunchIntent: $trainLaunchIntent, workoutVM: workoutVM, routineVM: routineVM)
                .tabItem { Label("训练", systemImage: "figure.strengthtraining.traditional") }
                .tag(LiftLogTab.train)
            WorkoutCalendarView(sessions: sessions, settings: settings.first)
                .tabItem { Label("日历", systemImage: "calendar") }
                .tag(LiftLogTab.calendar)
            ProgressAnalyticsView(sessions: sessions, exercises: exercises, settings: settings.first, bodyMeasurements: bodyMeasurements)
                .tabItem { Label("进度", systemImage: "chart.xyaxis.line") }
                .tag(LiftLogTab.progress)
            SettingsView(settings: settings.first, sessions: sessions, exercises: exercises, routines: routines)
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(LiftLogTab.settings)
        }
        .preferredColorScheme(settings.first?.theme.preferredColorScheme)
        .tint(settings.first?.accentColor.swiftUIColor ?? .pink)
        .environment(\.locale, settings.first?.localePreference.localeIdentifier.map(Locale.init(identifier:)) ?? Locale.current)
        .task {
            SeedData.ensureSeeded(modelContext: modelContext)
            workoutVM.attachContext(sessions: sessions, routines: routines, settings: settings.first)
            workoutVM.broadcastIdleSnapshot(routines: routines, hapticOnRestComplete: settings.first?.watchHapticOnRestComplete ?? true, weightUnit: settings.first?.weightUnit ?? .kg)
            workoutVM.restTimer.onFinish = {
                if settings.first?.watchHapticOnRestComplete ?? true {
                    DesignTokens.Haptic.success()
                }
                WatchConnectivityManager.shared.sendCommand(.restCompleted)
            }
            workoutVM.restTimer.onChange = { [weak workoutVM] in
                guard let workoutVM, let session = workoutVM.currentWorkout else { return }
                workoutVM.sync(session)
            }
        }
        .onChange(of: sessions.count) { _, _ in
            workoutVM.attachContext(sessions: sessions, routines: routines, settings: settings.first)
        }
        .onChange(of: routines.count) { _, _ in
            workoutVM.attachContext(sessions: sessions, routines: routines, settings: settings.first)
        }
        .onChange(of: settings.first?.weightUnitRaw) { _, _ in
            workoutVM.attachContext(sessions: sessions, routines: routines, settings: settings.first)
        }
        .onChange(of: settings.first?.oneRepMaxFormulaRaw) { _, _ in
            workoutVM.attachContext(sessions: sessions, routines: routines, settings: settings.first)
        }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            handleWatchTopLevelCommands()
        }
    }

    private func handleWatchTopLevelCommands() {
        let connectivity = WatchConnectivityManager.shared
        if connectivity.consumeRequestStateCommand() {
            if let session = sessions.first(where: { $0.status == .active || $0.status == .paused }) {
                workoutVM.sync(session)
            } else {
                workoutVM.broadcastIdleSnapshot(routines: routines, hapticOnRestComplete: settings.first?.watchHapticOnRestComplete ?? true, weightUnit: settings.first?.weightUnit ?? .kg)
            }
        }
        if connectivity.consumeStartQuickWorkoutCommand() {
            if !sessions.contains(where: { $0.status == .active || $0.status == .paused }) {
                let session = workoutVM.startEmptyWorkout(modelContext: modelContext)
                trainLaunchIntent = .addExercise(workoutId: session.id)
                selectedTab = .train
            }
        }
        if let routineId = connectivity.consumeStartRoutineWorkoutCommand() {
            if let routine = routines.first(where: { $0.id == routineId }), !sessions.contains(where: { $0.status == .active || $0.status == .paused }) {
                let session = routineVM.startWorkout(from: routine, exercises: exercises, modelContext: modelContext)
                workoutVM.register(activeSession: session)
                trainLaunchIntent = .none
                selectedTab = .train
            }
        }
        if connectivity.consumeRestCompletedCommand() {
            workoutVM.restTimer.skip()
        }
    }
}

struct DashboardView: View {
    let sessions: [WorkoutSession]
    let exercises: [Exercise]
    let routines: [WorkoutRoutine]
    let settings: UserSettings?
    let bodyMeasurements: [BodyMeasurement]
    @Binding var selectedTab: LiftLogTab
    @Binding var trainLaunchIntent: TrainLaunchIntent
    @Bindable var workoutVM: WorkoutSessionViewModel
    @Bindable var routineVM: RoutineViewModel
    @Environment(\.modelContext) private var modelContext
    @State private var selectedSession: WorkoutSession?
    @State private var dashboardVM = DashboardViewModel()

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
        dashboardVM.weekSummary(from: sessions)
    }

    private var completedSessions: [WorkoutSession] {
        AggregationManager.completedSessions(sessions)
    }

    private var streak: Int {
        dashboardVM.currentStreak(from: sessions)
    }

    private var recentRecords: [PersonalRecord] {
        dashboardVM.recentRecords(from: sessions, limit: 3)
    }

    private var todayProgress: CGFloat {
        guard let activeSession else { return todaySession == nil ? 0 : 1 }
        guard activeSession.totalSetCount > 0 else { return 0 }
        let value = Double(activeSession.completedSetCount) / Double(activeSession.totalSetCount)
        guard value.isFinite else { return 0 }
        return CGFloat(min(1, max(0, value)))
    }

    private var goalProgress: WeeklyGoalProgress {
        dashboardVM.goalProgress(settings: settings, sessions: sessions)
    }

    private var muscleInsights: [MuscleBalanceInsight] {
        dashboardVM.muscleBalanceInsights(from: sessions, settings: settings)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                    statusCard
                    WeeklyGoalsCard(progress: goalProgress, weightUnit: settings?.weightUnit.rawValue ?? "kg")
                    weekStats
                    if !recentRecords.isEmpty {
                        personalRecordsCard
                    }
                    if !muscleInsights.isEmpty {
                        MuscleBalanceCard(insights: muscleInsights)
                    }
                    BodyWeightCard(measurements: bodyMeasurements, unit: settings?.weightUnit ?? .kg)
                    if let lastCompleted {
                        SectionHeader(title: "上次训练", systemImage: "clock.arrow.circlepath")
                        Button { selectedSession = lastCompleted } label: {
                            WorkoutSummaryCard(session: lastCompleted)
                        }
                        .buttonStyle(.plain)
                    } else {
                        EmptyStateView(title: "暂无训练记录", message: "开始一次快速训练，或选择模板创建第一条记录。")
                    }
                    quickActions
                }
                .padding(.horizontal)
                .padding(.bottom)
                .padding(.top, 4)
            }
            .navigationTitle("训练")
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
                    Text("今日")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(activeSession != nil ? "训练进行中" : (todaySession == nil ? "准备开始" : "今日已完成"))
                        .font(.title2.bold())
                    if let activeSession {
                        Text("已完成 \(activeSession.completedSetCount)/\(activeSession.totalSetCount) 组")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("连续训练 \(streak) 天 · 累计 \(completedSessions.count) 次")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
    }

    private var weekStats: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "本周", systemImage: "calendar.badge.clock")
            HStack(spacing: 10) {
                StatTile(title: "训练", value: "\(weekSummary?.workoutCount ?? 0)", subtitle: "次", systemImage: "figure.strengthtraining.traditional")
                StatTile(title: "容量", value: "\(Int(weekSummary?.volume ?? 0))", subtitle: settings?.weightUnit.rawValue ?? "kg", systemImage: "scalemass")
                StatTile(title: "时长", value: (weekSummary?.duration ?? 0).shortDurationText, subtitle: "累计", systemImage: "timer")
            }
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: activeSession == nil ? "开始训练" : "当前训练", systemImage: "bolt.fill")
            if let activeSession {
                LiftCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(activeSession.name)
                                    .font(.headline)
                                Text("\(activeSession.completedSetCount)/\(activeSession.totalSetCount) 组 · \(activeSession.duration.shortDurationText)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(activeSession.status == .paused ? "已暂停" : "进行中")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(activeSession.status == .paused ? .orange : .green)
                        }
                        if let next = TrainingInsights.nextSet(in: activeSession) {
                            Text("下一组：\(next.exerciseName) 第\(next.setIndex)组 · \(next.weightText) × \(next.reps)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            Button {
                                continueWorkout()
                            } label: {
                                Label("继续训练", systemImage: "play.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                addExerciseFromDashboard(to: activeSession)
                            } label: {
                                Label("添加动作", systemImage: "plus.circle")
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
                        Label("快速训练", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Menu {
                        if routines.isEmpty {
                            Button("暂无模板") {}
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
                        Label("使用模板", systemImage: "list.bullet.rectangle")
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
        let session = routineVM.startWorkout(from: routine, exercises: exercises, modelContext: modelContext)
        workoutVM.register(activeSession: session)
        trainLaunchIntent = .none
        selectedTab = .train
    }

    private var personalRecordsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "最新个人记录", systemImage: "trophy.fill")
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
                                Text("估算 1RM \(Int(record.bestOneRepMax))")
                                    .font(.headline)
                                Text("\(Int(record.bestWeight)) × \(record.reps)")
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
                    ActiveWorkoutView(session: activeSession, exercises: exercises, settings: settings, allSessions: sessions, routines: routines, workoutVM: workoutVM, showingExercisePicker: $showingExercisePicker)
                } else {
                    startPanel
                }
            }
            .navigationTitle(activeSession == nil ? "训练" : "训练中")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if activeSession != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingExercisePicker = true } label: {
                            Label("添加动作", systemImage: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingExercisePicker) {
                if let activeSession {
                    ExercisePickerView(exercises: exercises, allSessions: sessions, settings: settings) { exercise in
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
        case .startQuick, .startRoutine:
            // Quick-start intents are consumed at the ContentView level when no
            // session exists. Once a session exists, fall through to the normal flow.
            trainLaunchIntent = .none
        }
    }

    private var startPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LiftCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("快速训练", systemImage: "bolt.fill")
                            .font(.title3.bold())
                        Text("没有计划？立即开始今天的训练。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button {
                            shouldPromptForFirstExercise = true
                            _ = workoutVM.startEmptyWorkout(modelContext: modelContext)
                        } label: {
                            Label("开始并添加动作", systemImage: "plus.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionHeader(title: "训练模板", systemImage: "list.bullet.rectangle")
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
                            EmptyStateView(title: "暂无模板", message: "创建推/拉/腿或属于你的训练模板，下次开始更快。")
                        }
                    } else {
                        ForEach(routines.sorted { $0.name < $1.name }) { routine in
                            RoutineStartCard(routine: routine) {
                                let session = routineVM.startWorkout(from: routine, exercises: exercises, modelContext: modelContext)
                                workoutVM.register(activeSession: session)
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
                    Text(routine.note.isEmpty ? "\(routine.exercises.count) 个动作 · 计划 \(estimatedSets) 组" : routine.note)
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
                            Label("复制", systemImage: "doc.on.doc")
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
    let allSessions: [WorkoutSession]
    let routines: [WorkoutRoutine]
    @Bindable var workoutVM: WorkoutSessionViewModel
    @Binding var showingExercisePicker: Bool
    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var showingFinishConfirmation = false
    @State private var showingCancelConfirmation = false
    @State private var currentTime = Date()
    @State private var editingSetId: UUID?
    @State private var swappingExerciseId: UUID?

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
                            SetRowView(
                                set: set,
                                restSeconds: workoutExercise.defaultRestSeconds,
                                session: session,
                                workoutExercise: workoutExercise,
                                workoutVM: workoutVM,
                                settings: settings,
                                allSessions: allSessions,
                                editingSetId: $editingSetId
                            )
                        }
                        .onDelete { offsets in
                            let sorted = workoutExercise.sets.sorted { $0.setIndex < $1.setIndex }
                            for offset in offsets {
                                workoutVM.deleteSet(sorted[offset], from: workoutExercise, in: session, modelContext: modelContext)
                            }
                        }
                        Button {
                            workoutVM.addSet(to: workoutExercise, in: session, modelContext: modelContext)
                            DesignTokens.Haptic.tap()
                        } label: {
                            Label("添加组", systemImage: "plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    } header: {
                        ExerciseSectionHeader(
                            workoutExercise: workoutExercise,
                            allSessions: allSessions,
                            settings: settings,
                            sessionId: session.id,
                            onAddSet: { workoutVM.addSet(to: workoutExercise, in: session, modelContext: modelContext) },
                            onSwap: { swappingExerciseId = workoutExercise.id },
                            onRemove: { workoutVM.deleteExercise(workoutExercise, from: session, modelContext: modelContext) }
                        )
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
                Button("取消") {
                    showingCancelConfirmation = true
                }
                .foregroundStyle(.red)
            }
            #if os(iOS)
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") {
                    Keyboard.dismiss()
                }
            }
            #endif
        }
        .onReceive(timer) { _ in
            currentTime = Date()
            workoutVM.restTimer.tick()
            let connectivity = WatchConnectivityManager.shared
            let completeCommand = connectivity.consumeCompleteCurrentSetCommand(for: session.id)
            if completeCommand.consumed {
                if let setId = completeCommand.setId {
                    workoutVM.completeSpecificSet(setId: setId, in: session, autoStartRest: settings?.autoStartRestTimer ?? true, modelContext: modelContext)
                } else {
                    workoutVM.completeNextSet(in: session, autoStartRest: settings?.autoStartRestTimer ?? true, modelContext: modelContext)
                }
            }
            if connectivity.consumePauseWorkoutCommand(), session.status == .active {
                workoutVM.pause(session, modelContext: modelContext)
            }
            if connectivity.consumeResumeWorkoutCommand(), session.status == .paused {
                workoutVM.resume(session, modelContext: modelContext)
            }
            if connectivity.consumeRequestStateCommand() {
                workoutVM.sync(session)
            }
            let endedCommand = connectivity.consumeEndedWorkoutCommand()
            if endedCommand.requested {
                Task {
                    await workoutVM.finish(session, modelContext: modelContext, writeToHealth: false, healthKitWorkoutUUID: endedCommand.healthKitUUID)
                }
            }
        }
        .sheet(item: Binding(
            get: { editingSet },
            set: { _ in editingSetId = nil }
        )) { context in
            SetEditorSheet(
                set: context.set,
                session: session,
                workoutExercise: context.workoutExercise,
                settings: settings,
                workoutVM: workoutVM,
                allSessions: allSessions
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(item: Binding(
            get: { swappingExerciseContext },
            set: { _ in swappingExerciseId = nil }
        )) { context in
            ExercisePickerView(exercises: exercises, allSessions: allSessions, settings: settings) { replacement in
                workoutVM.swapExercise(context, with: replacement, in: session, modelContext: modelContext)
                swappingExerciseId = nil
            }
        }
        .overlay(alignment: .top) {
            PRCelebrationOverlay(record: Binding(get: { workoutVM.pendingPRCelebration }, set: { workoutVM.pendingPRCelebration = $0 }))
        }
        .alert("此组未完成", isPresented: validationAlertBinding) {
            Button("好") { workoutVM.clearValidationWarning() }
        } message: {
            Text(workoutVM.pendingValidationWarning ?? "")
        }
        .confirmationDialog("结束本次训练？", isPresented: $showingFinishConfirmation, titleVisibility: .visible) {
            Button("结束并保存") {
                Task { await workoutVM.finish(session, modelContext: modelContext, writeToHealth: settings?.writesWorkoutsToHealth ?? true) }
            }
            Button("放弃本次训练", role: .destructive) {
                workoutVM.discard(session, modelContext: modelContext, routines: routines, hapticOnRestComplete: settings?.watchHapticOnRestComplete ?? true, weightUnit: settings?.weightUnit ?? .kg)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已完成的组将保存到历史，放弃则不会保留任何记录。")
        }
        .confirmationDialog("放弃本次训练？", isPresented: $showingCancelConfirmation, titleVisibility: .visible) {
            Button("放弃训练", role: .destructive) {
                workoutVM.discard(session, modelContext: modelContext, routines: routines, hapticOnRestComplete: settings?.watchHapticOnRestComplete ?? true, weightUnit: settings?.weightUnit ?? .kg)
            }
            Button("继续训练", role: .cancel) {}
        } message: {
            Text("将永久删除本次训练及所有已记录的组。")
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
                    Text("组")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: progress)
                .tint(.accentColor)
            HStack(spacing: 8) {
                MetricPill(title: "容量", value: "\(Int(session.totalVolume))")
                MetricPill(title: "次数", value: "\(session.totalReps)")
                MetricPill(title: "状态", value: session.status == .paused ? "已暂停" : "进行中")
            }
        }
        .padding(.vertical, 4)
    }

    private var elapsedDuration: TimeInterval {
        // Read currentTime to keep the view re-evaluating each tick; the value itself
        // comes from session.duration so it freezes during .paused.
        _ = currentTime
        return session.duration
    }

    private struct EditingContext: Identifiable {
        let id: UUID
        let set: SetRecord
        let workoutExercise: WorkoutExercise
    }

    private var editingSet: EditingContext? {
        guard let id = editingSetId else { return nil }
        for exercise in session.exercises {
            if let set = exercise.sets.first(where: { $0.id == id }) {
                return EditingContext(id: id, set: set, workoutExercise: exercise)
            }
        }
        return nil
    }

    private var swappingExerciseContext: WorkoutExercise? {
        guard let id = swappingExerciseId else { return nil }
        return session.exercises.first(where: { $0.id == id })
    }

    private var validationAlertBinding: Binding<Bool> {
        Binding(
            get: { workoutVM.pendingValidationWarning != nil },
            set: { if !$0 { workoutVM.clearValidationWarning() } }
        )
    }

    private var activeCommandBar: some View {
        HStack(spacing: 10) {
            Button {
                workoutVM.completeNextSet(in: session, autoStartRest: settings?.autoStartRestTimer ?? true, modelContext: modelContext)
            } label: {
                Label("完成本组", systemImage: "checkmark.circle.fill")
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
                Label(session.status == .paused ? "恢复" : "暂停", systemImage: session.status == .paused ? "play.fill" : "pause.fill")
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
            Label("搭建今日训练", systemImage: "plus.circle.fill")
                .font(.title3.bold())
            Text("选择本次训练的第一个动作。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(action: onAddExercise) {
                Label("添加首个动作", systemImage: "dumbbell.fill")
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
    let workoutExercise: WorkoutExercise
    @Bindable var workoutVM: WorkoutSessionViewModel
    let settings: UserSettings?
    let allSessions: [WorkoutSession]
    @Binding var editingSetId: UUID?

    private var summary: String {
        TrainingInsights.displayWeight(for: set) + " × \(set.actualReps)"
    }

    private var rowBackground: Color {
        switch set.setType {
        case .warmup: return .orange.opacity(0.10)
        case .drop: return .purple.opacity(0.10)
        case .failure: return .red.opacity(0.10)
        case .restPause: return .blue.opacity(0.08)
        case .superset: return .green.opacity(0.08)
        case .normal: return .clear
        }
    }

    var body: some View {
        Button {
            editingSetId = set.id
        } label: {
            HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
                ZStack {
                    Circle()
                        .strokeBorder(set.isCompleted ? Color.green : Color.secondary.opacity(0.4), lineWidth: 1.5)
                        .frame(width: 30, height: 30)
                    Text("\(set.setIndex)")
                        .font(.subheadline.bold().monospacedDigit())
                        .foregroundStyle(set.isCompleted ? .green : .primary)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        if set.setType != .normal {
                            Text(set.setType.title)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(setTypeColor.opacity(0.18), in: Capsule())
                                .foregroundStyle(setTypeColor)
                        }
                        Text(summary)
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.primary)
                    }
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        if let rpe = set.rpe {
                            Text("RPE \(String(format: "%.1f", rpe))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(set.isCompleted ? "已完成" : "点击编辑")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    let pr = workoutVM.complete(set, in: session, restSeconds: restSeconds, autoStartRest: settings?.autoStartRestTimer ?? true, modelContext: modelContext, allowPRCelebration: settings?.celebratesPersonalRecords ?? true)
                    if pr != nil { DesignTokens.Haptic.success() } else { DesignTokens.Haptic.tap() }
                } label: {
                    Image(systemName: set.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.title)
                        .foregroundStyle(set.isCompleted ? .green : .accentColor)
                        .symbolEffect(.bounce, value: set.isCompleted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(set.isCompleted ? "标记为未完成" : "标记为已完成")
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .listRowBackground(rowBackground)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("第 \(set.setIndex) 组：\(summary)，\(set.isCompleted ? "已完成" : "未完成")")
    }

    private var setTypeColor: Color {
        switch set.setType {
        case .warmup: return .orange
        case .drop: return .purple
        case .failure: return .red
        case .restPause: return .blue
        case .superset: return .green
        case .normal: return .secondary
        }
    }
}

struct ExercisePickerView: View {
    let exercises: [Exercise]
    var allSessions: [WorkoutSession] = []
    var settings: UserSettings? = nil
    let onSelect: (Exercise) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedMuscle: MuscleGroup?

    var filtered: [Exercise] {
        exercises.filter { exercise in
            (searchText.isEmpty || exercise.name.localizedCaseInsensitiveContains(searchText) || (exercise.englishName?.localizedCaseInsensitiveContains(searchText) ?? false)) &&
            (selectedMuscle == nil || exercise.primaryMuscle == selectedMuscle)
        }
        .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                muscleFilter
                List(filtered) { exercise in
                    Button {
                        onSelect(exercise)
                        dismiss()
                    } label: {
                        ExercisePickerRow(
                            exercise: exercise,
                            lastSet: TrainingInsights.lastSet(for: exercise.id, in: allSessions, formula: settings?.oneRepMaxFormula ?? .epley)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
            .searchable(text: $searchText, prompt: "搜索动作")
            .navigationTitle("添加动作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private var muscleFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                FilterChip(title: "全部", systemImage: "square.grid.2x2", isSelected: selectedMuscle == nil) {
                    selectedMuscle = nil
                }
                ForEach(MuscleGroup.allCases) { muscle in
                    FilterChip(title: muscle.displayName, systemImage: muscleSymbol(for: muscle), isSelected: selectedMuscle == muscle) {
                        selectedMuscle = (selectedMuscle == muscle) ? nil : muscle
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, DesignTokens.Spacing.sm)
        }
    }

    private func muscleSymbol(for muscle: MuscleGroup) -> String {
        switch muscle {
        case .chest: return "figure.arms.open"
        case .back: return "figure.walk.motion"
        case .legs: return "figure.run"
        case .shoulders: return "figure.flexibility"
        case .arms: return "dumbbell"
        case .core: return "figure.core.training"
        case .fullBody: return "figure.strengthtraining.traditional"
        }
    }
}

struct ExercisePickerRow: View {
    let exercise: Exercise
    let lastSet: LastSetSummary?

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: exercise.imageName ?? "dumbbell")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name)
                    .font(.subheadline.weight(.semibold))
                Text("\(exercise.primaryMuscle.displayName) · \(exercise.type.title)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let last = lastSet {
                    Text("上次：\(last.headlineText) · \(last.date.formatted(.dateTime.month().day()))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

struct FilterChip: View {
    let title: String
    let systemImage: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: {
            DesignTokens.Haptic.tap()
            action()
        }) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                if let systemImage {
                    Image(systemName: systemImage).font(.caption)
                }
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
            .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}

struct ExerciseSectionHeader: View {
    let workoutExercise: WorkoutExercise
    let allSessions: [WorkoutSession]
    let settings: UserSettings?
    let sessionId: UUID
    let onAddSet: () -> Void
    let onSwap: () -> Void
    let onRemove: () -> Void

    private var lastSet: LastSetSummary? {
        TrainingInsights.lastSet(for: workoutExercise.exerciseId, in: allSessions, excluding: sessionId, formula: settings?.oneRepMaxFormula ?? .epley)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(workoutExercise.exerciseName)
                    .textCase(nil)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(workoutExercise.sets.filter(\.isCompleted).count)/\(workoutExercise.sets.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Menu {
                    Button {
                        onAddSet()
                    } label: {
                        Label("添加组", systemImage: "plus")
                    }
                    Button {
                        onSwap()
                    } label: {
                        Label("更换动作", systemImage: "arrow.left.arrow.right")
                    }
                    Button(role: .destructive) {
                        onRemove()
                    } label: {
                        Label("删除该动作", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("动作菜单")
            }
            if let lastSet {
                LastSetBadge(summary: lastSet)
            }
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
                            Text("肌群")
                            Spacer()
                            Picker("肌群", selection: $viewModel.selectedMuscle) {
                                Text("全部").tag(MuscleGroup?.none)
                                ForEach(MuscleGroup.allCases) { Text($0.displayName).tag(Optional($0)) }
                            }
                            .pickerStyle(.menu)
                        }
                        Divider()
                        HStack {
                            Text("器械")
                            Spacer()
                            Picker("器械", selection: $viewModel.selectedType) {
                                Text("全部").tag(ExerciseType?.none)
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
                                    Text("\(exercise.primaryMuscle.displayName) · \(exercise.type.title)")
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
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
            .padding(.top, 4)
        }
        .searchable(text: $viewModel.searchText, prompt: "搜索动作")
        .navigationTitle("动作库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { showingAdd = true } label: { Label("新建", systemImage: "plus") }
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
                TextField("名称", text: $name)
                Picker("主要肌群", selection: $muscle) {
                    ForEach(MuscleGroup.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("器械类型", selection: $type) {
                    ForEach(ExerciseType.allCases) { Text($0.title).tag($0) }
                }
            }
            .navigationTitle("新建动作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
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
            TextField("名称", text: $exercise.name)
            TextField("英文名称", text: Binding($exercise.englishName, replacingNilWith: ""))
            Picker("主要肌群", selection: $exercise.primaryMuscleRaw) {
                ForEach(MuscleGroup.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            Picker("器械类型", selection: $exercise.typeRaw) {
                ForEach(ExerciseType.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Picker("默认输入方式", selection: $exercise.defaultWeightModeRaw) {
                ForEach(WeightMode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Toggle("分别记录左右两侧", isOn: $exercise.tracksLeftRightSeparately)
            TextField("动作要点", text: $exercise.instructions, axis: .vertical)
            TextField("注意事项", text: $exercise.cautions, axis: .vertical)
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
                EmptyStateView(title: "暂无模板", message: "为推/拉/腿或全身训练建立可复用的模板。")
            } else {
                ForEach(routines.sorted { $0.name < $1.name }) { routine in
                    NavigationLink {
                        RoutineEditorView(routine: routine, exercises: exercises, viewModel: viewModel)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(routine.name)
                                .font(.headline)
                            Text("\(routine.exercises.count) 个动作 · \(routine.note)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .swipeActions {
                        Button {
                            viewModel.duplicate(routine, modelContext: modelContext)
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                        }
                        .tint(.accentColor)
                        Button(role: .destructive) {
                            routineToDelete = routine
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("训练模板")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { showingCreate = true } label: {
                Label("新建模板", systemImage: "plus")
            }
        }
        .sheet(isPresented: $showingCreate) {
            NewRoutineView(viewModel: viewModel)
        }
        .confirmationDialog("删除该模板？", isPresented: Binding(
            get: { routineToDelete != nil },
            set: { if !$0 { routineToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("删除模板", role: .destructive) {
                if let routineToDelete {
                    viewModel.delete(routineToDelete, modelContext: modelContext)
                }
                routineToDelete = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(routineToDelete?.name ?? "该模板")将被删除，已有的训练历史不会受影响。")
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
                TextField("名称", text: $name)
                TextField("备注", text: $note, axis: .vertical)
            }
            .navigationTitle("新建模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
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
            Section("模板") {
                TextField("名称", text: $routine.name)
                TextField("备注", text: $routine.note, axis: .vertical)
            }
            Section("动作") {
                let sortedExercises = routine.exercises.sorted { $0.sortOrder < $1.sortOrder }
                if sortedExercises.isEmpty {
                    EmptyStateView(title: "暂无动作", message: "至少添加一个动作后才能开始训练。")
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
                    Label("添加动作", systemImage: "plus")
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
            Stepper("组数：\(item.targetSets)", value: $item.targetSets, in: 1...12)
            Stepper("次数：\(item.targetReps)", value: $item.targetReps, in: 0...100)
            TextField("目标重量", value: $item.targetWeight, format: .number)
                .keyboardType(.decimalPad)
            Stepper("休息：\(item.restSeconds) 秒", value: $item.restSeconds, in: 0...600, step: 15)
            Toggle("首组为热身", isOn: $item.enableWarmupSets)
            Toggle("递增重量", isOn: $item.enableRampingWeight)
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
                        StatTile(title: "本月", value: "\(monthSessions.count)", subtitle: "次", systemImage: "calendar")
                        StatTile(title: "容量", value: "\(Int(monthSessions.reduce(0) { $0 + $1.totalVolume }))", subtitle: settings?.weightUnit.rawValue ?? "kg", systemImage: "scalemass")
                        StatTile(title: "时长", value: monthSessions.reduce(0) { $0 + $1.duration }.shortDurationText, subtitle: "累计", systemImage: "timer")
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
                            let monthSessions = viewModel.sessionsInDisplayedMonth(from: sessions)
                            let maxVolume = monthSessions.map(\.totalVolume).max() ?? 1
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 10) {
                                ForEach(Array(viewModel.monthGridDays().enumerated()), id: \.offset) { _, day in
                                    if let day {
                                        let daySessions = viewModel.sessions(on: day, from: sessions)
                                        let dayVolume = daySessions.reduce(0) { $0 + $1.totalVolume }
                                        let intensity = maxVolume > 0 ? min(1, dayVolume / maxVolume) : 0
                                        Button {
                                            viewModel.selectedDate = day
                                            DesignTokens.Haptic.tap()
                                        } label: {
                                            VStack(spacing: 4) {
                                                Text(day.formatted(.dateTime.day()))
                                                    .font(.subheadline.weight(Calendar.current.isDateInToday(day) ? .bold : .regular))
                                                    .frame(width: 34, height: 30)
                                                    .background(Calendar.current.isDate(day, inSameDayAs: viewModel.selectedDate) ? Color.accentColor.opacity(0.2) : .clear, in: Circle())
                                                RoundedRectangle(cornerRadius: 2)
                                                    .fill(daySessions.isEmpty ? Color.clear : Color.accentColor.opacity(0.35 + intensity * 0.55))
                                                    .frame(width: 22, height: 4)
                                                    .overlay(alignment: .leading) {
                                                        if !daySessions.isEmpty {
                                                            RoundedRectangle(cornerRadius: 2)
                                                                .fill(Color.accentColor)
                                                                .frame(width: 22 * CGFloat(intensity), height: 4)
                                                        }
                                                    }
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("\(day.formatted(date: .complete, time: .omitted))，\(daySessions.count) 次训练")
                                    } else {
                                        Color.clear.frame(height: 40)
                                    }
                                }
                            }
                            .gesture(
                                DragGesture(minimumDistance: 30)
                                    .onEnded { value in
                                        let direction = value.translation.width
                                        let calendar = Calendar.current
                                        if direction < -40 {
                                            viewModel.selectedDate = calendar.date(byAdding: .month, value: 1, to: viewModel.selectedDate) ?? viewModel.selectedDate
                                            DesignTokens.Haptic.tap()
                                        } else if direction > 40 {
                                            viewModel.selectedDate = calendar.date(byAdding: .month, value: -1, to: viewModel.selectedDate) ?? viewModel.selectedDate
                                            DesignTokens.Haptic.tap()
                                        }
                                    }
                            )
                        }
                    }

                    SectionHeader(title: viewModel.selectedDate.formatted(date: .abbreviated, time: .omitted), systemImage: "list.bullet.clipboard")

                    let daySessions = viewModel.sessions(on: viewModel.selectedDate, from: sessions)
                    if daySessions.isEmpty {
                        LiftCard {
                            EmptyStateView(title: "当日无训练", message: "训练日将在此显示。")
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
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
                .padding(.top, 4)
            }
            .navigationTitle("日历")
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
    let bodyMeasurements: [BodyMeasurement]
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
                LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                    controls
                    overviewSection
                    trendSection
                    exerciseSection
                    BodyWeightCard(measurements: bodyMeasurements, unit: settings?.weightUnit ?? .kg)
                    muscleSection
                    heartRateSection
                }
                .padding(.horizontal)
                .padding(.bottom)
                .padding(.top, 4)
            }
            .navigationTitle("进度")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: chooseDefaultExercise)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("时间范围", selection: $viewModel.selectedRange) {
                ForEach(ProgressTimeRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)

            Picker("指标", selection: $viewModel.selectedTrendMetric) {
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
            SectionHeader(title: "总览", systemImage: "chart.line.uptrend.xyaxis")
            HStack(spacing: 10) {
                StatTile(title: "训练次数", value: "\(filteredSessions.count)", subtitle: viewModel.selectedRange.rawValue, systemImage: "calendar")
                StatTile(title: "总容量", value: "\(Int(volume))", subtitle: settings?.weightUnit.rawValue ?? "kg", systemImage: "scalemass")
                StatTile(title: "训练时长", value: duration.shortDurationText, subtitle: "累计", systemImage: "timer")
            }
            HStack(spacing: 10) {
                StatTile(title: "完成组", value: "\(sets)", subtitle: "组", systemImage: "checklist")
                StatTile(title: "个人记录", value: "\(records.count)", subtitle: "项", systemImage: "trophy")
                StatTile(title: "连续天数", value: "\(TrainingInsights.currentStreak(from: sessions))", subtitle: "天", systemImage: "flame")
            }
        }
    }

    private var trendSection: some View {
        ChartCard(title: "每周趋势") {
            if weeklySummaries.isEmpty {
                EmptyStateView(title: "暂无周数据", message: "完成训练后这里会显示每周趋势。")
            } else {
                Chart(weeklySummaries) { summary in
                    switch viewModel.selectedTrendMetric {
                    case .frequency:
                        BarMark(x: .value("周", summary.weekStart, unit: .weekOfYear), y: .value("次数", summary.workoutCount))
                    case .volume:
                        LineMark(x: .value("周", summary.weekStart, unit: .weekOfYear), y: .value("容量", summary.volume))
                        PointMark(x: .value("周", summary.weekStart, unit: .weekOfYear), y: .value("容量", summary.volume))
                    case .duration:
                        BarMark(x: .value("周", summary.weekStart, unit: .weekOfYear), y: .value("分钟", summary.duration / 60))
                    case .sets:
                        BarMark(x: .value("周", summary.weekStart, unit: .weekOfYear), y: .value("组数", summary.completedSets))
                    }
                }
            }
        }
    }

    private var exerciseSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "动作分析", systemImage: "dumbbell")
            Picker("动作", selection: $viewModel.selectedExerciseId) {
                Text("选择动作").tag(UUID?.none)
                ForEach(exercises) { exercise in
                    Text(exercise.name).tag(Optional(exercise.id))
                }
            }
            .pickerStyle(.menu)

            let trend = viewModel.exerciseTrend(exerciseId: viewModel.selectedExerciseId, sessions: sessions, formula: settings?.oneRepMaxFormula ?? .epley)
            if trend.isEmpty {
                LiftCard {
                    EmptyStateView(title: "暂无该动作数据", message: "选择有完成记录的动作以查看力量与容量趋势。")
                }
            } else {
                let formula = settings?.oneRepMaxFormula ?? .epley
                let gain = viewModel.selectedExerciseId.flatMap { TrainingInsights.strengthGain(for: $0, in: sessions, windowWeeks: 8, formula: formula) }
                HStack(spacing: 10) {
                    StatTile(title: "最大", value: "\(Int(trend.map(\.weight).max() ?? 0))", subtitle: settings?.weightUnit.rawValue ?? "kg", systemImage: "arrow.up")
                    StatTile(title: "最大 1RM", value: "\(Int(trend.map(\.oneRM).max() ?? 0))", subtitle: formula.displayName, systemImage: "bolt")
                    StatTile(title: "8 周涨幅", value: gain.map { String(format: "%+.0f%%", $0) } ?? "—", subtitle: "1RM", systemImage: "chart.line.uptrend.xyaxis")
                }
                HStack(spacing: 10) {
                    StatTile(title: "训练次数", value: "\(trend.count)", subtitle: "次", systemImage: "number")
                }
                ChartCard(title: "力量趋势") {
                    Chart(trend, id: \.date) { item in
                        LineMark(x: .value("日期", item.date), y: .value("最大重量", item.weight))
                        LineMark(x: .value("日期", item.date), y: .value("估算 1RM", item.oneRM))
                            .foregroundStyle(.orange)
                    }
                }
                ChartCard(title: "动作容量") {
                    Chart(trend, id: \.date) { item in
                        BarMark(x: .value("日期", item.date, unit: .day), y: .value("容量", item.volume))
                    }
                }
            }
        }
    }

    private var muscleSection: some View {
        ChartCard(title: "肌群容量") {
            let volumes = viewModel.muscleVolumes(from: sessions).filter { $0.volume.isFinite && $0.volume > 0 }
            if volumes.isEmpty {
                EmptyStateView(title: "暂无肌群数据", message: "完成的有重量训练组将在此呈现。")
            } else {
                Chart(volumes) { item in
                    let muscleName = MuscleGroup(rawValue: item.muscle)?.displayName ?? item.muscle
                    BarMark(x: .value("容量", item.volume), y: .value("肌群", muscleName))
                        .foregroundStyle(by: .value("肌群", muscleName))
                }
            }
        }
    }

    private var heartRateSection: some View {
        let samples = viewModel.heartRateSamples(from: sessions)
        let zones = AggregationManager.heartRateZones(samples: samples, maxHeartRate: settings?.maxHeartRate ?? 190)
        return ChartCard(title: "心率区间") {
            if samples.isEmpty {
                EmptyStateView(title: "暂无心率数据", message: "通过 Apple Watch 训练以记录心率。")
            } else {
                Chart(zones) { zone in
                    BarMark(x: .value("区间", zone.name), y: .value("样本", zone.sampleCount))
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
                            StatTile(title: "时长", value: session.duration.shortDurationText, subtitle: "总计")
                            StatTile(title: "容量", value: "\(Int(session.totalVolume))", subtitle: settings?.weightUnit.rawValue ?? "kg")
                            StatTile(title: "组数", value: "\(session.completedSetCount)", subtitle: "已完成")
                            StatTile(title: "平均心率", value: session.averageHeartRate.map { "\(Int($0))" } ?? "--", subtitle: "次/分")
                            StatTile(title: "消耗", value: session.activeEnergyKcal.map { "\(Int($0))" } ?? "--", subtitle: "千卡")
                        }
                        .padding(.vertical, 8)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                }
                if !session.heartRateSamples.isEmpty {
                    Section("心率") {
                        Chart(session.heartRateSamples.sorted { $0.timestamp < $1.timestamp }) { sample in
                            LineMark(x: .value("时间", sample.timestamp), y: .value("BPM", sample.bpm))
                        }
                        .frame(height: 180)
                        Chart(AggregationManager.heartRateZones(samples: session.heartRateSamples, maxHeartRate: settings?.maxHeartRate ?? 190)) { zone in
                            BarMark(x: .value("区间", zone.name), y: .value("样本", zone.sampleCount))
                        }
                        .frame(height: 160)
                    }
                }
                ForEach(session.exercises.sorted { $0.sortOrder < $1.sortOrder }) { exercise in
                    Section(exercise.exerciseName) {
                        ForEach(exercise.sets.sorted { $0.setIndex < $1.setIndex }) { set in
                            HStack {
                                Text("第\(set.setIndex)组 · \(set.setType.title)")
                                Spacer()
                                Text(setSummary(set))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !session.note.isEmpty {
                    Section("备注") { Text(session.note) }
                }

                Section {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("删除此训练", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    }
                }
            }
            .navigationTitle(session.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
            .confirmationDialog("删除此训练？", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    workoutVM.delete(session, modelContext: modelContext)
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将从历史记录中移除此训练。")
            }
        }
    }

    private func setSummary(_ set: SetRecord) -> String {
        switch set.weightMode {
        case .leftRightSeparate:
            return "\(Int(set.leftWeight))/\(Int(set.rightWeight)) × \(set.actualReps)"
        case .timeBased:
            return "\(set.durationSeconds) 秒"
        case .distanceBased:
            return "\(Int(set.distanceMeters)) 米 / \(set.durationSeconds) 秒"
        default:
            return "\(Int(set.weight)) × \(set.actualReps)"
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
    @State private var settingsVM = SettingsViewModel()
    @State private var exportPreview = ""
    @State private var exportURL: URL?
    @State private var statusMessage = ""
    @State private var healthStatus = HealthKitManager.shared.authorizationState.rawValue
    @State private var watchStatus = "Checking"
    @State private var showingClearHistoryConfirmation = false
    @State private var showingResetSamplesConfirmation = false
    @State private var showingBodyWeightHistory = false

    private var completedWorkoutCount: Int {
        sessions.filter { $0.status == .completed }.count
    }

    private var totalVolume: Double {
        sessions.filter { $0.status == .completed }.reduce(0) { $0 + $1.totalVolume }
    }

    private var watchConnectivityStatus: String {
        let manager = WatchConnectivityManager.shared
        guard manager.isSupported else { return "不可用" }
        guard manager.activationStateDescription == "Activated" else {
            switch manager.activationStateDescription {
            case "Not activated": return "未激活"
            case "Inactive": return "未连接"
            default: return manager.activationStateDescription
            }
        }
        guard manager.isCounterpartAppInstalled else { return "手表 App 未安装" }
        return manager.isReachable ? "已连接" : "暂时不可达"
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
                        SectionHeader(title: "偏好设置", systemImage: "gearshape")
                        LiftCard {
                            EmptyStateView(title: "设置不可用", message: "下次启动时将自动创建默认设置。")
                        }
                    }

                    SectionHeader(title: "资料", systemImage: "book.pages")
                    LiftCard {
                        VStack(spacing: 12) {
                            NavigationLink {
                                ExerciseLibraryView(exercises: exercises)
                            } label: {
                                HStack {
                                    Label("动作库", systemImage: "dumbbell")
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                            Divider()
                            NavigationLink {
                                BodyWeightHistoryView(unit: settings?.weightUnit ?? .kg)
                            } label: {
                                HStack {
                                    Label("体重记录", systemImage: "figure.arms.open")
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    SectionHeader(title: "健康与手表", systemImage: "heart")
                    LiftCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("健康权限")
                                Spacer()
                                Text(healthStatusText(healthStatus)).foregroundStyle(.secondary)
                            }
                            Divider()
                            HStack { Text("Apple Watch"); Spacer(); Text(watchStatus).foregroundStyle(.secondary) }
                            if let lastSent = WatchConnectivityManager.shared.lastSyncSentAt {
                                Divider()
                                HStack { Text("上次发送"); Spacer(); Text(lastSent.formatted(.relative(presentation: .named))).foregroundStyle(.secondary).font(.caption) }
                            }
                            if let lastReceived = WatchConnectivityManager.shared.lastSyncReceivedAt {
                                HStack { Text("上次接收"); Spacer(); Text(lastReceived.formatted(.relative(presentation: .named))).foregroundStyle(.secondary).font(.caption) }
                            }
                            HStack {
                                Text("回执进度")
                                Spacer()
                                Text("\(WatchConnectivityManager.shared.lastAcknowledgedSequence)/\(WatchConnectivityManager.shared.lastSentSequence)")
                                    .foregroundStyle(.secondary).font(.caption.monospacedDigit())
                            }
                            Divider()
                            Button {
                                Task {
                                    await HealthKitManager.shared.requestAuthorization()
                                    healthStatus = HealthKitManager.shared.authorizationState.rawValue
                                }
                            } label: {
                                Label("更新健康权限", systemImage: "heart.fill")
                            }
                            Divider()
                            Button {
                                Task { await importRecentHealthWorkouts() }
                            } label: {
                                Label("导入近期健康训练", systemImage: "heart.text.square")
                            }
                            .disabled(settingsVM.isImportingHealth)
                            if settingsVM.isImportingHealth {
                                ProgressView().controlSize(.small)
                            }
                            Divider()
                            Button {
                                forceWatchSync()
                            } label: {
                                Label("立即同步到手表", systemImage: "arrow.clockwise")
                            }
                        }
                    }

                    SectionHeader(title: "数据导出", systemImage: "square.and.arrow.up")
                    LiftCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Button {
                                createExport(.workoutHistory)
                            } label: {
                                Label("导出训练 CSV", systemImage: "tablecells")
                            }
                            Divider()
                            Button {
                                createExport(.exerciseLibrary)
                            } label: {
                                Label("导出动作 CSV", systemImage: "list.bullet.rectangle")
                            }
                            Divider()
                            Button {
                                createExport(.allData)
                            } label: {
                                Label("导出全部 JSON", systemImage: "doc.text")
                            }
                            if let exportURL {
                                Divider()
                                ShareLink(item: exportURL) {
                                    Label("分享最新导出", systemImage: "square.and.arrow.up")
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

                    SectionHeader(title: "数据管理", systemImage: "externaldrive")
                    LiftCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Button(role: .destructive) {
                                showingClearHistoryConfirmation = true
                            } label: {
                                Label("清空训练历史", systemImage: "trash").foregroundStyle(.red)
                            }
                            .disabled(sessions.isEmpty)
                            Divider()
                            Button {
                                showingResetSamplesConfirmation = true
                            } label: {
                                Label("恢复示例数据", systemImage: "arrow.clockwise")
                            }
                            Divider()
                            Text("清空历史会移除已保存的训练、组与心率样本，但会保留动作库、模板及偏好设置。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    SectionHeader(title: "关于", systemImage: "info.circle")
                    LiftCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Text("版本"); Spacer(); Text("1.0").foregroundStyle(.secondary) }
                            Divider()
                            HStack { Text("存储"); Spacer(); Text("本地 SwiftData").foregroundStyle(.secondary) }
                            Divider()
                            HStack { Text("同步策略"); Spacer(); Text("本地优先").foregroundStyle(.secondary) }
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
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        Keyboard.dismiss()
                    }
                }
                #endif
            }
            .confirmationDialog("清空全部训练历史？", isPresented: $showingClearHistoryConfirmation, titleVisibility: .visible) {
                Button("清空历史", role: .destructive) {
                    clearWorkoutHistory()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("此操作不可恢复。动作库、模板与偏好设置会保留。")
            }
            .confirmationDialog("恢复示例数据？", isPresented: $showingResetSamplesConfirmation, titleVisibility: .visible) {
                Button("恢复示例") {
                    SeedData.ensureSeeded(modelContext: modelContext)
                    statusMessage = "已恢复缺失的示例数据。"
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将补齐缺失的预设动作、模板、设置以及示例历史。")
            }
            .onAppear {
                healthStatus = HealthKitManager.shared.authorizationState.rawValue
                updateWatchStatus()
            }
        }
    }

    private func healthStatusText(_ raw: String) -> String {
        switch raw {
        case "authorized": return "已授权"
        case "denied": return "已拒绝"
        case "unavailable": return "不可用"
        default: return "未请求"
        }
    }

    private func createExport(_ kind: ExportManager.ExportKind) {
        do {
            let url = try ExportManager.writeExportFile(kind: kind, sessions: sessions, exercises: exercises, routines: routines)
            exportURL = url
            statusMessage = "已生成：\(url.lastPathComponent)"
            switch kind {
            case .workoutHistory:
                exportPreview = ExportManager.workoutHistoryCSV(sessions: sessions)
            case .exerciseLibrary:
                exportPreview = ExportManager.exerciseCSV(exercises: exercises)
            case .allData:
                exportPreview = String(data: ExportManager.allDataJSON(sessions: sessions, exercises: exercises, routines: routines) ?? Data(), encoding: .utf8) ?? ""
            }
        } catch {
            statusMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private func clearWorkoutHistory() {
        do {
            try workoutVM.deleteAllWorkoutHistory(modelContext: modelContext)
            exportPreview = ""
            exportURL = nil
            statusMessage = "训练历史已清空。"
        } catch {
            statusMessage = "清空失败：\(error.localizedDescription)"
        }
    }

    private func updateWatchStatus() {
        WatchConnectivityManager.shared.refreshStatus()
        watchStatus = watchConnectivityStatus
    }

    private func importRecentHealthWorkouts() async {
        await settingsVM.importRecentHealthWorkouts(into: sessions, workoutVM: workoutVM, modelContext: modelContext)
        statusMessage = settingsVM.statusMessage
        healthStatus = HealthKitManager.shared.authorizationState.rawValue
    }

    private func forceWatchSync() {
        if let session = sessions.first(where: { $0.status == .active || $0.status == .paused }) {
            workoutVM.attachContext(sessions: sessions, routines: routines, settings: settings)
            workoutVM.sync(session)
        } else {
            workoutVM.broadcastIdleSnapshot(routines: routines, hapticOnRestComplete: settings?.watchHapticOnRestComplete ?? true, weightUnit: settings?.weightUnit ?? .kg)
        }
        WatchConnectivityManager.shared.refreshStatus()
        watchStatus = watchConnectivityStatus
        statusMessage = "已发送同步请求。"
    }
}

struct EditableSettingsSection: View {
    @Bindable var settings: UserSettings
    let healthStatus: String

    var body: some View {
        SectionHeader(title: "外观", systemImage: "paintpalette")
        LiftCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("主题")
                    Spacer()
                    Picker("主题", selection: $settings.themeRaw) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.displayName).tag(theme.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Divider()
                HStack {
                    Text("主色调")
                    Spacer()
                    Picker("主色调", selection: $settings.accentColorRaw) {
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

        SectionHeader(title: "训练", systemImage: "dumbbell")
        LiftCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("重量单位")
                    Spacer()
                    Picker("重量单位", selection: $settings.weightUnitRaw) {
                        ForEach(WeightUnit.allCases) { unit in
                            Text(unit.rawValue.uppercased()).tag(unit.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Divider()
                HStack {
                    Text("1RM 估算公式")
                    Spacer()
                    Picker("1RM 估算公式", selection: $settings.oneRepMaxFormulaRaw) {
                        ForEach(OneRepMaxFormula.allCases) { formula in
                            Text(formula.displayName).tag(formula.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Divider()
                Stepper("默认休息：\(settings.defaultRestSeconds) 秒", value: $settings.defaultRestSeconds, in: 0...600, step: 15)
                Divider()
                Toggle("自动开始休息计时", isOn: $settings.autoStartRestTimer)
                Divider()
                Toggle("启用 RPE", isOn: $settings.usesRPE)
                Divider()
                Toggle("显示热身组", isOn: $settings.showsWarmupSets)
                Divider()
                Toggle("自重训练计入容量", isOn: $settings.usesBodyweightForBodyweightVolume)
                Divider()
                Toggle("打破记录时庆祝", isOn: $settings.celebratesPersonalRecords)
                Divider()
                Toggle("肌群平衡提醒", isOn: $settings.enableMuscleBalanceAlerts)
            }
        }

        SectionHeader(title: "每周目标", systemImage: "target")
        LiftCard {
            VStack(alignment: .leading, spacing: 12) {
                Stepper("训练次数：\(settings.weeklyFrequencyGoal) 次", value: $settings.weeklyFrequencyGoal, in: 1...14)
                Divider()
                HStack {
                    Text("容量目标")
                    Spacer()
                    TextField("容量", value: $settings.weeklyVolumeGoal, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                    Text(settings.weightUnit.rawValue.uppercased())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        SectionHeader(title: "语言", systemImage: "globe")
        LiftCard {
            HStack {
                Text("App 语言")
                Spacer()
                Picker("App 语言", selection: $settings.localePreferenceRaw) {
                    ForEach(AppLocalePreference.allCases) { pref in
                        Text(pref.displayName).tag(pref.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }
        }

        SectionHeader(title: "身体与心率", systemImage: "figure.walk")
        LiftCard {
            VStack(alignment: .leading, spacing: 12) {
                Stepper("年龄：\(settings.age) 岁", value: $settings.age, in: 12...100)
                Divider()
                HStack {
                    Text("体重（kg）")
                    Spacer()
                    TextField("体重 kg", value: $settings.bodyweightKg, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
                Divider()
                Toggle("自定义最大心率", isOn: Binding(
                    get: { settings.customMaxHeartRate != nil },
                    set: { enabled in
                        settings.customMaxHeartRate = enabled ? settings.maxHeartRate : nil
                    }
                ))
                Divider()
                if settings.customMaxHeartRate != nil {
                    Stepper("最大心率：\(settings.customMaxHeartRate ?? settings.maxHeartRate)", value: Binding(
                        get: { settings.customMaxHeartRate ?? settings.maxHeartRate },
                        set: { settings.customMaxHeartRate = min(230, max(120, $0)) }
                    ), in: 120...230)
                } else {
                    HStack { Text("估算最大心率"); Spacer(); Text("\(settings.maxHeartRate) 次/分").foregroundStyle(.secondary) }
                }
            }
        }

        SectionHeader(title: "Apple 健康", systemImage: "cross.case")
        LiftCard {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("将训练写入 Apple 健康", isOn: $settings.writesWorkoutsToHealth)
                Divider()
                Text(healthStatus == "authorized" ? "健康权限已开启。" : "需先授权后才能读取心率、能量并写入训练。")
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
                    Text("训练")
                        .font(.title2.bold())
                    Text("本地优先的力量训练记录")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            HStack(spacing: 10) {
                StatTile(title: "历史", value: "\(workouts)", subtitle: "次", systemImage: "clock.arrow.circlepath")
                StatTile(title: "动作", value: "\(exercises)", subtitle: "个", systemImage: "dumbbell")
                StatTile(title: "总容量", value: "\(Int(volume))", subtitle: unit, systemImage: "scalemass")
            }
            HStack {
                Label("\(routines) 个模板", systemImage: "square.stack.3d.up")
                Spacer()
                Label("无需登录", systemImage: "lock")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

struct RestTimerView: View {
    @Bindable var restTimer: RestTimerManager

    private var displayText: String {
        let total = max(0, restTimer.remainingSeconds)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            ZStack {
                Circle()
                    .stroke(Color.accentColor.opacity(0.15), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: CGFloat(restTimer.progress))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: restTimer.progress)
                Image(systemName: "timer")
                    .font(.subheadline.bold())
                    .foregroundStyle(.tint)
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text("休息")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(displayText)
                    .font(.title2.monospacedDigit().bold())
            }
            Spacer()
            HStack(spacing: 6) {
                Button("-30") { DesignTokens.Haptic.tap(); restTimer.adjust(by: -30) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("+30") { DesignTokens.Haptic.tap(); restTimer.adjust(by: 30) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button {
                    DesignTokens.Haptic.tap()
                    restTimer.skip()
                } label: {
                    Image(systemName: "forward.end.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("跳过休息")
            }
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
                Text("平均心率 \(session.averageHeartRate.map { String(Int($0)) } ?? "--")")
                Text("消耗 \(session.activeEnergyKcal.map { String(Int($0)) } ?? "--") 千卡")
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
                Text("下一组")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(target.exerciseName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("第\(target.setIndex)组 · \(target.setType.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(target.weightText) × \(target.reps)")
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
