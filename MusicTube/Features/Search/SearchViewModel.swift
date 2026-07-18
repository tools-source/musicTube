import Combine
import Foundation

@MainActor
protocol SearchDataSource: AnyObject {
    func fetchSearchResults(for query: String) async throws -> SearchResponse
    func fetchMoreSearchResults(query: String, continuation: String) async throws -> SearchResponse
    func autocompleteSuggestions(
        for query: String,
        limit: Int,
        includeRemote: Bool
    ) async -> [String]
    func recentSearchTrackSuggestions(limit: Int) async -> [Track]
}

extension AppState: SearchDataSource {}

@MainActor
final class SearchViewModel: ObservableObject {
    @Published private(set) var snapshot: SearchSnapshot

    private let appState: AppState
    private let dataSource: any SearchDataSource
    private let debounceNanoseconds: UInt64
    private var query = ""
    private var results: SearchResponse = .empty
    private var recentSearches: [String]
    private var autocompleteSuggestions: [String] = []
    private var suggestedTracks: [Track] = []
    private var visibleSongCount = 10
    private var visibleSuggestedTrackCount = 10
    private var selectedTab: SearchResultTab = .songs
    private var sortOption: SongSortOption
    private var isSearching = false
    private var isLoadingAutocomplete = false
    private var isLoadingSuggestedTracks = false
    private var isLoadingMoreSuggestedTracks = false
    private var isLoadingMoreResults = false
    private var hasMoreSuggestedTracks = true
    private var requestID: UUID?
    private var autocompleteRequestID: UUID?
    private var searchTask: Task<Void, Never>?
    private var autocompleteTask: Task<Void, Never>?
    private var suggestionTask: Task<Void, Never>?
    private var paginationTask: Task<Void, Never>?
    private var resultCache: [String: SearchResponse] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init(
        appState: AppState,
        dataSource: (any SearchDataSource)? = nil,
        debounceNanoseconds: UInt64 = 300_000_000,
        defaults: UserDefaults = .standard
    ) {
        self.appState = appState
        self.dataSource = dataSource ?? appState
        self.debounceNanoseconds = debounceNanoseconds
        recentSearches = appState.recentSearches
        sortOption = SongSortOption(
            rawValue: defaults.string(forKey: "search.songSortOption") ?? ""
        ) ?? .default
        snapshot = .empty
        observeRelevantAppState()
        rebuildSnapshot()
    }

    deinit {
        searchTask?.cancel()
        autocompleteTask?.cancel()
        suggestionTask?.cancel()
        paginationTask?.cancel()
    }

    var canLoadMoreResults: Bool {
        isSearching == false
            && isLoadingMoreResults == false
            && results.nextSongsContinuationToken?.isEmpty == false
    }

    func setQuery(_ value: String, immediately: Bool = false) {
        guard value != query || immediately else {
            if immediately { scheduleSearch(immediately: true) }
            return
        }
        query = value
        visibleSongCount = 10
        selectedTab = .songs
        scheduleAutocomplete()
        scheduleSearch(immediately: immediately)
        rebuildSnapshot()
    }

    func submit() {
        autocompleteTask?.cancel()
        autocompleteRequestID = nil
        autocompleteSuggestions = []
        isLoadingAutocomplete = false
        recordRecentSearch(query)
        setFieldFocused(false)
        scheduleSearch(immediately: true)
    }

    func clear() {
        searchTask?.cancel()
        autocompleteTask?.cancel()
        paginationTask?.cancel()
        requestID = nil
        autocompleteRequestID = nil
        query = ""
        results = .empty
        autocompleteSuggestions = []
        visibleSongCount = 10
        selectedTab = .songs
        isSearching = false
        isLoadingAutocomplete = false
        isLoadingMoreResults = false
        rebuildSnapshot()
        refreshSuggestedTracks()
    }

    func setFieldFocused(_ focused: Bool) {
        appState.isSearchFieldFocused = focused
        if focused,
           query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
           autocompleteSuggestions.isEmpty,
           isLoadingAutocomplete == false {
            scheduleAutocomplete()
        }
    }

    func selectSuggestion(_ value: String) {
        autocompleteTask?.cancel()
        autocompleteRequestID = nil
        query = value
        recordRecentSearch(value)
        autocompleteSuggestions = []
        isLoadingAutocomplete = false
        setFieldFocused(false)
        visibleSongCount = 10
        scheduleSearch(immediately: true)
        rebuildSnapshot()
    }

    func removeRecentSearch(_ value: String) {
        appState.removeRecentSearch(value)
        recentSearches = appState.recentSearches
        rebuildSnapshot()
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            refreshSuggestedTracks()
        }
    }

    func setSelectedTab(_ tab: SearchResultTab) {
        selectedTab = tab
        rebuildSnapshot()
    }

    func setSortOption(_ option: SongSortOption) {
        sortOption = option
        UserDefaults.standard.set(option.rawValue, forKey: "search.songSortOption")
        rebuildSnapshot()
    }

    func appear() {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            refreshSuggestedTracks()
        }
    }

    func disappear() {
        searchTask?.cancel()
        autocompleteTask?.cancel()
        suggestionTask?.cancel()
        paginationTask?.cancel()
        requestID = nil
        autocompleteRequestID = nil
        isSearching = false
        isLoadingAutocomplete = false
        isLoadingMoreResults = false
        setFieldFocused(false)
        rebuildSnapshot()
    }

    func songAppeared(_ item: IndexedTrackPresentation) {
        guard item.index >= snapshot.visibleSongs.count - 2 else { return }
        if visibleSongCount < results.songs.count {
            visibleSongCount = min(
                visibleSongCount + AppConfig.Search.visibleSongPageSize,
                results.songs.count
            )
            rebuildSnapshot()
        } else {
            loadMoreResults()
        }
    }

    func suggestedTrackAppeared(_ item: IndexedTrackPresentation) {
        guard item.index >= snapshot.suggestedTracks.count - 2 else { return }
        if visibleSuggestedTrackCount < suggestedTracks.count {
            visibleSuggestedTrackCount = min(
                visibleSuggestedTrackCount + AppConfig.Search.visibleSongPageSize,
                suggestedTracks.count
            )
            rebuildSnapshot()
            return
        }
        guard hasMoreSuggestedTracks, isLoadingMoreSuggestedTracks == false else { return }
        loadSuggestedTracks(
            limit: suggestedTracks.count + max(AppConfig.Search.resultsPerPage, AppConfig.Search.visibleSongPageSize),
            loadingMore: true
        )
    }

    func recognizeMusic() {
        Task { [weak self] in
            guard let self else { return }
            await appState.recognizeMusic()
            guard appState.searchQuery.isEmpty == false else { return }
            query = appState.searchQuery
            results = appState.searchResults
            rebuildSnapshot()
        }
    }

    func playSearchTrack(_ track: Track) {
        recordRecentSearch(query)
        appState.play(track: track, queue: results.songs)
    }

    func playSuggestedTrack(_ track: Track) {
        appState.play(track: track, queue: sortedTracks(suggestedTracks))
    }

    func togglePlayback() { appState.togglePlayback() }
    func recommendMoreLike(_ track: Track) { appState.recommendMoreLike(track) }
    func recommendLessLike(_ track: Track) { appState.recommendLessLike(track) }
    func downloadCollection(_ collection: MusicCollection) { appState.downloadCollection(collection) }
    func toggleCollectionSaved(_ collection: MusicCollection) { appState.toggleCollectionSaved(collection) }
    func isCollectionSaved(_ collection: MusicCollection) -> Bool { appState.isCollectionSaved(collection) }

    private func scheduleSearch(immediately: Bool) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            requestID = nil
            results = .empty
            isSearching = false
            isLoadingMoreResults = false
            rebuildSnapshot()
            return
        }

        let normalized = SearchTextNormalizer.normalized(trimmed)
        if let cached = resultCache[normalized] {
            results = cached
        }
        let id = UUID()
        requestID = id
        isSearching = true
        rebuildSnapshot()

        searchTask = Task { [weak self] in
            guard let self else { return }
            if immediately == false {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
            }
            guard Task.isCancelled == false, requestID == id else { return }
            do {
                let response = try await dataSource.fetchSearchResults(for: trimmed)
                guard Task.isCancelled == false, requestID == id else { return }
                resultCache[normalized] = response
                trimResultCache()
                results = response
                isSearching = false
                synchronizeSelectedTab()
                rebuildSnapshot()
            } catch is CancellationError {
                return
            } catch {
                guard requestID == id else { return }
                results = .empty
                isSearching = false
                appState.errorMessage = error.localizedDescription
                rebuildSnapshot()
            }
        }
    }

    private func scheduleAutocomplete() {
        autocompleteTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            autocompleteRequestID = nil
            autocompleteSuggestions = []
            isLoadingAutocomplete = false
            rebuildSnapshot()
            return
        }

        let id = UUID()
        autocompleteRequestID = id
        isLoadingAutocomplete = true
        rebuildSnapshot()
        autocompleteTask = Task { [weak self] in
            guard let self else { return }
            let local = await dataSource.autocompleteSuggestions(
                for: trimmed,
                limit: 10,
                includeRemote: false
            )
            guard Task.isCancelled == false, autocompleteRequestID == id else { return }
            autocompleteSuggestions = local
            rebuildSnapshot()

            do {
                try await Task.sleep(nanoseconds: debounceNanoseconds)
            } catch {
                return
            }
            guard Task.isCancelled == false, autocompleteRequestID == id else { return }
            let remote = await dataSource.autocompleteSuggestions(
                for: trimmed,
                limit: 10,
                includeRemote: true
            )
            guard Task.isCancelled == false, autocompleteRequestID == id else { return }
            autocompleteSuggestions = mergedAutocompleteSuggestions(
                local: local,
                remote: remote,
                limit: 10
            )
            isLoadingAutocomplete = false
            rebuildSnapshot()
        }
    }

    private func mergedAutocompleteSuggestions(
        local: [String],
        remote: [String],
        limit: Int
    ) -> [String] {
        var seen: Set<String> = []
        return (local + remote).filter { suggestion in
            let normalized = SearchTextNormalizer.normalized(suggestion)
            guard normalized.isEmpty == false else { return false }
            return seen.insert(normalized).inserted
        }
        .prefix(limit)
        .map { $0 }
    }

    private func refreshSuggestedTracks() {
        loadSuggestedTracks(limit: 18, loadingMore: false)
    }

    private func loadSuggestedTracks(limit: Int, loadingMore: Bool) {
        suggestionTask?.cancel()
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            suggestedTracks = []
            isLoadingSuggestedTracks = false
            isLoadingMoreSuggestedTracks = false
            rebuildSnapshot()
            return
        }

        let previousCount = suggestedTracks.count
        isLoadingSuggestedTracks = loadingMore == false
        isLoadingMoreSuggestedTracks = loadingMore
        suggestionTask = Task { [weak self] in
            guard let self else { return }
            let loaded = await dataSource.recentSearchTrackSuggestions(limit: limit)
            guard Task.isCancelled == false else { return }
            suggestedTracks = loaded
            isLoadingSuggestedTracks = false
            isLoadingMoreSuggestedTracks = false
            hasMoreSuggestedTracks = loadingMore
                ? loaded.count > previousCount && loaded.count >= limit
                : loaded.count >= limit
            visibleSuggestedTrackCount = min(
                max(loadingMore ? visibleSuggestedTrackCount + AppConfig.Search.visibleSongPageSize : 10, 10),
                suggestedTracks.count
            )
            rebuildSnapshot()
        }
    }

    private func loadMoreResults() {
        guard canLoadMoreResults, paginationTask == nil else { return }
        guard let continuation = results.nextSongsContinuationToken else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = requestID
        isLoadingMoreResults = true
        rebuildSnapshot()

        paginationTask = Task { [weak self] in
            guard let self else { return }
            defer { paginationTask = nil }
            do {
                let more = try await dataSource.fetchMoreSearchResults(
                    query: trimmed,
                    continuation: continuation
                )
                guard Task.isCancelled == false, requestID == id else { return }
                var merged = results
                var seen = Set<String>()
                merged.trackCategory.items = (results.songs + more.songs).filter {
                    seen.insert($0.playbackKey).inserted
                }
                merged.trackCategory.continuationToken = more.nextSongsContinuationToken
                results = merged
            } catch is CancellationError {
                return
            } catch {
                guard requestID == id else { return }
                appState.errorMessage = error.localizedDescription
            }
            isLoadingMoreResults = false
            rebuildSnapshot()
        }
    }

    private func recordRecentSearch(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        appState.recordRecentSearch(trimmed)
        recentSearches = appState.recentSearches
        rebuildSnapshot()
    }

    private func sortedTracks(_ tracks: [Track]) -> [Track] {
        switch sortOption {
        case .default:
            return tracks
        case .unheard:
            return tracks.filter { appState.isTrackSubstantiallyListened($0) == false }
        case .mostViewed:
            return tracks.sorted { ($0.viewCount ?? 0) > ($1.viewCount ?? 0) }
        case .shortest:
            return tracks.sorted {
                ($0.duration ?? .greatestFiniteMagnitude) < ($1.duration ?? .greatestFiniteMagnitude)
            }
        case .longest:
            return tracks.sorted { ($0.duration ?? 0) > ($1.duration ?? 0) }
        }
    }

    private func rebuildSnapshot() {
        let sortedResults = sortedTracks(results.songs)
        let visibleSongs = Array(sortedResults.prefix(visibleSongCount))
            .enumerated()
            .map { IndexedTrackPresentation(index: $0.offset, track: $0.element) }
        let sortedSuggestions = sortedTracks(suggestedTracks)
        let visibleSuggestions = Array(sortedSuggestions.prefix(visibleSuggestedTrackCount))
            .enumerated()
            .map { IndexedTrackPresentation(index: $0.offset, track: $0.element) }

        snapshot = SearchSnapshot(
            query: query,
            results: results,
            recentSearches: Array(recentSearches.prefix(8)),
            autocompleteSuggestions: autocompleteSuggestions,
            suggestedTracks: visibleSuggestions,
            visibleSongs: visibleSongs,
            availableTabs: availableTabs(),
            selectedTab: selectedTab,
            sortOption: sortOption,
            discoveryArtists: discoveryArtists(),
            discoveryMixes: appState.suggestedMixes,
            nowPlayingKey: appState.nowPlaying?.playbackKey,
            isPlaying: appState.isPlaying,
            hasNowPlaying: appState.nowPlaying != nil,
            isSearching: isSearching,
            isRecognizingMusic: appState.isRecognizingMusic,
            isLoadingAutocomplete: isLoadingAutocomplete,
            isLoadingSuggestedTracks: isLoadingSuggestedTracks,
            isLoadingMoreSuggestedTracks: isLoadingMoreSuggestedTracks,
            isLoadingMoreResults: isLoadingMoreResults,
            hasMoreSuggestedTracks: hasMoreSuggestedTracks
        )
    }

    private func availableTabs() -> [SearchResultTab] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
           results.isEmpty == false {
            return SearchResultTab.allCases
        }
        var tabs: [SearchResultTab] = []
        if results.songs.isEmpty == false { tabs.append(.songs) }
        if results.albums.isEmpty == false || results.playlists.isEmpty == false { tabs.append(.albums) }
        if results.artists.isEmpty == false { tabs.append(.artists) }
        return tabs.isEmpty ? SearchResultTab.allCases : tabs
    }

    private func synchronizeSelectedTab() {
        let tabs = availableTabs()
        let normalizedQuery = query.lowercased()
        if results.playlists.isEmpty == false,
           (normalizedQuery.contains("list=") || normalizedQuery.contains("/playlist")),
           tabs.contains(.albums) {
            selectedTab = .albums
        } else if tabs.contains(selectedTab) == false {
            selectedTab = tabs.first ?? .songs
        }
    }

    private func discoveryArtists() -> [String] {
        var counts: [String: Int] = [:]
        for track in appState.historyTracks + appState.featuredTracks where track.artist.isEmpty == false {
            counts[track.artist, default: 0] += 1
        }
        return counts
            .sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
            }
            .prefix(10)
            .map(\.key)
    }

    private func trimResultCache() {
        guard resultCache.count > 20 else { return }
        resultCache.removeValue(forKey: resultCache.keys.first ?? "")
    }

    private func observeRelevantAppState() {
        appState.$nowPlayingTrack
            .combineLatest(appState.$isPlaybackActive)
            .sink { [weak self] _, _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$homeContent
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$historyTracks
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
        appState.$recentSearches
            .sink { [weak self] searches in
                self?.recentSearches = searches
                self?.rebuildSnapshot()
            }
            .store(in: &cancellables)
        appState.$isRecognizingMusic
            .sink { [weak self] _ in self?.rebuildSnapshot() }
            .store(in: &cancellables)
    }
}
