import SwiftUI

struct MuscleBalanceCard: View {
    let insights: [MuscleBalanceInsight]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Label("肌群平衡", systemImage: "scalemass.fill")
                .font(.headline)
            if insights.isEmpty {
                Text("本周完成训练后将显示肌群平衡情况。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    ForEach(insights) { insight in
                        HStack(spacing: DesignTokens.Spacing.md) {
                            Image(systemName: insight.severity.symbol)
                                .foregroundStyle(insight.severity.tint)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(insight.muscle.displayName)
                                    .font(.subheadline.weight(.semibold))
                                Text(insight.recommendation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: DesignTokens.Spacing.sm)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(insight.weeklySetCount) 组")
                                    .font(.caption.monospacedDigit())
                                Text("\(Int(insight.weeklyVolume))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(insight.muscle.displayName)，\(insight.weeklySetCount) 组，\(insight.recommendation)")
                    }
                }
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

struct LastSetBadge: View {
    let summary: LastSetSummary

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.caption2)
            Text("上次：\(summary.headlineText)")
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
        .accessibilityLabel("上次：\(summary.headlineText)，\(summary.date.formatted(.dateTime.month().day()))")
    }
}
