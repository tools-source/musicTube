import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            AppTheme.loginBackground
                .ignoresSafeArea()

            VStack(spacing: 26) {
                Spacer()

                Image(systemName: "music.note.tv.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(AppTheme.primaryText)

                VStack(spacing: 10) {
                    Text("MusicTube")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.primaryText)

                    Text("Listen on your phone and in CarPlay with one seamless queue.")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()

                Button {
                    Task {
                        await appState.signIn()
                    }
                } label: {
                    HStack {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                        Text("Continue with YouTube")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.accent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(appState.isLoading)

                Text("No in-app ads. Playback behavior follows your YouTube account permissions.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.tertiaryText)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 32)
            }
            .padding(.horizontal, 24)
        }
        .overlay {
            if appState.isLoading {
                ProgressView()
                    .tint(AppTheme.primaryText)
            }
        }
    }
}
