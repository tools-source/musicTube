import AppIntents

struct MusicTubeShortcuts: AppShortcutsProvider {

    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {

        // MARK: Play Liked Songs
        AppShortcut(
            intent: PlayLikedSongsIntent(),
            phrases: [
                "Play my liked songs on \(.applicationName)",
                "Play liked songs on \(.applicationName)",
                "Play my favorites on \(.applicationName)"
            ],
            shortTitle: "Liked Songs",
            systemImageName: "heart.fill"
        )

        // MARK: Shuffle Liked Songs
        AppShortcut(
            intent: ShuffleLikedSongsIntent(),
            phrases: [
                "Shuffle my liked songs on \(.applicationName)",
                "Shuffle liked songs on \(.applicationName)",
                "Shuffle my favorites on \(.applicationName)"
            ],
            shortTitle: "Shuffle Liked",
            systemImageName: "shuffle"
        )

        // MARK: Play Specific Playlist
        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: [
                "Play \(\.$playlist) on \(.applicationName)",
                "Play my \(\.$playlist) playlist on \(.applicationName)",
                "Open \(\.$playlist) on \(.applicationName)"
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )

        // MARK: Play Saved Songs
        AppShortcut(
            intent: PlaySavedSongsIntent(),
            phrases: [
                "Play my saved songs on \(.applicationName)",
                "Play saved songs on \(.applicationName)"
            ],
            shortTitle: "Saved Songs",
            systemImageName: "bookmark.fill"
        )

        // MARK: Play Recently Played
        AppShortcut(
            intent: PlayRecentlyPlayedIntent(),
            phrases: [
                "Play recently played on \(.applicationName)",
                "Resume music on \(.applicationName)",
                "Continue listening on \(.applicationName)"
            ],
            shortTitle: "Recently Played",
            systemImageName: "clock.fill"
        )

        // MARK: Play Downloads
        AppShortcut(
            intent: PlayDownloadsIntent(),
            phrases: [
                "Play my downloads on \(.applicationName)",
                "Play offline music on \(.applicationName)",
                "Play downloaded songs on \(.applicationName)",
                "Play \(\.$folder) downloads on \(.applicationName)",
                "Play my \(\.$folder) folder on \(.applicationName)"
            ],
            shortTitle: "Downloads",
            systemImageName: "arrow.down.circle.fill"
        )

        // MARK: Play Top Picks
        AppShortcut(
            intent: PlayTopPicksIntent(),
            phrases: [
                "Play top picks on \(.applicationName)",
                "Play recommendations on \(.applicationName)",
                "Play something on \(.applicationName)"
            ],
            shortTitle: "Top Picks",
            systemImageName: "wand.and.stars"
        )

        // MARK: Skip Song
        AppShortcut(
            intent: SkipSongIntent(),
            phrases: [
                "Skip this song on \(.applicationName)",
                "Next song on \(.applicationName)",
                "Skip on \(.applicationName)"
            ],
            shortTitle: "Skip Song",
            systemImageName: "forward.fill"
        )

        // MARK: Pause / Resume
        AppShortcut(
            intent: PauseResumeIntent(),
            phrases: [
                "Pause \(.applicationName)",
                "Resume \(.applicationName)",
                "Pause music on \(.applicationName)",
                "Resume music on \(.applicationName)"
            ],
            shortTitle: "Pause / Resume",
            systemImageName: "playpause.fill"
        )
    }
}
