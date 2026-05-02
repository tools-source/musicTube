import SwiftUI
import UIKit

enum AppTheme {
    static let accent = Color(red: 1, green: 0.23, blue: 0.42)

    static let primaryText = Color.primary
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let tertiaryText = Color(uiColor: .tertiaryLabel)

    static let screenBackgroundTop = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1)
            : UIColor(red: 0.97, green: 0.97, blue: 0.99, alpha: 1)
    })

    static let screenBackgroundBottom = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.04, green: 0.04, blue: 0.08, alpha: 1)
            : UIColor(red: 0.93, green: 0.94, blue: 0.97, alpha: 1)
    })

    static var screenBackground: LinearGradient {
        LinearGradient(
            colors: [screenBackgroundTop, screenBackgroundBottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static let loginBackgroundTop = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1)
            : UIColor(red: 0.98, green: 0.97, blue: 0.98, alpha: 1)
    })

    static let loginBackgroundBottom = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.15, green: 0.03, blue: 0.05, alpha: 1)
            : UIColor(red: 0.96, green: 0.90, blue: 0.92, alpha: 1)
    })

    static var loginBackground: LinearGradient {
        LinearGradient(
            colors: [loginBackgroundTop, loginBackgroundBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static let playerBackgroundTop = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.04, green: 0.04, blue: 0.07, alpha: 1)
            : UIColor(red: 0.97, green: 0.96, blue: 0.98, alpha: 1)
    })

    static let playerBackgroundMid = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.10, green: 0.02, blue: 0.10, alpha: 1)
            : UIColor(red: 0.94, green: 0.91, blue: 0.95, alpha: 1)
    })

    static let playerBackgroundBottom = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.black
            : UIColor(red: 0.91, green: 0.93, blue: 0.97, alpha: 1)
    })

    static var playerBackground: LinearGradient {
        LinearGradient(
            colors: [playerBackgroundTop, playerBackgroundMid, playerBackgroundBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static let cardFill = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.07)
            : UIColor.black.withAlphaComponent(0.05)
    })

    static let cardFillStrong = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 0.10, alpha: 1)
            : UIColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 1)
    })

    static let controlFill = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.black.withAlphaComponent(0.07)
    })

    static let controlFillStrong = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.12)
            : UIColor.black.withAlphaComponent(0.10)
    })

    static let divider = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.07)
            : UIColor.black.withAlphaComponent(0.08)
    })

    static let inputFill = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.black.withAlphaComponent(0.06)
    })

    static let inverseFill = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? .white : .black
    })

    static let inverseText = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? .black : .white
    })

    static let miniPlayerBackground = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 0.07, alpha: 1)
            : UIColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1)
    })

    static let miniPlayerBorder = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.06)
            : UIColor.black.withAlphaComponent(0.08)
    })

    static let playerGlassOverlay = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.black.withAlphaComponent(0.34)
            : UIColor.white.withAlphaComponent(0.42)
    })

    static let playerGlassStroke = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor.black.withAlphaComponent(0.08)
    })

    static let progressTrack = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.10)
            : UIColor.black.withAlphaComponent(0.10)
    })

    static let progressBuffered = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.28)
            : UIColor.black.withAlphaComponent(0.24)
    })

    static let progressPlayed = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.92)
            : UIColor.black.withAlphaComponent(0.88)
    })

    static let playerHandle = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.28)
            : UIColor.black.withAlphaComponent(0.18)
    })
}

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            switch appState.authState {
            case .restoring:
                ProgressView("Loading your music...")
                    .tint(.primary)
                .task {
                    await appState.restoreSession()
                }
            case .guest, .signedIn:
                MainTabView()
                    .playlistPickerSheet(host: .main)
            }
        }
        .fullScreenCover(isPresented: $appState.isPlayerPresented, onDismiss: {
            appState.dismissPlayer()
        }) {
            if let nowPlaying = appState.nowPlaying {
                PlayerView(track: nowPlaying, playbackService: appState.playbackEngine)
                    .environmentObject(appState)
                    .playlistPickerSheet(host: .player)
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { appState.errorMessage != nil },
                set: { _ in appState.errorMessage = nil }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.errorMessage ?? "Unknown error")
        }
    }
}

// MARK: - MainTabView

private struct MainTabView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView {
                HomeView()
                    .tabItem { Label("Home", systemImage: "house.fill") }

                SearchView()
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }

                DownloadsView()
                    .tabItem { Label("Downloads", systemImage: "arrow.down.circle.fill") }

                LibraryView()
                    .tabItem { Label("Library", systemImage: "music.note.list") }
            }
            .toolbarColorScheme(colorScheme == .dark ? .dark : .light, for: .tabBar)

            // Persistent mini player sits between content and tab bar
            MiniPlayerContainer()
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.84), value: appState.nowPlaying?.id)
        .task {
            Self.configureTabBarAppearance(for: colorScheme)
        }
        .onChange(of: colorScheme) { _, updatedScheme in
            Self.configureTabBarAppearance(for: updatedScheme)
        }
    }

    private static func configureTabBarAppearance(for colorScheme: ColorScheme) {
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = UIBlurEffect(
            style: colorScheme == .dark ? .systemUltraThinMaterialDark : .systemUltraThinMaterialLight
        )
        appearance.backgroundColor = colorScheme == .dark
            ? UIColor(white: 0.05, alpha: 0.92)
            : UIColor(red: 0.98, green: 0.98, blue: 0.995, alpha: 0.92)
        appearance.shadowColor = .clear

        let item = UITabBarItemAppearance()
        let normalColor = colorScheme == .dark
            ? UIColor(white: 0.45, alpha: 1)
            : UIColor(red: 0.32, green: 0.32, blue: 0.38, alpha: 1)
        let selectedColor = colorScheme == .dark ? UIColor.white : UIColor.black
        item.normal.iconColor = normalColor
        item.normal.titleTextAttributes = [.foregroundColor: normalColor]
        item.selected.iconColor = selectedColor
        item.selected.titleTextAttributes = [.foregroundColor: selectedColor]

        appearance.stackedLayoutAppearance = item
        appearance.inlineLayoutAppearance = item
        appearance.compactInlineLayoutAppearance = item

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}

private struct MiniPlayerContainer: View {
    @EnvironmentObject private var appState: AppState
    
    var body: some View {
        if let nowPlaying = appState.nowPlaying {
            MiniPlayerBar(
                track: nowPlaying,
                playbackService: appState.playbackEngine,
                onTap: { appState.isPlayerPresented = true },
                onPreviousTap: { appState.playPreviousTrack() },
                onPlayPauseTap: { appState.togglePlayback() },
                onNextTap: { appState.playNextTrack() },
                onCloseTap: { appState.closeNowPlaying() }
            )
        // Sits just above the tab bar (tab bar ~49pt + safe area handled inside)
        .padding(.bottom, 49)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct PlaylistPickerSheetModifier: ViewModifier {
    @EnvironmentObject private var appState: AppState
    let host: AppState.PlaylistPickerHost

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: {
                appState.playlistPickerState != .hidden && appState.playlistPickerHost == host
            },
            set: { isPresented in
                if !isPresented, appState.playlistPickerHost == host {
                    appState.dismissPlaylistPicker()
                }
            }
        ), onDismiss: {
            if appState.playlistPickerHost == host {
                appState.dismissPlaylistPicker()
            }
        }) {
            PlaylistPickerSheet()
                .environmentObject(appState)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

private extension View {
    func playlistPickerSheet(host: AppState.PlaylistPickerHost) -> some View {
        modifier(PlaylistPickerSheetModifier(host: host))
    }
}

private struct PlaylistPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @State private var playlistName = ""
    @State private var addSongsQuery = ""
    @State private var addSongResults: [Track] = []
    @State private var addSongsTask: Task<Void, Never>?
    @State private var isSearchingSongs = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(appState.playlistPickerTrack == nil ? "Create playlist" : "Save to playlist")
                            .font(.title3.bold())
                            .foregroundStyle(AppTheme.primaryText)

                        Text(helperText)
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.secondaryText)
                    }

                    if isTargetingExistingPlaylist {
                        addSongsSection
                    } else if appState.playlistPickerTrack != nil, appState.customPlaylists.isEmpty == false {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Your playlists")
                                .font(.headline)
                                .foregroundStyle(AppTheme.primaryText)

                            VStack(spacing: 0) {
                                ForEach(Array(appState.customPlaylists.enumerated()), id: \.element.id) { index, playlist in
                                    playlistSelectionRow(playlist, isLast: index == appState.customPlaylists.count - 1)
                                }
                            }

                            Divider()
                                .overlay(AppTheme.divider)
                        }
                    }

                    if isTargetingExistingPlaylist == false {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(appState.playlistPickerTrack == nil ? "New playlist" : "Create new playlist")
                                .font(.headline)
                                .foregroundStyle(AppTheme.primaryText)

                            TextField("Playlist name", text: $playlistName)
                                .textInputAutocapitalization(.words)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(AppTheme.inputFill)
                                )
                                .foregroundStyle(AppTheme.primaryText)

                            Button {
                                if appState.createCustomPlaylist(named: playlistName) {
                                    dismiss()
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "music.note.list")
                                    Text(appState.playlistPickerTrack == nil ? "Create Playlist" : "Create & Add Song")
                                        .fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(AppTheme.accent)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            if let track = appState.playlistPickerTrack {
                                trackPreview(track)
                            }
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 20)
            }
            .background(AppTheme.screenBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        appState.dismissPlaylistPicker()
                        dismiss()
                    }
                    .foregroundStyle(AppTheme.accent)
                }
            }
            .onDisappear {
                addSongsTask?.cancel()
            }
        }
    }

    private var helperText: String {
        if let playlist = appState.playlistPickerTargetPlaylist {
            return "Search for songs and add them directly to \(playlist.title)."
        }

        if let track = appState.playlistPickerTrack {
            return "Add \(track.title) to an existing playlist or create a new one."
        }

        return "Create a playlist now and start filling it from search, home, downloads, or the player."
    }

    private var isTargetingExistingPlaylist: Bool {
        appState.playlistPickerTargetPlaylist != nil
    }

    private var addSongsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find songs")
                .font(.headline)
                .foregroundStyle(AppTheme.primaryText)

            TextField("Search songs to add", text: $addSongsQuery)
                .textInputAutocapitalization(.words)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(AppTheme.inputFill)
                )
                .foregroundStyle(AppTheme.primaryText)
                .onChange(of: addSongsQuery) { _, newValue in
                    scheduleSongSearch(for: newValue)
                }

            if isSearchingSongs {
                Text("Searching songs...")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.tertiaryText)
            } else if addSongsQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Type a song name, artist, or album to add tracks to this playlist.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.tertiaryText)
            } else if addSongResults.isEmpty {
                Text("No songs matched that search.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.tertiaryText)
            } else {
                VStack(spacing: 0) {
                    let visibleResults = Array(addSongResults.prefix(12))
                    ForEach(Array(visibleResults.enumerated()), id: \.element.id) { index, track in
                        addSongRow(track)

                        if index < visibleResults.count - 1 {
                            Divider()
                                .overlay(AppTheme.divider)
                                .padding(.leading, 60)
                        }
                    }
                }
            }
        }
    }

    private func addSongRow(_ track: Track) -> some View {
        HStack(spacing: 12) {
            AsyncArtworkView(url: track.artworkURL, cornerRadius: 10)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)

                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            if let playlist = appState.playlistPickerTargetPlaylist, appState.isTrack(track, in: playlist) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.green.opacity(0.92))
            } else {
                Button {
                    guard let playlist = appState.playlistPickerTargetPlaylist else { return }
                    appState.addTrack(track, to: playlist)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(AppTheme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
    }

    private func scheduleSongSearch(for query: String) {
        addSongsTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            isSearchingSongs = false
            addSongResults = []
            return
        }

        isSearchingSongs = true
        addSongsTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard Task.isCancelled == false else { return }
            let results = await appState.searchTracksForPlaylist(trimmed)
            guard Task.isCancelled == false else { return }
            await MainActor.run {
                addSongResults = results
                isSearchingSongs = false
            }
        }
    }

    private func trackPreview(_ track: Track) -> some View {
        HStack(spacing: 12) {
            AsyncArtworkView(url: track.artworkURL, cornerRadius: 10)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Spacer()
        }
        .padding(.vertical, 8)
    }

    private func playlistSelectionRow(_ playlist: Playlist, isLast: Bool) -> some View {
        Button {
            appState.addPlaylistPickerTrack(to: playlist)
            dismiss()
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    AsyncArtworkView(url: playlist.artworkURL, cornerRadius: 10)
                        .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(playlist.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.primaryText)
                            .lineLimit(1)

                        Text(playlist.itemCount == 1 ? "1 track" : "\(playlist.itemCount) tracks")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(AppTheme.accent)
                }
                .padding(.vertical, 8)

                if isLast == false {
                    Divider()
                        .overlay(AppTheme.divider)
                        .padding(.leading, 60)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - MiniPlayerBar (matches mockup)

private struct MiniPlayerBar: View {
    let track: Track
    @ObservedObject var playbackService: PlaybackService
    let onTap: () -> Void
    let onPreviousTap: () -> Void
    let onPlayPauseTap: () -> Void
    let onNextTap: () -> Void
    let onCloseTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Main row
            HStack(spacing: 0) {
                // Artwork + info — tappable to open player
                Button(action: onTap) {
                    HStack(spacing: 12) {
                        AsyncArtworkView(url: track.artworkURL, cornerRadius: 8)
                            .frame(width: 44, height: 44)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppTheme.primaryText)
                                .lineLimit(1)
                            Text(track.artist)
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: onCloseTap) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(AppTheme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(AppTheme.controlFill)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)

                // Transport controls
                HStack(spacing: 4) {
                    // Skip back
                    Button(action: onPreviousTap) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(playbackService.hasPreviousTrack ? AppTheme.primaryText : AppTheme.tertiaryText)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .disabled(!playbackService.hasPreviousTrack)

                    // Play / Pause — filled circle like mockup
                    Button(action: onPlayPauseTap) {
                        ZStack {
                            Circle()
                                .fill(Color(red: 1, green: 0.23, blue: 0.42))
                                .frame(width: 36, height: 36)

                            if playbackService.isResolvingStream {
                                ProgressView().tint(.white).scaleEffect(0.65)
                            } else {
                                Image(systemName: playbackService.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                                    .offset(x: playbackService.isPlaying ? 0 : 1)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    // Skip forward
                    Button(action: onNextTap) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(playbackService.hasNextTrack ? AppTheme.primaryText : AppTheme.tertiaryText)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .disabled(!playbackService.hasNextTrack)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Thin progress bar at very bottom of bar
            MiniProgressStrip(progress: playbackProgress)
        }
        .background(
            Rectangle()
                .fill(AppTheme.miniPlayerBackground)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(AppTheme.miniPlayerBorder)
                        .frame(height: 0.5)
                }
        )
    }

    private var playbackProgress: Double {
        guard playbackService.duration.isFinite, playbackService.duration > 0 else { return 0 }
        return min(max(playbackService.currentTime / playbackService.duration, 0), 1)
    }
}

// MARK: - MiniProgressStrip

private struct MiniProgressStrip: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            let clamped = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Rectangle().fill(AppTheme.progressTrack)
                Rectangle()
                    .fill(AppTheme.accent)
                    .frame(width: max(geo.size.width * clamped, 0))
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}
