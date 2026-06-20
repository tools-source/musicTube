import SwiftUI

/// MusicTube's animated cold-start splash. The static `LaunchScreen.storyboard` paints
/// instantly while the process boots; this SwiftUI view then takes over and performs the
/// branded intro (logo bloom + equalizer pulse + wordmark reveal) before handing off to
/// the app. Driven by `RootView`, which fades it out once the intro completes.
struct LaunchExperienceView: View {
    /// Called when the intro animation has finished and the splash can be removed.
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var logoIn = false
    @State private var ringExpand = false
    @State private var wordmarkIn = false
    @State private var taglineIn = false
    @State private var barsActive = false

    private let brand = Color(red: 1.0, green: 0.23, blue: 0.42)

    var body: some View {
        ZStack {
            // Always render the splash on a dark canvas (regardless of system appearance)
            // so it blends seamlessly out of the dark launch background — one branded
            // launch moment instead of a flash between two screens.
            AuroraBackground(intensity: 1.0, luminous: true)
                .environment(\.colorScheme, .dark)
            Color.black.opacity(0.28).ignoresSafeArea()

            VStack(spacing: 26) {
                logoMark
                wordmark
                tagline
            }
            .padding(.bottom, 40)
        }
        .onAppear(perform: runIntro)
    }

    // MARK: Logo

    private var logoMark: some View {
        ZStack {
            // Expanding pulse rings.
            ForEach(0..<2, id: \.self) { index in
                Circle()
                    .stroke(brand.opacity(0.45), lineWidth: 2)
                    .frame(width: 132, height: 132)
                    .scaleEffect(ringExpand ? 1.9 + Double(index) * 0.35 : 0.7)
                    .opacity(ringExpand ? 0 : 0.8)
            }

            // Glowing badge.
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [brand, Color(red: 0.78, green: 0.12, blue: 0.42)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 124, height: 124)
                .shadow(color: brand.opacity(0.6), radius: 28, y: 12)
                .overlay(equalizer)
                .overlay(
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                )
                .scaleEffect(logoIn ? 1 : 0.5)
                .opacity(logoIn ? 1 : 0)
                .rotation3DEffect(
                    .degrees(logoIn ? 0 : -22),
                    axis: (x: 1, y: -0.4, z: 0)
                )
        }
    }

    /// A tiny three-bar equalizer that breathes while the splash is up.
    private var equalizer: some View {
        HStack(alignment: .center, spacing: 7) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(.white)
                    .frame(width: 9, height: barHeight(index))
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 0.5 + Double(index) * 0.12)
                                .repeatForever(autoreverses: true),
                        value: barsActive
                    )
            }
        }
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let tall: [CGFloat] = [40, 58, 30]
        let short: [CGFloat] = [22, 34, 18]
        return barsActive ? tall[index] : short[index]
    }

    // MARK: Wordmark

    private var wordmark: some View {
        HStack(spacing: 0) {
            Text("Music")
                .foregroundStyle(.white)
            Text("Tube")
                .foregroundStyle(brand)
        }
        .font(.system(size: 38, weight: .heavy, design: .rounded))
        .opacity(wordmarkIn ? 1 : 0)
        .offset(y: wordmarkIn ? 0 : 14)
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
    }

    private var tagline: some View {
        Text("Your sound, intelligently tuned.")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white.opacity(0.78))
            .opacity(taglineIn ? 1 : 0)
            .offset(y: taglineIn ? 0 : 10)
    }

    // MARK: Choreography

    private func runIntro() {
        guard reduceMotion == false else {
            logoIn = true
            wordmarkIn = true
            taglineIn = true
            barsActive = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: onFinished)
            return
        }

        withAnimation(.spring(response: 0.7, dampingFraction: 0.62)) {
            logoIn = true
        }
        withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
            ringExpand = true
        }
        barsActive = true

        withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.45)) {
            wordmarkIn = true
        }
        withAnimation(.easeOut(duration: 0.5).delay(0.75)) {
            taglineIn = true
        }

        // Hand back to the app after the intro has had room to land.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25, execute: onFinished)
    }
}
