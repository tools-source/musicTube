import SwiftUI

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
                } else {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.88).delay(delay)) {
                        shown = true
                    }
                }
            }
    }
}

extension View {
    func appearTransition(delay: Double = 0, yOffset: CGFloat = 18) -> some View {
        modifier(AppearTransitionModifier(delay: delay, yOffset: yOffset))
    }

    func premiumScreenBackground() -> some View {
        background(AppTheme.screenBackground.ignoresSafeArea())
    }
}
