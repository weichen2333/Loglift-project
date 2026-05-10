import SwiftUI

struct PRCelebrationOverlay: View {
    @Binding var record: PRCandidate?
    @Environment(\.colorScheme) private var colorScheme
    @State private var animateIn = false

    var body: some View {
        ZStack(alignment: .top) {
            if let record {
                Color.black.opacity(animateIn ? 0.18 : 0).ignoresSafeArea()
                    .onTapGesture { dismiss() }
                VStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(.yellow)
                        .symbolEffect(.bounce, value: animateIn)
                    Text("打破个人记录")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(record.exerciseName)
                        .font(.title3.bold())
                    Text(headline(for: record))
                        .font(.title2.monospacedDigit().bold())
                        .foregroundStyle(.tint)
                    if !record.deltaText.isEmpty {
                        Text("超出上次最佳 " + record.deltaText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("继续训练") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, DesignTokens.Spacing.sm)
                }
                .padding(DesignTokens.Spacing.lg)
                .frame(maxWidth: 360)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(.yellow.opacity(0.6), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.18), radius: 24, y: 14)
                .padding(DesignTokens.Spacing.xl)
                .padding(.top, 64)
                .scaleEffect(animateIn ? 1 : 0.85)
                .opacity(animateIn ? 1 : 0)
                .onAppear {
                    DesignTokens.Haptic.success()
                    withAnimation(DesignTokens.Animation.spring) { animateIn = true }
                }
                .onDisappear { animateIn = false }
            }
        }
        .animation(DesignTokens.Animation.snappy, value: record)
    }

    private func headline(for record: PRCandidate) -> String {
        switch record.kind {
        case .maxWeight:
            return "新最大重量"
        case .oneRepMax:
            return "估算 1RM \(format(record.value))"
        case .totalVolume:
            return "总容量 \(format(record.value))"
        }
    }

    private func format(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(value))" : String(format: "%.1f", value)
    }

    private func dismiss() {
        withAnimation(DesignTokens.Animation.snappy) { animateIn = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            record = nil
        }
    }
}
