import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    enum AuthState {
        case restoring
        case guest
        case signedIn
    }

    struct HomeContent: Equatable {
        var featuredTracks: [Track] = []
        var recentTracks: [Track] = []
        var suggestedMixes: [Playlist] = []
        var statusMessage: String?
    }

    private struct TrackCacheEntry {
        let tracks: [Track]
        let expiresAt: Date
    }

    enum PlaylistPickerState: Equatable {
        case hidden
        case create(seedTrack: Track?)
        case add(to: Playlist)
    }

    enum PlaylistPickerHost: Equatable {
        case main
        case player
    }

    private enum ResolvedSearchInput {
        case text(String)
        case playlist(Playlist)
        case video(String)
    }

    @Published private(set) var authState: AuthState = .restoring
    @Published private(set) var user: YouTubeUser?
    @Published private(set) var homeContent = HomeContent()
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var savedCollections: [MusicCollection] = []
    @Published var searchResults: SearchResponse = .empty
    @Published private(set) var playbackState: PlaybackState = .idle
    @Published var searchQuery: String = ""
    @Published private(set) var recentSearches: [String] = []
    @Published private(set) var isSearching = false
    @Published private(set) var isRecognizingMusic = false
    @Published var isLoading = false
    @Published var isLoadingPlaylists = false
    @Published var isPlayerPresented = false
    @Published var errorMessage: String?
    @Published private(set) var libraryStatusMessage: String?
    @Published private(set) var likedTrackIDs: Set<String> = []
    @Published private(set) var savedTrackIDs: Set<String> = []
    @Published private(set) var historyTracks: [Track] = []
    @Published private(set) var librarySectionOrder: [AppLibrarySection] = AppLibrarySection.defaultOrder
    @Published private(set) var isSyncingLikedSongs = false
    @Published private(set) var hasLoadedHome = false
    @Published private(set) var hasLoadedLibrary = false
    @Published private(set) var sleepTimerEndDate: Date?
    @Published private(set) var isDownloadingNowPlaying = false
    @Published private(set) var isDeletingAccountData = false
    @Published private(set) var relatedTracks: [Track] = []
    @Published private(set) var isLoadingRelatedTracks = false
    @Published private(set) var isLoadingMoreRecommendations = false
    @Published private(set) var isLoadingMoreSearchResults = false
    @Published var playlistPickerState: PlaylistPickerState = .hidden
    @Published private(set) var playlistPickerHost: PlaylistPickerHost = .main
    @Published private(set) var resolvingDownloadSourceIDs: Set<String> = []

    private var session: YouTubeSession?
    private var sleepTimerTask: Task<Void, Never>?
    private var relatedTracksTask: Task<Void, Never>?
    private var likedSongsHydrationTask: Task<Void, Never>?
    let downloadService = DownloadService.shared
    private let authService: AuthProviding
    private let catalogService: MusicCatalogProviding
    private let playbackService: PlaybackService
    private let musicRecognitionService = MusicRecognitionService()
    private let localMusicProfileStore: MusicProfileStoring
    private var playlistCache: [String: TrackCacheEntry] = [:]
    private var collectionCache: [String: TrackCacheEntry] = [:]
    private var homeCache: HomeContent?
    private var homeCacheExpiresAt: Date?
    private var cancellables: Set<AnyCancellable> = []
    private var accountLikedTrackIDs: Set<String> = []
    private var isRefreshingDashboard = false
    private var activeSearchRequestID: UUID?
    private var lastLikedSongsAccountSyncDate: Date?
    private let homeCacheTTL: TimeInterval = 30 * 60
    private let localLikedPlaylistID = AppConfig.Library.localLikedPlaylistID
    private let localSavedSongsPlaylistID = AppConfig.Library.localSavedSongsPlaylistID
    private let localReplayMixPlaylistID = AppConfig.Library.localReplayMixPlaylistID
    private let localFavoritesMixPlaylistID = AppConfig.Library.localFavoritesMixPlaylistID
    private let deviceProfileID = AppConfig.Library.deviceProfileID
    private let likedSongsAccountSyncCooldown = AppConfig.Library.likedSongsSyncCooldown
    private let maxConcurrentBatchStreamResolutions = AppConfig.Downloads.maxConcurrentStreamResolutions
    private let batchDownloadResolveSpacingNanoseconds = AppConfig.Downloads.batchResolveSpacingNanoseconds
    private let trackCacheTTL = AppConfig.Cache.trackListTTL

    init(
        authService: AuthProviding,
        catalogService: MusicCatalogProviding,
        playbackService: PlaybackService,
        localMusicProfileStore: MusicProfileStoring = LocalMusicProfileStore.shared
    ) {
        self.authService = authService
        self.catalogService = catalogService
        self.playbackService = playbackService
        self.localMusicProfileStore = localMusicProfileStore
        syncLocalMusicProfileState()

        observePublisher(playbackService.$state) { state, playbackState in
            let previousTrack = state.playbackState.nowPlaying
            let previousIsPlaying = state.playbackState.isPlaying
            guard state.playbackState != playbackState else { return }
            state.playbackState = playbackState

            if previousTrack != playbackState.nowPlaying {
                state.refreshRelatedTracksTask(for: playbackState.nowPlaying)
            }

            if previousTrack != playbackState.nowPlaying || previousIsPlaying != playbackState.isPlaying {
                state.refreshCarPlay()
            }
        }

        observePublisher(playbackService.$playbackErrorMessage) { state, message in
            guard let message else { return }
            state.errorMessage = message
        }

        observePublisher(downloadService.$lastError) { state, error in
            guard let error else { return }
            state.errorMessage = error.localizedDescription
        }

        AppContainer.shared.appState = self

        observePublisher($authState) { state, authState in
            guard authState != .restoring else { return }
            state.refreshCarPlay()
        }
    }

    deinit {
        sleepTimerTask?.cancel()
        relatedTracksTask?.cancel()
        likedSongsHydrationTask?.cancel()
        cancellables.forEach { $0.cancel() }

        if AppContainer.shared.appState === self {
            AppContainer.shared.appState = nil
        }
    }

    static func makeDefault() -> AppState {
        AppState(
            authService: YouTubeAuthService(),
            catalogService: YouTubeAPIService(),
            playbackService: PlaybackService()
        )
    }

    var playbackEngine: PlaybackService {
        playbackService
    }

    var nowPlaying: Track? {
        playbackState.nowPlaying
    }

    var isPlaying: Bool {
        playbackState.isPlaying
    }

    var featuredTracks: [Track] {
        homeContent.featuredTracks
    }

    var recentTracks: [Track] {
        homeContent.recentTracks
    }

    var suggestedMixes: [Playlist] {
        homeContent.suggestedMixes
    }

    var homeStatusMessage: String? {
        homeContent.statusMessage
    }

    var isYouTubeConnected: Bool {
        session != nil
    }

    private func observePublisher<Value>(
        _ publisher: Published<Value>.Publisher,
        handler: @escaping (AppState, Value) -> Void
    ) {
        publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self else { return }
                handler(self, value)
            }
            .store(in: &cancellables)
    }

    private func cachedPlaylistTracks(for playlistID: String) -> [Track]? {
        guard let entry = playlistCache[playlistID] else { return nil }
        guard entry.expiresAt > Date() else {
            playlistCache.removeValue(forKey: playlistID)
            return nil
        }

        return entry.tracks
    }

    private func setPlaylistCache(_ tracks: [Track], for playlistID: String) {
        playlistCache[playlistID] = TrackCacheEntry(
            tracks: tracks,
            expiresAt: Date().addingTimeInterval(trackCacheTTL)
        )
    }

    private func cachedCollectionTracks(for collectionID: String) -> [Track]? {
        guard let entry = collectionCache[collectionID] else { return nil }
        guard entry.expiresAt > Date() else {
            collectionCache.removeValue(forKey: collectionID)
            return nil
        }

        return entry.tracks
    }

    private func setCollectionCache(_ tracks: [Track], for collectionID: String) {
        collectionCache[collectionID] = TrackCacheEntry(
            tracks: tracks,
            expiresAt: Date().addingTimeInterval(trackCacheTTL)
        )
    }

    private func updateHomeContent(
        featuredTracks: [Track]? = nil,
        recentTracks: [Track]? = nil,
        suggestedMixes: [Playlist]? = nil,
        statusMessage: String?? = nil
    ) {
        var updated = homeContent

        if let featuredTracks {
            updated.featuredTracks = featuredTracks
        }

        if let recentTracks {
            updated.recentTracks = recentTracks
        }

        if let suggestedMixes {
            updated.suggestedMixes = suggestedMixes
        }

        if let statusMessage {
            updated.statusMessage = statusMessage
        }

        guard updated != homeContent else { return }
        homeContent = updated

        // Cache the updated home content for 30 minutes
        homeCache = updated
        homeCacheExpiresAt = Date().addingTimeInterval(homeCacheTTL)
    }

    private func refreshCarPlay() {
        AppContainer.shared.carPlayManager?.refresh(using: self)
    }

    var canLoadMoreSearchResults: Bool {
        searchResults.nextSongsContinuationToken?.isEmpty == false
    }

    var likedSongsPlaylist: Playlist? {
        playlists.first(where: { $0.kind == .likedMusic })
    }

    var savedSongsPlaylist: Playlist? {
        playlists.first(where: { $0.kind == .savedSongs })
    }

    var customPlaylists: [Playlist] {
        playlists.filter { $0.kind == .custom }
    }

    var savedPlaylistCollections: [MusicCollection] {
        savedCollections.filter { $0.kind == .playlist }
    }

    var savedAlbumCollections: [MusicCollection] {
        savedCollections.filter { $0.kind == .album }
    }

    var savedArtistCollections: [MusicCollection] {
        savedCollections.filter { $0.kind == .artist }
    }

    var visibleLibrarySectionOrder: [AppLibrarySection] {
        librarySectionOrder.filter(isLibrarySectionVisible(_:))
    }

    var libraryPlaylists: [Playlist] {
        playlists.filter { $0.kind != .likedMusic && $0.kind != .savedSongs }
    }

    var isUsingLocalLibraryFallback: Bool {
        playlists.contains(where: { isLocalCollectionID($0.id) })
    }

    func isTrackLiked(_ track: Track) -> Bool {
        likedTrackIDs.contains(trackIdentifier(track))
    }

    func isTrackSaved(_ track: Track) -> Bool {
        savedTrackIDs.contains(trackIdentifier(track))
    }

    func isCollectionSaved(_ collection: MusicCollection) -> Bool {
        savedCollections.contains(where: { $0.id == collection.id })
    }

    func isLibrarySectionVisible(_ section: AppLibrarySection) -> Bool {
        switch section {
        case .history:
            return historyTracks.isEmpty == false
        case .quickActions, .likedSongs, .savedSongs, .customPlaylists, .savedCollections:
            return true
        }
    }

    func moveLibrarySection(_ draggedSection: AppLibrarySection, to targetSection: AppLibrarySection) {
        guard draggedSection != targetSection else { return }
        guard let sourceIndex = librarySectionOrder.firstIndex(of: draggedSection),
              let targetIndex = librarySectionOrder.firstIndex(of: targetSection) else {
            return
        }

        var updatedOrder = librarySectionOrder
        let movedSection = updatedOrder.remove(at: sourceIndex)
        updatedOrder.insert(movedSection, at: targetIndex)
        persistLibrarySectionOrder(updatedOrder)
    }

    var playlistPickerTrack: Track? {
        if case .create(let track) = playlistPickerState { return track }
        return nil
    }

    var playlistPickerTargetPlaylist: Playlist? {
        if case .add(let playlist) = playlistPickerState { return playlist }
        return nil
    }

    func signIn() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let session = try await authService.signIn()
            applyAuthorizedSession(session)
            syncLocalMusicProfileState()
            await refreshDashboard()
        } catch {
            errorMessage = error.localizedDescription
            authState = .guest
        }
    }

    func signOut() async {
        await authService.signOut()
        session = nil
        user = nil
        authState = .guest
        clearRemoteState()
        syncLocalMusicProfileState()
        await refreshDashboard()
    }

    func deleteCurrentAccountData() async {
        guard isDeletingAccountData == false else { return }

        isDeletingAccountData = true
        defer { isDeletingAccountData = false }

        await authService.signOut()
        downloadService.deleteAllDownloads()
        localMusicProfileStore.clearAllData()

        session = nil
        user = nil
        authState = .guest
        resetAllLoadedState()
        syncLocalMusicProfileState()
        await refreshDashboard()
    }

    func refreshDashboard() async {
        guard isRefreshingDashboard == false else { return }

        isRefreshingDashboard = true
        defer { isRefreshingDashboard = false }

        // If we have any cached content, show it immediately so the screen isn't blank,
        // then refresh everything in the background regardless of cache age.
        if let cached = homeCache, cached.featuredTracks.isEmpty == false {
            updateHomeContent(
                featuredTracks: cached.featuredTracks,
                recentTracks: cached.recentTracks,
                suggestedMixes: cached.suggestedMixes,
                statusMessage: cached.statusMessage
            )
            hasLoadedHome = true

            // Only skip the network hit if the cache is still fresh (< 30 min)
            if let expiresAt = homeCacheExpiresAt, expiresAt > Date() {
                Task { await self.refreshLibrary() }
                return
            }
        }

        // Parallel load — library and home don't depend on each other
        async let libraryLoad: Void = refreshLibrary()
        async let homeLoad: Void = refreshHome()
        _ = await (libraryLoad, homeLoad)
    }

    func refreshHome() async {
        guard isLoading == false else { return }

        isLoading = true
        defer {
            isLoading = false
            hasLoadedHome = true
        }

        var didFallBackFromExpiredSession = false

        if session != nil {
            do {
                if let home = try await performAuthenticatedOperation({ accessToken in
                    try await catalogService.loadHome(accessToken: accessToken)
                }) {
                    let learnedTracks = await smartRecommendations(
                        limit: 24,
                        excluding: Set((home.featured + home.recent).map(trackIdentifier))
                    )
                    let mergedFeatured = curatedSuggestionTracks(
                        deduplicatedTracks(home.featured + learnedTracks + home.recent)
                    )
                    let featured = Array(mergedFeatured.prefix(60))
                    let featuredIDs = Set(featured.map(trackIdentifier))
                    let recent = Array(
                        curatedSuggestionTracks(
                            deduplicatedTracks(home.recent + learnedTracks.shuffled() + home.featured.shuffled())
                        )
                            .filter { featuredIDs.contains(trackIdentifier($0)) == false }
                            .prefix(40)
                    )

                    updateHomeContent(
                        featuredTracks: featured,
                        recentTracks: recent,
                        statusMessage: nil
                    )

                    refreshCarPlay()

                    Task {
                        await rebuildSuggestedMixes()
                        self.refreshCarPlay()
                    }

                    Task {
                        self.playbackService.prefetchStreams(for: Array(featured.prefix(10)))
                    }
                    return
                }
            } catch {
                if await handleAuthorizationFailureIfNeeded(for: error) {
                    didFallBackFromExpiredSession = true
                    updateHomeContent(
                        statusMessage: "Your YouTube session expired, so MusicTube is using on-device picks for now."
                    )
                }
                if await buildHomeFromLoadedLibrary() {
                    updateHomeContent(
                        statusMessage: "Using your MusicTube taste profile while YouTube recommendations reload."
                    )
                    refreshCarPlay()
                    return
                }
            }
        }

        if await buildHomeFromLoadedLibrary() {
            updateHomeContent(
                statusMessage: hasPersonalizedRecommendationSignals()
                    ? nil
                    : starterRecommendationsStatusMessage(expiredSessionFallback: didFallBackFromExpiredSession)
            )
            refreshCarPlay()
            return
        }

        if await buildStarterHome() {
            updateHomeContent(
                statusMessage: starterRecommendationsStatusMessage(expiredSessionFallback: didFallBackFromExpiredSession)
            )
            refreshCarPlay()
            return
        }

        updateHomeContent(
            featuredTracks: [],
            recentTracks: [],
            suggestedMixes: [],
            statusMessage: isYouTubeConnected
                ? "Reconnect YouTube or play more songs so MusicTube can rebuild your recommendations."
                : "Search and play a few songs so MusicTube can learn what you like."
        )
        playlistCache = playlistCache.filter { isSyntheticMixID($0.key) == false }
    }

    func loadMoreRecommendedTracksIfNeeded() async {
        guard isLoadingMoreRecommendations == false else { return }

        isLoadingMoreRecommendations = true
        defer { isLoadingMoreRecommendations = false }

        let existingIDs = Set((featuredTracks + recentTracks).map(trackIdentifier))
        var moreTracks = await smartRecommendations(limit: 24, excluding: existingIDs)
        if moreTracks.isEmpty {
            moreTracks = await starterRecommendations(limit: 24, excluding: existingIDs)
        }
        guard moreTracks.isEmpty == false else { return }

        updateHomeContent(
            featuredTracks: curatedSuggestionTracks(deduplicatedTracks(featuredTracks + moreTracks))
        )
        refreshCarPlay()
    }

    func performSearch() async {
        _ = await search(query: searchQuery)
    }

    func search(query: String) async -> SearchResponse {
        let resolvedInput = resolveSearchInput(from: query)
        let trimmed: String
        switch resolvedInput {
        case .text(let value):
            trimmed = value
        case .playlist(let playlist):
            trimmed = playlist.id
        case .video(let videoID):
            trimmed = videoID
        }

        if trimmed.isEmpty {
            clearSearch()
            return .empty
        }

        let requestID = UUID()
        activeSearchRequestID = requestID
        isSearching = true
        isLoadingMoreSearchResults = false

        do {
            let accessToken = await authorizedAccessTokenIfAvailable()
            if let directResponse = try await resolveDirectSearchResponse(
                from: resolvedInput,
                accessToken: accessToken
            ) {
                guard activeSearchRequestID == requestID else { return .empty }
                searchResults = directResponse
                isSearching = false
                errorMessage = nil
                return directResponse
            }

            let results = try await catalogService.search(query: trimmed, accessToken: accessToken)
            guard activeSearchRequestID == requestID else { return results }
            searchResults = results
            isSearching = false
            errorMessage = nil
            return results
        } catch {
            guard activeSearchRequestID == requestID else { return .empty }
            searchResults = .empty
            isSearching = false
            errorMessage = error.localizedDescription
            return .empty
        }
    }

    func clearSearch() {
        activeSearchRequestID = nil
        isSearching = false
        isLoadingMoreSearchResults = false
        searchResults = .empty
    }

    func recognizeMusic() async {
        guard isRecognizingMusic == false else {
            musicRecognitionService.stopRecognition()
            return
        }

        isRecognizingMusic = true
        errorMessage = nil
        
        do {
            let detectedQuery = try await musicRecognitionService.recognizeSong()
            searchQuery = detectedQuery
            isRecognizingMusic = false
            await performSearch()
        } catch {
            isRecognizingMusic = false
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    func loadMoreSearchResultsIfNeeded() async {
        guard isLoadingMoreSearchResults == false else { return }
        guard isSearching == false else { return }
        guard let continuation = searchResults.nextSongsContinuationToken, continuation.isEmpty == false else { return }

        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return }

        let requestID = activeSearchRequestID
        isLoadingMoreSearchResults = true
        defer { isLoadingMoreSearchResults = false }

        do {
            let accessToken = await authorizedAccessTokenIfAvailable()
            let moreResults = try await catalogService.loadMoreSearchResults(
                query: trimmedQuery,
                continuation: continuation,
                accessToken: accessToken
            )
            guard activeSearchRequestID == requestID else { return }

            var mergedResults = searchResults
            mergedResults.trackCategory.items = deduplicatedTracks(searchResults.songs + moreResults.songs)
            mergedResults.trackCategory.continuationToken = moreResults.nextSongsContinuationToken
            searchResults = mergedResults
        } catch {
            guard activeSearchRequestID == requestID else { return }
            errorMessage = error.localizedDescription
        }
    }

    func recordRecentSearch(_ query: String) {
        let snapshot = localMusicProfileStore.recordSearch(query, for: currentProfileID)
        recentSearches = snapshot.recentSearches
    }

    func removeRecentSearch(_ query: String) {
        let snapshot = localMusicProfileStore.removeRecentSearch(query, for: currentProfileID)
        recentSearches = snapshot.recentSearches
    }

    func removeHistoryTrack(_ track: Track) {
        let _ = localMusicProfileStore.removeRecentTrack(track, profileID: currentProfileID)
        syncLocalMusicProfileState()
        refreshLocalLibraryOverlay()

        if featuredTracks.isEmpty || homeStatusMessage != nil {
            Task { [weak self] in
                await self?.refreshHome()
            }
        }
    }

    func clearHistory() {
        let _ = localMusicProfileStore.clearRecentTracks(profileID: currentProfileID)
        syncLocalMusicProfileState()
        refreshLocalLibraryOverlay()

        if featuredTracks.isEmpty || homeStatusMessage != nil {
            Task { [weak self] in
                await self?.refreshHome()
            }
        }
    }

    func recentSearchTrackSuggestions(limit: Int = 18) async -> [Track] {
        let suggestionQueries = Array(recentSearches.prefix(6))
        guard suggestionQueries.isEmpty == false else { return [] }

        let resultBuckets = await withTaskGroup(of: [Track]?.self) { group in
            let accessToken = await authorizedAccessTokenIfAvailable()
            for query in suggestionQueries {
                guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { continue }

                group.addTask {
                    do {
                        if let directResponse = try await self.resolveDirectSearchResponse(
                            from: self.resolveSearchInput(from: query),
                            accessToken: accessToken
                        ) {
                            let bucket = Array(directResponse.songs.prefix(12))
                            return bucket.isEmpty ? nil : bucket
                        }

                        let results = try await self.catalogService.search(query: query, accessToken: accessToken)
                        let bucket = Array(results.songs.prefix(12))
                        return bucket.isEmpty ? nil : bucket
                    } catch {
                        return nil
                    }
                }
            }

            var buckets: [[Track]] = []
            for await bucket in group {
                if let bucket {
                    buckets.append(bucket)
                }
            }
            return buckets
        }

        guard resultBuckets.isEmpty == false else { return [] }

        var suggestions: [Track] = []
        var seenTrackIDs: Set<String> = []
        var bucketOffsets = Array(repeating: 0, count: resultBuckets.count)

        while suggestions.count < limit {
            var appendedTrackThisRound = false

            for bucketIndex in resultBuckets.indices {
                while bucketOffsets[bucketIndex] < resultBuckets[bucketIndex].count {
                    let track = resultBuckets[bucketIndex][bucketOffsets[bucketIndex]]
                    bucketOffsets[bucketIndex] += 1

                    let identifier = trackIdentifier(track)
                    guard seenTrackIDs.insert(identifier).inserted else { continue }

                    suggestions.append(track)
                    appendedTrackThisRound = true
                    break
                }

                if suggestions.count >= limit {
                    break
                }
            }

            if appendedTrackThisRound == false {
                break
            }
        }

        return curatedSuggestionTracks(suggestions)
    }

    func play(track: Track, queue: [Track]? = nil) {
        playbackService.play(track: track, queue: queue)
        refreshCarPlay()

        Task { @MainActor [weak self] in
            self?.recordLocalPlayback(for: track)
        }
    }

    func prefetchPlayback(for tracks: [Track]) {
        playbackService.prefetchStreams(for: tracks)
    }

    func playNextTrack() {
        playbackService.playNextTrack()
        refreshCarPlay()
    }

    func playPreviousTrack() {
        playbackService.playPreviousTrack()
        refreshCarPlay()
    }

    func refreshLibrary() async {
        guard isLoadingPlaylists == false else { return }

        isLoadingPlaylists = true
        defer {
            isLoadingPlaylists = false
            hasLoadedLibrary = true
        }

        if session != nil {
            do {
                if let loadedPlaylists = try await performAuthenticatedOperation({ accessToken in
                    try await catalogService.loadPlaylists(accessToken: accessToken)
                }) {
                    playlists = mergedLibraryPlaylists(remotePlaylists: loadedPlaylists)
                    trimCachesToValidCollections()
                    if let likedPlaylist = likedSongsPlaylist, isLocalCollectionID(likedPlaylist.id) == false {
                        libraryStatusMessage = "Syncing all liked songs from YouTube..."
                        startLikedSongsHydration(forceRefresh: true)
                    } else {
                        libraryStatusMessage = libraryStatusMessageText(for: playlists, savedCollections: savedCollections)
                    }
                    refreshCarPlay()
                    return
                }
            } catch {
                if await handleAuthorizationFailureIfNeeded(for: error) {
                    libraryStatusMessage = "Your YouTube session expired, so MusicTube is showing your on-device library."
                }
            }
        }

        let preservedLibraryStatus = libraryStatusMessage
        cancelLikedSongsHydration(clearAccountLikes: false)
        playlists = mergedLibraryPlaylists(remotePlaylists: [])
        trimCachesToValidCollections()
        libraryStatusMessage = preservedLibraryStatus ?? libraryStatusMessageText(for: playlists, savedCollections: savedCollections)
        refreshCarPlay()
    }

    func loadPlaylistItems(
        for playlist: Playlist,
        forceRefresh: Bool = false,
        surfaceErrors: Bool = true
    ) async -> [Track] {
        if isSyntheticMixID(playlist.id) || isLocalCollectionID(playlist.id) {
            if forceRefresh == false, let cached = cachedPlaylistTracks(for: playlist.id) {
                return cached
            }

            _ = mergedLibraryPlaylists(remotePlaylists: playlists.filter { isLocalCollectionID($0.id) == false })
            return cachedPlaylistTracks(for: playlist.id) ?? []
        }

        let localLikedTracks = playlist.kind == .likedMusic
            ? localMusicProfileStore.snapshot(for: currentProfileID).likedTracks
            : []

        if forceRefresh == false,
           let cached = cachedPlaylistTracks(for: playlist.id),
           cached.isEmpty == false {
            return cached
        }

        do {
            let tracks: [Track]
            if session != nil {
                tracks = try await performAuthenticatedOperation { accessToken in
                    try await self.catalogService.loadPlaylistItems(
                        for: playlist,
                        accessToken: accessToken
                    )
                } ?? []
            } else {
                if playlist.kind == .likedMusic {
                    tracks = localLikedTracks
                } else {
                    tracks = try await catalogService.loadPlaylistItems(
                        for: playlist,
                        accessToken: nil
                    )
                }
            }

            if tracks.isEmpty {
                playlistCache.removeValue(forKey: playlist.id)
            } else {
                setPlaylistCache(tracks, for: playlist.id)
            }
            if surfaceErrors {
                errorMessage = nil
            }
            return tracks
        } catch {
            if surfaceErrors && shouldSuppressBackgroundCatalogError(error) == false {
                errorMessage = error.localizedDescription
            }
            if let cached = cachedPlaylistTracks(for: playlist.id), cached.isEmpty == false {
                return cached
            }
            if playlist.kind == .likedMusic, localLikedTracks.isEmpty == false {
                let fallbackTracks = deduplicatedTracks(localLikedTracks)
                setPlaylistCache(fallbackTracks, for: playlist.id)
                return fallbackTracks
            }
            return []
        }
    }

    func loadCollectionItems(
        for collection: MusicCollection,
        forceRefresh: Bool = false,
        surfaceErrors: Bool = true
    ) async -> [Track] {
        if forceRefresh == false,
           let cached = cachedCollectionTracks(for: collection.id),
           cached.isEmpty == false {
            return cached
        }

        do {
            let tracks: [Track]
            if session != nil {
                tracks = try await performAuthenticatedOperation { accessToken in
                    try await self.catalogService.loadCollectionItems(
                        for: collection,
                        accessToken: accessToken
                    )
                } ?? []
            } else {
                tracks = try await catalogService.loadCollectionItems(
                    for: collection,
                    accessToken: nil
                )
            }
            if tracks.isEmpty {
                collectionCache.removeValue(forKey: collection.id)
            } else {
                setCollectionCache(tracks, for: collection.id)
            }
            if surfaceErrors {
                errorMessage = nil
            }
            return tracks
        } catch {
            if surfaceErrors && shouldSuppressBackgroundCatalogError(error) == false {
                errorMessage = error.localizedDescription
            }
            if let cached = cachedCollectionTracks(for: collection.id), cached.isEmpty == false {
                return cached
            }
            return []
        }
    }

    func pause() {
        playbackService.pause()
    }

    func resumePlayback() {
        playbackService.resume()
    }

    func seek(to time: TimeInterval) {
        playbackService.seek(to: time)
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            resumePlayback()
        }
    }

    func closeNowPlaying() {
        playbackService.stop()
        isPlayerPresented = false
    }

    func dismissPlayer() {
        isPlayerPresented = false
    }

    func toggleShuffle() {
        playbackService.toggleShuffle()
    }

    func cycleRepeatMode() {
        playbackService.cycleRepeatMode()
    }

    func setSleepTimer(minutes: Int) {
        sleepTimerTask?.cancel()
        sleepTimerEndDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000)
            guard Task.isCancelled == false else { return }
            await MainActor.run { [weak self] in
                self?.pause()
                self?.sleepTimerEndDate = nil
            }
        }
    }

    func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEndDate = nil
    }

    func downloadNowPlaying() {
        guard let track = nowPlaying else { return }
        downloadTrack(track)
    }

    func isDownloadingSource(id sourceID: String) -> Bool {
        resolvingDownloadSourceIDs.contains(sourceID)
            || downloadService.isDownloading(sourceID: sourceID)
    }

    func downloadTrack(
        _ track: Track,
        source: DownloadSource? = nil,
        sourceTrackIndex: Int? = nil
    ) {
        guard !downloadService.isDownloaded(track), !downloadService.isDownloading(track) else { return }

        isDownloadingNowPlaying = true
        Task {
            defer { Task { @MainActor in self.isDownloadingNowPlaying = false } }
            do {
                if let streamURL = try await playbackService.resolveDownloadStreamURL(for: track) {
                    guard isValidDownloadURL(streamURL) else {
                        await MainActor.run {
                            self.errorMessage = "Download failed: invalid stream URL format"
                        }
                        return
                    }
                    downloadService.startDownload(
                        track: track,
                        streamURL: streamURL,
                        source: source,
                        sourceTrackIndex: sourceTrackIndex
                    )
                } else {
                    await MainActor.run {
                        self.errorMessage = "Couldn't extract audio for this track. Try a different version."
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = userFriendlyDownloadError(error)
                }
            }
        }
    }

    func downloadCollection(_ collection: MusicCollection) {
        let source = DownloadSource(id: collection.id, title: collection.title, kind: collection.kind)
        resolvingDownloadSourceIDs.insert(source.id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.resolvingDownloadSourceIDs.remove(source.id) }
            let tracks = await self.loadCollectionItems(for: collection)
            guard tracks.isEmpty == false else { return }
            await self.downloadTracks(tracks, source: source)
        }
    }

    func downloadPlaylist(_ playlist: Playlist) {
        let source = DownloadSource(
            id: "playlist:\(playlist.id)",
            title: playlist.title,
            kind: .playlist
        )
        resolvingDownloadSourceIDs.insert(source.id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.resolvingDownloadSourceIDs.remove(source.id) }
            let tracks = await self.loadPlaylistItems(for: playlist)
            guard tracks.isEmpty == false else { return }
            await self.downloadTracks(tracks, source: source)
        }
    }

    private func downloadTracks(_ tracks: [Track], source: DownloadSource?) async {
        let pendingTracks = tracks.enumerated().filter {
            downloadService.isDownloaded($0.element) == false && downloadService.isDownloading($0.element) == false
        }
        guard pendingTracks.isEmpty == false else { return }

        for startIndex in stride(from: 0, to: pendingTracks.count, by: maxConcurrentBatchStreamResolutions) {
            let endIndex = min(startIndex + maxConcurrentBatchStreamResolutions, pendingTracks.count)
            let batch = Array(pendingTracks[startIndex..<endIndex])

            await withTaskGroup(of: Void.self) { group in
                for item in batch {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        do {
                            if let streamURL = try await self.playbackService.resolveDownloadStreamURL(for: item.element) {
                                guard self.isValidDownloadURL(streamURL) else {
                                    await MainActor.run {
                                        if self.errorMessage == nil {
                                            self.errorMessage = "Download failed for \(item.element.title): invalid stream URL"
                                        }
                                    }
                                    return
                                }
                                await MainActor.run {
                                    self.downloadService.startDownload(
                                        track: item.element,
                                        streamURL: streamURL,
                                        source: source,
                                        sourceTrackIndex: item.offset
                                    )
                                }
                            }
                        } catch {
                            await MainActor.run {
                                if self.errorMessage == nil {
                                    self.errorMessage = "Failed to download \(item.element.title): \(self.userFriendlyDownloadError(error))"
                                }
                            }
                        }
                    }
                }
            }

            if endIndex < pendingTracks.count {
                try? await Task.sleep(nanoseconds: batchDownloadResolveSpacingNanoseconds)
            }
        }
    }

    func toggleLike(for track: Track) {
        let shouldLike = likedTrackIDs.contains(trackIdentifier(track)) == false
        applyLocalLikeState(shouldLike, for: track)
    }

    func toggleTrackSaved(_ track: Track) {
        let shouldSave = isTrackSaved(track) == false
        let _ = localMusicProfileStore.setTrackSaved(shouldSave, for: track, profileID: currentProfileID)
        syncLocalMusicProfileState()
        refreshLocalLibraryOverlay()

        if featuredTracks.isEmpty || homeStatusMessage != nil {
            Task { [weak self] in
                await self?.refreshHome()
            }
        }
    }

    func toggleCollectionSaved(_ collection: MusicCollection) {
        let shouldSave = isCollectionSaved(collection) == false
        let _ = localMusicProfileStore.setCollectionSaved(shouldSave, for: collection, profileID: currentProfileID)
        syncLocalMusicProfileState()
        refreshLocalLibraryOverlay()
    }

    func presentPlaylistPicker(for track: Track) {
        playlistPickerHost = isPlayerPresented ? .player : .main
        playlistPickerState = .create(seedTrack: track)
    }

    func presentPlaylistCreator() {
        playlistPickerHost = isPlayerPresented ? .player : .main
        playlistPickerState = .create(seedTrack: nil)
    }

    func presentPlaylistSongAdder(for playlist: Playlist) {
        playlistPickerHost = isPlayerPresented ? .player : .main
        playlistPickerState = .add(to: playlist)
    }

    func dismissPlaylistPicker() {
        playlistPickerState = .hidden
        playlistPickerHost = .main
        clearSearch()
        searchQuery = ""
    }

    func addPlaylistPickerTrack(to playlist: Playlist) {
        guard let track = playlistPickerTrack else { return }
        addTrack(track, to: playlist)
        dismissPlaylistPicker()
    }

    func addTrack(_ track: Track, to playlist: Playlist) {
        let _ = localMusicProfileStore.addTrack(track, toCustomPlaylist: playlist.id, profileID: currentProfileID)
        syncLocalMusicProfileState()
        refreshLocalLibraryOverlay()
        setPlaylistCache(
            deduplicatedTracks([track] + (cachedPlaylistTracks(for: playlist.id) ?? [])),
            for: playlist.id
        )
    }

    @discardableResult
    func createCustomPlaylist(named name: String) -> Bool {
        guard let playlist = localMusicProfileStore.createCustomPlaylist(
            named: name,
            description: "",
            seedTrack: playlistPickerTrack,
            profileID: currentProfileID
        ) else {
            return false
        }

        syncLocalMusicProfileState()
        refreshLocalLibraryOverlay()
        setPlaylistCache(playlist.tracks, for: playlist.id)
        dismissPlaylistPicker()
        return true
    }

    func renameCustomPlaylist(_ playlist: Playlist, to name: String) -> Bool {
        guard playlist.kind == .custom else { return false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false else { return false }

        let _ = localMusicProfileStore.renameCustomPlaylist(
            playlistID: playlist.id,
            to: trimmedName,
            description: playlist.description,
            profileID: currentProfileID
        )
        syncLocalMusicProfileState()
        refreshLocalLibraryOverlay()
        return true
    }

    func deleteCustomPlaylist(_ playlist: Playlist) {
        guard playlist.kind == .custom else { return }
        let _ = localMusicProfileStore.deleteCustomPlaylist(playlist.id, profileID: currentProfileID)
        playlistCache.removeValue(forKey: playlist.id)
        syncLocalMusicProfileState()
        refreshLocalLibraryOverlay()
    }

    func removeTrack(_ track: Track, from playlist: Playlist) {
        guard playlist.kind == .custom else { return }
        let _ = localMusicProfileStore.removeTrack(track, fromCustomPlaylist: playlist.id, profileID: currentProfileID)
        syncLocalMusicProfileState()
        refreshLocalLibraryOverlay()
        var updatedTracks = cachedPlaylistTracks(for: playlist.id) ?? []
        updatedTracks.removeAll { $0.playbackKey == track.playbackKey }
        if updatedTracks.isEmpty {
            playlistCache.removeValue(forKey: playlist.id)
        } else {
            setPlaylistCache(updatedTracks, for: playlist.id)
        }
    }

    func isTrack(_ track: Track, in playlist: Playlist) -> Bool {
        let cachedTracks = cachedPlaylistTracks(for: playlist.id) ?? []
        return cachedTracks.contains { $0.playbackKey == track.playbackKey }
    }

    func searchTracksForPlaylist(_ query: String) async -> [Track] {
        let resolvedInput = resolveSearchInput(from: query)
        let trimmed: String
        switch resolvedInput {
        case .text(let value):
            trimmed = value
        case .playlist(let playlist):
            trimmed = playlist.id
        case .video(let videoID):
            trimmed = videoID
        }

        guard trimmed.isEmpty == false else { return [] }

        do {
            let accessToken = await authorizedAccessTokenIfAvailable()
            if let directResponse = try await resolveDirectSearchResponse(
                from: resolvedInput,
                accessToken: accessToken
            ) {
                return directResponse.songs
            }

            let results = try await catalogService.search(query: trimmed, accessToken: accessToken)
            return results.songs
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func refreshLikedSongsPlaylistFromAccount() async {
        guard let likedPlaylist = likedSongsPlaylist else {
            syncLocalMusicProfileState()
            return
        }

        guard isLocalCollectionID(likedPlaylist.id) == false else {
            syncLocalMusicProfileState()
            return
        }

        if let lastLikedSongsAccountSyncDate,
           Date().timeIntervalSince(lastLikedSongsAccountSyncDate) < likedSongsAccountSyncCooldown {
            return
        }

        startLikedSongsHydration(forceRefresh: true)
    }

    func restoreSession() async {
        if let restored = await authService.restoreSession() {
            applyAuthorizedSession(restored)
        } else {
            authState = .guest
        }

        syncLocalMusicProfileState()
        
        Task {
            await refreshDashboard()
        }
    }

    private func refreshRelatedTracksTask(for track: Track?) {
        relatedTracksTask?.cancel()
        relatedTracksTask = nil

        guard let track else {
            relatedTracks = []
            isLoadingRelatedTracks = false
            return
        }

        isLoadingRelatedTracks = true
        relatedTracksTask = Task { [weak self] in
            guard let self else { return }
            let tracks = await self.smartRecommendations(
                limit: 18,
                excluding: Set([self.trackIdentifier(track)]),
                focusedTrack: track
            )
            guard Task.isCancelled == false else { return }
            await MainActor.run {
                self.relatedTracks = tracks
                self.isLoadingRelatedTracks = false
            }
        }
    }

    private func resetAllLoadedState() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        relatedTracksTask?.cancel()
        relatedTracksTask = nil
        cancelLikedSongsHydration()
        playbackService.stop()
        updateHomeContent(
            featuredTracks: [],
            recentTracks: [],
            suggestedMixes: [],
            statusMessage: nil
        )
        playlists = []
        searchResults = .empty
        searchQuery = ""
        isPlayerPresented = false
        isSearching = false
        isDownloadingNowPlaying = false
        playlistCache = [:]
        collectionCache = [:]
        activeSearchRequestID = nil
        errorMessage = nil
        libraryStatusMessage = nil
        likedTrackIDs = []
        savedTrackIDs = []
        historyTracks = []
        savedCollections = []
        recentSearches = []
        relatedTracks = []
        hasLoadedHome = false
        hasLoadedLibrary = false
        isRefreshingDashboard = false
        isSyncingLikedSongs = false
        sleepTimerEndDate = nil
        playlistPickerState = .hidden
        lastLikedSongsAccountSyncDate = nil
        accountLikedTrackIDs = []
    }

    private func clearRemoteState() {
        updateHomeContent(
            featuredTracks: [],
            recentTracks: [],
            suggestedMixes: [],
            statusMessage: nil
        )
        playlists = []
        cancelLikedSongsHydration()
        playlistCache = playlistCache.filter { isLocalCollectionID($0.key) }
        collectionCache.removeAll()
        hasLoadedHome = false
        hasLoadedLibrary = false
        lastLikedSongsAccountSyncDate = nil
    }

    private func buildHomeFromLoadedLibrary() async -> Bool {
        let snapshot = localMusicProfileStore.snapshot(for: currentProfileID)
        let candidateMixes = selectSuggestedMixSourcePlaylists(from: playlists)
        let likedPlaylist = likedSongsPlaylist
        let savedSongsPlaylist = savedSongsPlaylist

        async let likedTracksFetch: [Track] = {
            if let likedPlaylist {
                return await self.loadPlaylistItems(for: likedPlaylist, surfaceErrors: false)
            }
            return []
        }()
        async let savedTracksFetch: [Track] = {
            if let savedSongsPlaylist {
                return await self.loadPlaylistItems(for: savedSongsPlaylist)
            }
            return snapshot.savedTracks
        }()

        let mixTracks = await withTaskGroup(of: [Track].self) { group in
            for playlist in candidateMixes.prefix(6) {
                group.addTask { await self.loadPlaylistItems(for: playlist, surfaceErrors: false) }
            }

            var tracks: [Track] = []
            for await batch in group {
                tracks.append(contentsOf: self.randomizedTracks(from: batch, limit: 14))
            }
            return tracks
        }

        let likedTracks = curatedSuggestionTracks(await likedTracksFetch)
        let savedTracks = curatedSuggestionTracks(await savedTracksFetch)
        let topTracks = curatedSuggestionTracks(snapshot.topTracks)
        let recentProfileTracks = curatedSuggestionTracks(snapshot.recentTracks)
        let curatedMixTracks = curatedSuggestionTracks(mixTracks)
        let learnedTracks = await smartRecommendations(
            limit: 30,
            excluding: Set((likedTracks + savedTracks + curatedMixTracks).map(trackIdentifier))
        )

        let featuredPool = curatedSuggestionTracks(
            deduplicatedTracks(
            learnedTracks +
            savedTracks.shuffled() +
            likedTracks.shuffled() +
            topTracks.shuffled() +
            curatedMixTracks.shuffled() +
            recentProfileTracks.shuffled()
            )
        )

        guard featuredPool.isEmpty == false else { return false }

        let featured = Array(featuredPool.prefix(50))
        let featuredIDs = Set(featured.map(trackIdentifier))
        let recent = Array(
            curatedSuggestionTracks(
                deduplicatedTracks(recentProfileTracks + curatedMixTracks.shuffled() + learnedTracks.shuffled())
            )
                .filter { featuredIDs.contains(trackIdentifier($0)) == false }
                .prefix(30)
        )

        updateHomeContent(
            featuredTracks: featured,
            recentTracks: recent
        )
        await rebuildSuggestedMixes()
        return true
    }

    private func buildStarterHome() async -> Bool {
        let starterTracks = await starterRecommendations(limit: 40, excluding: [])
        let blendedPool = deduplicatedTracks(starterTracks)
        guard blendedPool.isEmpty == false else { return false }

        let curatedTracks = curatedSuggestionTracks(blendedPool)
        updateHomeContent(
            featuredTracks: Array(curatedTracks.prefix(40)),
            recentTracks: Array(curatedTracks.dropFirst(16).prefix(24)),
            suggestedMixes: []
        )
        playlistCache = playlistCache.filter { isSyntheticMixID($0.key) == false }
        return true
    }

    private func starterRecommendations(
        limit: Int,
        excluding excludedIdentifiers: Set<String>
    ) async -> [Track] {
        let starterQueries = [
            "top songs official audio",
            "new music official audio",
            "arabic songs official audio",
            "worship songs official audio",
            "afrobeats official audio",
            "acoustic songs official audio",
            "indie pop official audio",
            "chill music official audio"
        ]

        let resultBuckets = await withTaskGroup(of: [Track]?.self) { group in
            let accessToken = await authorizedAccessTokenIfAvailable()
            for query in starterQueries {
                group.addTask {
                    do {
                        let results = try await self.catalogService.search(query: query, accessToken: accessToken)
                        let bucket = Array(results.songs.prefix(16))
                        return bucket.isEmpty ? nil : bucket
                    } catch {
                        return nil
                    }
                }
            }

            var buckets: [[Track]] = []
            for await bucket in group {
                if let bucket {
                    buckets.append(bucket)
                }
            }
            return buckets
        }

        guard resultBuckets.isEmpty == false else { return [] }

        var collected: [Track] = []
        var seen = excludedIdentifiers
        var offsets = Array(repeating: 0, count: resultBuckets.count)

        while collected.count < limit {
            var appendedTrackThisRound = false

            for bucketIndex in resultBuckets.indices {
                while offsets[bucketIndex] < resultBuckets[bucketIndex].count {
                    let track = resultBuckets[bucketIndex][offsets[bucketIndex]]
                    offsets[bucketIndex] += 1

                    let identifier = trackIdentifier(track)
                    guard seen.insert(identifier).inserted else { continue }

                    collected.append(track)
                    appendedTrackThisRound = true
                    break
                }

                if collected.count >= limit {
                    break
                }
            }

            if appendedTrackThisRound == false {
                break
            }
        }

        return curatedSuggestionTracks(collected)
    }

    private func smartRecommendations(
        limit: Int,
        excluding excludedIdentifiers: Set<String>,
        focusedTrack: Track? = nil
    ) async -> [Track] {
        let snapshot = localMusicProfileStore.snapshot(for: currentProfileID)
        let savedSeedTracks = curatedSuggestionTracks(snapshot.savedTracks)
        let likedSeedTracks = curatedSuggestionTracks(snapshot.likedTracks)
        let topArtists = orderedUniqueQueries(
            snapshot.topArtists +
            savedSeedTracks.map(\.artist) +
            likedSeedTracks.map(\.artist) +
            savedArtistCollections.map(\.title)
        )
        var queries: [String] = []

        if let focusedTrack, focusedTrack.isEligibleForMusicSuggestions {
            queries.append("\(focusedTrack.artist) \(focusedTrack.title)")
            queries.append("\(focusedTrack.artist) official audio")
            queries.append("\(focusedTrack.artist) songs")
            queries.append("\(focusedTrack.title) official audio")
        }

        queries.append(contentsOf: topArtists.prefix(4).map { "\($0) official audio" })
        queries.append(contentsOf: recentSearches.prefix(3))
        queries.append(contentsOf: savedSeedTracks.prefix(3).map { "\($0.artist) \($0.title)" })
        queries.append(contentsOf: likedSeedTracks.prefix(3).map { "\($0.artist) songs" })
        queries.append(contentsOf: savedArtistCollections.prefix(3).map { "\($0.title) songs" })

        let normalizedQueries = orderedUniqueQueries(queries)
        guard normalizedQueries.isEmpty == false else {
            return []
        }

        let preferredArtists = Set(
            topArtists
            .prefix(8)
            .map(normalizedRecommendationText)
        )

        let resultBuckets = await withTaskGroup(of: [Track].self) { group in
            let accessToken = await authorizedAccessTokenIfAvailable()
            for query in normalizedQueries.prefix(focusedTrack == nil ? 6 : 4) {
                group.addTask {
                    let response = try? await self.catalogService.search(query: query, accessToken: accessToken)
                    return Array((response?.songs ?? []).prefix(focusedTrack == nil ? 10 : 14))
                }
            }

            var buckets: [[Track]] = []
            for await bucket in group {
                if bucket.isEmpty == false {
                    buckets.append(bucket)
                }
            }
            return buckets
        }

        let rankedTracks = curatedSuggestionTracks(deduplicatedTracks(resultBuckets.flatMap { $0 })).sorted {
            recommendationScore(for: $0, focusedTrack: focusedTrack, preferredArtists: preferredArtists) >
            recommendationScore(for: $1, focusedTrack: focusedTrack, preferredArtists: preferredArtists)
        }

        var collected: [Track] = []
        var seen = excludedIdentifiers

        for track in rankedTracks {
            let identifier = trackIdentifier(track)
            guard seen.insert(identifier).inserted else { continue }
            let score = recommendationScore(for: track, focusedTrack: focusedTrack, preferredArtists: preferredArtists)
            guard score > 0 || focusedTrack == nil else { continue }
            collected.append(track)
            if collected.count >= limit {
                return collected
            }
        }

        return collected
    }

    private func deduplicatedTracks(_ tracks: [Track]) -> [Track] {
        var seenTrackIDs: Set<String> = []
        return tracks.filter { track in
            let identifier = trackIdentifier(track)
            return seenTrackIDs.insert(identifier).inserted
        }
    }

    private func curatedSuggestionTracks(_ tracks: [Track]) -> [Track] {
        let withoutShorts = tracks.filter { $0.isLikelyShortFormVideo == false }
        let curated = withoutShorts.filter(\.isEligibleForMusicSuggestions)
        if curated.isEmpty == false {
            return curated
        }
        return withoutShorts
    }

    private func isQuotaOrTransientCatalogError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("quota")
            || message.contains("daily limit")
            || message.contains("rate limit")
            || message.contains("temporarily unavailable")
            || message.contains("backend error")
            || message.contains("timed out")
            || message.contains("network connection was lost")
            || message.contains("offline")
            || message.contains("returned status 429")
            || message.contains("returned status 500")
            || message.contains("returned status 502")
            || message.contains("returned status 503")
    }

    private func shouldSuppressBackgroundCatalogError(_ error: Error) -> Bool {
        isAuthorizationError(error) || isQuotaOrTransientCatalogError(error)
    }

    private func prioritizeLibraryPlaylists(_ playlists: [Playlist]) -> [Playlist] {
        let likedPlaylists = playlists.filter { $0.kind == .likedMusic }
        let savedSongs = playlists.filter { $0.kind == .savedSongs }
        let remainingPlaylists = playlists.filter { $0.kind != .likedMusic && $0.kind != .savedSongs }
        return likedPlaylists + savedSongs + remainingPlaylists
    }

    private func selectSuggestedMixSourcePlaylists(from playlists: [Playlist], limit: Int = 8) -> [Playlist] {
        let candidates = playlists.suggestedMixCandidates()
        guard candidates.isEmpty == false else { return [] }

        let poolSize = min(candidates.count, max(limit * 2, limit))
        return Array(candidates.prefix(poolSize).shuffled().prefix(limit))
    }

    private func randomizedTracks(from tracks: [Track], limit: Int) -> [Track] {
        guard tracks.isEmpty == false else { return [] }
        return Array(tracks.shuffled().prefix(limit))
    }

    private func recommendationScore(
        for track: Track,
        focusedTrack: Track?,
        preferredArtists: Set<String>
    ) -> Int {
        let normalizedArtist = normalizedRecommendationText(track.artist)
        let normalizedTitle = normalizedRecommendationText(track.title)
        var score = 0

        if preferredArtists.contains(normalizedArtist) {
            score += 5
        }

        if let focusedTrack {
            let focusedArtist = normalizedRecommendationText(focusedTrack.artist)
            let focusedTitleTokens = Set(normalizedRecommendationText(focusedTrack.title).split(separator: " ").map(String.init))
            let candidateTitleTokens = Set(normalizedTitle.split(separator: " ").map(String.init))
            let overlap = focusedTitleTokens.intersection(candidateTitleTokens).count

            if normalizedArtist == focusedArtist {
                score += 12
            }
            score += min(overlap * 3, 9)
        }

        return score
    }

    private func normalizedRecommendationText(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s\\p{Arabic}]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func hasPersonalizedRecommendationSignals() -> Bool {
        let snapshot = localMusicProfileStore.snapshot(for: currentProfileID)
        let hasPlaylistSignals = playlists.contains {
            ($0.kind == .standard || $0.kind == .custom || $0.kind == .uploads) && $0.itemCount > 0
        }

        return snapshot.topArtists.isEmpty == false
            || snapshot.savedTracks.isEmpty == false
            || snapshot.likedTracks.isEmpty == false
            || snapshot.topTracks.isEmpty == false
            || snapshot.recentTracks.isEmpty == false
            || snapshot.recentSearches.isEmpty == false
            || savedArtistCollections.isEmpty == false
            || hasPlaylistSignals
    }

    private func starterRecommendationsStatusMessage(expiredSessionFallback: Bool) -> String {
        if expiredSessionFallback {
            return "Your YouTube session expired, so MusicTube is using starter picks for now."
        }

        return isYouTubeConnected
            ? "Starter picks while MusicTube rebuilds your recommendations."
            : "Starter picks while MusicTube learns what you like."
    }

    nonisolated private func isValidDownloadURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    nonisolated private func userFriendlyDownloadError(_ error: Error) -> String {
        let errorString = error.localizedDescription
        if errorString.contains("Cannot allocate memory") {
            return "Not enough storage space. Delete some downloads and try again."
        }
        if errorString.contains("regexMatchError") || errorString.contains("YouTubeKitError") {
            return "MusicTube couldn't extract audio for this track. It might be age-restricted or unavailable. Try searching for a different version."
        }
        if errorString.contains("maxRetriesExceeded") {
            return "Download failed after multiple retries. Check your internet connection and try again."
        }
        if errorString.contains("videoUnavailable") || errorString.contains("videoPrivate") {
            return "This video is unavailable or private and cannot be downloaded."
        }
        if errorString.contains("membersOnly") {
            return "This content is members-only and cannot be downloaded."
        }
        return "Download failed: \(errorString)"
    }

    private func trackIdentifier(_ track: Track) -> String {
        track.youtubeVideoID ?? track.id
    }

    private var currentProfileID: String {
        deviceProfileID
    }

    private func isSyntheticMixID(_ playlistID: String) -> Bool {
        playlistID.hasPrefix("suggested-mix-")
    }

    private func isLocalCollectionID(_ playlistID: String) -> Bool {
        playlistID.hasPrefix("local-")
    }

    private func isAuthorizationError(_ error: Error) -> Bool {
        if let error = error as? YouTubeAPIService.YouTubeAPIError,
           case .authenticationFailure = error {
            return true
        }

        let message = error.localizedDescription.lowercased()
        return message.contains("invalid authentication credentials")
            || message.contains("oauth 2")
            || message.contains("login cookie")
            || message.contains("session expired")
            || message.contains("sign in again")
            || message.contains("status 401")
            || message.contains("status 403")
    }

    private func applyAuthorizedSession(_ session: YouTubeSession) {
        self.session = session
        user = session.user
        authState = .signedIn
    }

    private func clearAuthorizationState() {
        session = nil
        user = nil
        authState = .guest
        clearRemoteState()
        syncLocalMusicProfileState()
        errorMessage = nil
    }

    private func authorizedSessionIfAvailable(forceRefresh: Bool = false) async -> YouTubeSession? {
        guard session != nil else { return nil }

        if forceRefresh == false, let session, session.isExpired == false {
            return session
        }

        let refreshedSession = forceRefresh
            ? await authService.refreshSession()
            : await authService.restoreSession()

        guard let refreshedSession else {
            await authService.signOut()
            clearAuthorizationState()
            return nil
        }

        applyAuthorizedSession(refreshedSession)
        return refreshedSession
    }

    private func authorizedAccessTokenIfAvailable(forceRefresh: Bool = false) async -> String? {
        await authorizedSessionIfAvailable(forceRefresh: forceRefresh)?.accessToken
    }

    private func performAuthenticatedOperation<T>(
        _ operation: (String) async throws -> T
    ) async throws -> T? {
        guard let accessToken = await authorizedAccessTokenIfAvailable() else {
            return nil
        }

        do {
            return try await operation(accessToken)
        } catch {
            guard isAuthorizationError(error) else {
                throw error
            }

            guard let refreshedAccessToken = await authorizedAccessTokenIfAvailable(forceRefresh: true) else {
                _ = await handleAuthorizationFailureIfNeeded(for: error)
                throw error
            }

            do {
                return try await operation(refreshedAccessToken)
            } catch {
                if isAuthorizationError(error) {
                    _ = await handleAuthorizationFailureIfNeeded(for: error)
                }
                throw error
            }
        }
    }

    private func handleAuthorizationFailureIfNeeded(for error: Error) async -> Bool {
        guard isAuthorizationError(error) else { return false }

        await authService.signOut()
        clearAuthorizationState()
        return true
    }

    private func syncLocalMusicProfileState() {
        let snapshot = localMusicProfileStore.snapshot(for: currentProfileID)
        likedTrackIDs = Set(snapshot.likedTracks.map(trackIdentifier)).union(accountLikedTrackIDs)
        savedTrackIDs = Set(snapshot.savedTracks.map(trackIdentifier))
        savedCollections = snapshot.savedCollections
        librarySectionOrder = snapshot.librarySectionOrder
        recentSearches = snapshot.recentSearches
        historyTracks = snapshot.recentTracks
    }

    private func persistLibrarySectionOrder(_ order: [AppLibrarySection]) {
        let normalizedOrder = AppLibrarySection.normalizedOrder(from: order.map(\.rawValue))
        guard normalizedOrder != librarySectionOrder else { return }

        let snapshot = localMusicProfileStore.setLibrarySectionOrder(normalizedOrder, profileID: currentProfileID)
        librarySectionOrder = snapshot.librarySectionOrder
        refreshCarPlay()
    }

    private func resolveDirectSearchResponse(
        from resolvedInput: ResolvedSearchInput,
        accessToken: String?
    ) async throws -> SearchResponse? {
        switch resolvedInput {
        case .text:
            return nil

        case .playlist(let playlist):
            let tracks = try await catalogService.loadPlaylistItems(for: playlist, accessToken: accessToken)
            var response = SearchResponse.empty
            response.trackCategory.items = tracks
            response.playlistCategory.items = [directLinkedCollection(for: playlist, tracks: tracks)]
            return response

        case .video(let videoID):
            var response = SearchResponse.empty
            if let track = try await catalogService.lookupTrack(videoID: videoID, accessToken: accessToken) {
                response.trackCategory.items = [track]
            }
            return response
        }
    }

    private func resolveSearchInput(from query: String) -> ResolvedSearchInput {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return .text("") }
        guard let url = normalizedYouTubeURL(from: trimmed) else { return .text(trimmed) }

        let pathComponents = url.pathComponents.filter { $0 != "/" && $0.isEmpty == false }
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let videoID = queryItems.first(where: { $0.name == "v" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlistID = queryItems.first(where: { $0.name == "list" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = url.host?.lowercased()
        let firstPath = pathComponents.first?.lowercased()

        if host == "youtu.be" || host == "www.youtu.be" {
            if let sharedVideoID = pathComponents.first, sharedVideoID.isEmpty == false {
                return .video(sharedVideoID)
            }
        }

        switch firstPath {
        case "watch":
            if let videoID, videoID.isEmpty == false {
                return .video(videoID)
            }
            if let playlistID, playlistID.isEmpty == false {
                return .playlist(temporaryLinkedPlaylist(id: playlistID))
            }

        case "playlist":
            if let playlistID, playlistID.isEmpty == false {
                return .playlist(temporaryLinkedPlaylist(id: playlistID))
            }

        case "shorts", "embed", "live", "v":
            if pathComponents.count > 1 {
                let directVideoID = pathComponents[1]
                if directVideoID.isEmpty == false {
                    return .video(directVideoID)
                }
            }

        default:
            break
        }

        if let videoID, videoID.isEmpty == false {
            return .video(videoID)
        }

        if let playlistID, playlistID.isEmpty == false {
            return .playlist(temporaryLinkedPlaylist(id: playlistID))
        }

        if let handle = pathComponents.first(where: { $0.hasPrefix("@") }), handle.isEmpty == false {
            return .text(handle)
        }

        return .text(trimmed)
    }

    private func normalizedYouTubeURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        let candidate: String
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            candidate = trimmed
        } else if trimmed.contains("youtube.com") || trimmed.contains("youtu.be") {
            candidate = "https://\(trimmed)"
        } else {
            return nil
        }

        guard let url = URL(string: candidate), let host = url.host?.lowercased() else {
            return nil
        }

        guard host.hasSuffix("youtube.com") || host == "youtu.be" || host.hasSuffix(".youtu.be") else {
            return nil
        }

        return url
    }

    private func temporaryLinkedPlaylist(id: String) -> Playlist {
        Playlist(
            id: id,
            title: id.hasPrefix("OLAK") ? "Linked Album" : "Linked Playlist",
            description: "",
            artworkURL: nil,
            itemCount: 0,
            kind: .standard
        )
    }

    private func directLinkedCollection(for playlist: Playlist, tracks: [Track]) -> MusicCollection {
        let title = playlist.title.isEmpty ? "Linked Playlist" : playlist.title
        let description = playlist.description.isEmpty
            ? "Opened from a YouTube link"
            : playlist.description
        let itemCount = max(playlist.itemCount, tracks.count)
        let kind: MusicCollectionKind = playlist.id.hasPrefix("OLAK") ? .album : .playlist
        let subtitle: String
        if itemCount > 0 {
            subtitle = itemCount == 1 ? "1 track" : "\(itemCount) tracks"
        } else {
            subtitle = kind == .album ? "YouTube album" : "YouTube playlist"
        }

        return MusicCollection(
            sourceID: playlist.id,
            title: title,
            subtitle: subtitle,
            description: description,
            artworkURL: tracks.first?.artworkURL ?? playlist.artworkURL,
            itemCount: itemCount,
            kind: kind,
            queryHint: title
        )
    }

    private func refreshLocalLibraryOverlay() {
        playlists = mergedLibraryPlaylists(remotePlaylists: playlists.filter { isLocalCollectionID($0.id) == false })
        trimCachesToValidCollections()
        libraryStatusMessage = libraryStatusMessageText(for: playlists, savedCollections: savedCollections)
        refreshCarPlay()
    }

    private func trimCachesToValidCollections() {
        let validPlaylistIDs = Set(playlists.map(\.id) + suggestedMixes.map(\.id))
        playlistCache = playlistCache.filter { validPlaylistIDs.contains($0.key) || isSyntheticMixID($0.key) }
        let validCollectionIDs = Set(savedCollections.map(\.id))
        collectionCache = collectionCache.filter { validCollectionIDs.contains($0.key) }
    }

    private func recordLocalPlayback(for track: Track) {
        _ = localMusicProfileStore.recordPlayback(of: track, for: currentProfileID)
        syncLocalMusicProfileState()
        refreshLocalLibraryOverlay()

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Avoid rebuilding Home on every play; that causes visible list "reload" jitter.
            // Rehydrate only when recommendations are genuinely empty.
            if self.featuredTracks.isEmpty {
                _ = await self.buildHomeFromLoadedLibrary()
                self.refreshCarPlay()
            }
        }
    }

    private func mergedLibraryPlaylists(remotePlaylists: [Playlist]) -> [Playlist] {
        let remoteCollections = remotePlaylists.filter { isLocalCollectionID($0.id) == false }
        let hasRemoteLikedSongs = remoteCollections.contains(where: { $0.kind == .likedMusic })
        let localCollections = buildLocalProfilePlaylists(includeLikedSongs: hasRemoteLikedSongs == false)
        return prioritizeLibraryPlaylists(remoteCollections + localCollections)
    }

    private func buildLocalProfilePlaylists(includeLikedSongs: Bool) -> [Playlist] {
        let snapshot = localMusicProfileStore.snapshot(for: currentProfileID)

        var collections: [Playlist] = []

        if includeLikedSongs, snapshot.likedTracks.isEmpty == false {
            let likedTracks = snapshot.likedTracks
            setPlaylistCache(likedTracks, for: localLikedPlaylistID)
            collections.append(
                Playlist(
                    id: localLikedPlaylistID,
                    title: "Liked Songs",
                    description: "Songs you liked in MusicTube",
                    artworkURL: likedTracks.first?.artworkURL,
                    itemCount: likedTracks.count,
                    kind: .likedMusic
                )
            )
        } else {
            playlistCache.removeValue(forKey: localLikedPlaylistID)
        }

        if snapshot.savedTracks.isEmpty == false {
            let savedTracks = Array(snapshot.savedTracks.prefix(200))
            setPlaylistCache(savedTracks, for: localSavedSongsPlaylistID)
            collections.append(
                Playlist(
                    id: localSavedSongsPlaylistID,
                    title: "Saved Songs",
                    description: "Songs you saved to your library",
                    artworkURL: savedTracks.first?.artworkURL,
                    itemCount: savedTracks.count,
                    kind: .savedSongs
                )
            )
        } else {
            playlistCache.removeValue(forKey: localSavedSongsPlaylistID)
        }

        for customPlaylist in snapshot.customPlaylists {
            setPlaylistCache(customPlaylist.tracks, for: customPlaylist.id)
            collections.append(
                Playlist(
                    id: customPlaylist.id,
                    title: customPlaylist.title,
                    description: customPlaylist.description,
                    artworkURL: customPlaylist.tracks.first?.artworkURL,
                    itemCount: customPlaylist.tracks.count,
                    kind: .custom
                )
            )
        }

        if snapshot.recentTracks.isEmpty == false {
            let replayTracks = Array(snapshot.recentTracks.prefix(60))
            setPlaylistCache(replayTracks, for: localReplayMixPlaylistID)
            collections.append(
                Playlist(
                    id: localReplayMixPlaylistID,
                    title: "Replay Mix",
                    description: "Built from your recent MusicTube plays",
                    artworkURL: replayTracks.first?.artworkURL,
                    itemCount: replayTracks.count,
                    kind: .standard
                )
            )
        } else {
            playlistCache.removeValue(forKey: localReplayMixPlaylistID)
        }

        let favoriteTracks = Array(deduplicatedTracks(snapshot.savedTracks + snapshot.likedTracks + snapshot.topTracks).prefix(60))
        if favoriteTracks.isEmpty == false {
            setPlaylistCache(favoriteTracks, for: localFavoritesMixPlaylistID)
            collections.append(
                Playlist(
                    id: localFavoritesMixPlaylistID,
                    title: "Favorites Mix",
                    description: "Made from the songs you come back to most",
                    artworkURL: favoriteTracks.first?.artworkURL,
                    itemCount: favoriteTracks.count,
                    kind: .standard
                )
            )
        } else {
            playlistCache.removeValue(forKey: localFavoritesMixPlaylistID)
        }

        return collections
    }

    private func libraryStatusMessageText(for playlists: [Playlist], savedCollections: [MusicCollection]) -> String? {
        if playlists.isEmpty && savedCollections.isEmpty {
            return "Save songs, playlists, albums, and artists to start building your library."
        }

        if isYouTubeConnected == false {
            return "Guest mode keeps your MusicTube library and playlists on this device."
        }

        return nil
    }

    private func hydrateLikedSongsPlaylistIfNeeded(forceRefresh: Bool) async {
        guard let likedPlaylist = likedSongsPlaylist else {
            accountLikedTrackIDs = []
            syncLocalMusicProfileState()
            return
        }

        let tracks = await loadPlaylistItems(
            for: likedPlaylist,
            forceRefresh: forceRefresh,
            surfaceErrors: false
        )
        var resolvedTracks = tracks

        if isLocalCollectionID(likedPlaylist.id) == false {
            let mergedSnapshot = localMusicProfileStore.mergeLikedTracks(
                tracks,
                profileID: currentProfileID
            )
            accountLikedTrackIDs = Set(tracks.map(trackIdentifier))
            resolvedTracks = deduplicatedTracks(tracks + mergedSnapshot.likedTracks)
            if resolvedTracks.isEmpty {
                playlistCache.removeValue(forKey: likedPlaylist.id)
            } else {
                setPlaylistCache(resolvedTracks, for: likedPlaylist.id)
            }
        } else {
            accountLikedTrackIDs = []
        }

        likedTrackIDs = Set(localMusicProfileStore.snapshot(for: currentProfileID).likedTracks.map(trackIdentifier))
            .union(accountLikedTrackIDs)

        if let playlistIndex = playlists.firstIndex(where: { $0.id == likedPlaylist.id }) {
            var updatedPlaylists = playlists
            updatedPlaylists[playlistIndex] = Playlist(
                id: likedPlaylist.id,
                title: likedPlaylist.title,
                description: likedPlaylist.description,
                artworkURL: resolvedTracks.first?.artworkURL ?? likedPlaylist.artworkURL,
                itemCount: resolvedTracks.count,
                kind: likedPlaylist.kind
            )
            playlists = updatedPlaylists
        }
    }

    private func startLikedSongsHydration(forceRefresh: Bool) {
        cancelLikedSongsHydration(clearAccountLikes: false)

        guard let likedPlaylist = likedSongsPlaylist,
              isLocalCollectionID(likedPlaylist.id) == false,
              session?.accessToken != nil else {
            accountLikedTrackIDs = []
            syncLocalMusicProfileState()
            libraryStatusMessage = libraryStatusMessageText(for: playlists, savedCollections: savedCollections)
            return
        }

        isSyncingLikedSongs = true
        libraryStatusMessage = "Syncing all liked songs from YouTube..."

        likedSongsHydrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.hydrateLikedSongsPlaylistIfNeeded(forceRefresh: forceRefresh)
            guard Task.isCancelled == false else { return }
            self.lastLikedSongsAccountSyncDate = Date()
            self.isSyncingLikedSongs = false
            self.libraryStatusMessage = self.libraryStatusMessageText(for: self.playlists, savedCollections: self.savedCollections)
            self.refreshCarPlay()
        }
    }

    private func cancelLikedSongsHydration(clearAccountLikes: Bool = true) {
        likedSongsHydrationTask?.cancel()
        likedSongsHydrationTask = nil
        isSyncingLikedSongs = false
        if clearAccountLikes {
            accountLikedTrackIDs = []
            syncLocalMusicProfileState()
        }
    }

    private func rebuildSuggestedMixes() async {
        let sourcePlaylists = selectSuggestedMixSourcePlaylists(from: playlists, limit: 6)

        let likedPlaylistSnapshot = likedSongsPlaylist
        async let likedFetch: [Track] = {
            if let playlist = likedPlaylistSnapshot {
                return await self.loadPlaylistItems(for: playlist, surfaceErrors: false)
            }
            return []
        }()

        let playlistFetches: [[Track]] = await withTaskGroup(of: [Track].self) { group in
            for playlist in sourcePlaylists {
                group.addTask { await self.loadPlaylistItems(for: playlist, surfaceErrors: false) }
            }

            var results: [[Track]] = []
            for await tracks in group {
                results.append(tracks)
            }
            return results
        }

        let likedTracks = curatedSuggestionTracks(await likedFetch)

        var sourcePools: [[Track]] = []
        if featuredTracks.isEmpty == false || recentTracks.isEmpty == false {
            sourcePools.append(curatedSuggestionTracks(deduplicatedTracks(featuredTracks.shuffled() + recentTracks.shuffled())))
        }
        if likedTracks.isEmpty == false {
            sourcePools.append(curatedSuggestionTracks(deduplicatedTracks(likedTracks.shuffled() + featuredTracks.shuffled())))
        }

        for tracks in playlistFetches where tracks.isEmpty == false {
            sourcePools.append(curatedSuggestionTracks(deduplicatedTracks(tracks.shuffled() + recentTracks.shuffled())))
        }

        let mixTitles = [
            "Daily Mix 1",
            "Daily Mix 2",
            "Replay Mix",
            "Discovery Mix",
            "Favorites Mix",
            "Late Night Mix"
        ]

        let mixes = Array(sourcePools.prefix(mixTitles.count).enumerated()).compactMap { index, pool -> Playlist? in
            let tracks = Array(curatedSuggestionTracks(deduplicatedTracks(pool)).prefix(32))
            guard tracks.isEmpty == false else { return nil }

            let mixID = "suggested-mix-\(index + 1)"
            setPlaylistCache(tracks, for: mixID)

            return Playlist(
                id: mixID,
                title: mixTitles[index],
                description: "Made for you",
                artworkURL: tracks.first?.artworkURL,
                itemCount: tracks.count,
                kind: .standard
            )
        }

        updateHomeContent(suggestedMixes: mixes)
    }

    private func applyLocalLikeState(_ isLiked: Bool, for track: Track) {
        _ = localMusicProfileStore.setLike(isLiked, for: track, profileID: currentProfileID)
        syncLocalMusicProfileState()
        updateLikedSongsPlaylistCache(for: track, isLiked: isLiked)
        refreshLocalLibraryOverlay()
    }

    private func updateLikedSongsPlaylistCache(for track: Track, isLiked: Bool) {
        guard let likedPlaylist = likedSongsPlaylist else { return }

        let playlistID = likedPlaylist.id
        let identifier = trackIdentifier(track)
        let cachedTracks = cachedPlaylistTracks(for: playlistID) ?? []
        let wasPresent = cachedTracks.contains { trackIdentifier($0) == identifier }

        var updatedTracks = cachedTracks.filter { trackIdentifier($0) != identifier }
        if isLiked {
            updatedTracks.insert(track, at: 0)
        }
        updatedTracks = deduplicatedTracks(updatedTracks)

        if updatedTracks.isEmpty {
            playlistCache.removeValue(forKey: playlistID)
        } else {
            setPlaylistCache(updatedTracks, for: playlistID)
        }

        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }) else { return }

        let countDelta: Int
        switch (isLiked, wasPresent) {
        case (true, false):
            countDelta = 1
        case (false, true):
            countDelta = -1
        default:
            countDelta = 0
        }

        let currentPlaylist = playlists[playlistIndex]
        var updatedPlaylists = playlists
        updatedPlaylists[playlistIndex] = Playlist(
            id: currentPlaylist.id,
            title: currentPlaylist.title,
            description: currentPlaylist.description,
            artworkURL: updatedTracks.first?.artworkURL ?? currentPlaylist.artworkURL,
            itemCount: max(currentPlaylist.itemCount + countDelta, updatedTracks.count),
            kind: currentPlaylist.kind
        )
        playlists = updatedPlaylists
    }

    private func orderedUniqueQueries(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return nil }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }
}

final class AppContainer {
    static let shared = AppContainer()
    weak var appState: AppState?
    weak var carPlayManager: CarPlayManager?

    private init() {}
}
