import SwiftUI

/// MusicTube's optional first-run brand moment. Returning users move directly from the
/// static launch screen into the app without an interaction-blocking animation.
struct LaunchExperienceView: View {
    /// Called when the intro animation has finished and the splash can be removed.
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var logoIn = false
    @State private var ringExpand = false
    @State private var wordmarkIn = false
    @State private var taglineIn = false

    private let brand = Color(red: 1.0, green: 0.23, blue: 0.42)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.07, blue: 0.09), .black],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 26) {
                logoMark
                wordmark
                tagline
            }
            .padding(.bottom, 40)
        }
        .task {
            await runIntro()
        }
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

            Image("LaunchIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 124, height: 124)
                .shadow(color: brand.opacity(0.6), radius: 28, y: 12)
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

    @MainActor
    private func runIntro() async {
        guard reduceMotion == false else {
            logoIn = true
            wordmarkIn = true
            taglineIn = true
            onFinished()
            return
        }

        withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
            logoIn = true
        }
        withAnimation(.easeOut(duration: 0.65)) {
            ringExpand = true
        }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.82).delay(0.08)) {
            wordmarkIn = true
        }
        withAnimation(.easeOut(duration: 0.22).delay(0.16)) {
            taglineIn = true
        }

        try? await Task.sleep(nanoseconds: 450_000_000)
        guard Task.isCancelled == false else { return }
        onFinished()
    }
}
