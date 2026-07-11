import Combine
import Foundation

@MainActor
final class RootViewModel: ObservableObject {
    @Published private(set) var isRecognizingMusic: Bool
    @Published var isPlayerPresented: Bool
    @Published var isPreferenceOnboardingPresented: Bool
    @Published var errorMessage: String?
    @Published private(set) var isPlaybackActive: Bool
    @Published private(set) var hasNowPlaying: Bool

    private let appState: AppState
    private var cancellables: Set<AnyCancellable> = []

    init(appState: AppState) {
        self.appState = appState
        isRecognizingMusic = appState.isRecognizingMusic
        isPlayerPresented = appState.isPlayerPresented
        isPreferenceOnboardingPresented = appState.isPreferenceOnboardingPresented
        errorMessage = appState.errorMessage
        isPlaybackActive = appState.isPlaybackActive
        hasNowPlaying = appState.nowPlaying != nil
        observePresentationState()
    }

    func restoreSession() async {
        await appState.restoreSession()
    }

    func dismissPlayer() {
        appState.dismissPlayer()
    }

    private func observePresentationState() {
        appState.$isRecognizingMusic
            .removeDuplicates()
            .assign(to: &$isRecognizingMusic)
        appState.$isPlayerPresented
            .removeDuplicates()
            .sink { [weak self] in
                guard let self else { return }
                if isPlayerPresented != $0 { isPlayerPresented = $0 }
            }
            .store(in: &cancellables)
        $isPlayerPresented
            .removeDuplicates()
            .dropFirst()
            .sink { [weak appState] in appState?.isPlayerPresented = $0 }
            .store(in: &cancellables)

        appState.$isPreferenceOnboardingPresented
            .removeDuplicates()
            .sink { [weak self] in
                guard let self else { return }
                if isPreferenceOnboardingPresented != $0 { isPreferenceOnboardingPresented = $0 }
            }
            .store(in: &cancellables)
        $isPreferenceOnboardingPresented
            .removeDuplicates()
            .dropFirst()
            .sink { [weak appState] in appState?.isPreferenceOnboardingPresented = $0 }
            .store(in: &cancellables)

        appState.$errorMessage
            .sink { [weak self] in
                guard let self else { return }
                if errorMessage != $0 { errorMessage = $0 }
            }
            .store(in: &cancellables)
        $errorMessage
            .dropFirst()
            .sink { [weak appState] in appState?.errorMessage = $0 }
            .store(in: &cancellables)

        appState.$isPlaybackActive
            .removeDuplicates()
            .assign(to: &$isPlaybackActive)
        appState.$nowPlayingTrack
            .map { $0 != nil }
            .removeDuplicates()
            .assign(to: &$hasNowPlaying)
    }
}
