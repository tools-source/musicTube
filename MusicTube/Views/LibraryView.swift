import SwiftUI

struct LibraryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: AppState
    @State private var isShowingDeleteDataConfirmation = false
    @State private var dropTargetSection: AppLibrarySection?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 24) {
                    AccountSectionView(isShowingDeleteDataConfirmation: $isShowingDeleteDataConfirmation)

                    ForEach(appState.visibleLibrarySectionOrder) { section in
                        reorderableSection(section)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, bottomSpacing)
                .animation(.spring(response: 0.28, dampingFraction: 0.84), value: appState.librarySectionOrder)
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(playlist: playlist)
            }
            .navigationDestination(for: MusicCollection.self) { collection in
                CollectionDetailView(collection: collection)
            }
            .navigationDestination(for: String.self) { route in
                if route == "HistoryDetail" {
                    HistoryDetailView()
                }
            }
            .refreshable {
                await appState.refreshLibrary(forceRefresh: true)
            }
            .task {
                if appState.hasLoadedLibrary == false, appState.isLoadingPlaylists == false {
                    await appState.refreshLibrary()
                }
            }
            .background(libraryBackground.ignoresSafeArea())
            .alert(
                "Delete MusicTube Data from This iPhone?",
                isPresented: $isShowingDeleteDataConfirmation
            ) {
                Button("Delete Data", role: .destructive) {
                    Task {
                        await appState.deleteCurrentAccountData()
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This removes your local library, playlists, downloads, likes, and listening history from this iPhone. Your Google and YouTube accounts are not affected.")
            }
        }
    }

    private var bottomSpacing: CGFloat {
        appState.nowPlaying == nil ? 108 : 174
    }

    private var libraryBackground: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [
                    Color.black,
                    Color(red: 0.03, green: 0.03, blue: 0.05)
                ]
                : [
                    Color(red: 0.97, green: 0.97, blue: 0.99),
                    Color(red: 0.93, green: 0.94, blue: 0.97)
                ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    @ViewBuilder
    private func reorderableSection(_ section: AppLibrarySection) -> some View {
        librarySectionContent(for: section, isHighlighted: dropTargetSection == section)
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .draggable(section.rawValue)
            .dropDestination(for: String.self) { items, _ in
                guard let droppedValue = items.first,
                      let draggedSection = AppLibrarySection(rawValue: droppedValue) else {
                    dropTargetSection = nil
                    return false
                }

                dropTargetSection = nil
                appState.moveLibrarySection(draggedSection, to: section)
                return true
            } isTargeted: { isTargeted in
                if isTargeted {
                    dropTargetSection = section
                } else if dropTargetSection == section {
                    dropTargetSection = nil
                }
            }
    }

    @ViewBuilder
    private func librarySectionContent(for section: AppLibrarySection, isHighlighted: Bool) -> some View {
        switch section {
        case .quickActions:
            QuickActionsSectionView(showsDragHandle: true, isHighlighted: isHighlighted)
        case .history:
            HistorySectionView(showsDragHandle: true, isHighlighted: isHighlighted)
        case .likedSongs:
            LikedSongsSectionView(showsDragHandle: true, isHighlighted: isHighlighted)
        case .savedSongs:
            SavedSongsSectionView(showsDragHandle: true, isHighlighted: isHighlighted)
        case .customPlaylists:
            CustomPlaylistsSectionView(showsDragHandle: true, isHighlighted: isHighlighted)
        case .savedCollections:
            SavedCollectionsSectionView(showsDragHandle: true, isHighlighted: isHighlighted)
        }
    }
}

private struct LibrarySectionView<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    var showsDragHandle = false
    var isHighlighted = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.title3.bold())
                    .foregroundStyle(Color.primary)

                Spacer(minLength: 12)

                if showsDragHandle {
                    Image(systemName: "line.3.horizontal")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(colorScheme == .dark ? Color.white.opacity(isHighlighted ? 0.14 : 0.08) : Color.black.opacity(isHighlighted ? 0.10 : 0.05))
                        )
                        .accessibilityHidden(true)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(colorScheme == .dark ? Color.white.opacity(0.03) : Color.white.opacity(0.38))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(
                                colorScheme == .dark
                                    ? Color.white.opacity(isHighlighted ? 0.16 : 0.06)
                                    : Color.black.opacity(isHighlighted ? 0.16 : 0.07),
                                lineWidth: 1
                            )
                    }
                    .overlay {
                        if isHighlighted {
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .strokeBorder(Color(red: 1, green: 0.23, blue: 0.42).opacity(0.42), lineWidth: 2)
                        }
                    }
            )
            .scaleEffect(isHighlighted ? 1.01 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.84), value: isHighlighted)
        }
    }
}

private struct LibraryLoadingLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(.primary)
            Text(text)
                .foregroundStyle(Color.secondary)
        }
    }
}

private struct AccountSectionView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var isShowingDeleteDataConfirmation: Bool

    var body: some View {
        LibrarySectionView(title: appState.isYouTubeConnected ? "Account" : "Guest Mode") {
            VStack(alignment: .leading, spacing: 16) {
                if let user = appState.user {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(user.name)
                            .font(.headline)
                            .foregroundStyle(Color.primary)

                        Text(user.email)
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your library is local and ready to use.")
                            .font(.headline)
                            .foregroundStyle(Color.primary)

                        Text("Connect YouTube anytime to import your account library while keeping your MusicTube guest library and playlists on this device.")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()
                    .overlay(Color.secondary.opacity(0.2))

                if let libraryStatusMessage = appState.libraryStatusMessage {
                    Text(libraryStatusMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if appState.isYouTubeConnected {
                    Button {
                        Task { await appState.switchAccount() }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.left.arrow.right")
                            Text("Switch Account")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color(red: 1, green: 0.23, blue: 0.42))
                        .foregroundStyle(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.isLoading)

                    Button("Disconnect YouTube", role: .destructive) {
                        Task {
                            await appState.signOut()
                        }
                    }
                    .font(.headline)
                } else {
                    Button {
                        Task {
                            await appState.signIn()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                            Text("Connect YouTube")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(red: 1, green: 0.23, blue: 0.42))
                        .foregroundStyle(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.isLoading)
                }

                Button("Delete MusicTube Data", role: .destructive) {
                    isShowingDeleteDataConfirmation = true
                }
                .font(.headline)
                .disabled(appState.isDeletingAccountData)

                if appState.isDeletingAccountData {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(.primary)
                        Text("Deleting local MusicTube data...")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
    }
}

private struct QuickActionsSectionView: View {
    @EnvironmentObject private var appState: AppState
    var showsDragHandle = false
    var isHighlighted = false

    var body: some View {
        LibrarySectionView(
            title: "Quick Actions",
            showsDragHandle: showsDragHandle,
            isHighlighted: isHighlighted
        ) {
            Button {
                appState.presentPlaylistCreator()
            } label: {
                HStack {
                    Image(systemName: "music.note.list")
                    Text("Create Playlist")
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "plus.circle.fill")
                }
                .foregroundStyle(Color.primary)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}

private struct HistorySectionView: View {
    @EnvironmentObject private var appState: AppState
    var showsDragHandle = false
    var isHighlighted = false

    var body: some View {
        LibrarySectionView(
            title: "History",
            showsDragHandle: showsDragHandle,
            isHighlighted: isHighlighted
        ) {
            Toggle(isOn: Binding(
                get: { appState.isHistoryEnabled },
                set: { _ in appState.toggleHistoryEnabled() }
            )) {
                Label("Track recently played", systemImage: "clock")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary)
            }
            .tint(Color(red: 1, green: 0.23, blue: 0.42))

            if appState.isHistoryEnabled && appState.historyTracks.isEmpty == false {
                Divider().overlay(Color.secondary.opacity(0.18))

                NavigationLink(value: "HistoryDetail") {
                    HStack(spacing: 12) {
                        Image(systemName: "clock.fill")
                            .font(.title2)
                            .foregroundStyle(Color.primary)
                            .frame(width: 52, height: 52)
                            .background(Color.primary.opacity(0.1))
                            .cornerRadius(10)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Recently Played")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.primary)
                                .lineLimit(1)

                            Text("\(appState.historyTracks.count) songs")
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                        }

                        Spacer(minLength: 10)

                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(Color.secondary)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if appState.isHistoryEnabled == false {
                Text("Recently played songs won't be tracked.")
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
            }
        }
    }
}

private struct LikedSongsSectionView: View {
    @EnvironmentObject private var appState: AppState
    var showsDragHandle = false
    var isHighlighted = false

    var body: some View {
        LibrarySectionView(
            title: "Liked Songs",
            showsDragHandle: showsDragHandle,
            isHighlighted: isHighlighted
        ) {
            if appState.isLoadingPlaylists && appState.playlists.isEmpty {
                LibraryLoadingLabel(text: "Syncing liked songs...")
            } else if let likedSongs = appState.likedSongsPlaylist {
                VStack(alignment: .leading, spacing: 10) {
                    NavigationLink(value: likedSongs) {
                        PlaylistRow(playlist: likedSongs)
                    }
                    .buttonStyle(.plain)

                    if appState.isSyncingLikedSongs {
                        LibraryLoadingLabel(text: "Importing the rest of your YouTube liked songs...")
                    }
                }
            } else {
                Text("Tap the heart on a song to keep it here.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }
        }
    }
}

private struct SavedSongsSectionView: View {
    @EnvironmentObject private var appState: AppState
    var showsDragHandle = false
    var isHighlighted = false

    var body: some View {
        LibrarySectionView(
            title: "Saved Songs",
            showsDragHandle: showsDragHandle,
            isHighlighted: isHighlighted
        ) {
            if let savedSongs = appState.savedSongsPlaylist {
                NavigationLink(value: savedSongs) {
                    PlaylistRow(playlist: savedSongs)
                }
                .buttonStyle(.plain)
            } else {
                Text("Save any song from Search, Home, Downloads, or the Player and it’ll show up here.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }
        }
    }
}

private struct CustomPlaylistsSectionView: View {
    @EnvironmentObject private var appState: AppState
    var showsDragHandle = false
    var isHighlighted = false

    var body: some View {
        LibrarySectionView(
            title: "Your Playlists",
            showsDragHandle: showsDragHandle,
            isHighlighted: isHighlighted
        ) {
            if appState.customPlaylists.isEmpty {
                Text("Create playlists and add tracks from anywhere in the app.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(appState.customPlaylists.enumerated()), id: \.element.id) { index, playlist in
                        NavigationLink(value: playlist) {
                            PlaylistRow(playlist: playlist) {
                                appState.downloadPlaylist(playlist)
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                appState.deleteCustomPlaylist(playlist)
                            } label: {
                                Label("Delete Playlist", systemImage: "trash")
                            }
                        }

                        if index < appState.customPlaylists.count - 1 {
                            Divider()
                                .overlay(Color.secondary.opacity(0.18))
                                .padding(.leading, 64)
                        }
                    }
                }
            }
        }
    }
}

private struct SavedCollectionsSectionView: View {
    @EnvironmentObject private var appState: AppState
    var showsDragHandle = false
    var isHighlighted = false

    var body: some View {
        LibrarySectionView(
            title: "Saved Collections",
            showsDragHandle: showsDragHandle,
            isHighlighted: isHighlighted
        ) {
            if appState.savedCollections.isEmpty {
                Text("Save playlists, albums, and artists from Search for quick access later.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(appState.savedCollections.enumerated()), id: \.element.id) { index, collection in
                        NavigationLink(value: collection) {
                            SavedCollectionRow(collection: collection)
                        }
                        .buttonStyle(.plain)

                        if index < appState.savedCollections.count - 1 {
                            Divider()
                                .overlay(Color.secondary.opacity(0.18))
                                .padding(.leading, 64)
                        }
                    }
                }
            }
        }
    }
}

private struct PlaylistRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var downloadService = DownloadService.shared
    let playlist: Playlist
    var onDownload: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            AsyncArtworkView(url: playlist.artworkURL, cornerRadius: 10)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                Text(itemCountLabel)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }

            Spacer(minLength: 10)

            if let onDownload {
                SourceDownloadButton(
                    totalCount: playlist.itemCount,
                    downloadedCount: downloadService.downloadCount(for: playlistDownloadSource),
                    pendingCount: downloadService.pendingRequestCount(for: playlistDownloadSource),
                    isPreparing: downloadService.isPreparing(source: playlistDownloadSource),
                    isDownloading: downloadService.isDownloading(source: playlistDownloadSource),
                    size: 36,
                    foregroundColor: Color.primary,
                    backgroundColor: colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08),
                    action: onDownload
                )
            }

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.secondary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var itemCountLabel: String {
        switch playlist.kind {
        case .likedMusic:
            return playlist.itemCount == 1 ? "1 song" : "\(playlist.itemCount) songs"
        case .uploads:
            return playlist.itemCount == 1 ? "1 upload" : "\(playlist.itemCount) uploads"
        case .savedSongs:
            return playlist.itemCount == 1 ? "1 saved song" : "\(playlist.itemCount) saved songs"
        case .custom:
            return playlist.itemCount == 1 ? "1 track" : "\(playlist.itemCount) tracks"
        case .standard:
            return playlist.itemCount == 1 ? "1 track" : "\(playlist.itemCount) tracks"
        }
    }

    private var playlistDownloadSource: DownloadSource {
        DownloadSource(
            id: "playlist:\(playlist.id)",
            title: playlist.title,
            kind: .playlist
        )
    }
}

private struct SavedCollectionRow: View {
    let collection: MusicCollection

    var body: some View {
        HStack(spacing: 12) {
            AsyncArtworkView(url: collection.artworkURL, cornerRadius: 10)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(collection.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.secondary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts: [String] = []
        switch collection.kind {
        case .playlist: parts.append("Playlist")
        case .album: parts.append("Album")
        case .artist: parts.append("Artist")
        }
        if collection.subtitle.isEmpty == false {
            parts.append(collection.subtitle)
        }
        if collection.itemCount > 0 {
            parts.append(collection.itemCount == 1 ? "1 track" : "\(collection.itemCount) tracks")
        }
        return parts.joined(separator: " · ")
    }
}

struct PlaylistDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var downloadService = DownloadService.shared
    let playlist: Playlist

    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var isEditSheetPresented = false
    @State private var editedPlaylistName = ""

    private var currentPlaylist: Playlist {
        appState.playlists.first(where: { $0.id == playlist.id }) ?? playlist
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                if !isLoading && !tracks.isEmpty {
                    playbackActionsRow(tracks: tracks)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }

                if isLoading {
                    loadingCard("Loading playlist tracks...")
                } else if tracks.isEmpty {
                    emptyCard("This playlist is empty for now.")
                } else {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        playlistTrackRow(track, index: index)

                        if index < tracks.count - 1 {
                            Divider()
                                .overlay(Color.secondary.opacity(0.18))
                                .padding(.leading, 64)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, appState.nowPlaying == nil ? 108 : 174)
        }
        .background(detailBackground)
        .navigationTitle(currentPlaylist.title)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                SourceDownloadButton(
                    totalCount: playlistDownloadTotalCount,
                    downloadedCount: downloadService.downloadCount(for: playlistDownloadSource),
                    pendingCount: downloadService.pendingRequestCount(for: playlistDownloadSource),
                    isPreparing: downloadService.isPreparing(source: playlistDownloadSource),
                    isDownloading: downloadService.isDownloading(source: playlistDownloadSource),
                    size: 32,
                    foregroundColor: Color.primary,
                    backgroundColor: .clear
                ) {
                    appState.downloadPlaylist(currentPlaylist)
                }

                if playlist.kind == .custom {
                    Menu {
                        Button {
                            editedPlaylistName = currentPlaylist.title
                            isEditSheetPresented = true
                        } label: {
                            Label("Edit Playlist", systemImage: "pencil")
                        }

                        Button {
                            appState.presentPlaylistSongAdder(for: currentPlaylist)
                        } label: {
                            Label("Add Songs", systemImage: "plus.circle")
                        }

                        Button(role: .destructive) {
                            appState.deleteCustomPlaylist(currentPlaylist)
                            dismiss()
                        } label: {
                            Label("Delete Playlist", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(Color(red: 1, green: 0.23, blue: 0.42))
                    }
                }
            }
        }
        .sheet(isPresented: $isEditSheetPresented) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Playlist name")
                        .font(.headline)
                        .foregroundStyle(Color.primary)

                    TextField("Playlist name", text: $editedPlaylistName)
                        .textInputAutocapitalization(.words)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .foregroundStyle(Color.primary)

                    Spacer()
                }
                .padding(20)
                .background(detailBackground)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            isEditSheetPresented = false
                        }
                        .foregroundStyle(Color.secondary)
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if appState.renameCustomPlaylist(currentPlaylist, to: editedPlaylistName) {
                                isEditSheetPresented = false
                            }
                        }
                        .foregroundStyle(Color(red: 1, green: 0.23, blue: 0.42))
                        .disabled(editedPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.height(220)])
        }
        .task {
            await loadInitialTracks()
        }
        .onChange(of: appState.isSyncingLikedSongs) { _, isSyncing in
            guard playlist.kind == .likedMusic, isSyncing == false else { return }
            Task {
                tracks = await appState.loadPlaylistItems(
                    for: playlist,
                    forceRefresh: false,
                    surfaceErrors: false
                )
                prefetchVisibleTracks(from: tracks)
            }
        }
        .refreshable {
            tracks = await appState.loadPlaylistItems(for: playlist, forceRefresh: true)
            isLoading = false
            prefetchVisibleTracks(from: tracks)
        }
    }

    private var detailBackground: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color.black, Color(red: 0.03, green: 0.03, blue: 0.05)]
                : [Color(red: 0.97, green: 0.97, blue: 0.99), Color(red: 0.93, green: 0.94, blue: 0.97)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private func playbackActionsRow(tracks: [Track]) -> some View {
        HStack(spacing: 12) {
            Button {
                guard let first = tracks.first else { return }
                if appState.playbackEngine.shuffleMode { appState.toggleShuffle() }
                appState.play(track: first, queue: tracks)
            } label: {
                Label("Play All", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(red: 1, green: 0.23, blue: 0.42)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Button {
                guard let first = tracks.first else { return }
                if appState.playbackEngine.shuffleMode == false { appState.toggleShuffle() }
                appState.play(track: first, queue: tracks)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.08)))
                    .foregroundStyle(Color.primary)
            }
            .buttonStyle(.plain)
        }
    }

    private func loadingCard(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(.primary)
            Text(text)
                .foregroundStyle(Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
    }

    private func emptyCard(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
    }

    @ViewBuilder
    private func playlistTrackRow(_ track: Track, index: Int) -> some View {
        if playlist.kind == .custom {
            editableTrackRow(track)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        removeTrackFromVisiblePlaylist(track)
                    } label: {
                        Label("Remove", systemImage: "minus.circle")
                    }
                }
        } else {
            let playlistSource = DownloadSource(
                id: "playlist:\(currentPlaylist.id)",
                title: currentPlaylist.title,
                kind: .playlist
            )
            // Enable prefetch-on-appear so every row that scrolls into view warms its
            // stream URL, guaranteeing near-instant playback whenever the user taps play.
            TrackRowView(
                track: track,
                showsNowPlayingIndicator: true,
                showsDownloadButton: true,
                downloadSource: playlistSource,
                downloadSourceTrackIndex: index,
                prefetchPlaybackOnAppear: true
            ) {
                appState.play(track: track, queue: tracks)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                playlistTrackSwipeAction(for: track)
            }
        }
    }

    @ViewBuilder
    private func playlistTrackSwipeAction(for track: Track) -> some View {
        switch playlist.kind {
        case .likedMusic:
            Button(role: .destructive) {
                appState.toggleLike(for: track)
                tracks.removeAll { $0.playbackKey == track.playbackKey }
            } label: {
                Label("Unlike", systemImage: "heart.slash")
            }
        case .savedSongs:
            Button(role: .destructive) {
                appState.toggleTrackSaved(track)
                tracks.removeAll { $0.playbackKey == track.playbackKey }
            } label: {
                Label("Unsave", systemImage: "bookmark.slash")
            }
        default:
            EmptyView()
        }
    }

    private func removeTrackFromVisiblePlaylist(_ track: Track) {
        appState.removeTrack(track, from: playlist)
        tracks.removeAll { $0.playbackKey == track.playbackKey }
    }

    private func editableTrackRow(_ track: Track) -> some View {
        let isCurrentTrack = appState.nowPlaying?.playbackKey == track.playbackKey
        let isCurrentlyPlaying = isCurrentTrack && appState.isPlaying

        return HStack(spacing: 12) {
            Button {
                appState.play(track: track, queue: tracks)
            } label: {
                HStack(spacing: 12) {
                    AsyncArtworkView(url: track.artworkURL, cornerRadius: 10)
                        .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isCurrentTrack ? Color(red: 1, green: 0.24, blue: 0.43) : Color.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        HStack(spacing: 4) {
                            if isCurrentlyPlaying {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color(red: 1, green: 0.24, blue: 0.43))
                                Text("Playing")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color(red: 1, green: 0.24, blue: 0.43))
                            } else if isCurrentTrack {
                                Image(systemName: "speaker.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color(red: 1, green: 0.24, blue: 0.43).opacity(0.7))
                                Text("Paused")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color(red: 1, green: 0.24, blue: 0.43).opacity(0.7))
                            }

                            if let duration = track.formattedDuration {
                                Text(duration)
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                                    .fixedSize()
                            }

                            if let views = track.formattedViewCount {
                                Text("· \(views)")
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                                    .fixedSize()
                            }
                        }
                    }

                    Spacer(minLength: 8)
                }
            }
            .buttonStyle(.plain)

            DownloadButton(track: track, size: 36)

            Button {
                removeTrackFromVisiblePlaylist(track)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.red.opacity(0.92))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.red.opacity(0.14)))
            }
            .buttonStyle(.plain)

            Button {
                if isCurrentTrack {
                    appState.togglePlayback()
                } else {
                    appState.play(track: track, queue: tracks)
                }
            } label: {
                Image(systemName: isCurrentlyPlaying ? "pause.fill" : "play.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(Color(red: 1, green: 0.24, blue: 0.43))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isCurrentTrack
                      ? Color(red: 1, green: 0.24, blue: 0.43).opacity(0.07)
                      : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            isCurrentTrack
                                ? Color(red: 1, green: 0.24, blue: 0.43).opacity(0.38)
                                : Color.clear,
                            lineWidth: 1.5
                        )
                )
        )
        .padding(.horizontal, -10)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isCurrentTrack)
    }

    private func loadInitialTracks() async {
        guard tracks.isEmpty else { return }

        let initialTracks = await appState.loadPlaylistItems(for: playlist, forceRefresh: false)
        tracks = initialTracks
        isLoading = false
        prefetchVisibleTracks(from: initialTracks)

        guard playlist.kind == .likedMusic else { return }
        guard appState.isSyncingLikedSongs == false else { return }

        let refreshedTracks = await appState.loadPlaylistItems(
            for: playlist,
            forceRefresh: true,
            surfaceErrors: false
        )
        guard refreshedTracks != initialTracks else { return }
        tracks = refreshedTracks
        prefetchVisibleTracks(from: refreshedTracks)
    }

    private func prefetchVisibleTracks(from tracks: [Track]) {
        // Warm the first 10 tracks so the user can tap any visible row instantly,
        // even before the per-row .task prefetch fires.
        let warmTracks = Array(tracks.prefix(10))
        guard warmTracks.isEmpty == false else { return }
        appState.prefetchPlayback(for: warmTracks)
    }

    private var playlistDownloadSource: DownloadSource {
        DownloadSource(
            id: "playlist:\(currentPlaylist.id)",
            title: currentPlaylist.title,
            kind: .playlist
        )
    }

    private var playlistDownloadTotalCount: Int {
        max(currentPlaylist.itemCount, tracks.count)
    }
}

private struct SourceDownloadButton: View {
    let totalCount: Int
    let downloadedCount: Int
    let pendingCount: Int
    let isPreparing: Bool
    let isDownloading: Bool
    let size: CGFloat
    let foregroundColor: Color
    let backgroundColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(backgroundColor)
                    .frame(width: size, height: size)

                icon
                    .frame(width: size, height: size)
            }
            .overlay(alignment: .bottomTrailing) {
                if let badgeText {
                    Text(badgeText)
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .foregroundStyle(badgeForegroundColor)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(badgeBackgroundColor))
                        .padding(2)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isBusy || isComplete)
    }

    @ViewBuilder
    private var icon: some View {
        if isBusy {
            ProgressView()
                .controlSize(.small)
                .tint(foregroundColor)
        } else if isComplete {
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(foregroundColor)
        } else if downloadedCount > 0 {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: size * 0.54, weight: .semibold))
                .foregroundStyle(foregroundColor)
        } else {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: size * 0.54, weight: .semibold))
                .foregroundStyle(foregroundColor)
        }
    }

    private var claimedCount: Int {
        min(totalCount, downloadedCount + pendingCount)
    }

    private var isBusy: Bool {
        isPreparing || isDownloading
    }

    private var isComplete: Bool {
        totalCount > 0 && downloadedCount >= totalCount && isBusy == false
    }

    private var badgeText: String? {
        guard totalCount > 0 else { return nil }
        guard isBusy || downloadedCount > 0 else { return nil }
        return "\(max(downloadedCount, claimedCount))/\(totalCount)"
    }

    private var badgeBackgroundColor: Color {
        isComplete ? AppTheme.primaryText : AppTheme.controlFillStrong
    }

    private var badgeForegroundColor: Color {
        isComplete ? AppTheme.inverseText : AppTheme.primaryText
    }
}

struct HistoryDetailView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: AppState
    @State private var isShowingClearConfirmation = false

    var body: some View {
        content
        .background(
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color.black, Color(red: 0.03, green: 0.03, blue: 0.05)]
                    : [Color(red: 0.97, green: 0.97, blue: 0.99), Color(red: 0.93, green: 0.94, blue: 0.97)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .navigationTitle("Recently Played")
        .toolbar {
            if !appState.historyTracks.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isShowingClearConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(AppTheme.accent)
                    }
                }
            }
        }
        .alert(
            "Clear recently played?",
            isPresented: $isShowingClearConfirmation
        ) {
            Button("Clear History", role: .destructive) {
                appState.clearHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove your listening history from this device.")
        }
    }
    
    @ViewBuilder
    private var content: some View {
        if appState.historyTracks.isEmpty {
            emptyState
        } else {
            historyList
        }
    }
    
    private var emptyState: some View {
        ScrollView(showsIndicators: false) {
            Text("No history yet.")
                .foregroundStyle(Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                )
                .padding(.horizontal, 20)
                .padding(.top, 12)
        }
    }
    
    private var historyList: some View {
        List {
            ForEach(appState.historyTracks, id: \.id) { track in
                TrackRowView(
                    track: track,
                    showsNowPlayingIndicator: true,
                    showsDownloadButton: true,
                    prefetchPlaybackOnAppear: true
                ) {
                    appState.play(track: track, queue: appState.historyTracks)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        appState.removeHistoryTrack(track)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.visible)
                .listRowSeparatorTint(Color.secondary.opacity(0.18))
                .alignmentGuide(.listRowSeparatorLeading) { _ in 64 }
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            }
            
            Color.clear
                .frame(height: appState.nowPlaying == nil ? 108 : 174)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .padding(.top, 4)
    }
}

struct CollectionDetailView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var downloadService = DownloadService.shared
    let collection: MusicCollection

    @State private var tracks: [Track] = []
    @State private var isLoading = true

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 14) {
                headerCard

                if !isLoading && !tracks.isEmpty {
                    collectionPlaybackActionsRow(tracks: tracks)
                        .padding(.horizontal, 0)
                }

                if isLoading {
                    loadingCard("Loading \(collectionTitleLowercased) tracks...")
                } else if tracks.isEmpty {
                    loadingCard("No playable songs were found for this \(collectionTitleLowercased).")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            TrackRowView(
                                track: track,
                                showsNowPlayingIndicator: true,
                                showsDownloadButton: true,
                                downloadSource: DownloadSource(
                                    id: collection.id,
                                    title: collection.title,
                                    kind: collection.kind
                                ),
                                downloadSourceTrackIndex: index,
                                prefetchPlaybackOnAppear: true
                            ) {
                                appState.play(track: track, queue: tracks)
                            }

                            if index < tracks.count - 1 {
                                Divider()
                                    .overlay(AppTheme.divider)
                                    .padding(.leading, 64)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, appState.nowPlaying == nil ? 108 : 174)
        }
        .background(AppTheme.screenBackground.ignoresSafeArea())
        .navigationTitle(collection.title)
        .task {
            guard tracks.isEmpty else { return }
            tracks = await appState.loadCollectionItems(for: collection)
            isLoading = false
            prefetchVisibleTracks(from: tracks)
        }
        .refreshable {
            tracks = await appState.loadCollectionItems(for: collection, forceRefresh: true)
            isLoading = false
            prefetchVisibleTracks(from: tracks)
        }
    }

    private var headerCard: some View {
        HStack(spacing: 14) {
            AsyncArtworkView(url: collection.artworkURL, cornerRadius: 18)
                .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 6) {
                Text(collectionKindLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.tertiaryText)

                Text(collection.title)
                    .font(.headline)
                    .foregroundStyle(AppTheme.primaryText)

                if collection.subtitle.isEmpty == false {
                    Text(collection.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(2)
                }
            }

            Spacer()

            HStack(spacing: 10) {
                SourceDownloadButton(
                    totalCount: collectionDownloadTotalCount,
                    downloadedCount: downloadService.downloadCount(for: collectionDownloadSource),
                    pendingCount: downloadService.pendingRequestCount(for: collectionDownloadSource),
                    isPreparing: downloadService.isPreparing(source: collectionDownloadSource),
                    isDownloading: downloadService.isDownloading(source: collectionDownloadSource),
                    size: 40,
                    foregroundColor: AppTheme.primaryText,
                    backgroundColor: AppTheme.controlFill
                ) {
                    appState.downloadCollection(collection)
                }

                Button {
                    appState.toggleCollectionSaved(collection)
                } label: {
                    Image(systemName: appState.isCollectionSaved(collection) ? "bookmark.fill" : "bookmark")
                        .font(.headline)
                        .foregroundStyle(appState.isCollectionSaved(collection) ? AppTheme.accent : AppTheme.secondaryText)
                        .frame(width: 40, height: 40)
                        .background(AppTheme.controlFill)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(AppTheme.cardFill)
        )
    }

    private var collectionKindLabel: String {
        switch collection.kind {
        case .playlist: return "Playlist"
        case .album: return "Album"
        case .artist: return "Artist"
        }
    }

    private var collectionTitleLowercased: String {
        collectionKindLabel.lowercased()
    }

    private var collectionDownloadSource: DownloadSource {
        DownloadSource(id: collection.id, title: collection.title, kind: collection.kind)
    }

    private var collectionDownloadTotalCount: Int {
        max(collection.itemCount, tracks.count)
    }

    private func collectionPlaybackActionsRow(tracks: [Track]) -> some View {
        HStack(spacing: 12) {
            Button {
                guard let first = tracks.first else { return }
                if appState.playbackEngine.shuffleMode { appState.toggleShuffle() }
                appState.play(track: first, queue: tracks)
            } label: {
                Label("Play All", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.accent))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Button {
                guard let first = tracks.first else { return }
                if appState.playbackEngine.shuffleMode == false { appState.toggleShuffle() }
                appState.play(track: first, queue: tracks)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.controlFill))
                    .foregroundStyle(AppTheme.primaryText)
            }
            .buttonStyle(.plain)
        }
    }

    private func loadingCard(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(AppTheme.primaryText)
            Text(text)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(AppTheme.cardFill)
        )
    }

    private func prefetchVisibleTracks(from tracks: [Track]) {
        let warmTracks = Array(tracks.prefix(10))
        guard warmTracks.isEmpty == false else { return }
        appState.prefetchPlayback(for: warmTracks)
    }
}
