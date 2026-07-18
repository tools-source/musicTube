import SwiftUI
import UIKit

// MARK: - MainTabView

struct MainTabView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $coordinator.selectedTab) {
                HomeView(viewModel: coordinator.home)
                    .tabItem { Label("Home", systemImage: "house.fill") }
                    .tag(AppState.MainTab.home)

                SearchView(viewModel: coordinator.search)
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag(AppState.MainTab.search)

                LibraryView(viewModel: coordinator.library)
                    .tabItem { Label("Library", systemImage: "music.note.list") }
                    .tag(AppState.MainTab.library)

                DownloadsView(viewModel: coordinator.downloads)
                    .tabItem { Label("Downloads", systemImage: "arrow.down.circle.fill") }
                    .tag(AppState.MainTab.downloads)
            }
            .toolbarColorScheme(colorScheme == .dark ? .dark : .light, for: .tabBar)

            // Persistent mini player sits between content and tab bar
            MiniPlayerContainer()
        }
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
        let selectedColor = UIColor(red: 1, green: 0.23, blue: 0.42, alpha: 1)
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
        Group {
            if let nowPlaying = appState.nowPlaying, appState.isSearchFieldFocused == false {
                MiniPlayerBar(
                    track: nowPlaying,
                    playbackService: appState.playbackEngine,
                    onTap: { appState.isPlayerPresented = true },
                    onPlayPauseTap: { appState.togglePlayback() },
                    onNextTap: { appState.playNextTrack() },
                    onCloseTap: { appState.closeNowPlaying() }
                )
                .padding(.bottom, 57)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .bottom).combined(with: .opacity)
                ))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.84), value: appState.nowPlaying?.id)
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

extension View {
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
                                ForEach(appState.customPlaylists) { playlist in
                                    playlistSelectionRow(playlist, isLast: playlist.id == appState.customPlaylists.last?.id)
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
                                .appSurface(fill: AppTheme.inputFill)
                                .foregroundStyle(AppTheme.primaryText)

                            Button {
                                if appState.createCustomPlaylist(named: playlistName) {
                                    dismiss()
                                }
                            } label: {
                                Label(
                                    appState.playlistPickerTrack == nil ? "Create Playlist" : "Create & Add Song",
                                    systemImage: "music.note.list"
                                )
                            }
                            .buttonStyle(AppPrimaryActionButtonStyle())
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
                .appSurface(fill: AppTheme.inputFill)
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
                    ForEach(visibleResults) { track in
                        addSongRow(track)

                        if track.id != visibleResults.last?.id {
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
            AsyncArtworkView(url: track.artworkURL, cornerRadius: AppCornerRadius.artwork)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
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
            AsyncArtworkView(url: track.artworkURL, cornerRadius: AppCornerRadius.artwork)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)
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
                    AsyncArtworkView(url: playlist.artworkURL, cornerRadius: AppCornerRadius.artwork)
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

// MARK: - MiniPlayerBar

private struct MiniPlayerBar: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowingHeartBurst = false
    @State private var heartBurstID = 0

    let track: Track
    @ObservedObject var playbackService: PlaybackService
    let onTap: () -> Void
    let onPlayPauseTap: () -> Void
    let onNextTap: () -> Void
    let onCloseTap: () -> Void

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: AppSpacing.small) {
                    Button(action: onTap) {
                        HStack(spacing: 11) {
                            AsyncArtworkView(url: track.artworkURL, cornerRadius: 6)
                                .frame(width: 44, height: 44)
                                .shadow(color: .black.opacity(0.16), radius: 5, y: 2)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AppTheme.primaryText)
                                    .lineLimit(1)

                                Text(miniPlayerSubtitle)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(miniPlayerSubtitleColor)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open Now Playing for \(track.title) by \(track.artist)")

                    Button(action: onPlayPauseTap) {
                        ZStack {
                            if playbackService.isResolvingStream {
                                ProgressView()
                                    .tint(AppTheme.primaryText)
                                    .scaleEffect(0.72)
                            } else {
                                Image(systemName: playbackService.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(AppTheme.primaryText)
                                    .offset(x: playbackService.isPlaying ? 0 : 1.5)
                            }
                        }
                        .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.plain)
                    .animation(.spring(response: 0.28, dampingFraction: 0.7), value: playbackService.isPlaying)
                    .accessibilityLabel(playbackService.isPlaying ? "Pause" : "Play")

                    Button(action: onNextTap) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(playbackService.hasNextTrack ? AppTheme.primaryText : AppTheme.tertiaryText)
                            .frame(width: 38, height: 42)
                    }
                    .buttonStyle(.plain)
                    .disabled(!playbackService.hasNextTrack)
                    .accessibilityLabel("Next track")

                    Button(action: onCloseTap) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(AppTheme.secondaryText)
                            .frame(width: 30, height: 42)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close Now Playing")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                MiniProgressStrip(progress: playbackProgress)
                    .padding(.horizontal, 1)
            }

            if isShowingHeartBurst {
                MiniHeartBurstView()
                    .id(heartBurstID)
                    .transition(.scale(scale: 0.35).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(AppTheme.miniPlayerBackground.opacity(colorScheme == .dark ? 0.86 : 0.92))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(AppTheme.miniPlayerBorder, lineWidth: 1)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.10), radius: 16, y: 8)
        .padding(.horizontal, 8)
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded { likeWithHeartBurst() }
        )
    }

    private var playbackProgress: Double {
        guard playbackService.duration.isFinite, playbackService.duration > 0 else { return 0 }
        return min(max(playbackService.currentTime / playbackService.duration, 0), 1)
    }

    private var miniPlayerSubtitle: String {
        if playbackService.isResolvingStream ||
            (playbackService.isBufferingPlayback && playbackService.currentTime < 1) {
            return "Starting..."
        }

        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return artist.isEmpty ? "MusicTube" : artist
    }

    private var miniPlayerSubtitleColor: Color {
        miniPlayerSubtitle == "Starting..." ? AppTheme.accent : AppTheme.secondaryText
    }

    private func likeWithHeartBurst() {
        appState.likeTrackIfNeeded(track)
        heartBurstID += 1
        withAnimation(.spring(response: 0.24, dampingFraction: 0.62)) {
            isShowingHeartBurst = true
        }

        let currentID = heartBurstID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard heartBurstID == currentID else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                isShowingHeartBurst = false
            }
        }
    }
}

private struct MiniHeartBurstView: View {
    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 58, weight: .bold))
            .foregroundStyle(AppTheme.accent)
            .shadow(color: AppTheme.accent.opacity(0.35), radius: 16, y: 6)
    }
}

// MARK: - MiniProgressStrip

private struct MiniProgressStrip: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            let clamped = min(max(progress, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppTheme.progressTrack)
                Capsule()
                    .fill(AppTheme.accent)
                    .frame(width: max(geo.size.width * clamped, clamped > 0 ? 6 : 0))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}
