import SwiftUI

private enum SearchResultTab: String, CaseIterable {
    case songs = "Songs"
    case albums = "Albums"
    case artists = "Artists"
}

private enum SongSortOption: String, CaseIterable {
    case `default` = "Default"
    case mostViewed = "Most Viewed"
    case shortest = "Shortest"
    case longest = "Longest"
}

struct SearchView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchTask: Task<Void, Never>?
    @State private var autocompleteTask: Task<Void, Never>?
    @State private var suggestedTracks: [Track] = []
    @State private var autocompleteSuggestions: [String] = []
    @State private var isLoadingSuggestedTracks = false
    @State private var isLoadingMoreSuggestedTracks = false
    @State private var isLoadingAutocompleteSuggestions = false
    @State private var immediateSearchQuery: String?
    @State private var visibleSongCount = 10
    @State private var visibleSuggestedTrackCount = 10
    @State private var selectedTab: SearchResultTab = .songs
    @State private var cachedAvailableTabs: [SearchResultTab] = SearchResultTab.allCases
    @State private var songSortOption: SongSortOption = .default
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    searchBar

                    if shouldShowAutocompleteSuggestions {
                        autocompleteSuggestionsSection
                    }

                    if trimmedSearchQuery.isEmpty {
                        searchHeader
                    }

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
            .onChange(of: appState.searchQuery) { oldValue, newValue in
                let shouldSearchImmediately = normalized(newValue) == normalized(immediateSearchQuery ?? "")
                if normalized(oldValue) != normalized(newValue) {
                    visibleSongCount = 10
                }
                scheduleAutocompleteRefresh(for: newValue)
                scheduleSearch(for: newValue, immediately: shouldSearchImmediately)
                if shouldSearchImmediately {
                    immediateSearchQuery = nil
                }
            }
            .onChange(of: searchResultCountsKey) { _, _ in
                recomputeAvailableTabs()
                syncSelectedTabWithResults()
            }
            .onChange(of: appState.searchResults.songs.count) { oldCount, newCount in
                if newCount < visibleSongCount {
                    visibleSongCount = max(10, newCount)
                } else if oldCount > 0, newCount > oldCount {
                    visibleSongCount = newCount
                } else {
                    visibleSongCount = min(max(visibleSongCount, 10), newCount)
                }
            }
            .onChange(of: isSearchFieldFocused) { _, isFocused in
                appState.isSearchFieldFocused = isFocused
            }
            .onDisappear {
                appState.isSearchFieldFocused = false
                searchTask?.cancel()
                autocompleteTask?.cancel()
            }
            .task(id: suggestionsRefreshKey) {
                await refreshSuggestedTracks()
            }
            .background(searchBackground.ignoresSafeArea())
        }
    }

    private var searchHeader: some View {
        SearchHeaderView(
            isYouTubeConnected: appState.isYouTubeConnected,
            isRecognizingMusic: appState.isRecognizingMusic,
            onRecognizeTap: {
                Task {
                    await appState.recognizeMusic()
                }
            }
        )
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.tertiaryText)

                TextField("Songs, playlists, albums, artists", text: $appState.searchQuery)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .submitLabel(.search)
                    .focused($isSearchFieldFocused)
                    .onSubmit {
                        autocompleteTask?.cancel()
                        autocompleteSuggestions = []
                        isLoadingAutocompleteSuggestions = false
                        isSearchFieldFocused = false
                        commitRecentSearch(from: appState.searchQuery)
                        scheduleSearch(for: appState.searchQuery, immediately: true)
                    }

                if trimmedSearchQuery.isEmpty == false {
                    Button {
                        clearSearchField()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(AppTheme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(AppTheme.cardFill)
            )

            if showsCancelButton {
                Button("Cancel") {
                    clearSearchField()
                    isSearchFieldFocused = false
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.primaryText)
                .buttonStyle(.plain)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showsCancelButton)
    }

    private var resultSummary: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(appState.searchResults.totalResultCount) results")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)
        }
    }

    private var resultTabs: some View {
        HStack(alignment: .center, spacing: 12) {
            SearchResultTabsView(
                availableTabs: availableTabs,
                selectedTab: selectedTab,
                onSelect: { selectedTab = $0 }
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            if selectedTab == .songs, appState.searchResults.songs.isEmpty == false {
                SearchSongSortButton(
                    selectedOption: songSortOption,
                    onSelect: { songSortOption = $0 }
                )
            }
        }
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

    private var showsCancelButton: Bool {
        isSearchFieldFocused && trimmedSearchQuery.isEmpty
    }

    private var shouldShowAutocompleteSuggestions: Bool {
        isSearchFieldFocused && trimmedSearchQuery.isEmpty == false && (
            isLoadingAutocompleteSuggestions || autocompleteSuggestions.isEmpty == false
        )
    }

    private var suggestionsRefreshKey: String {
        // Only depends on the query, not the full recent-searches list.
        trimmedSearchQuery
    }

    private var searchResultCountsKey: String {
        "\(appState.searchResults.songs.count)|\(appState.searchResults.playlists.count)|\(appState.searchResults.albums.count)|\(appState.searchResults.artists.count)"
    }

    private func recomputeAvailableTabs() {
        var tabs: [SearchResultTab] = []
        if appState.searchResults.songs.isEmpty == false { tabs.append(.songs) }
        if appState.searchResults.albums.isEmpty == false || appState.searchResults.playlists.isEmpty == false { tabs.append(.albums) }
        if appState.searchResults.artists.isEmpty == false { tabs.append(.artists) }
        cachedAvailableTabs = tabs.isEmpty ? SearchResultTab.allCases : tabs
    }

    private var availableTabs: [SearchResultTab] { cachedAvailableTabs }

    private var visibleSongs: [Track] {
        let sorted: [Track]
        switch songSortOption {
        case .default:
            sorted = appState.searchResults.songs
        case .mostViewed:
            sorted = appState.searchResults.songs.sorted {
                ($0.viewCount ?? 0) > ($1.viewCount ?? 0)
            }
        case .shortest:
            sorted = appState.searchResults.songs.sorted {
                ($0.duration ?? .greatestFiniteMagnitude) < ($1.duration ?? .greatestFiniteMagnitude)
            }
        case .longest:
            sorted = appState.searchResults.songs.sorted {
                ($0.duration ?? 0) > ($1.duration ?? 0)
            }
        }
        return Array(sorted.prefix(visibleSongCount))
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
                .foregroundStyle(AppTheme.primaryText)

            VStack(spacing: 0) {
                ForEach(Array(collections.enumerated()), id: \.element.id) { index, collection in
                    NavigationLink(value: collection) {
                        SearchCollectionRow(collection: collection)
                    }
                    .buttonStyle(.plain)

                    if index < collections.count - 1 {
                        Divider()
                            .overlay(AppTheme.divider)
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

    private var autocompleteSuggestionsSection: some View {
        SearchAutocompleteSuggestionsSection(
            suggestions: autocompleteSuggestions,
            isLoading: isLoadingAutocompleteSuggestions,
            onSelect: selectSuggestion
        )
    }

    private var suggestionsSection: some View {
        SearchSuggestionsSection(
            visibleTracks: visibleSuggestedTracks,
            isLoadingSuggestedTracks: isLoadingSuggestedTracks,
            isLoadingMoreSuggestedTracks: isLoadingMoreSuggestedTracks,
            onPlay: playSuggestedTrack,
            onAppear: handleSuggestedTrackAppearance(index:displayedCount:)
        )
    }

    private var bottomSpacing: CGFloat {
        appState.nowPlaying == nil || isSearchFieldFocused ? 108 : 172
    }

    private var visibleSuggestedTracks: [Track] {
        Array(suggestedTracks.prefix(visibleSuggestedTrackCount))
    }

    private var searchBackground: some View {
        AppTheme.screenBackground
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

    private func handleSuggestedTrackAppearance(index: Int, displayedCount: Int) {
        guard index >= displayedCount - 2 else { return }

        if visibleSuggestedTrackCount < suggestedTracks.count {
            visibleSuggestedTrackCount = min(
                visibleSuggestedTrackCount + AppConfig.Search.visibleSongPageSize,
                suggestedTracks.count
            )
            return
        }

        guard isLoadingMoreSuggestedTracks == false else { return }
        guard trimmedSearchQuery.isEmpty else { return }

        let nextLimit = suggestedTracks.count + max(AppConfig.Search.resultsPerPage, AppConfig.Search.visibleSongPageSize)
        Task {
            await loadMoreSuggestedTracks(limit: nextLimit)
        }
    }

    private func selectSuggestion(_ query: String) {
        immediateSearchQuery = query
        appState.searchQuery = query
        commitRecentSearch(from: query)
        autocompleteSuggestions = []
        isSearchFieldFocused = false
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
            isLoadingMoreSuggestedTracks = false
            visibleSuggestedTrackCount = 10
            return
        }

        isLoadingSuggestedTracks = true
        visibleSuggestedTrackCount = 10
        let loadedTracks = await appState.recentSearchTrackSuggestions(limit: 18)
        guard Task.isCancelled == false else { return }
        suggestedTracks = loadedTracks
        isLoadingSuggestedTracks = false
        visibleSuggestedTrackCount = min(max(visibleSuggestedTrackCount, 10), suggestedTracks.count)
    }

    private func loadMoreSuggestedTracks(limit: Int) async {
        guard trimmedSearchQuery.isEmpty else { return }

        isLoadingMoreSuggestedTracks = true
        let loadedTracks = await appState.recentSearchTrackSuggestions(limit: limit)
        guard Task.isCancelled == false else { return }

        suggestedTracks = loadedTracks
        visibleSuggestedTrackCount = min(
            max(visibleSuggestedTrackCount + AppConfig.Search.visibleSongPageSize, 10),
            suggestedTracks.count
        )
        isLoadingMoreSuggestedTracks = false
    }

    private func normalized(_ value: String) -> String {
        SearchTextNormalizer.normalized(value)
    }

    private func clearSearchField() {
        autocompleteTask?.cancel()
        immediateSearchQuery = nil
        autocompleteSuggestions = []
        isLoadingAutocompleteSuggestions = false
        visibleSuggestedTrackCount = 10
        appState.searchQuery = ""
        appState.clearSearch()
        visibleSongCount = 10
        selectedTab = .songs
    }

    private func scheduleAutocompleteRefresh(for query: String) {
        autocompleteTask?.cancel()

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else {
            autocompleteSuggestions = []
            isLoadingAutocompleteSuggestions = false
            return
        }

        isLoadingAutocompleteSuggestions = true
        autocompleteTask = Task {
            try? await Task.sleep(nanoseconds: AppConfig.Search.autocompleteDebounceNanoseconds)
            guard Task.isCancelled == false else { return }

            let suggestions = await appState.autocompleteSuggestions(for: trimmedQuery, limit: 10)
            guard Task.isCancelled == false else { return }

            await MainActor.run {
                self.autocompleteSuggestions = suggestions
                self.isLoadingAutocompleteSuggestions = false
            }
        }
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
        if prefersCollectionsTab,
           availableTabs.contains(.albums),
           selectedTab != .albums {
            selectedTab = .albums
            return
        }

        guard availableTabs.contains(selectedTab) == false else { return }
        selectedTab = availableTabs.first ?? .songs
    }

    private var prefersCollectionsTab: Bool {
        guard appState.searchResults.playlists.isEmpty == false else { return false }
        let normalizedQuery = trimmedSearchQuery.lowercased()
        return normalizedQuery.contains("list=") || normalizedQuery.contains("/playlist")
    }
}

private struct SearchHeaderView: View {
    let isYouTubeConnected: Bool
    let isRecognizingMusic: Bool
    let onRecognizeTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Search songs, playlists, albums, and artists, then save anything you like to your library.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)

            Text(
                isYouTubeConnected
                    ? "Connected to YouTube, with your MusicTube library available everywhere."
                    : "Guest mode is active. Connect YouTube anytime from Library for account sync."
            )
            .font(.footnote)
            .foregroundStyle(AppTheme.tertiaryText)

            Button(action: onRecognizeTap) {
                HStack(spacing: 12) {
                    Image(systemName: isRecognizingMusic ? "waveform.circle.fill" : "music.note")
                        .font(.title3.weight(.semibold))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(isRecognizingMusic ? "Listening for music..." : "Recognize what’s playing")
                            .font(.subheadline.weight(.semibold))

                        Text(
                            isRecognizingMusic
                                ? "Tap again to stop and use a different search."
                                : "Use your microphone to identify a nearby song and search it instantly."
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
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(isRecognizingMusic ? AppTheme.accent : AppTheme.controlFill)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRecognizingMusic ? "Stop recognizing music" : "Recognize music with microphone")
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

private struct SearchSongSortButton: View {
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

private struct SearchStatusCard: View {
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
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(AppTheme.cardFill)
        )
    }
}

private struct SearchSongResultsSection: View {
    let visibleSongs: [Track]
    let isLoadingMoreResults: Bool
    let onPlay: (Track) -> Void
    let onAppear: (Int, Int) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
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

private struct SearchRecentSearchesSection: View {
    let recentQueries: [String]
    let onSelect: (String) -> Void
    let onDelete: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent searches")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)

            VStack(spacing: 0) {
                ForEach(Array(recentQueries.enumerated()), id: \.element) { index, query in
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

                    if index < recentQueries.count - 1 {
                        Divider()
                            .overlay(AppTheme.divider)
                            .padding(.leading, 38)
                    }
                }
            }
        }
    }
}

private struct SearchAutocompleteSuggestionsSection: View {
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
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
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

                        if index < suggestions.count - 1 {
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

private struct SearchSuggestionsSection: View {
    @EnvironmentObject private var appState: AppState
    let visibleTracks: [Track]
    let isLoadingSuggestedTracks: Bool
    let isLoadingMoreSuggestedTracks: Bool
    let onPlay: (Track) -> Void
    let onAppear: (Int, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Suggestions")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)

            if isLoadingSuggestedTracks, visibleTracks.isEmpty {
                SearchStatusCard(label: "Learning your taste...", showsProgress: true)
            } else if visibleTracks.isEmpty {
                SearchStatusCard(
                    label: "Search and play a few songs to unlock personalized suggestions.",
                    showsProgress: false
                )
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visibleTracks.enumerated()), id: \.element.id) { index, track in
                        TrackSwipeActionsView(
                            onMore: { appState.recommendMoreLike(track) },
                            onLess: { appState.recommendLessLike(track) }
                        ) {
                            RecommendedRow(track: track) {
                                onPlay(track)
                            }
                        }
                        .onAppear {
                            onAppear(index, visibleTracks.count)
                        }

                        if index < visibleTracks.count - 1 {
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

private struct SearchCollectionRow: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var downloadService = DownloadService.shared
    let collection: MusicCollection

    var body: some View {
        HStack(spacing: 12) {
            AsyncArtworkView(url: collection.artworkURL, cornerRadius: 10)
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
                SearchSourceDownloadButton(
                    totalCount: collection.itemCount,
                    downloadedCount: downloadService.downloadCount(for: collectionDownloadSource),
                    pendingCount: downloadService.pendingRequestCount(for: collectionDownloadSource),
                    isPreparing: downloadService.isPreparing(source: collectionDownloadSource),
                    isDownloading: downloadService.isDownloading(source: collectionDownloadSource),
                    size: 36
                ) {
                    appState.downloadCollection(collection)
                }

                Button {
                    appState.toggleCollectionSaved(collection)
                } label: {
                    Image(systemName: appState.isCollectionSaved(collection) ? "bookmark.fill" : "bookmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(appState.isCollectionSaved(collection) ? AppTheme.accent : AppTheme.primaryText)
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

private struct SearchSourceDownloadButton: View {
    let totalCount: Int
    let downloadedCount: Int
    let pendingCount: Int
    let isPreparing: Bool
    let isDownloading: Bool
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(AppTheme.controlFillStrong)
                    .frame(width: size, height: size)

                icon
                    .frame(width: size, height: size)
            }
            .overlay(alignment: .bottomTrailing) {
                if let badgeText {
                    Text(badgeText)
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .foregroundStyle(AppTheme.primaryText)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(AppTheme.controlFillStrong))
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
                .tint(AppTheme.primaryText)
        } else if isComplete {
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(AppTheme.primaryText)
        } else if downloadedCount > 0 {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: size * 0.54, weight: .semibold))
                .foregroundStyle(AppTheme.primaryText)
        } else {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: size * 0.54, weight: .semibold))
                .foregroundStyle(AppTheme.primaryText)
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
}
