import AppIntents
import Foundation

// Waits up to 5 s for the app to finish restoring its auth session.
// Called at the top of every playback intent so that background/locked-screen
// launches have a fully initialised AppState before we try to fetch content.
@MainActor
private func readyAppState() async -> AppState? {
    guard let appState = AppContainer.shared.appState else { return nil }
    var ticks = 0
    while appState.authState == .restoring && ticks < 50 {
        try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms
        ticks += 1
    }
    return appState
}

// MARK: - Play Liked Songs

struct PlayLikedSongsIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Liked Songs"
    static var description = IntentDescription("Start playing your liked songs in MusicTube")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appState = await readyAppState() else {
            return .result(dialog: IntentDialog("MusicTube isn't ready yet. Try again in a moment."))
        }
        if appState.playlists.isEmpty { await appState.refreshLibrary() }
        guard let liked = appState.likedSongsPlaylist else {
            return .result(dialog: IntentDialog("No liked songs playlist found. Sign in to YouTube in MusicTube to sync your likes."))
        }
        let tracks = await appState.loadPlaylistItems(for: liked)
        guard let first = tracks.first else {
            return .result(dialog: IntentDialog("Your liked songs playlist is empty. Like some songs in MusicTube first."))
        }
        appState.play(track: first, queue: tracks)
        appState.isPlayerPresented = true
        return .result(dialog: IntentDialog("Playing your liked songs."))
    }
}

// MARK: - Shuffle Liked Songs

struct ShuffleLikedSongsIntent: AppIntent {
    static var title: LocalizedStringResource = "Shuffle Liked Songs"
    static var description = IntentDescription("Shuffle and play your liked songs in MusicTube")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appState = await readyAppState() else {
            return .result(dialog: IntentDialog("MusicTube isn't ready yet. Try again in a moment."))
        }
        if appState.playlists.isEmpty { await appState.refreshLibrary() }
        guard let liked = appState.likedSongsPlaylist else {
            return .result(dialog: IntentDialog("No liked songs playlist found. Sign in to YouTube in MusicTube to sync your likes."))
        }
        let tracks = await appState.loadPlaylistItems(for: liked)
        guard tracks.isEmpty == false else {
            return .result(dialog: IntentDialog("Your liked songs playlist is empty."))
        }
        let seedTrack = tracks.randomElement() ?? tracks[0]
        appState.play(track: seedTrack, queue: tracks)
        if appState.playbackEngine.shuffleMode == false { appState.toggleShuffle() }
        appState.isPlayerPresented = true
        return .result(dialog: IntentDialog("Shuffling your liked songs."))
    }
}

// MARK: - Play Specific Playlist

struct PlayPlaylistIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Playlist"
    static var description = IntentDescription("Play a specific playlist in MusicTube")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appState = await readyAppState() else {
            return .result(dialog: IntentDialog("MusicTube isn't ready yet. Try again in a moment."))
        }
        if appState.playlists.isEmpty { await appState.refreshLibrary() }
        guard let target = appState.playlists.first(where: { $0.id == playlist.id }) else {
            return .result(dialog: IntentDialog("Playlist not found. Open MusicTube to check your library."))
        }
        let tracks = await appState.loadPlaylistItems(for: target)
        guard let first = tracks.first else {
            return .result(dialog: IntentDialog("That playlist is empty."))
        }
        appState.play(track: first, queue: tracks)
        appState.isPlayerPresented = true
        return .result(dialog: IntentDialog("Playing your playlist."))
    }
}

// MARK: - Play Saved Songs

struct PlaySavedSongsIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Saved Songs"
    static var description = IntentDescription("Play your saved songs in MusicTube")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appState = await readyAppState() else {
            return .result(dialog: IntentDialog("MusicTube isn't ready yet. Try again in a moment."))
        }
        if appState.playlists.isEmpty { await appState.refreshLibrary() }
        guard let saved = appState.savedSongsPlaylist else {
            return .result(dialog: IntentDialog("No saved songs found. Save some tracks in MusicTube first."))
        }
        let tracks = await appState.loadPlaylistItems(for: saved)
        guard let first = tracks.first else {
            return .result(dialog: IntentDialog("Your saved songs are empty."))
        }
        appState.play(track: first, queue: tracks)
        appState.isPlayerPresented = true
        return .result(dialog: IntentDialog("Playing your saved songs."))
    }
}

// MARK: - Play Recently Played

struct PlayRecentlyPlayedIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Recently Played"
    static var description = IntentDescription("Resume your recently played tracks in MusicTube")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appState = await readyAppState() else {
            return .result(dialog: IntentDialog("MusicTube isn't ready yet. Try again in a moment."))
        }
        let history = appState.historyTracks
        guard history.isEmpty == false else {
            return .result(dialog: IntentDialog("No recently played tracks. Play some music in MusicTube first."))
        }
        appState.play(track: history[0], queue: history)
        appState.isPlayerPresented = true
        return .result(dialog: IntentDialog("Resuming recently played tracks."))
    }
}

// MARK: - Play Downloads

struct PlayDownloadsIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Downloads"
    static var description = IntentDescription("Play your offline downloaded songs in MusicTube, optionally from a specific folder")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Folder")
    var folder: DownloadFolderEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appState = await readyAppState() else {
            return .result(dialog: IntentDialog("MusicTube isn't ready yet. Try again in a moment."))
        }
        let service = appState.downloadService
        let records = folder.map { service.downloads(in: $0.id) } ?? service.availableDownloads
        let tracks = records.map(\.localTrack)
        guard tracks.isEmpty == false else {
            return .result(dialog: IntentDialog(
                folder != nil
                    ? "That download folder is empty."
                    : "No downloads found. Download some songs in MusicTube to listen offline."
            ))
        }
        appState.play(track: tracks[0], queue: tracks)
        appState.isPlayerPresented = true
        return .result(dialog: IntentDialog(
            folder != nil
                ? "Playing your downloaded folder."
                : "Playing your downloaded songs."
        ))
    }
}

// MARK: - Play Top Picks

struct PlayTopPicksIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Top Picks"
    static var description = IntentDescription("Play your recommended top picks in MusicTube")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let appState = await readyAppState() else {
            return .result(dialog: IntentDialog("MusicTube isn't ready yet. Try again in a moment."))
        }
        if appState.featuredTracks.isEmpty && appState.recentTracks.isEmpty {
            await appState.refreshHome()
        }
        let picks = appState.featuredTracks.isEmpty ? appState.recentTracks : appState.featuredTracks
        guard let first = picks.first else {
            return .result(dialog: IntentDialog("No top picks available yet. Open MusicTube to load your recommendations."))
        }
        appState.play(track: first, queue: picks)
        appState.isPlayerPresented = true
        return .result(dialog: IntentDialog("Playing your top picks."))
    }
}

// MARK: - Skip Song

struct SkipSongIntent: AppIntent {
    static var title: LocalizedStringResource = "Skip Song"
    static var description = IntentDescription("Skip to the next song in MusicTube")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let skipped = await MainActor.run { () -> Bool in
            guard let appState = AppContainer.shared.appState,
                  appState.nowPlaying != nil else { return false }
            appState.playNextTrack()
            return true
        }
        return .result(dialog: IntentDialog(skipped ? "Skipped." : "Nothing is playing in MusicTube right now."))
    }
}

// MARK: - Pause / Resume

struct PauseResumeIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause or Resume"
    static var description = IntentDescription("Toggle play/pause in MusicTube")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        enum Outcome { case paused, resumed, idle }
        let outcome: Outcome = await MainActor.run {
            guard let appState = AppContainer.shared.appState,
                  appState.nowPlaying != nil else { return .idle }
            let wasPlaying = appState.isPlaying
            appState.togglePlayback()
            return wasPlaying ? .paused : .resumed
        }
        switch outcome {
        case .paused:   return .result(dialog: IntentDialog("Paused."))
        case .resumed:  return .result(dialog: IntentDialog("Resumed."))
        case .idle:     return .result(dialog: IntentDialog("Nothing is playing in MusicTube right now."))
        }
    }
}
