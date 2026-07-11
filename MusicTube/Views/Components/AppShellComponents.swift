import SwiftUI
import UIKit

// MARK: - MainTabView

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState
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
        Group {
            if let nowPlaying = appState.nowPlaying, appState.isSearchFieldFocused == false {
                MiniPlayerBar(
                    track: nowPlaying,
                    playbackService: appState.playbackEngine,
                    onTap: { appState.isPlayerPresented = true },
                    onPreviousTap: { appState.playPreviousTrack() },
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
                                .background(Color(red: 1, green: 0.23, blue: 0.42))
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
                    .foregroundStyle(Color(red: 1, green: 0.23, blue: 0.42))
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
            AsyncArtworkView(url: track.artworkURL, cornerRadius: 10)
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
                        .foregroundStyle(Color(red: 1, green: 0.23, blue: 0.42))
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
                        .foregroundStyle(Color(red: 1, green: 0.23, blue: 0.42))
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
    let onPreviousTap: () -> Void
    let onPlayPauseTap: () -> Void
    let onNextTap: () -> Void
    let onCloseTap: () -> Void

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    // Artwork — opens full player
                    Button(action: onTap) {
                        AsyncArtworkView(url: track.artworkURL, cornerRadius: 11)
                            .frame(width: 50, height: 50)
                            .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open Now Playing for \(track.title)")

                    // Title and status — opens full player
                    Button(action: onTap) {
                        VStack(alignment: .leading, spacing: 3) {
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
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open Now Playing for \(track.title) by \(track.artist)")

                    // Controls
                    HStack(spacing: 4) {
                        // Previous
                        Button(action: onPreviousTap) {
                            Image(systemName: "backward.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(playbackService.hasPreviousTrack ? AppTheme.primaryText : AppTheme.tertiaryText)
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.plain)
                        .disabled(!playbackService.hasPreviousTrack)
                        .accessibilityLabel("Previous track")

                        // Play / Pause
                        Button(action: onPlayPauseTap) {
                            ZStack {
                                Circle()
                                    .fill(AppTheme.accent)
                                    .frame(width: 40, height: 40)
                                if playbackService.isResolvingStream {
                                    ProgressView().tint(.white).scaleEffect(0.65)
                                } else {
                                    Image(systemName: playbackService.isPlaying ? "pause.fill" : "play.fill")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(.white)
                                        .offset(x: playbackService.isPlaying ? 0 : 1.5)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: playbackService.isPlaying)
                        .accessibilityLabel(playbackService.isPlaying ? "Pause" : "Play")

                        // Next
                        Button(action: onNextTap) {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(playbackService.hasNextTrack ? AppTheme.primaryText : AppTheme.tertiaryText)
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.plain)
                        .disabled(!playbackService.hasNextTrack)
                        .accessibilityLabel("Next track")

                        // Close
                        Button(action: onCloseTap) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(AppTheme.secondaryText)
                                .frame(width: 28, height: 28)
                                .background(AppTheme.controlFillStrong)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close Now Playing")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

                // Progress capsule
                MiniProgressStrip(progress: playbackProgress)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 11)
            }

            if isShowingHeartBurst {
                MiniHeartBurstView()
                    .id(heartBurstID)
                    .transition(.scale(scale: 0.35).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .background {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(AppTheme.miniPlayerBackground.opacity(colorScheme == .dark ? 0.34 : 0.22))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(AppTheme.playerGlassOverlay.opacity(colorScheme == .dark ? 0.48 : 0.34))
                }
                .overlay(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.34 : 0.78),
                                    Color.white.opacity(colorScheme == .dark ? 0.13 : 0.32),
                                    Color.white.opacity(colorScheme == .dark ? 0.02 : 0.08),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .blendMode(.screen)
                }
                .overlay(alignment: .top) {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.36 : 0.92),
                                    Color.white.opacity(colorScheme == .dark ? 0.08 : 0.22),
                                    Color.clear
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 1.5)
                        .padding(.horizontal, 18)
                        .padding(.top, 1)
                        .blendMode(.screen)
                }
                .overlay(alignment: .topTrailing) {
                    Circle()
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.34))
                        .frame(width: 96, height: 96)
                        .blur(radius: 28)
                        .offset(x: 18, y: -48)
                        .blendMode(.screen)
                }
                .overlay(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [
                                    AppTheme.accent.opacity(colorScheme == .dark ? 0.24 : 0.16),
                                    Color.clear
                                ],
                                center: .bottomTrailing,
                                startRadius: 4,
                                endRadius: 180
                            )
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.20 : 0.70),
                                    AppTheme.miniPlayerBorder,
                                    AppTheme.accent.opacity(0.18)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.14), radius: 24, y: 12)
        .padding(.horizontal, 12)
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
