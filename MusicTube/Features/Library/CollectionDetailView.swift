import SwiftUI

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
                        ForEach(tracks.indices, id: \.self) { index in
                            let track = tracks[index]
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
                    source: collectionDownloadSource,
                    totalCount: collectionDownloadTotalCount,
                    downloadedCount: downloadService.downloadCount(for: collectionDownloadSource, matching: tracks),
                    pendingCount: downloadService.pendingRequestCount(for: collectionDownloadSource),
                    progress: downloadService.aggregateProgress(
                        for: collectionDownloadSource,
                        totalCount: collectionDownloadTotalCount,
                        matching: tracks
                    ),
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
        tracks.isEmpty ? collection.itemCount : tracks.count
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
