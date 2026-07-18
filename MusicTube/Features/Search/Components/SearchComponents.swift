import SwiftUI

struct SearchHeaderView: View {
    let isRecognizingMusic: Bool
    let onRecognizeTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onRecognizeTap) {
                HStack(spacing: 12) {
                    Image(systemName: isRecognizingMusic ? "waveform.circle.fill" : "music.note")
                        .font(.title3.weight(.semibold))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(isRecognizingMusic ? "Listening for music..." : "Recognize what’s playing")
                            .font(.subheadline.weight(.semibold))

                        Text(
                            isRecognizingMusic
                                ? "Matching nearby audio"
                                : "Identify a song nearby"
                        )
                        .font(.footnote)
                        .foregroundStyle(AppTheme.secondaryText)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: isRecognizingMusic ? "stop.fill" : "mic.fill")
                        .font(.subheadline.weight(.bold))
                }
                .foregroundStyle(AppTheme.primaryText)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                        .fill(isRecognizingMusic ? AppTheme.accent : AppTheme.controlFill)
                        .overlay {
                            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                                .strokeBorder(AppTheme.surfaceStroke, lineWidth: 1)
                        }
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRecognizingMusic ? "Stop recognizing music" : "Recognize music with microphone")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SearchResultTabsView: View {
    let availableTabs: [SearchResultTab]
    let selectedTab: SearchResultTab
    let onSelect: (SearchResultTab) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(availableTabs, id: \.self) { tab in
                    Button {
                        onSelect(tab)
                    } label: {
                        Text(tab.rawValue)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selectedTab == tab ? AppTheme.inverseText : AppTheme.primaryText)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(
                                Capsule()
                                    .fill(selectedTab == tab ? AppTheme.inverseFill : AppTheme.controlFill)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

struct SearchSongSortButton: View {
    let selectedOption: SongSortOption
    let onSelect: (SongSortOption) -> Void

    var body: some View {
        Menu {
            ForEach(SongSortOption.allCases, id: \.self) { option in
                Button {
                    onSelect(option)
                } label: {
                    Label(
                        option.rawValue,
                        systemImage: selectedOption == option ? "checkmark" : "line.3.horizontal.decrease"
                    )
                }
            }
        } label: {
            Image(systemName: selectedOption == .default
                ? "line.3.horizontal.decrease.circle"
                : "line.3.horizontal.decrease.circle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(selectedOption == .default ? AppTheme.primaryText : AppTheme.accent)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(AppTheme.controlFill)
                )
        }
        .accessibilityLabel("Sort songs")
    }
}

struct SearchStatusCard: View {
    let label: String
    let showsProgress: Bool

    var body: some View {
        HStack(spacing: 10) {
            if showsProgress {
                ProgressView()
                    .tint(AppTheme.primaryText)
            }

            Text(label)
                .font(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .appSurface()
    }
}

struct SearchSongResultsSection: View {
    let items: [IndexedTrackPresentation]
    let isLoadingMoreResults: Bool
    let nowPlayingKey: String?
    let isPlaying: Bool
    let onPlay: (Track) -> Void
    let onTogglePlayback: () -> Void
    let onAppear: (IndexedTrackPresentation) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                SearchStatusCard(label: "No songs matched that search.", showsProgress: false)
            } else {
                ForEach(items) { item in
                    RecommendedRow(
                        track: item.track,
                        isCurrentTrack: nowPlayingKey == item.track.playbackKey,
                        isPlaying: isPlaying
                    ) {
                        onPlay(item.track)
                    } onPlayPause: {
                        onTogglePlayback()
                    }
                    .onAppear {
                        onAppear(item)
                    }

                    if item.id != items.last?.id {
                        Divider()
                            .overlay(AppTheme.divider)
                            .padding(.leading, 64)
                    }
                }

                if isLoadingMoreResults {
                    SearchStatusCard(label: "Loading more songs...", showsProgress: true)
                        .padding(.top, 16)
                }
            }
        }
    }
}

struct SearchRecentSearchesSection: View {
    let recentQueries: [String]
    let onSelect: (String) -> Void
    let onDelete: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent searches")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)

            VStack(spacing: 0) {
                ForEach(recentQueries, id: \.self) { query in
                    HStack(spacing: 12) {
                        Button {
                            onSelect(query)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AppTheme.tertiaryText)

                                Text(query)
                                    .font(.subheadline)
                                    .foregroundStyle(AppTheme.primaryText)
                                    .lineLimit(1)

                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)

                        Button {
                            onDelete(query)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(AppTheme.tertiaryText)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete \(query)")
                    }
                    .padding(.vertical, 8)

                    if query != recentQueries.last {
                        Divider()
                            .overlay(AppTheme.divider)
                            .padding(.leading, 38)
                    }
                }
            }
        }
    }
}

struct SearchAutocompleteSuggestionsSection: View {
    let suggestions: [String]
    let isLoading: Bool
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Suggestions")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)

            if isLoading, suggestions.isEmpty {
                SearchStatusCard(label: "Updating suggestions...", showsProgress: true)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            onSelect(suggestion)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "magnifyingglass")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(AppTheme.tertiaryText)

                                Text(suggestion)
                                    .font(.subheadline)
                                    .foregroundStyle(AppTheme.primaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)

                        if suggestion != suggestions.last {
                            Divider()
                                .overlay(AppTheme.divider)
                                .padding(.leading, 30)
                        }
                    }
                }
            }
        }
    }
}

struct SearchSuggestionsSection: View {
    let items: [IndexedTrackPresentation]
    let isLoadingSuggestedTracks: Bool
    let isLoadingMoreSuggestedTracks: Bool
    let selectedSortOption: SongSortOption
    let nowPlayingKey: String?
    let isPlaying: Bool
    let onSelectSortOption: (SongSortOption) -> Void
    let onPlay: (Track) -> Void
    let onTogglePlayback: () -> Void
    let onMore: (Track) -> Void
    let onLess: (Track) -> Void
    let onAppear: (IndexedTrackPresentation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Suggestions")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)

                Spacer(minLength: 8)

                if items.isEmpty == false {
                    SearchSongSortButton(
                        selectedOption: selectedSortOption,
                        onSelect: onSelectSortOption
                    )
                }
            }

            if isLoadingSuggestedTracks, items.isEmpty {
                SearchStatusCard(label: "Learning your taste...", showsProgress: true)
            } else if items.isEmpty {
                SearchStatusCard(
                    label: "Search and play a few songs to unlock personalized suggestions.",
                    showsProgress: false
                )
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        TrackSwipeActionsView(
                            onMore: { onMore(item.track) },
                            onLess: { onLess(item.track) }
                        ) {
                            RecommendedRow(
                                track: item.track,
                                isCurrentTrack: nowPlayingKey == item.track.playbackKey,
                                isPlaying: isPlaying
                            ) {
                                onPlay(item.track)
                            } onPlayPause: {
                                onTogglePlayback()
                            }
                        }
                        .onAppear {
                            onAppear(item)
                        }

                        if item.id != items.last?.id {
                            Divider()
                                .overlay(AppTheme.divider)
                                .padding(.leading, 64)
                        }
                    }

                    if isLoadingMoreSuggestedTracks {
                        SearchStatusCard(label: "Loading more suggestions...", showsProgress: true)
                            .padding(.top, 16)
                    }
                }
            }
        }
    }
}

struct SearchCollectionRow: View {
    let collection: MusicCollection
    let isSaved: Bool
    let onDownload: () -> Void
    let onToggleSaved: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AsyncArtworkView(url: collection.artworkURL, cornerRadius: AppCornerRadius.artwork)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(collection.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                SourceDownloadButton(
                    source: collectionDownloadSource,
                    totalCount: collection.itemCount,
                    size: 36
                ) {
                    onDownload()
                }

                Button(action: onToggleSaved) {
                    Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSaved ? AppTheme.accent : AppTheme.primaryText)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(AppTheme.controlFillStrong))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
    }

    private var detailLine: String {
        var parts = [collectionKindLabel]
        if collection.subtitle.isEmpty == false {
            parts.append(collection.subtitle)
        }
        if collection.itemCount > 0 {
            parts.append(collection.itemCount == 1 ? "1 track" : "\(collection.itemCount) tracks")
        }
        return parts.joined(separator: " · ")
    }

    private var collectionKindLabel: String {
        switch collection.kind {
        case .playlist: return "Playlist"
        case .album: return "Album"
        case .artist: return "Artist"
        }
    }

    private var collectionDownloadSource: DownloadSource {
        DownloadSource(id: collection.id, title: collection.title, kind: collection.kind)
    }
}

// MARK: - SearchDiscoverySection

struct SearchDiscoverySection: View {
    let artists: [String]
    let mixes: [Playlist]
    let onSelectArtist: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !artists.isEmpty {
                artistsRow
            }
            if !mixes.isEmpty {
                mixesRow
            }
        }
    }

    private var artistsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Artists You Listen To")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(artists, id: \.self) { artist in
                        Button {
                            onSelectArtist(artist)
                        } label: {
                            Text(artist)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(AppTheme.primaryText)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(
                                    Capsule()
                                        .fill(AppTheme.controlFill)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var mixesRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your Mixes")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(mixes) { playlist in
                        NavigationLink(value: playlist) {
                            VStack(alignment: .leading, spacing: 6) {
                                AsyncArtworkView(url: playlist.artworkURL, cornerRadius: 12)
                                    .frame(width: 120, height: 120)

                                Text(playlist.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.primaryText)
                                    .lineLimit(1)
                            }
                            .frame(width: 120)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}
