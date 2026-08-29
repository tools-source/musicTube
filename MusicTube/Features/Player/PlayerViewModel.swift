import Combine
import Foundation

struct PlayerProgressSnapshot: Equatable, Sendable {
    var currentTime: TimeInterval
    var duration: TimeInterval
    var bufferedTime: TimeInterval

    static let empty = PlayerProgressSnapshot(currentTime: 0, duration: 0, bufferedTime: 0)
}

@MainActor
final class PlayerProgressViewModel: ObservableObject {
    @Published private(set) var snapshot: PlayerProgressSnapshot = .empty

    func apply(_ state: PlaybackState) {
        let nextSnapshot = PlayerProgressSnapshot(
            currentTime: state.currentTime,
            duration: state.duration,
            bufferedTime: state.bufferedTime
        )
        guard nextSnapshot != snapshot else { return }
        snapshot = nextSnapshot
    }
}

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published private(set) var snapshot: PlayerSnapshot = .empty
    let progress = PlayerProgressViewModel()

    private struct PlaybackPresentation: Equatable {
        let track: Track?
        let isPlaying: Bool
        let isResolvingStream: Bool
        let playbackErrorMessage: String?
        let hasNextTrack: Bool
        let hasPreviousTrack: Bool
        let isBufferingPlayback: Bool

        init(state: PlaybackState) {
            track = state.nowPlaying
            isPlaying = state.isPlaying
            isResolvingStream = state.isResolvingStream
            playbackErrorMessage = state.playbackErrorMessage
            hasNextTrack = state.hasNextTrack
            hasPreviousTrack = state.hasPreviousTrack
            isBufferingPlayback = state.isBufferingPlayback
        }
    }

    private let appState: AppState
    private let playback: PlaybackService
    private let downloads: DownloadService
    private var cancellables: Set<AnyCancellable> = []

    init(
        appState: AppState,
        playback: PlaybackService,
        downloads: DownloadService? = nil
    ) {
        self.appState = appState
        self.playback = playback
        self.downloads = downloads ?? .shared
        observeRelevantState()
        rebuildSnapshot()
    }

    func appear() {
        appState.refreshRelatedTracksForCurrentTrackIfNeeded()
    }

    func dismiss() { appState.dismissPlayer() }
    func togglePlayback() { appState.togglePlayback() }
    func previous() { appState.playPreviousTrack() }
    func next() { appState.playNextTrack() }
    func seek(to time: TimeInterval) { appState.seek(to: time) }
    func toggleShuffle() { appState.toggleShuffle() }
    func cycleRepeat() { appState.cycleRepeatMode() }

    func toggleLike() {
        guard let track = snapshot.track else { return }
        appState.toggleLike(for: track)
    }

    func download() {
        guard let track = snapshot.track else { return }
        appState.downloadTrack(track)
    }

    func playQueueItem(_ item: IndexedTrackPresentation) {
        appState.play(track: item.track, queue: playback.currentQueue)
    }

    func playRelated(_ track: Track) {
        appState.play(track: track, queue: snapshot.related)
    }

    func retryRelated() {
        appState.retryRelatedTracksForCurrentTrack()
    }

    func setSleepTimer(minutes: Int) { appState.setSleepTimer(minutes: minutes) }
    func cancelSleepTimer() { appState.cancelSleepTimer() }
    func setPlaybackRate(_ rate: Float) { appState.setPlaybackRate(rate) }

    private func rebuildSnapshot() {
        let state = playback.state
        let track = state.nowPlaying
        let nextSnapshot = PlayerSnapshot(
            track: track,
            currentTime: state.currentTime,
            duration: state.duration,
            bufferedTime: state.bufferedTime,
            isPlaying: state.isPlaying,
            isBuffering: state.isBufferingPlayback || state.isResolvingStream,
            hasPrevious: state.hasPreviousTrack,
            hasNext: state.hasNextTrack,
            shuffleEnabled: playback.shuffleMode,
            repeatMode: playback.repeatMode,
            queue: playback.currentQueue.enumerated().map {
                IndexedTrackPresentation(index: $0.offset, track: $0.element)
            },
            related: Array(appState.relatedTracks.prefix(12)),
            isLoadingRelated: appState.isLoadingRelatedTracks,
            isLiked: track.map(appState.isTrackLiked) ?? false,
            isDownloaded: track.map(downloads.isDownloaded) ?? false,
            isDownloading: track.map(downloads.isDownloading) ?? false,
            downloadProgress: track.map(downloads.downloadProgress) ?? 0,
            sleepTimerEndDate: appState.sleepTimerEndDate
        )
        guard nextSnapshot != snapshot else { return }
        snapshot = nextSnapshot
    }

    private func observeRelevantState() {
        playback.$state
            .sink { [weak self] state in self?.progress.apply(state) }
            .store(in: &cancellables)
        playback.$state
            .map(PlaybackPresentation.init)
            .removeDuplicates()
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        playback.$shuffleMode
            .combineLatest(playback.$repeatMode, playback.$currentQueue)
            .sink { [weak self] _, _, _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$relatedTracks
            .combineLatest(appState.$isLoadingRelatedTracks)
            .sink { [weak self] _, _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$likedTrackIDs
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$sleepTimerEndDate
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        downloads.$downloads
            .combineLatest(downloads.$activeDownloads)
            .sink { [weak self] _, _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
    }
}
