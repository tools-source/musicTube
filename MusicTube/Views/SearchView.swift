import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject var viewModel: SearchViewModel
    @FocusState private var isSearchFieldFocused: Bool

    private var snapshot: SearchSnapshot { viewModel.snapshot }
    private var trimmedQuery: String {
        snapshot.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    searchBar

                    if showsRecentSearches {
                        recentSearchesSection
                    } else if showsAutocomplete {
                        autocompleteSection
                    }

                    if trimmedQuery.isEmpty, showsRecentSearches == false {
                        SearchHeaderView(
                            isRecognizingMusic: snapshot.isRecognizingMusic,
                            onRecognizeTap: viewModel.recognizeMusic
                        )
                        .appearTransition(delay: 0.04)

                        discoverySection
                            .appearTransition(delay: 0.10)

                        suggestionsSection
                            .appearTransition(delay: 0.16)
                    }

                    if showsAutocomplete == false {
                        resultsSection
                    }
                }
                .padding(.horizontal, AppLayout.horizontalMargin)
                .padding(.top, 12)
                .padding(.bottom, bottomSpacing)
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(
                    playlist: playlist,
                    viewModel: coordinator.playlistViewModel(for: playlist)
                )
            }
            .navigationDestination(for: MusicCollection.self) { collection in
                CollectionDetailView(collection: collection)
            }
            .onChange(of: isSearchFieldFocused) { _, focused in
                viewModel.setFieldFocused(focused)
            }
            .onDisappear(perform: viewModel.disappear)
            .task { viewModel.appear() }
            .premiumScreenBackground()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.tertiaryText)

                TextField(
                    "Songs, playlists, albums, artists",
                    text: Binding(
                        get: { snapshot.query },
                        set: { viewModel.setQuery($0) }
                    )
                )
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .submitLabel(.search)
                .focused($isSearchFieldFocused)
                .onSubmit {
                    viewModel.submit()
                    isSearchFieldFocused = false
                }

                if trimmedQuery.isEmpty == false {
                    Button(action: viewModel.clear) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(AppTheme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, AppSpacing.medium)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                    .fill(AppTheme.cardFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                            .strokeBorder(AppTheme.surfaceStroke, lineWidth: 1)
                    }
            )

            if isSearchFieldFocused && trimmedQuery.isEmpty {
                Button("Cancel") {
                    viewModel.clear()
                    isSearchFieldFocused = false
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.primaryText)
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        if snapshot.isSearching, snapshot.results.isEmpty {
            SearchStatusCard(
                label: "Searching songs, playlists, albums, and artists...",
                showsProgress: true
            )
        } else if snapshot.results.isEmpty {
            if trimmedQuery.isEmpty == false {
                SearchStatusCard(label: "No results matched that search.", showsProgress: false)
            }
        } else {
            if snapshot.isSearching {
                SearchStatusCard(label: "Refreshing results...", showsProgress: true)
            }

            Text("\(snapshot.results.totalResultCount) results")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.secondaryText)

            resultControls
            resultContent
        }
    }

    private var resultControls: some View {
        HStack(alignment: .center, spacing: 12) {
            SearchResultTabsView(
                availableTabs: snapshot.availableTabs,
                selectedTab: snapshot.selectedTab,
                onSelect: viewModel.setSelectedTab
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            if snapshot.selectedTab == .songs, snapshot.results.songs.isEmpty == false {
                SearchSongSortButton(
                    selectedOption: snapshot.sortOption,
                    onSelect: viewModel.setSortOption
                )
            }
        }
    }

    @ViewBuilder
    private var resultContent: some View {
        switch snapshot.selectedTab {
        case .songs:
            SearchSongResultsSection(
                items: snapshot.visibleSongs,
                isLoadingMoreResults: snapshot.isLoadingMoreResults,
                nowPlayingKey: snapshot.nowPlayingKey,
                isPlaying: snapshot.isPlaying,
                onPlay: viewModel.playSearchTrack,
                onTogglePlayback: viewModel.togglePlayback,
                onAppear: { item in
                    Task { @MainActor in
                        await Task.yield()
                        viewModel.songAppeared(item)
                    }
                }
            )
        case .albums:
            collectionResults
        case .artists:
            artistResults
        }
    }

    private var collectionResults: some View {
        VStack(alignment: .leading, spacing: 18) {
            if snapshot.results.albums.isEmpty && snapshot.results.playlists.isEmpty {
                SearchStatusCard(label: "No albums or playlists matched that search.", showsProgress: false)
            }
            if snapshot.results.albums.isEmpty == false {
                collectionSection(title: "Albums", collections: snapshot.results.albums)
            }
            if snapshot.results.playlists.isEmpty == false {
                collectionSection(title: "Playlists", collections: snapshot.results.playlists)
            }
        }
    }

    private var artistResults: some View {
        VStack(alignment: .leading, spacing: 18) {
            if snapshot.results.artists.isEmpty {
                SearchStatusCard(label: "No artists matched that search.", showsProgress: false)
            } else {
                collectionSection(title: "Artists", collections: snapshot.results.artists)
            }
        }
    }

    private func collectionSection(title: String, collections: [MusicCollection]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(AppTheme.primaryText)

            VStack(spacing: 0) {
                ForEach(collections) { collection in
                    NavigationLink(value: collection) {
                        SearchCollectionRow(
                            collection: collection,
                            isSaved: viewModel.isCollectionSaved(collection),
                            onDownload: { viewModel.downloadCollection(collection) },
                            onToggleSaved: { viewModel.toggleCollectionSaved(collection) }
                        )
                    }
                    .buttonStyle(.plain)

                    if collection.id != collections.last?.id {
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
            recentQueries: snapshot.recentSearches,
            onSelect: selectSuggestion,
            onDelete: viewModel.removeRecentSearch
        )
    }

    private var autocompleteSection: some View {
        SearchAutocompleteSuggestionsSection(
            suggestions: snapshot.autocompleteSuggestions,
            isLoading: snapshot.isLoadingAutocomplete,
            onSelect: selectSuggestion
        )
    }

    @ViewBuilder
    private var discoverySection: some View {
        if snapshot.discoveryArtists.isEmpty == false || snapshot.discoveryMixes.isEmpty == false {
            SearchDiscoverySection(
                artists: snapshot.discoveryArtists,
                mixes: snapshot.discoveryMixes,
                onSelectArtist: selectSuggestion
            )
        }
    }

    private func selectSuggestion(_ suggestion: String) {
        viewModel.selectSuggestion(suggestion)
        isSearchFieldFocused = false
    }

    private var suggestionsSection: some View {
        SearchSuggestionsSection(
            items: snapshot.suggestedTracks,
            isLoadingSuggestedTracks: snapshot.isLoadingSuggestedTracks,
            isLoadingMoreSuggestedTracks: snapshot.isLoadingMoreSuggestedTracks,
            selectedSortOption: snapshot.sortOption,
            nowPlayingKey: snapshot.nowPlayingKey,
            isPlaying: snapshot.isPlaying,
            onSelectSortOption: viewModel.setSortOption,
            onPlay: viewModel.playSuggestedTrack,
            onTogglePlayback: viewModel.togglePlayback,
            onMore: viewModel.recommendMoreLike,
            onLess: viewModel.recommendLessLike,
            onAppear: { item in
                Task { @MainActor in
                    await Task.yield()
                    viewModel.suggestedTrackAppeared(item)
                }
            }
        )
    }

    private var showsRecentSearches: Bool {
        isSearchFieldFocused && trimmedQuery.isEmpty && snapshot.recentSearches.isEmpty == false
    }

    private var showsAutocomplete: Bool {
        isSearchFieldFocused
            && trimmedQuery.isEmpty == false
            && (snapshot.isLoadingAutocomplete || snapshot.autocompleteSuggestions.isEmpty == false)
    }

    private var bottomSpacing: CGFloat {
        snapshot.hasNowPlaying && isSearchFieldFocused == false ? 172 : 108
    }
}
