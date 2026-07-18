import SwiftUI

enum AppSpacing {
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 16
    static let large: CGFloat = 24
    static let xLarge: CGFloat = 32
}

enum AppCornerRadius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 10
    static let large: CGFloat = 12
    static let artwork: CGFloat = 10
}

enum AppIconSize {
    static let compact: CGFloat = 16
    static let standard: CGFloat = 22
    static let control: CGFloat = 28
}

enum AppArtworkSize {
    static let compactRow: CGFloat = 48
    static let standardRow: CGFloat = 64
    static let card: CGFloat = 168
    static let nowPlayingMaximum: CGFloat = 420
}

enum AppAnimationDuration {
    static let quick: Double = 0.16
    static let standard: Double = 0.24
    static let presentation: Double = 0.36
}

enum AppLayout {
    static let minimumRowHeight: CGFloat = 56
    static let sectionSpacing: CGFloat = 24
    static let horizontalMargin: CGFloat = 20
}

struct AppPrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, AppSpacing.medium)
            .background(
                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                    .fill(AppTheme.accent.opacity(configuration.isPressed ? 0.78 : 1))
            )
            .opacity(isEnabled ? 1 : 0.46)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: AppAnimationDuration.quick), value: configuration.isPressed)
    }
}

struct AppSecondaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(AppTheme.primaryText)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, AppSpacing.medium)
            .background(
                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                    .fill(AppTheme.controlFill.opacity(configuration.isPressed ? 0.72 : 1))
                    .overlay {
                        RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                            .strokeBorder(AppTheme.surfaceStroke, lineWidth: 1)
                    }
            )
            .opacity(isEnabled ? 1 : 0.46)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: AppAnimationDuration.quick), value: configuration.isPressed)
    }
}

private struct AppSurfaceModifier: ViewModifier {
    let fill: Color
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(AppTheme.surfaceStroke, lineWidth: 1)
                    }
            )
    }
}

extension View {
    func appSurface(
        fill: Color = AppTheme.cardFill,
        cornerRadius: CGFloat = AppCornerRadius.large
    ) -> some View {
        modifier(AppSurfaceModifier(fill: fill, cornerRadius: cornerRadius))
    }
}
