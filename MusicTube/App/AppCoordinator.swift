import Combine
import Foundation

@MainActor
final class AppCoordinator: ObservableObject {
    @Published var selectedTab: AppState.MainTab {
        didSet {
            guard appState.selectedMainTab != selectedTab else { return }
            appState.selectedMainTab = selectedTab
        }
    }

    let search: SearchViewModel
    let home: HomeViewModel
    let downloads: DownloadViewModel
    let library: LibraryViewModel
    let player: PlayerViewModel
    let authentication: AuthenticationViewModel
    let settings: SettingsViewModel
    let root: RootViewModel
    let appState: AppState
    private var cancellables: Set<AnyCancellable> = []
    private var playlistModels: [String: PlaylistViewModel] = [:]

    init(appState: AppState) {
        self.appState = appState
        selectedTab = appState.selectedMainTab
        search = SearchViewModel(appState: appState)
        home = HomeViewModel(appState: appState)
        downloads = DownloadViewModel(appState: appState)
        library = LibraryViewModel(appState: appState)
        player = PlayerViewModel(appState: appState, playback: appState.playbackEngine)
        authentication = AuthenticationViewModel(appState: appState)
        settings = SettingsViewModel(appState: appState, authentication: authentication)
        root = RootViewModel(appState: appState)

        appState.$selectedMainTab
            .removeDuplicates()
            .sink { [weak self] tab in
                guard let self, selectedTab != tab else { return }
                selectedTab = tab
            }
            .store(in: &cancellables)
    }

    func handleIncomingURL(_ url: URL) async {
        await appState.handleIncomingURL(url)
    }

    func applicationDidBecomeActive() {
        appState.handleApplicationDidBecomeActive()
    }

    func playlistViewModel(for playlist: Playlist) -> PlaylistViewModel {
        if let existing = playlistModels[playlist.id] { return existing }
        let model = PlaylistViewModel(playlist: playlist, appState: appState)
        playlistModels[playlist.id] = model
        return model
    }
}
