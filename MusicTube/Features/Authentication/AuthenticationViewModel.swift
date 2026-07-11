import Combine
import Foundation

@MainActor
final class AuthenticationViewModel: ObservableObject {
    @Published private(set) var user: YouTubeUser?
    @Published private(set) var isConnected: Bool
    @Published private(set) var isLoading: Bool
    @Published private(set) var isDeletingData: Bool
    @Published private(set) var statusMessage: String?

    private let appState: AppState
    private var cancellables: Set<AnyCancellable> = []

    init(appState: AppState) {
        self.appState = appState
        user = appState.user
        isConnected = appState.isYouTubeConnected
        isLoading = appState.isLoading
        isDeletingData = appState.isDeletingAccountData
        statusMessage = appState.libraryStatusMessage
        observe()
    }

    func signIn() async { await appState.signIn() }
    func signOut() async { await appState.signOut() }
    func switchAccount() async { await appState.switchAccount() }
    func deleteLocalData() async { await appState.deleteCurrentAccountData() }

    private func observe() {
        appState.$user
            .combineLatest(appState.$authState)
            .sink { [weak self] user, _ in
                self?.user = user
                self?.isConnected = self?.appState.isYouTubeConnected ?? false
            }
            .store(in: &cancellables)
        appState.$isLoading
            .sink { [weak self] in self?.isLoading = $0 }
            .store(in: &cancellables)
        appState.$isDeletingAccountData
            .sink { [weak self] in self?.isDeletingData = $0 }
            .store(in: &cancellables)
        appState.$libraryStatusMessage
            .sink { [weak self] in self?.statusMessage = $0 }
            .store(in: &cancellables)
    }
}
