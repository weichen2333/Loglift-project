import SwiftUI

enum DesignTokens {
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Corner {
        static let pill: CGFloat = 999
        static let card: CGFloat = 14
        static let chip: CGFloat = 10
        static let small: CGFloat = 8
    }

    enum Stroke {
        static let hairline: CGFloat = 0.5
        static let regular: CGFloat = 1
    }

    enum Animation {
        static let snappy = SwiftUI.Animation.snappy(duration: 0.22)
        static let spring = SwiftUI.Animation.spring(response: 0.32, dampingFraction: 0.78)
        static let easeFast = SwiftUI.Animation.easeInOut(duration: 0.18)
    }

    enum Haptic {
        static func tap() {
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
        }

        static func success() {
            #if canImport(UIKit)
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            #endif
        }

        static func warning() {
            #if canImport(UIKit)
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.warning)
            #endif
        }
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
        case .light: "浅色"
        case .dark: "深色"
        case .system: "跟随系统"
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
        case .pink: "粉色"
        case .blue: "蓝色"
        case .green: "绿色"
        case .orange: "橙色"
        case .purple: "紫色"
        case .red: "红色"
        }
    }
}

extension MuscleBalanceInsight.Severity {
    var tint: Color {
        switch self {
        case .ok: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }
}
