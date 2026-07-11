import Combine
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var preferenceProfile: UserPreferenceProfile
    @Published private(set) var hasNowPlaying: Bool

    let authentication: AuthenticationViewModel
    private let appState: AppState
    private var cancellables: Set<AnyCancellable> = []

    init(appState: AppState, authentication: AuthenticationViewModel) {
        self.appState = appState
        self.authentication = authentication
        preferenceProfile = appState.userPreferenceProfile
        hasNowPlaying = appState.nowPlaying != nil

        appState.$userPreferenceProfile
            .sink { [weak self] in self?.preferenceProfile = $0 }
            .store(in: &cancellables)
        appState.$nowPlayingTrack
            .sink { [weak self] in self?.hasNowPlaying = $0 != nil }
            .store(in: &cancellables)
        authentication.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func addPreference(_ tag: UserPreferenceTag) {
        appState.setPreferenceTag(tag, isSelected: true)
    }

    func addCustomPreference(named name: String, category: UserPreferenceCategory = .genres) {
        appState.addCustomPreference(named: name, category: category)
    }

    func removePreference(_ id: String) {
        appState.removePreference(id)
    }

    func updatePreference(_ id: String, name: String, category: UserPreferenceCategory) {
        appState.updateCustomPreference(id, name: name, category: category)
    }
}
