import SwiftUI
import SwiftData
import Charts

struct BodyWeightCard: View {
    let measurements: [BodyMeasurement]
    let unit: WeightUnit
    @State private var showingLog = false

    private var sorted: [BodyMeasurement] {
        measurements.sorted { $0.date < $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            HStack {
                Label("体重", systemImage: "figure.arms.open")
                    .font(.headline)
                Spacer()
                Button {
                    showingLog = true
                } label: {
                    Label("记录", systemImage: "plus.circle.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("记录体重")
            }

            if let latest = sorted.last {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                    Text(displayWeight(latest.bodyMassKg))
                        .font(.title.monospacedDigit().bold())
                    Text(unit.rawValue.uppercased())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let delta = changeText() {
                        Text(delta)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, DesignTokens.Spacing.sm)
                            .padding(.vertical, 4)
                            .background(deltaColor.opacity(0.18), in: Capsule())
                            .foregroundStyle(deltaColor)
                    }
                    Spacer()
                    Text(latest.date.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("记录体重以查看趋势。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if sorted.count >= 2 {
                Chart(sorted) { entry in
                    LineMark(x: .value("日期", entry.date), y: .value("kg", entry.bodyMassKg))
                        .interpolationMethod(.catmullRom)
                    PointMark(x: .value("日期", entry.date), y: .value("kg", entry.bodyMassKg))
                        .symbolSize(30)
                }
                .chartXAxis { AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { _ in AxisGridLine(); AxisTick(); AxisValueLabel(format: .dateTime.month().day()) } }
                .frame(height: 140)
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.Corner.card))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Corner.card)
                .stroke(.quaternary, lineWidth: DesignTokens.Stroke.regular)
        }
        .sheet(isPresented: $showingLog) {
            LogBodyWeightSheet(unit: unit, defaultKg: sorted.last?.bodyMassKg ?? 70)
                .presentationDetents([.medium])
        }
    }

    private func displayWeight(_ kg: Double) -> String {
        let value = unit == .kg ? kg : UnitConversionManager.kilogramsToPounds(kg)
        return String(format: "%.1f", value)
    }

    private var deltaColor: Color {
        guard sorted.count >= 2 else { return .secondary }
        let delta = sorted.last!.bodyMassKg - sorted.first!.bodyMassKg
        if abs(delta) < 0.2 { return .secondary }
        return delta > 0 ? .orange : .green
    }

    private func changeText() -> String? {
        guard sorted.count >= 2 else { return nil }
        let delta = sorted.last!.bodyMassKg - sorted.first!.bodyMassKg
        guard abs(delta) >= 0.1 else { return nil }
        let value = unit == .kg ? delta : UnitConversionManager.kilogramsToPounds(delta)
        let formatted = String(format: "%+.1f", value)
        return "\(formatted) \(unit.rawValue.uppercased())"
    }
}

struct BodyWeightHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BodyMeasurement.date, order: .reverse) private var measurements: [BodyMeasurement]
    @State private var viewModel = BodyMeasurementViewModel()
    let unit: WeightUnit
    @State private var showingLog = false

    var body: some View {
        List {
            if measurements.isEmpty {
                Section {
                    EmptyStateView(title: "暂无体重记录", message: "开始每周记录体重以查看趋势。")
                }
            }
            ForEach(measurements) { measurement in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(measurement.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline.weight(.semibold))
                        if !measurement.note.isEmpty {
                            Text(measurement.note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(formatted(measurement.bodyMassKg))
                        .font(.headline.monospacedDigit())
                }
                .swipeActions {
                    Button(role: .destructive) {
                        viewModel.delete(measurement, modelContext: modelContext)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("体重记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { showingLog = true } label: {
                Label("记录", systemImage: "plus")
            }
        }
        .sheet(isPresented: $showingLog) {
            LogBodyWeightSheet(unit: unit, defaultKg: measurements.first?.bodyMassKg ?? 70)
                .presentationDetents([.medium])
        }
    }

    private func formatted(_ kg: Double) -> String {
        let value = unit == .kg ? kg : UnitConversionManager.kilogramsToPounds(kg)
        return String(format: "%.1f \(unit.rawValue.uppercased())", value)
    }
}

struct LogBodyWeightSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = BodyMeasurementViewModel()

    let unit: WeightUnit
    @State private var inputValue: Double
    @State private var note: String = ""

    init(unit: WeightUnit, defaultKg: Double) {
        self.unit = unit
        let initial = unit == .kg ? defaultKg : UnitConversionManager.kilogramsToPounds(defaultKg)
        _inputValue = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        TextField("体重", value: $inputValue, format: .number.precision(.fractionLength(0...1)))
                            .keyboardType(.decimalPad)
                            .font(.title.monospacedDigit().bold())
                        Text(unit.rawValue.uppercased())
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("备注") {
                    TextField("可选", text: $note, axis: .vertical)
                }
            }
            .navigationTitle("记录体重")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let kg = unit == .kg ? inputValue : UnitConversionManager.poundsToKilograms(inputValue)
                        viewModel.record(kilograms: kg, note: note, modelContext: modelContext)
                        dismiss()
                    }
                    .disabled(inputValue <= 0)
                }
            }
        }
    }
}
