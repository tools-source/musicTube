import SwiftUI

struct CollectionDetailView: View {
    @EnvironmentObject private var appState: AppState
    let collection: MusicCollection

    @State private var tracks: [Track] = []
    @State private var isLoading = true

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 14) {
                collectionHeader

                if !isLoading && !tracks.isEmpty {
                    collectionPlaybackActionsRow(tracks: tracks)
                }

                if isLoading {
                    statusCard("Loading \(collectionTitleLowercased) tracks...", showsProgress: true)
                } else if tracks.isEmpty {
                    statusCard("No playable songs were found for this \(collectionTitleLowercased).")
                } else {
                    VStack(spacing: 0) {
                        ForEach(tracks.indices, id: \.self) { index in
                            let track = tracks[index]
                            TrackRowView(
                                track: track,
                                showsDownloadButton: true,
                                downloadSource: DownloadSource(
                                    id: collection.id,
                                    title: collection.title,
                                    kind: collection.kind
                                ),
                                downloadSourceTrackIndex: index
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
        .premiumScreenBackground()
        .navigationTitle(collection.title)
        .navigationBarTitleDisplayMode(.inline)
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

    private var collectionHeader: some View {
        HStack(spacing: 16) {
            AsyncArtworkView(url: collection.artworkURL, cornerRadius: AppCornerRadius.artwork)
                .frame(width: 112, height: 112)

            VStack(alignment: .leading, spacing: 6) {
                Text(collectionKindLabel.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.tertiaryText)

                Text(collection.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(2)

                if collection.subtitle.isEmpty == false {
                    Text(collection.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                }

                Text(collectionItemCountLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.tertiaryText)

                if collection.description.isEmpty == false {
                    Text(collection.description)
                        .font(.caption)
                        .foregroundStyle(AppTheme.tertiaryText)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var collectionItemCountLabel: String {
        let count = collectionDownloadTotalCount
        return count == 1 ? "1 song" : "\(count) songs"
    }

    private func downloadCollection() {
        if tracks.isEmpty {
            appState.downloadCollection(collection)
        } else {
            appState.downloadTracks(tracks, source: collectionDownloadSource)
        }
    }

    private func collectionPlaybackActionsRow(tracks: [Track]) -> some View {
        HStack(spacing: 8) {
            Button {
                guard let first = tracks.first else { return }
                if appState.playbackEngine.shuffleMode { appState.toggleShuffle() }
                appState.play(track: first, queue: tracks)
            } label: {
                Label("Play All", systemImage: "play.fill")
            }
            .buttonStyle(AppPrimaryActionButtonStyle())

            Button {
                guard let first = tracks.first else { return }
                if appState.playbackEngine.shuffleMode == false { appState.toggleShuffle() }
                appState.play(track: first, queue: tracks)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .buttonStyle(AppSecondaryActionButtonStyle())

            SourceDownloadButton(
                source: collectionDownloadSource,
                tracks: tracks,
                totalCount: collectionDownloadTotalCount,
                size: 44,
                foregroundColor: AppTheme.primaryText,
                backgroundColor: AppTheme.controlFillStrong
            ) {
                downloadCollection()
            }

            Button {
                appState.toggleCollectionSaved(collection)
            } label: {
                Image(systemName: appState.isCollectionSaved(collection) ? "bookmark.fill" : "bookmark")
                    .font(.headline)
                    .foregroundStyle(appState.isCollectionSaved(collection) ? AppTheme.accent : AppTheme.primaryText)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.controlFillStrong)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(appState.isCollectionSaved(collection) ? "Remove from library" : "Save to library")
        }
    }

    private func statusCard(_ text: String, showsProgress: Bool = false) -> some View {
        HStack(spacing: 10) {
            if showsProgress {
                ProgressView()
                    .tint(AppTheme.primaryText)
            }
            Text(text)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .appSurface()
    }

    private func prefetchVisibleTracks(from tracks: [Track]) {
        let warmTracks = Array(tracks.prefix(10))
        guard warmTracks.isEmpty == false else { return }
        appState.prefetchPlayback(for: warmTracks)
    }
}
