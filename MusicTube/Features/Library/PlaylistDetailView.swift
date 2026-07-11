import SwiftUI

struct PlaylistDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var downloadService = DownloadService.shared
    let playlist: Playlist
    @ObservedObject var viewModel: PlaylistViewModel

    @State private var isEditSheetPresented = false
    @State private var editedPlaylistName = ""

    private var currentPlaylist: Playlist {
        viewModel.playlist
    }

    private var tracks: [Track] { viewModel.tracks }
    private var isLoading: Bool { viewModel.isLoading }

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
                    ForEach(tracks.indices, id: \.self) { index in
                        let track = tracks[index]
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
            .padding(.bottom, viewModel.nowPlayingKey == nil ? 108 : 174)
        }
        .background(detailBackground)
        .navigationTitle(currentPlaylist.title)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                SourceDownloadButton(
                    source: playlistDownloadSource,
                    totalCount: playlistDownloadTotalCount,
                    downloadedCount: downloadService.downloadCount(for: playlistDownloadSource, matching: tracks),
                    pendingCount: downloadService.pendingRequestCount(for: playlistDownloadSource),
                    progress: downloadService.aggregateProgress(
                        for: playlistDownloadSource,
                        totalCount: playlistDownloadTotalCount,
                        matching: tracks
                    ),
                    isPreparing: downloadService.isPreparing(source: playlistDownloadSource),
                    isDownloading: downloadService.isDownloading(source: playlistDownloadSource),
                    size: 32,
                    foregroundColor: Color.primary,
                    backgroundColor: .clear
                ) {
                    viewModel.download()
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
                            viewModel.presentSongAdder()
                        } label: {
                            Label("Add Songs", systemImage: "plus.circle")
                        }

                        Button(role: .destructive) {
                            viewModel.delete()
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
                            if viewModel.rename(to: editedPlaylistName) {
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
            await viewModel.loadInitial()
        }
        .onChange(of: viewModel.isSyncingLikedSongs) { _, isSyncing in
            guard playlist.kind == .likedMusic, isSyncing == false else { return }
            Task {
                await viewModel.refreshAfterLikedSync()
            }
        }
        .refreshable {
            await viewModel.refresh()
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
                viewModel.playAll(shuffled: false)
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
                viewModel.playAll(shuffled: true)
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
                viewModel.play(track)
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
                viewModel.toggleLike(track)
            } label: {
                Label("Unlike", systemImage: "heart.slash")
            }
        case .savedSongs:
            Button(role: .destructive) {
                viewModel.toggleSaved(track)
            } label: {
                Label("Unsave", systemImage: "bookmark.slash")
            }
        default:
            EmptyView()
        }
    }

    private func removeTrackFromVisiblePlaylist(_ track: Track) {
        viewModel.remove(track)
    }

    private func editableTrackRow(_ track: Track) -> some View {
        let isCurrentTrack = viewModel.nowPlayingKey == track.playbackKey
        let isCurrentlyPlaying = isCurrentTrack && viewModel.isPlaying

        return HStack(spacing: 12) {
            Button {
                viewModel.play(track)
            } label: {
                HStack(spacing: 12) {
                    AsyncArtworkView(url: track.artworkURL, cornerRadius: 10)
                        .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isCurrentTrack ? Color(red: 1, green: 0.24, blue: 0.43) : Color.primary)
                            .lineLimit(1)
                            .allowsTightening(true)
                            .truncationMode(.tail)
                            .layoutPriority(1)

                        HStack(spacing: 4) {
                            HStack(spacing: 4) {
                                if isCurrentlyPlaying {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Color(red: 1, green: 0.24, blue: 0.43))
                                    Text("Playing")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color(red: 1, green: 0.24, blue: 0.43))
                                        .lineLimit(1)
                                } else if isCurrentTrack {
                                    Image(systemName: "speaker.fill")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Color(red: 1, green: 0.24, blue: 0.43).opacity(0.7))
                                    Text("Paused")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color(red: 1, green: 0.24, blue: 0.43).opacity(0.7))
                                        .lineLimit(1)
                                }
                            }
                            .fixedSize(horizontal: true, vertical: false)

                            TrackEngagementBadges(track: track)

                            if let duration = track.formattedDuration {
                                Text(duration)
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }

                            if let views = track.formattedViewCount {
                                Text("· \(views)")
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                        .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)

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
                    viewModel.togglePlayback()
                } else {
                    viewModel.play(track)
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

    private var playlistDownloadSource: DownloadSource {
        DownloadSource(
            id: "playlist:\(currentPlaylist.id)",
            title: currentPlaylist.title,
            kind: .playlist
        )
    }

    private var playlistDownloadTotalCount: Int {
        tracks.isEmpty ? currentPlaylist.itemCount : tracks.count
    }
}

struct SourceDownloadButton: View {
    @ObservedObject private var downloadService = DownloadService.shared

    let source: DownloadSource
    let totalCount: Int
    let downloadedCount: Int
    let pendingCount: Int
    let progress: Double
    let isPreparing: Bool
    let isDownloading: Bool
    let size: CGFloat
    let foregroundColor: Color
    let backgroundColor: Color
    let action: () -> Void

    var body: some View {
        Button {
            if isBusy {
                downloadService.cancelDownloads(for: source)
            } else {
                action()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(backgroundColor)
                    .frame(width: size, height: size)

                if showsProgressBorder {
                    Circle()
                        .stroke(AppTheme.progressTrack, lineWidth: 2.5)
                        .frame(width: size, height: size)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.cyan, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: size, height: size)
                        .animation(.linear(duration: 0.25), value: progress)
                }

                icon
                    .frame(width: size, height: size)
            }
        }
        .buttonStyle(.plain)
        .disabled(isComplete)
    }

    @ViewBuilder
    private var icon: some View {
        if isBusy {
            Image(systemName: "stop.fill")
                .font(.system(size: size * 0.30, weight: .bold))
                .foregroundStyle(foregroundColor)
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

    private var isBusy: Bool {
        isPreparing || isDownloading
    }

    private var isComplete: Bool {
        totalCount > 0 && downloadedCount >= totalCount && isBusy == false
    }

    private var showsProgressBorder: Bool {
        isBusy || progress > 0 || downloadedCount > 0
    }
}
