import SwiftUI
import UIKit

enum AppTheme {
    static let accent = Color(red: 1, green: 0.23, blue: 0.42)

    static let primaryText = Color.primary
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let tertiaryText = Color(uiColor: .tertiaryLabel)

    static let screenBackgroundTop = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1)
            : UIColor(red: 0.97, green: 0.97, blue: 0.99, alpha: 1)
    })

    static let screenBackgroundBottom = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.04, green: 0.04, blue: 0.08, alpha: 1)
            : UIColor(red: 0.93, green: 0.94, blue: 0.97, alpha: 1)
    })

    static var screenBackground: LinearGradient {
        LinearGradient(
            colors: [screenBackgroundTop, screenBackgroundBottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static let loginBackgroundTop = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1)
            : UIColor(red: 0.98, green: 0.97, blue: 0.98, alpha: 1)
    })

    static let loginBackgroundBottom = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.15, green: 0.03, blue: 0.05, alpha: 1)
            : UIColor(red: 0.96, green: 0.90, blue: 0.92, alpha: 1)
    })

    static var loginBackground: LinearGradient {
        LinearGradient(
            colors: [loginBackgroundTop, loginBackgroundBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static let playerBackgroundTop = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.04, green: 0.04, blue: 0.07, alpha: 1)
            : UIColor(red: 0.97, green: 0.96, blue: 0.98, alpha: 1)
    })

    static let playerBackgroundMid = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.10, green: 0.02, blue: 0.10, alpha: 1)
            : UIColor(red: 0.94, green: 0.91, blue: 0.95, alpha: 1)
    })

    static let playerBackgroundBottom = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.black
            : UIColor(red: 0.91, green: 0.93, blue: 0.97, alpha: 1)
    })

    static var playerBackground: LinearGradient {
        LinearGradient(
            colors: [playerBackgroundTop, playerBackgroundMid, playerBackgroundBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static let cardFill = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.07)
            : UIColor.black.withAlphaComponent(0.05)
    })

    static let cardFillStrong = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 0.10, alpha: 1)
            : UIColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 1)
    })

    static let controlFill = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.black.withAlphaComponent(0.07)
    })

    static let controlFillStrong = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.12)
            : UIColor.black.withAlphaComponent(0.10)
    })

    static let divider = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.07)
            : UIColor.black.withAlphaComponent(0.08)
    })

    static let inputFill = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.black.withAlphaComponent(0.06)
    })

    static let inverseFill = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? .white : .black
    })

    static let inverseText = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? .black : .white
    })

    static let miniPlayerBackground = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 0.07, alpha: 1)
            : UIColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1)
    })

    static let miniPlayerBorder = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.06)
            : UIColor.black.withAlphaComponent(0.08)
    })

    static let playerGlassOverlay = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.black.withAlphaComponent(0.34)
            : UIColor.white.withAlphaComponent(0.42)
    })

    static let playerGlassStroke = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.black.withAlphaComponent(0.08)
    })

    static let progressTrack = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.10)
            : UIColor.black.withAlphaComponent(0.10)
    })

    static let progressBuffered = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.28)
            : UIColor.black.withAlphaComponent(0.24)
    })

    static let progressPlayed = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.92)
            : UIColor.black.withAlphaComponent(0.88)
    })

    static let playerHandle = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.28)
            : UIColor.black.withAlphaComponent(0.18)
    })
}

struct RootView: View {
    let coordinator: AppCoordinator
    @ObservedObject private var model: RootViewModel
    @ObservedObject private var reviewPrompter = AppReviewPrompter.shared
    @ObservedObject private var downloadService = DownloadService.shared
    @AppStorage("musictube.hasCompletedLaunchExperience") private var hasCompletedLaunchExperience = false
    @State private var isLaunching = false

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _model = ObservedObject(wrappedValue: coordinator.root)
    }

    var body: some View {
        mainContent
            .onAppear {
                isLaunching = hasCompletedLaunchExperience == false
            }
            .overlay {
                if isLaunching {
                    LaunchExperienceView {
                        hasCompletedLaunchExperience = true
                        withAnimation(.easeInOut(duration: 0.55)) {
                            isLaunching = false
                        }
                    }
                    .transition(.opacity)
                    .zIndex(10)
                }
            }
    }

    private var mainContent: some View {
        Group {
            if model.isRecognizingMusic {
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack {
                        Spacer()
                        VStack(spacing: AppSpacing.medium) {
                            ProgressView()
                                .tint(.white)
                            Text("Listening...")
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                        Spacer()
                    }
                }
            } else {
                MainTabView(coordinator: coordinator)
                    .playlistPickerSheet(host: .main)
            }
        }
        .task {
            await model.restoreSession()
        }
        .fullScreenCover(isPresented: $model.isPlayerPresented, onDismiss: {
            model.dismissPlayer()
        }) {
            if model.hasNowPlaying {
                PlayerView(viewModel: coordinator.player)
                    .environmentObject(coordinator.appState)
                    .playlistPickerSheet(host: .player)
            }
        }
        .fullScreenCover(isPresented: $model.isPreferenceOnboardingPresented) {
            PreferenceOnboardingView()
                .environmentObject(coordinator.appState)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { _ in model.errorMessage = nil }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
        .onOpenURL { url in
            Task {
                await coordinator.handleIncomingURL(url)
            }
        }
        .task {
            evaluateReviewPrompt()
        }
        .onChange(of: model.isPlaybackActive) { _, _ in
            evaluateReviewPrompt()
        }
        .onChange(of: model.isPlayerPresented) { _, _ in
            evaluateReviewPrompt()
        }
        .onReceive(downloadService.$downloads) { _ in
            DispatchQueue.main.async {
                evaluateReviewPrompt()
            }
        }
        .onReceive(downloadService.$activeDownloads) { _ in
            DispatchQueue.main.async {
                evaluateReviewPrompt()
            }
        }
        .alert(
            "Enjoying MusicTube?",
            isPresented: $reviewPrompter.isShowingPrePrompt
        ) {
            Button("Rate now") {
                reviewPrompter.requestNativeReview()
            }
            Button("Later") {
                reviewPrompter.remindLater()
            }
            Button("No thanks", role: .cancel) {
                reviewPrompter.optOut()
            }
        } message: {
            Text("A quick rating helps support the app and keeps MusicTube getting better.")
        }
    }

    private func evaluateReviewPrompt() {
        reviewPrompter.evaluatePresentation(
            isPlaybackActive: model.isPlaybackActive,
            isPlayerPresented: model.isPlayerPresented,
            hasActiveDownloads: hasDownloadCriticalActivity
        )
    }

    private var hasDownloadCriticalActivity: Bool {
        downloadService.activeDownloads.isEmpty == false
            || downloadService.pendingRequests.isEmpty == false
            || downloadService.preparingSourceIDs.isEmpty == false
            || downloadService.resolvingTrackKeys.isEmpty == false
    }
}
