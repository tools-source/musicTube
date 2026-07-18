import Combine
import Foundation

@MainActor
final class PlaylistViewModel: ObservableObject {
    @Published private(set) var playlist: Playlist
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var isLoading = true
    @Published private(set) var isSyncingLikedSongs = false
    @Published private(set) var nowPlayingKey: String?
    @Published private(set) var isPlaying = false

    private let appState: AppState
    private var cancellables: Set<AnyCancellable> = []

    init(playlist: Playlist, appState: AppState) {
        self.playlist = playlist
        self.appState = appState
        nowPlayingKey = appState.nowPlaying?.playbackKey
        isPlaying = appState.isPlaying
        observeRelevantState()
    }

    func loadInitial() async {
        guard tracks.isEmpty else { return }
        let initial = await appState.loadPlaylistItems(for: playlist, forceRefresh: false)
        tracks = initial
        isLoading = false
        prefetch(initial)

        guard playlist.kind == .likedMusic, appState.isSyncingLikedSongs == false else { return }
        let refreshed = await appState.loadPlaylistItems(
            for: playlist,
            forceRefresh: true,
            surfaceErrors: false
        )
        if refreshed != initial {
            tracks = refreshed
            prefetch(refreshed)
        }
    }

    func refresh() async {
        tracks = await appState.loadPlaylistItems(for: playlist, forceRefresh: true)
        isLoading = false
        prefetch(tracks)
    }

    func refreshAfterLikedSync() async {
        guard playlist.kind == .likedMusic, isSyncingLikedSongs == false else { return }
        tracks = await appState.loadPlaylistItems(
            for: playlist,
            forceRefresh: false,
            surfaceErrors: false
        )
        prefetch(tracks)
    }

    func play(_ track: Track) { appState.play(track: track, queue: tracks) }
    func togglePlayback() { appState.togglePlayback() }

    func playAll(shuffled: Bool) {
        guard let first = tracks.first else { return }
        if appState.playbackEngine.shuffleMode != shuffled { appState.toggleShuffle() }
        appState.play(track: first, queue: tracks)
    }

    func toggleLike(_ track: Track) {
        appState.toggleLike(for: track)
        tracks.removeAll { $0.playbackKey == track.playbackKey }
    }

    func toggleSaved(_ track: Track) {
        appState.toggleTrackSaved(track)
        tracks.removeAll { $0.playbackKey == track.playbackKey }
    }

    func remove(_ track: Track) {
        appState.removeTrack(track, from: playlist)
        tracks.removeAll { $0.playbackKey == track.playbackKey }
    }

    func rename(to name: String) -> Bool {
        appState.renameCustomPlaylist(playlist, to: name)
    }

    func delete() { appState.deleteCustomPlaylist(playlist) }
    func presentSongAdder() { appState.presentPlaylistSongAdder(for: playlist) }
    func download() {
        guard tracks.isEmpty == false else {
            appState.downloadPlaylist(playlist)
            return
        }
        appState.downloadTracks(tracks, source: downloadSource)
    }

    private func prefetch(_ tracks: [Track]) {
        let warmTracks = Array(tracks.prefix(10))
        guard warmTracks.isEmpty == false else { return }
        appState.prefetchPlayback(for: warmTracks)
    }

    private var downloadSource: DownloadSource {
        DownloadSource(
            id: "playlist:\(playlist.id)",
            title: playlist.title,
            kind: .playlist
        )
    }

    private func observeRelevantState() {
        appState.$playlists
            .sink { [weak self] playlists in
                guard let self else { return }
                if let updated = playlists.first(where: { $0.id == self.playlist.id }) {
                    playlist = updated
                }
            }
            .store(in: &cancellables)
        appState.$isSyncingLikedSongs
            .sink { [weak self] in self?.isSyncingLikedSongs = $0 }
            .store(in: &cancellables)
        appState.$nowPlayingTrack
            .combineLatest(appState.$isPlaybackActive)
            .sink { [weak self] track, playing in
                self?.nowPlayingKey = track?.playbackKey
                self?.isPlaying = playing
            }
            .store(in: &cancellables)
    }
}
