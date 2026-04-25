import SwiftUI

private enum SearchResultTab: String, CaseIterable {
    case songs = "Songs"
    case albums = "Albums"
    case artists = "Artists"
}

struct SearchView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchTask: Task<Void, Never>?
    @State private var suggestedTracks: [Track] = []
    @State private var isLoadingSuggestedTracks = false
    @State private var immediateSearchQuery: String?
    @State private var visibleSongCount = 10
    @State private var selectedTab: SearchResultTab = .songs

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    searchHeader

                    if trimmedSearchQuery.isEmpty, appState.recentSearches.isEmpty == false {
                        recentSearchesSection
                    }

                    if trimmedSearchQuery.isEmpty {
                        suggestionsSection
                    }

                    if appState.isSearching, appState.searchResults.isEmpty {
                        statusCard(label: "Searching songs, playlists, albums, and artists...")
                    } else if appState.searchResults.isEmpty {
                        if trimmedSearchQuery.isEmpty, appState.recentSearches.isEmpty == false {
                            EmptyView()
                        } else {
                            statusCard(label: emptyStateMessage)
                        }
                    } else {
                        if appState.isSearching {
                            statusCard(label: "Refreshing results...")
                        }

                        resultSummary
                        resultTabs
                        searchResultsContent
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, bottomSpacing)
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: MusicCollection.self) { collection in
                CollectionDetailView(collection: collection)
            }
            .searchable(text: $appState.searchQuery, prompt: "Songs, playlists, albums, artists")
            .onSubmit(of: .search) {
                commitRecentSearch(from: appState.searchQuery)
                scheduleSearch(for: appState.searchQuery, immediately: true)
            }
            .onChange(of: appState.searchQuery) { oldValue, newValue in
                let shouldSearchImmediately = normalized(newValue) == normalized(immediateSearchQuery ?? "")
                if normalized(oldValue) != normalized(newValue) {
                    visibleSongCount = 10
                }
                scheduleSearch(for: newValue, immediately: shouldSearchImmediately)
                if shouldSearchImmediately {
                    immediateSearchQuery = nil
                }
            }
            .onChange(of: searchResultCountsKey) { _, _ in
                syncSelectedTabWithResults()
            }
            .onChange(of: appState.searchResults.songs.count) { _, newCount in
                if newCount < visibleSongCount {
                    visibleSongCount = max(10, newCount)
                } else {
                    visibleSongCount = min(max(visibleSongCount, 10), newCount)
                }
            }
            .onDisappear {
                searchTask?.cancel()
            }
            .task(id: suggestionsRefreshKey) {
                await refreshSuggestedTracks()
            }
            .background(searchBackground.ignoresSafeArea())
        }
    }

    private var searchHeader: some View {
        SearchHeaderView(isYouTubeConnected: appState.isYouTubeConnected)
    }

    private var resultSummary: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(appState.searchResults.totalResultCount) results")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.6))
        }
    }

    private var resultTabs: some View {
        SearchResultTabsView(
            availableTabs: availableTabs,
            selectedTab: selectedTab,
            onSelect: { selectedTab = $0 }
        )
    }

    @ViewBuilder
    private var searchResultsContent: some View {
        switch selectedTab {
        case .songs:
            songResultsSection
        case .albums:
            albumResultsSection
        case .artists:
            artistResultsSection
        }
    }

    private var emptyStateMessage: String {
        if trimmedSearchQuery.isEmpty {
            return "Search for songs, playlists, albums, or artists."
        }

        if appState.isSearching {
            return "Searching..."
        }

        return "No results matched that search."
    }

    private var trimmedSearchQuery: String {
        appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var suggestionsRefreshKey: String {
        "\(trimmedSearchQuery)|\(appState.recentSearches.joined(separator: "||"))"
    }

    private var searchResultCountsKey: String {
        [
            String(appState.searchResults.songs.count),
            String(appState.searchResults.playlists.count),
            String(appState.searchResults.albums.count),
            String(appState.searchResults.artists.count)
        ].joined(separator: "|")
    }

    private var availableTabs: [SearchResultTab] {
        var tabs: [SearchResultTab] = []
        if appState.searchResults.songs.isEmpty == false {
            tabs.append(.songs)
        }
        if appState.searchResults.albums.isEmpty == false || appState.searchResults.playlists.isEmpty == false {
            tabs.append(.albums)
        }
        if appState.searchResults.artists.isEmpty == false {
            tabs.append(.artists)
        }
        return tabs.isEmpty ? SearchResultTab.allCases : tabs
    }

    private var visibleSongs: [Track] {
        Array(appState.searchResults.songs.prefix(visibleSongCount))
    }

    private var songResultsSection: some View {
        SearchSongResultsSection(
            visibleSongs: visibleSongs,
            isLoadingMoreResults: appState.isLoadingMoreSearchResults,
            onPlay: playSearchTrack,
            onAppear: handleSongAppearance(index:displayedCount:)
        )
    }

    private var albumResultsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            if appState.searchResults.albums.isEmpty && appState.searchResults.playlists.isEmpty {
                statusCard(label: "No albums or playlists matched that search.")
            }

            if appState.searchResults.albums.isEmpty == false {
                collectionSection(title: "Albums", collections: appState.searchResults.albums)
            }

            if appState.searchResults.playlists.isEmpty == false {
                collectionSection(title: "Playlists", collections: appState.searchResults.playlists)
            }
        }
    }

    private var artistResultsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            if appState.searchResults.artists.isEmpty {
                statusCard(label: "No artists matched that search.")
            } else {
                collectionSection(title: "Artists", collections: appState.searchResults.artists)
            }
        }
    }

    private func collectionSection(title: String, collections: [MusicCollection]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.82))

            VStack(spacing: 0) {
                ForEach(Array(collections.enumerated()), id: \.element.id) { index, collection in
                    NavigationLink(value: collection) {
                        SearchCollectionRow(collection: collection)
                    }
                    .buttonStyle(.plain)

                    if index < collections.count - 1 {
                        Divider()
                            .overlay(Color.white.opacity(0.07))
                            .padding(.leading, 64)
                    }
                }
            }
        }
    }

    private var recentSearchesSection: some View {
        SearchRecentSearchesSection(
            recentQueries: Array(appState.recentSearches.prefix(8)),
            onSelect: selectSuggestion,
            onDelete: { appState.removeRecentSearch($0) }
        )
    }

    private var suggestionsSection: some View {
        SearchSuggestionsSection(
            suggestedTracks: suggestedTracks,
            isLoadingSuggestedTracks: isLoadingSuggestedTracks,
            onPlay: playSuggestedTrack
        )
    }

    private var bottomSpacing: CGFloat {
        appState.nowPlaying == nil ? 108 : 172
    }

    private var searchBackground: some View {
        LinearGradient(
            colors: [
                Color.black,
                Color(red: 0.04, green: 0.04, blue: 0.08)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func statusCard(label: String) -> some View {
        SearchStatusCard(
            label: label,
            showsProgress: appState.isSearching || isLoadingSuggestedTracks
        )
    }

    private func playSearchTrack(_ track: Track) {
        commitRecentSearch(from: appState.searchQuery)
        appState.play(track: track, queue: appState.searchResults.songs)
    }

    private func playSuggestedTrack(_ track: Track) {
        appState.play(track: track, queue: suggestedTracks)
    }

    private func handleSongAppearance(index: Int, displayedCount: Int) {
        guard index >= displayedCount - 2 else { return }

        if visibleSongCount < appState.searchResults.songs.count {
            visibleSongCount = min(
                visibleSongCount + AppConfig.Search.visibleSongPageSize,
                appState.searchResults.songs.count
            )
        } else if appState.canLoadMoreSearchResults {
            Task {
                await appState.loadMoreSearchResultsIfNeeded()
            }
        }
    }

    private func selectSuggestion(_ query: String) {
        immediateSearchQuery = query
        appState.searchQuery = query
        commitRecentSearch(from: query)
    }

    private func commitRecentSearch(from query: String) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return }
        appState.recordRecentSearch(trimmedQuery)
    }

    private func refreshSuggestedTracks() async {
        guard trimmedSearchQuery.isEmpty else {
            suggestedTracks = []
            isLoadingSuggestedTracks = false
            return
        }

        isLoadingSuggestedTracks = true
        let loadedTracks = await appState.recentSearchTrackSuggestions(limit: 18)
        guard Task.isCancelled == false else { return }
        suggestedTracks = loadedTracks
        isLoadingSuggestedTracks = false
    }

    private func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func scheduleSearch(for query: String, immediately: Bool = false) {
        searchTask?.cancel()

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else {
            appState.clearSearch()
            visibleSongCount = 10
            selectedTab = .songs
            return
        }

        searchTask = Task {
            if immediately == false {
                try? await Task.sleep(nanoseconds: AppConfig.Search.debounceNanoseconds)
            }

            guard Task.isCancelled == false else { return }
            _ = await appState.search(query: trimmedQuery)
        }
    }

    private func syncSelectedTabWithResults() {
        guard availableTabs.contains(selectedTab) == false else { return }
        selectedTab = availableTabs.first ?? .songs
    }
}

private struct SearchHeaderView: View {
    let isYouTubeConnected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Search songs, playlists, albums, and artists, then save anything you like to your library.")
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.68))

            Text(
                isYouTubeConnected
                    ? "Connected to YouTube, with your MusicTube library available everywhere."
                    : "Guest mode is active. Connect YouTube anytime from Library for account sync."
            )
            .font(.footnote)
            .foregroundStyle(Color.white.opacity(0.46))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SearchResultTabsView: View {
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
                            .foregroundStyle(selectedTab == tab ? .black : .white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(
                                Capsule()
                                    .fill(selectedTab == tab ? Color.white : Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct SearchStatusCard: View {
    let label: String
    let showsProgress: Bool

    var body: some View {
        HStack(spacing: 10) {
            if showsProgress {
                ProgressView()
                    .tint(.white)
            }

            Text(label)
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.72))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
    }
}

private struct SearchSongResultsSection: View {
    let visibleSongs: [Track]
    let isLoadingMoreResults: Bool
    let onPlay: (Track) -> Void
    let onAppear: (Int, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if visibleSongs.isEmpty {
                SearchStatusCard(label: "No songs matched that search.", showsProgress: false)
            } else {
                ForEach(Array(visibleSongs.enumerated()), id: \.element.id) { index, track in
                    RecommendedRow(track: track) {
                        onPlay(track)
                    }
                    .onAppear {
                        onAppear(index, visibleSongs.count)
                    }

                    if index < visibleSongs.count - 1 {
                        Divider()
                            .overlay(Color.white.opacity(0.07))
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

private struct SearchRecentSearchesSection: View {
    let recentQueries: [String]
    let onSelect: (String) -> Void
    let onDelete: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent searches")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.72))

            VStack(spacing: 0) {
                ForEach(Array(recentQueries.enumerated()), id: \.element) { index, query in
                    HStack(spacing: 12) {
                        Button {
                            onSelect(query)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.white.opacity(0.52))

                                Text(query)
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
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
                                .foregroundStyle(Color.white.opacity(0.44))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Delete \(query)")
                    }
                    .padding(.vertical, 8)

                    if index < recentQueries.count - 1 {
                        Divider()
                            .overlay(Color.white.opacity(0.07))
                            .padding(.leading, 38)
                    }
                }
            }
        }
    }
}

private struct SearchSuggestionsSection: View {
    let suggestedTracks: [Track]
    let isLoadingSuggestedTracks: Bool
    let onPlay: (Track) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Suggestions")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.72))

            if isLoadingSuggestedTracks, suggestedTracks.isEmpty {
                SearchStatusCard(label: "Learning your taste...", showsProgress: true)
            } else if suggestedTracks.isEmpty {
                SearchStatusCard(
                    label: "Search and play a few songs to unlock personalized suggestions.",
                    showsProgress: false
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(suggestedTracks.enumerated()), id: \.element.id) { index, track in
                        RecommendedRow(track: track) {
                            onPlay(track)
                        }

                        if index < suggestedTracks.count - 1 {
                            Divider()
                                .overlay(Color.white.opacity(0.07))
                                .padding(.leading, 64)
                        }
                    }
                }
            }
        }
    }
}

private struct SearchCollectionRow: View {
    @EnvironmentObject private var appState: AppState
    let collection: MusicCollection

    var body: some View {
        HStack(spacing: 12) {
            AsyncArtworkView(url: collection.artworkURL, cornerRadius: 10)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(collection.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Button {
                    appState.downloadCollection(collection)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)

                Button {
                    appState.toggleCollectionSaved(collection)
                } label: {
                    Image(systemName: appState.isCollectionSaved(collection) ? "bookmark.fill" : "bookmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(appState.isCollectionSaved(collection) ? Color(red: 1, green: 0.23, blue: 0.42) : .white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.white.opacity(0.10)))
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
}
