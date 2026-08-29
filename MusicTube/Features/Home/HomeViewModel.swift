import Combine
import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var snapshot: HomeSnapshot = .empty

    private struct PlaybackSummary: Equatable {
        let nowPlayingKey: String?
        let isPlaying: Bool
    }

    private let appState: AppState
    private let playback: PlaybackService
    private var visibleRecommendationCount = 10
    private var cancellables: Set<AnyCancellable> = []

    init(appState: AppState) {
        self.appState = appState
        self.playback = appState.playbackEngine
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
        let playbackState = playback.liveState
        let currentQueue = playback.currentQueue
        let continueListening: [Track]
        if playbackState.nowPlaying != nil, currentQueue.isEmpty == false {
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

        let nextSnapshot = HomeSnapshot(
            continueListening: continueListening,
            madeForYou: recommendations,
            recentlyPlayed: Array(appState.historyTracks.prefix(12)),
            mixes: Array(appState.suggestedMixes.prefix(10)),
            contextualTracks: Array(contextual.prefix(8)),
            statusMessage: appState.homeStatusMessage,
            recommendationBlurb: appState.recommendationBlurb,
            nowPlayingKey: playbackState.nowPlaying?.playbackKey,
            isPlaying: playbackState.isPlaying,
            isLoading: appState.isLoading || appState.isLoadingMoreRecommendations,
            hasLoaded: appState.hasLoadedHome,
            displayName: appState.user?.name.components(separatedBy: " ").first
        )
        guard nextSnapshot != snapshot else { return }
        snapshot = nextSnapshot
    }

    // Every subscription here rebuilds the snapshot by re-reading `AppState` /
    // `PlaybackService`, so each one hops to the next main-queue turn — see
    // `receiveAfterStateCommit()`. The hop sits after `removeDuplicates()` so
    // high-frequency playback ticks are filtered out before it.
    private func observeRelevantState() {
        appState.$homeContent
            .receiveAfterStateCommit()
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$historyTracks
            .receiveAfterStateCommit()
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$relatedTracks
            .receiveAfterStateCommit()
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        playback.$state
            .map {
                PlaybackSummary(
                    nowPlayingKey: $0.nowPlaying?.playbackKey,
                    isPlaying: $0.isPlaying
                )
            }
            .removeDuplicates()
            .receiveAfterStateCommit()
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        playback.$currentQueue
            .map { $0.map(\.playbackKey) }
            .removeDuplicates()
            .receiveAfterStateCommit()
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$recommendationBlurb
            .receiveAfterStateCommit()
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$isLoading
            .combineLatest(appState.$isLoadingMoreRecommendations)
            .receiveAfterStateCommit()
            .sink { [weak self] _, _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$hasLoadedHome
            .receiveAfterStateCommit()
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$user
            .receiveAfterStateCommit()
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
    }
}
