import SwiftUI

struct WeeklyGoalsCard: View {
    let progress: WeeklyGoalProgress
    let weightUnit: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Label("每周目标", systemImage: "target")
                .font(.headline)
            HStack(spacing: DesignTokens.Spacing.md) {
                GoalRing(
                    title: "训练次数",
                    actual: "\(progress.frequencyActual)",
                    target: "/ \(progress.frequencyTarget)",
                    ratio: progress.frequencyRatio,
                    tint: .pink
                )
                GoalRing(
                    title: "训练容量",
                    actual: "\(Int(progress.volumeActual))",
                    target: "/ \(Int(progress.volumeTarget)) \(weightUnit)",
                    ratio: progress.volumeRatio,
                    tint: .blue
                )
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.Corner.card))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Corner.card)
                .stroke(.quaternary, lineWidth: DesignTokens.Stroke.regular)
        }
    }
}

private struct GoalRing: View {
    let title: String
    let actual: String
    let target: String
    let ratio: Double
    let tint: Color

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.18), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, ratio)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(ratio * 100))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(actual)
                        .font(.title3.monospacedDigit().bold())
                    Text(target)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
