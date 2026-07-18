import SwiftUI

struct PlaylistDetailView: View {
    @Environment(\.dismiss) private var dismiss
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
            LazyVStack(spacing: AppSpacing.medium) {
                playlistHeader

                if !isLoading && !tracks.isEmpty {
                    playbackActionsRow(tracks: tracks)
                }

                if isLoading {
                    loadingCard("Loading playlist tracks...")
                } else if tracks.isEmpty {
                    emptyCard("This playlist is empty for now.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(tracks.indices, id: \.self) { index in
                            let track = tracks[index]
                            playlistTrackRow(track, index: index)

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
            .padding(.bottom, viewModel.nowPlayingKey == nil ? 108 : 174)
        }
        .premiumScreenBackground()
        .navigationTitle(currentPlaylist.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
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
                            .foregroundStyle(AppTheme.accent)
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
                        .appSurface(fill: AppTheme.inputFill)
                        .foregroundStyle(Color.primary)

                    Spacer()
                }
                .padding(20)
                .premiumScreenBackground()
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
                        .foregroundStyle(AppTheme.accent)
                        .disabled(editedPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.height(240)])
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

    private var playlistHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            AsyncArtworkView(url: currentPlaylist.artworkURL, cornerRadius: AppCornerRadius.artwork)
                .frame(width: 112, height: 112)

            VStack(alignment: .leading, spacing: 6) {
                Text(playlistKindLabel.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.tertiaryText)

                Text(currentPlaylist.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(2)

                Text(playlistItemCountLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.secondaryText)

                if currentPlaylist.description.isEmpty == false {
                    Text(currentPlaylist.description)
                        .font(.caption)
                        .foregroundStyle(AppTheme.tertiaryText)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func playbackActionsRow(tracks: [Track]) -> some View {
        HStack(spacing: 12) {
            Button {
                viewModel.playAll(shuffled: false)
            } label: {
                Label("Play All", systemImage: "play.fill")
            }
            .buttonStyle(AppPrimaryActionButtonStyle())

            Button {
                viewModel.playAll(shuffled: true)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .buttonStyle(AppSecondaryActionButtonStyle())

            SourceDownloadButton(
                source: playlistDownloadSource,
                tracks: tracks,
                totalCount: playlistDownloadTotalCount,
                size: 44,
                foregroundColor: AppTheme.primaryText,
                backgroundColor: AppTheme.controlFillStrong
            ) {
                viewModel.download()
            }
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
        .appSurface()
    }

    private func emptyCard(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .appSurface()
    }

    @ViewBuilder
    private func playlistTrackRow(_ track: Track, index: Int) -> some View {
        TrackRowView(
            track: track,
            showsNowPlayingIndicator: true,
            showsDownloadButton: true,
            downloadSource: playlistDownloadSource,
            downloadSourceTrackIndex: index,
            prefetchPlaybackOnAppear: true
        ) {
            viewModel.play(track)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if playlist.kind == .custom {
                Button(role: .destructive) {
                    removeTrackFromVisiblePlaylist(track)
                } label: {
                    Label("Remove", systemImage: "minus.circle")
                }
            } else {
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

    private var playlistKindLabel: String {
        switch currentPlaylist.kind {
        case .standard: return "Playlist"
        case .likedMusic: return "Liked Music"
        case .uploads: return "Uploads"
        case .savedSongs: return "Saved Songs"
        case .custom: return "Your Playlist"
        }
    }

    private var playlistItemCountLabel: String {
        let count = playlistDownloadTotalCount
        return count == 1 ? "1 song" : "\(count) songs"
    }
}
