import Combine
import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var snapshot: HomeSnapshot = .empty

    private let appState: AppState
    private var visibleRecommendationCount = 10
    private var cancellables: Set<AnyCancellable> = []

    init(appState: AppState) {
        self.appState = appState
        observeRelevantState()
        rebuildSnapshot()
    }

    func appear() async {
        guard appState.hasLoadedHome == false,
              appState.isLoading == false,
              appState.isLoadingPlaylists == false else { return }
        await appState.refreshDashboard()
    }

    func refresh() async {
        await appState.refreshDashboard(forceRefresh: true)
    }

    func play(_ track: Track, queue: [Track]) {
        appState.play(track: track, queue: queue)
    }

    func playContinueListening(_ track: Track) {
        let queue = appState.playbackEngine.currentQueue
        appState.play(
            track: track,
            queue: queue.isEmpty ? snapshot.continueListening : queue
        )
    }

    func togglePlayback() {
        appState.togglePlayback()
    }

    func recommendMoreLike(_ track: Track) {
        appState.recommendMoreLike(track)
    }

    func recommendLessLike(_ track: Track) {
        appState.recommendLessLike(track)
    }

    func recommendationAppeared(_ item: IndexedTrackPresentation) {
        guard item.index >= snapshot.madeForYou.count - 2 else { return }
        if visibleRecommendationCount < appState.featuredTracks.count {
            visibleRecommendationCount = min(
                visibleRecommendationCount + AppConfig.Search.visibleSongPageSize,
                appState.featuredTracks.count
            )
            rebuildSnapshot()
        } else if appState.isLoadingMoreRecommendations == false {
            Task { [weak self] in
                await self?.appState.loadMoreRecommendedTracksIfNeeded()
            }
        }
    }

    private func rebuildSnapshot() {
        let currentQueue = appState.playbackEngine.currentQueue
        let continueListening: [Track]
        if appState.nowPlaying != nil, currentQueue.isEmpty == false {
            continueListening = Array(currentQueue.prefix(12))
        } else {
            continueListening = Array(appState.historyTracks.prefix(12))
        }

        let recommendations = Array(appState.featuredTracks.prefix(visibleRecommendationCount))
            .enumerated()
            .map { IndexedTrackPresentation(index: $0.offset, track: $0.element) }
        let recommendationIDs = Set(recommendations.map { $0.track.playbackKey })
        let contextual = appState.relatedTracks.isEmpty
            ? appState.recentTracks.filter { recommendationIDs.contains($0.playbackKey) == false }
            : appState.relatedTracks

        snapshot = HomeSnapshot(
            continueListening: continueListening,
            madeForYou: recommendations,
            recentlyPlayed: Array(appState.historyTracks.prefix(12)),
            mixes: Array(appState.suggestedMixes.prefix(10)),
            contextualTracks: Array(contextual.prefix(8)),
            statusMessage: appState.homeStatusMessage,
            recommendationBlurb: appState.recommendationBlurb,
            nowPlayingKey: appState.nowPlaying?.playbackKey,
            isPlaying: appState.isPlaying,
            isLoading: appState.isLoading || appState.isLoadingMoreRecommendations,
            hasLoaded: appState.hasLoadedHome,
            displayName: appState.user?.name.components(separatedBy: " ").first
        )
    }

    private func observeRelevantState() {
        appState.$homeContent
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$historyTracks
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$relatedTracks
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$nowPlayingTrack
            .combineLatest(appState.$isPlaybackActive)
            .sink { [weak self] _, _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$recommendationBlurb
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$isLoading
            .combineLatest(appState.$isLoadingMoreRecommendations)
            .sink { [weak self] _, _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$hasLoadedHome
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$user
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
    }
}
