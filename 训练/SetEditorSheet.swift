import SwiftUI
import SwiftData

struct SetEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let set: SetRecord
    let session: WorkoutSession
    let workoutExercise: WorkoutExercise
    let settings: UserSettings?
    let workoutVM: WorkoutSessionViewModel
    let allSessions: [WorkoutSession]

    @State private var weightInput: Double
    @State private var leftWeightInput: Double
    @State private var rightWeightInput: Double
    @State private var assistanceInput: Double
    @State private var bodyweightLoadInput: Double
    @State private var repsInput: Int
    @State private var rpeInput: Double
    @State private var durationInput: Int
    @State private var distanceInput: Double
    @State private var setType: SetType
    @State private var showRPE: Bool

    init(set: SetRecord, session: WorkoutSession, workoutExercise: WorkoutExercise, settings: UserSettings?, workoutVM: WorkoutSessionViewModel, allSessions: [WorkoutSession]) {
        self.set = set
        self.session = session
        self.workoutExercise = workoutExercise
        self.settings = settings
        self.workoutVM = workoutVM
        self.allSessions = allSessions
        _weightInput = State(initialValue: set.weight)
        _leftWeightInput = State(initialValue: set.leftWeight)
        _rightWeightInput = State(initialValue: set.rightWeight)
        _assistanceInput = State(initialValue: set.assistanceWeight)
        _bodyweightLoadInput = State(initialValue: set.bodyweightAdditionalLoad)
        _repsInput = State(initialValue: max(0, set.actualReps))
        _rpeInput = State(initialValue: set.rpe ?? 7)
        _durationInput = State(initialValue: set.durationSeconds)
        _distanceInput = State(initialValue: set.distanceMeters)
        _setType = State(initialValue: set.setType)
        _showRPE = State(initialValue: set.rpe != nil)
    }

    private var unitLabel: String { (settings?.weightUnit ?? .kg).rawValue.uppercased() }

    private var lastSummary: LastSetSummary? {
        TrainingInsights.lastSet(
            for: workoutExercise.exerciseId,
            in: allSessions,
            excluding: session.id,
            formula: settings?.oneRepMaxFormula ?? .epley
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(workoutExercise.exerciseName)
                            .font(.title3.bold())
                        Spacer()
                        Text("第 \(set.setIndex) 组")
                            .foregroundStyle(.secondary)
                    }
                    if let last = lastSummary {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("上次：\(last.headlineText)")
                                Text(last.date.formatted(.dateTime.year().month(.abbreviated).day()))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .listRowBackground(Color.accentColor.opacity(0.08))
                    }
                    Picker("组类型", selection: $setType) {
                        ForEach(SetType.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("次数与负荷") {
                    weightSection
                    repsSection
                    if showRPE {
                        rpeSection
                    } else if settings?.usesRPE ?? true {
                        Button {
                            showRPE = true
                        } label: {
                            Label("添加 RPE", systemImage: "gauge.with.dots.needle.bottom.50percent")
                        }
                    }
                }

                Section {
                    Button {
                        copyFromLast()
                    } label: {
                        Label("沿用上次数据", systemImage: "doc.on.doc")
                    }
                    .disabled(lastSummary == nil)

                    if lastSummary != nil {
                        Button {
                            if let last = lastSummary {
                                seedFromLast(last)
                                applyDelta(weight: 2.5)
                            }
                        } label: {
                            Label("比上次多 2.5\(unitLabel.lowercased())", systemImage: "arrow.up.circle")
                        }
                    }
                }
            }
            .navigationTitle("编辑组")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存并完成") { commit(complete: true) }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .accessibilityHint("保存修改并将该组标为已完成")
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        commit(complete: false)
                    } label: {
                        Label("仅保存", systemImage: "tray.and.arrow.down")
                    }
                    Spacer()
                    if set.isCompleted {
                        Button {
                            set.toggleCompletion()
                            try? modelContext.save()
                            workoutVM.sync(session)
                            dismiss()
                        } label: {
                            Label("撤销完成", systemImage: "arrow.uturn.backward.circle")
                        }
                        .tint(.orange)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var weightSection: some View {
        switch set.weightMode {
        case .leftRightSeparate:
            DualWeightField(label: "左", value: $leftWeightInput, unit: unitLabel)
            DualWeightField(label: "右", value: $rightWeightInput, unit: unitLabel)
        case .bodyweight:
            QuickWeightField(label: "附加负重", value: $bodyweightLoadInput, unit: unitLabel, allowsNegative: false)
        case .assistedBodyweight:
            QuickWeightField(label: "助力", value: $assistanceInput, unit: unitLabel, allowsNegative: false)
        case .timeBased:
            DurationField(seconds: $durationInput)
        case .distanceBased:
            DistanceField(distance: $distanceInput, seconds: $durationInput)
        default:
            QuickWeightField(label: "重量", value: $weightInput, unit: unitLabel, allowsNegative: false)
        }
    }

    @ViewBuilder
    private var repsSection: some View {
        switch set.weightMode {
        case .timeBased:
            EmptyView()
        case .distanceBased:
            EmptyView()
        default:
            HStack {
                Text("次数")
                Spacer()
                CompactStepper(value: $repsInput, range: 0...100, accessibilityLabel: "次数")
            }
        }
    }

    private var rpeSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack {
                Text("RPE \(String(format: "%.1f", rpeInput))")
                    .font(.headline.monospacedDigit())
                Spacer()
                Button {
                    showRPE = false
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("移除 RPE")
            }
            Slider(value: $rpeInput, in: 1...10, step: 0.5)
            HStack {
                Text("轻松")
                Spacer()
                Text("极限")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func copyFromLast() {
        guard let last = lastSummary else { return }
        seedFromLast(last)
        DesignTokens.Haptic.tap()
    }

    private func seedFromLast(_ last: LastSetSummary) {
        switch set.weightMode {
        case .leftRightSeparate:
            leftWeightInput = last.leftWeight
            rightWeightInput = last.rightWeight
            repsInput = last.reps
        case .bodyweight:
            bodyweightLoadInput = last.bodyweightAdditionalLoad
            repsInput = last.reps
        case .assistedBodyweight:
            assistanceInput = last.assistanceWeight
            repsInput = last.reps
        case .timeBased:
            durationInput = last.reps > 0 ? last.reps : durationInput
        case .distanceBased:
            distanceInput = last.workingWeight
            durationInput = last.reps
        default:
            weightInput = last.workingWeight
            repsInput = last.reps
        }
    }

    private func applyDelta(weight: Double) {
        switch set.weightMode {
        case .leftRightSeparate:
            leftWeightInput += weight / 2
            rightWeightInput += weight / 2
        case .bodyweight:
            bodyweightLoadInput += weight
        case .assistedBodyweight:
            assistanceInput = max(0, assistanceInput - weight)
        case .timeBased, .distanceBased:
            break
        default:
            weightInput += weight
        }
    }

    private func commit(complete: Bool) {
        applyToSet()
        try? modelContext.save()

        if complete && !set.isCompleted {
            let restSeconds = workoutExercise.defaultRestSeconds
            let pr = workoutVM.complete(set, in: session, restSeconds: restSeconds, autoStartRest: settings?.autoStartRestTimer ?? true, modelContext: modelContext, allowPRCelebration: settings?.celebratesPersonalRecords ?? true)
            if pr != nil { DesignTokens.Haptic.success() }
            else if workoutVM.pendingValidationWarning != nil { return }
            else { DesignTokens.Haptic.tap() }
        } else {
            workoutVM.sync(session)
        }
        dismiss()
    }

    private func applyToSet() {
        set.setType = setType
        switch set.weightMode {
        case .leftRightSeparate:
            set.leftWeight = max(0, leftWeightInput)
            set.rightWeight = max(0, rightWeightInput)
            set.actualReps = max(0, repsInput)
        case .bodyweight:
            set.bodyweightAdditionalLoad = max(0, bodyweightLoadInput)
            set.actualReps = max(0, repsInput)
        case .assistedBodyweight:
            set.assistanceWeight = max(0, assistanceInput)
            set.actualReps = max(0, repsInput)
        case .timeBased:
            set.durationSeconds = max(0, durationInput)
        case .distanceBased:
            set.distanceMeters = max(0, distanceInput)
            set.durationSeconds = max(0, durationInput)
        default:
            set.weight = max(0, weightInput)
            set.actualReps = max(0, repsInput)
        }
        set.rpe = showRPE ? rpeInput : nil
    }
}

private struct QuickWeightField: View {
    let label: String
    @Binding var value: Double
    let unit: String
    let allowsNegative: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                TextField("0", value: $value, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.title2.monospacedDigit().bold())
                    .frame(maxWidth: 120)
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: DesignTokens.Spacing.sm) {
                ForEach([-5.0, -2.5, -1.0, 1.0, 2.5, 5.0], id: \.self) { delta in
                    Button(formatDelta(delta)) {
                        DesignTokens.Haptic.tap()
                        value = max(allowsNegative ? -10000 : 0, value + delta)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private func formatDelta(_ value: Double) -> String {
        let prefix = value > 0 ? "+" : ""
        if value.truncatingRemainder(dividingBy: 1) == 0 { return "\(prefix)\(Int(value))" }
        return "\(prefix)\(String(format: "%.1f", value))"
    }
}

private struct DualWeightField: View {
    let label: String
    @Binding var value: Double
    let unit: String

    var body: some View {
        QuickWeightField(label: label, value: $value, unit: unit, allowsNegative: false)
    }
}

private struct CompactStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let accessibilityLabel: String

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button {
                DesignTokens.Haptic.tap()
                value = max(range.lowerBound, value - 1)
            } label: {
                Image(systemName: "minus.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            TextField("0", value: $value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(.title2.monospacedDigit().bold())
                .frame(minWidth: 60)
                .accessibilityLabel(accessibilityLabel)

            Button {
                DesignTokens.Haptic.tap()
                value = min(range.upperBound, value + 1)
            } label: {
                Image(systemName: "plus.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
    }
}

private struct DurationField: View {
    @Binding var seconds: Int

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack {
                Text("时长")
                Spacer()
                TextField("0", value: $seconds, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(.title2.monospacedDigit().bold())
                    .frame(maxWidth: 100)
                Text("秒").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: DesignTokens.Spacing.sm) {
                ForEach([-30, -10, 10, 30, 60], id: \.self) { delta in
                    Button("\(delta > 0 ? "+" : "")\(delta)") {
                        seconds = max(0, seconds + delta)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }
}

private struct DistanceField: View {
    @Binding var distance: Double
    @Binding var seconds: Int

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack {
                Text("距离")
                Spacer()
                TextField("0", value: $distance, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.title2.monospacedDigit().bold())
                    .frame(maxWidth: 100)
                Text("米").font(.caption).foregroundStyle(.secondary)
            }
            DurationField(seconds: $seconds)
        }
    }
}
