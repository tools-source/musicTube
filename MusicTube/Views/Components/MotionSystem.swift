import SwiftUI

// MARK: - Aurora Background
//
// MusicTube's signature motion: a slow, living field of brand-tinted light blobs that
// drift behind content. It's the one element that makes every screen feel like *this*
// app and not a stock SwiftUI list. Honors Reduce Motion by holding a static gradient.

struct AuroraBackground: View {
    /// Tints of the drifting blobs. Defaults to the MusicTube pink + cool counter-tones.
    var palette: [Color] = AuroraBackground.defaultPalette
    /// Overall intensity of the glow (0...1). Lower it for content-heavy screens.
    var intensity: Double = 1.0
    /// Highlight blobs by tilting toward white. Used by the launch screen.
    var luminous: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var animate = false

    static let defaultPalette: [Color] = [
        Color(red: 1.0, green: 0.23, blue: 0.42),   // brand pink
        Color(red: 0.55, green: 0.18, blue: 0.85),  // violet
        Color(red: 0.10, green: 0.52, blue: 0.96),  // electric blue
        Color(red: 1.0, green: 0.42, blue: 0.62)    // rose
    ]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                baseLayer

                blob(palette[0 % palette.count], diameter: size.width * 0.95)
                    .offset(
                        x: animate ? -size.width * 0.28 : -size.width * 0.05,
                        y: animate ? -size.height * 0.22 : -size.height * 0.34
                    )
                    .animation(loop(18), value: animate)

                blob(palette[1 % palette.count], diameter: size.width * 0.85)
                    .offset(
                        x: animate ? size.width * 0.30 : size.width * 0.10,
                        y: animate ? -size.height * 0.10 : size.height * 0.05
                    )
                    .animation(loop(22), value: animate)

                blob(palette[2 % palette.count], diameter: size.width * 1.05)
                    .offset(
                        x: animate ? size.width * 0.18 : size.width * 0.34,
                        y: animate ? size.height * 0.34 : size.height * 0.18
                    )
                    .animation(loop(26), value: animate)

                blob(palette[3 % palette.count], diameter: size.width * 0.70)
                    .offset(
                        x: animate ? -size.width * 0.24 : -size.width * 0.10,
                        y: animate ? size.height * 0.30 : size.height * 0.40
                    )
                    .animation(loop(20), value: animate)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .onAppear {
            // Hold a static gradient field under Reduce Motion or Low Power Mode so the
            // signature look survives without drifting blobs draining the battery — the
            // app keeps all five tabs (and their backgrounds) alive at once.
            guard reduceMotion == false,
                  ProcessInfo.processInfo.isLowPowerModeEnabled == false else { return }
            animate = true
        }
        .onDisappear {
            animate = false
        }
    }

    private var baseLayer: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(red: 0.02, green: 0.02, blue: 0.05), Color.black]
                : [Color(red: 0.97, green: 0.97, blue: 0.99), Color(red: 0.92, green: 0.93, blue: 0.97)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func blob(_ color: Color, diameter: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        (luminous ? Color.white.opacity(0.35) : color).opacity(blobOpacity),
                        color.opacity(blobOpacity * 0.55),
                        .clear
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter * 0.55
                )
            )
            .frame(width: diameter, height: diameter)
            .blur(radius: 40)
            .blendMode(colorScheme == .dark ? .screen : .plusLighter)
    }

    private var blobOpacity: Double {
        let base = colorScheme == .dark ? 0.55 : 0.40
        return base * max(0, min(intensity, 1))
    }

    private func loop(_ duration: Double) -> Animation {
        reduceMotion
            ? .default
            : .easeInOut(duration: duration).repeatForever(autoreverses: true)
    }
}

// MARK: - Staggered entrance

/// Slides + fades a view up into place, optionally after a per-item delay. Used to make
/// home sections cascade in instead of snapping. No-ops under Reduce Motion.
struct AppearTransitionModifier: ViewModifier {
    let delay: Double
    let yOffset: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : yOffset)
            .onAppear {
                guard shown == false else { return }
                if reduceMotion {
                    shown = true
                    return
                }
                withAnimation(.spring(response: 0.62, dampingFraction: 0.86).delay(delay)) {
                    shown = true
                }
            }
    }
}

extension View {
    /// Cascade this view in on first appearance.
    func appearTransition(delay: Double = 0, yOffset: CGFloat = 26) -> some View {
        modifier(AppearTransitionModifier(delay: delay, yOffset: yOffset))
    }

    /// MusicTube's signature animated screen backdrop. Layers the drifting aurora behind
    /// the standard adaptive gradient so every tab feels alive and unmistakably on-brand.
    /// Use this in place of `.background(AppTheme.screenBackground.ignoresSafeArea())`.
    func auroraScreenBackground(intensity: Double = 0.5) -> some View {
        background {
            ZStack {
                AppTheme.screenBackground
                AuroraBackground(intensity: intensity).opacity(0.9)
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Shimmer

/// A diagonal light sweep used for AI / "thinking" affordances (the recommendation blurb).
struct AIShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content.overlay {
            if reduceMotion == false {
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.45), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(width: proxy.size.width * 1.6)
                    .offset(x: phase * proxy.size.width * 1.6)
                    .blendMode(.screen)
                }
                .allowsHitTesting(false)
                .mask(content)
                .onAppear {
                    withAnimation(.linear(duration: 1.7).repeatForever(autoreverses: false)) {
                        phase = 1.3
                    }
                }
            }
        }
    }
}

extension View {
    func aiShimmering() -> some View { modifier(AIShimmerModifier()) }
}

// MARK: - Pressable scale

/// Gives any tappable element a tactile spring-press. Pair with a tap/Button.
struct PressableScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableScaleStyle {
    static var pressable: PressableScaleStyle { PressableScaleStyle() }
}
