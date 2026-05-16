import Combine
import Foundation
import UIKit

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

    private struct ActiveListeningSession {
        let track: Track
        let startingOffset: TimeInterval
    }

    private struct RecommendationBucket: Sendable {
        let query: String
        let tracks: [Track]
    }

    private struct RecommendationScoreComponents {
        let collaborative: Double
        let contentSimilarity: Double
        let behavior: Double

        var total: Double {
            (0.5 * collaborative) + (0.3 * contentSimilarity) + (0.2 * behavior)
        }
    }

    private struct RecommendationSeedContext {
        let queries: [String]
        let preferredArtists: Set<String>
        let focusedArtist: String?
        let focusedTitleTokens: Set<String>
        let keywordTokens: Set<String>
        let behaviorInsightsByTrackKey: [String: TrackBehaviorInsight]
        let behaviorInsightsByArtist: [String: [TrackBehaviorInsight]]
        let likedTrackKeys: Set<String>
        let savedTrackKeys: Set<String>
        let downloadedTrackKeys: Set<String>
        let collaborativeSeedTrackKeys: Set<String>
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
    private(set) var playbackState: PlaybackState = .idle
    @Published private(set) var nowPlayingTrack: Track?
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
    @Published var isSearchFieldFocused = false
    @Published var playlistPickerState: PlaylistPickerState = .hidden
    @Published private(set) var playlistPickerHost: PlaylistPickerHost = .main
    @Published private(set) var dislikedTrackIDs: Set<String> = []
    @Published var isHistoryEnabled: Bool = true
    @Published private(set) var isPlaybackActive = false

    private var session: YouTubeSession?
    private var sleepTimerTask: Task<Void, Never>?
    private var relatedTracksTask: Task<Void, Never>?
    private var autoplayContinuationTask: Task<Void, Never>?
    private var playbackCompletionWatchTask: Task<Void, Never>?
    private var likedSongsHydrationTask: Task<Void, Never>?
    let downloadService = DownloadService.shared
    private let authService: AuthProviding
    private let catalogService: MusicCatalogProviding
    private let playbackService: PlaybackService
    private let logger: any AppLogging
    private let musicRecognitionService = MusicRecognitionService()
    private let localMusicProfileStore: MusicProfileStoring
    private let recommendationCandidateCache = CacheStore<String, [Track]>(
        ttl: AppConfig.Recommendations.candidateCacheTTL,
        maxEntries: AppConfig.Recommendations.maxCachedQueries
    )
    private var playlistCache: [String: TrackCacheEntry] = [:]
    private var collectionCache: [String: TrackCacheEntry] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var accountLikedTrackIDs: Set<String> = []
    private var isRefreshingDashboard = false
    private var activeSearchRequestID: UUID?
    private let localLikedPlaylistID = AppConfig.Library.localLikedPlaylistID
    private let localSavedSongsPlaylistID = AppConfig.Library.localSavedSongsPlaylistID
    private let localReplayMixPlaylistID = AppConfig.Library.localReplayMixPlaylistID
    private let localFavoritesMixPlaylistID = AppConfig.Library.localFavoritesMixPlaylistID
    private let deviceProfileID = AppConfig.Library.deviceProfileID
    private let likedSongsAccountSyncCooldown = AppConfig.Library.likedSongsSyncCooldown
    private let maxConcurrentBatchStreamResolutions = AppConfig.Downloads.maxConcurrentStreamResolutions
    private let batchDownloadResolveSpacingNanoseconds = AppConfig.Downloads.batchResolveSpacingNanoseconds
    private let pendingDownloadRetryDelayNanoseconds = AppConfig.Downloads.pendingDownloadRetryDelayNanoseconds
    private let maxPendingDownloadRetryPassesWithoutProgress = AppConfig.Downloads.maxPendingDownloadRetryPassesWithoutProgress
    private let trackCacheTTL = AppConfig.Cache.trackListTTL
    private let dislikedTrackIDsKey = "musictube.dislikedTrackIDs"
    private let historyEnabledKey = "musictube.historyEnabled"
    private let lastLikedSyncKey = "musictube.lastLikedSongsAccountSyncDate"
    private var lastLikedSongsAccountSyncDate: Date? {
        get { UserDefaults.standard.object(forKey: lastLikedSyncKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastLikedSyncKey) }
    }
    private var pendingDownloadResumeTask: Task<Void, Never>?
    private var activeListeningSession: ActiveListeningSession?
    private var collaborativeRecommendationSeedTrackKeys: Set<String> = []
    private var sessionRestoreStarted = false
    private var isAppInBackground = false
    private var lifecycleObservers: [NSObjectProtocol] = []

    init(
        authService: AuthProviding,
        catalogService: MusicCatalogProviding,
        playbackService: PlaybackService,
        localMusicProfileStore: MusicProfileStoring = LocalMusicProfileStore.shared,
        logger: any AppLogging = DefaultAppLogger(category: "AppState")
    ) {
        self.authService = authService
        self.catalogService = catalogService
        self.playbackService = playbackService
        self.localMusicProfileStore = localMusicProfileStore
        self.logger = logger
        if let raw = UserDefaults.standard.object(forKey: "musictube.dislikedTrackIDs") as? [String] {
            dislikedTrackIDs = Set(raw)
        }
        if UserDefaults.standard.object(forKey: "musictube.historyEnabled") != nil {
            isHistoryEnabled = UserDefaults.standard.bool(forKey: "musictube.historyEnabled")
        }
        syncLocalMusicProfileState()

        // Make recognition a "secondary audio source" so the RemoteCommandManager
        // stops it before primary playback resumes. Without this, a Shazam
        // session that's still listening when the user taps "play" from the
        // Lock Screen keeps holding the `.playAndRecord` audio session and
        // routes pause taps to itself instead of to PlaybackService.
        playbackService.registerSecondaryAudioSource(musicRecognitionService)

        observePublisher(playbackService.$state) { state, playbackState in
            let previousPlaybackState = state.playbackState
            let previousTrack = previousPlaybackState.nowPlaying
            let previousIsPlaying = previousPlaybackState.isPlaying
            guard previousPlaybackState != playbackState else { return }
            state.handlePlaybackStateTransition(from: previousPlaybackState, to: playbackState)
            state.playbackState = playbackState
            if state.nowPlayingTrack != playbackState.nowPlaying {
                state.nowPlayingTrack = playbackState.nowPlaying
            }
            if state.isPlaybackActive != playbackState.isPlaying {
                state.isPlaybackActive = playbackState.isPlaying
            }

            if previousPlaybackState.playbackErrorMessage != playbackState.playbackErrorMessage,
               let message = playbackState.playbackErrorMessage {
                state.errorMessage = message
            }

            if previousTrack != playbackState.nowPlaying, state.isAppInBackground == false {
                state.refreshRelatedTracksTask(for: playbackState.nowPlaying)
            } else if previousTrack != playbackState.nowPlaying {
                state.cancelRelatedTracksRefresh()
            }

            if previousTrack != playbackState.nowPlaying || previousIsPlaying != playbackState.isPlaying {
                state.refreshCarPlay()
            }
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

        observeAppLifecycle()
    }

    deinit {
        sleepTimerTask?.cancel()
        relatedTracksTask?.cancel()
        autoplayContinuationTask?.cancel()
        playbackCompletionWatchTask?.cancel()
        likedSongsHydrationTask?.cancel()
        pendingDownloadResumeTask?.cancel()
        cancellables.forEach { $0.cancel() }
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }

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
        nowPlayingTrack
    }

    var isPlaying: Bool {
        isPlaybackActive
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

    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        let backgroundObserver = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isAppInBackground = true
                self?.cancelRelatedTracksRefresh()
            }
        }

        let foregroundObserver = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isAppInBackground = false
                self.refreshRelatedTracksTask(for: self.playbackState.nowPlaying)
            }
        }

        lifecycleObservers = [backgroundObserver, foregroundObserver]
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
        case .history, .quickActions, .likedSongs, .savedSongs, .customPlaylists, .savedCollections:
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
            logger.info("Starting YouTube sign-in")
            let session = try await authService.signIn()
            applyAuthorizedSession(session)
            syncLocalMusicProfileState()
            logger.info("YouTube sign-in succeeded for user \(session.user.email)")
            await refreshDashboard()
        } catch {
            logger.error("YouTube sign-in failed", error: error)
            errorMessage = error.localizedDescription
            authState = .guest
        }
    }

    func signOut() async {
        logger.info("Signing out current YouTube session")
        await authService.signOut()
        session = nil
        user = nil
        authState = .guest
        // Remove account-synced liked tracks so they don't appear in guest mode.
        // Tracks the user explicitly liked inside MusicTube are also cleared here;
        // they will be re-synced from YouTube on the next sign-in.
        localMusicProfileStore.clearAccountLikedTracks(profileID: currentProfileID)
        clearRemoteState()
        syncLocalMusicProfileState()
        await refreshDashboard()
    }

    func deleteCurrentAccountData() async {
        guard isDeletingAccountData == false else { return }

        isDeletingAccountData = true
        defer { isDeletingAccountData = false }

        logger.info("Deleting current account data and signing out")
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

        // Refresh the visible home feed immediately so the app opens to content first.
        await refreshHome()
        // Refresh library data without blocking the initial home experience.
        Task { [weak self] in
            await self?.refreshLibrary()
        }
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
                    collaborativeRecommendationSeedTrackKeys = Set((home.featured + home.recent).map(trackIdentifier))
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

    func toggleHistoryEnabled() {
        isHistoryEnabled.toggle()
        UserDefaults.standard.set(isHistoryEnabled, forKey: historyEnabledKey)
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

    func autocompleteSuggestions(for query: String, limit: Int = 10) async -> [String] {
        let normalizedQuery = SearchTextNormalizer.normalized(query)
        guard normalizedQuery.isEmpty == false else {
            return Array(recentSearches.prefix(limit))
        }

        let capturedRecentSearches = recentSearches
        let snapshot = localMusicProfileStore.snapshot(for: currentProfileID)
        let savedTrackTitles = snapshot.savedTracks.map(\.title)
        let savedTrackArtists = snapshot.savedTracks.map(\.artist)
        let likedTrackTitles = snapshot.likedTracks.map(\.title)
        let topTrackCombined = snapshot.topTracks.map { "\($0.artist) \($0.title)" }
        let historyTitles = historyTracks.map(\.title)
        let historyCombined = historyTracks.map { "\($0.artist) \($0.title)" }
        let playlistTitles = playlists.map(\.title)
        let collectionTitles = savedCollections.map(\.title)
        let collectionHints = savedCollections.map(\.queryHint)
        let downloadTitles = downloadService.availableDownloads.map(\.track.title)
        let downloadCombined = downloadService.availableDownloads.map { "\($0.track.artist) \($0.track.title)" }

        let localSuggestions: [String] = await Task.detached(priority: .userInitiated) {
            typealias Candidate = (text: String, sourcePriority: Int, ordinal: Int)
            var candidates: [Candidate] = []

            func appendCandidates(_ values: [String], sourcePriority: Int) {
                for (index, value) in values.enumerated() {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.isEmpty == false else { continue }
                    candidates.append((text: trimmed, sourcePriority: sourcePriority, ordinal: index))
                }
            }

            appendCandidates(capturedRecentSearches, sourcePriority: 0)
            appendCandidates(historyTitles, sourcePriority: 1)
            appendCandidates(historyCombined, sourcePriority: 1)
            appendCandidates(savedTrackTitles, sourcePriority: 2)
            appendCandidates(savedTrackArtists, sourcePriority: 2)
            appendCandidates(likedTrackTitles, sourcePriority: 2)
            appendCandidates(topTrackCombined, sourcePriority: 2)
            appendCandidates(playlistTitles, sourcePriority: 3)
            appendCandidates(collectionTitles, sourcePriority: 3)
            appendCandidates(collectionHints, sourcePriority: 3)
            appendCandidates(downloadTitles, sourcePriority: 4)
            appendCandidates(downloadCombined, sourcePriority: 4)

            var rankedSuggestions: [(text: String, score: Int)] = []
            var seenNormalizedSuggestions: Set<String> = []
            let queryTokens = Set(SearchTextNormalizer.tokens(from: normalizedQuery))

            for candidate in candidates {
                let normalizedCandidate = SearchTextNormalizer.normalized(candidate.text)
                guard normalizedCandidate.isEmpty == false else { continue }
                guard seenNormalizedSuggestions.insert(normalizedCandidate).inserted else { continue }

                let candidateTokens = Set(SearchTextNormalizer.tokens(from: normalizedCandidate))
                let tokenOverlap = queryTokens.intersection(candidateTokens).count

                let matchScore: Int
                if normalizedCandidate == normalizedQuery {
                    matchScore = 200
                } else if normalizedCandidate.hasPrefix(normalizedQuery) {
                    matchScore = 160
                } else if candidateTokens.contains(where: { $0.hasPrefix(normalizedQuery) }) {
                    matchScore = 130
                } else if normalizedCandidate.contains(normalizedQuery) {
                    matchScore = 100
                } else if tokenOverlap > 0 {
                    matchScore = min(90, 50 + (tokenOverlap * 12))
                } else {
                    continue
                }

                let sourceBoost = max(0, 40 - (candidate.sourcePriority * 6))
                let recencyBoost = max(0, 18 - candidate.ordinal)
                rankedSuggestions.append(
                    (text: candidate.text, score: matchScore + sourceBoost + recencyBoost)
                )
            }

            return rankedSuggestions
                .sorted {
                    if $0.score != $1.score {
                        return $0.score > $1.score
                    }
                    return $0.text.localizedCaseInsensitiveCompare($1.text) == .orderedAscending
                }
                .map(\.text)
                .prefix(limit)
                .map { $0 }
        }.value

        if localSuggestions.count >= limit {
            return localSuggestions
        }

        let accessToken = await authorizedAccessTokenIfAvailable()
        guard let remoteResponse = try? await catalogService.search(query: query, accessToken: accessToken) else {
            return localSuggestions
        }

        var remoteCandidates: [String] = []
        remoteCandidates.append(contentsOf: remoteResponse.songs.prefix(6).map(\.title))
        remoteCandidates.append(contentsOf: remoteResponse.songs.prefix(6).map { "\($0.artist) \($0.title)" })
        remoteCandidates.append(contentsOf: remoteResponse.artists.prefix(4).map(\.title))
        remoteCandidates.append(contentsOf: remoteResponse.albums.prefix(4).map(\.title))
        remoteCandidates.append(contentsOf: remoteResponse.playlists.prefix(4).map(\.title))

        var mergedSuggestions = localSuggestions
        var seenNormalizedSuggestions = Set(localSuggestions.map { SearchTextNormalizer.normalized($0) })

        for candidate in remoteCandidates {
            let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedCandidate = SearchTextNormalizer.normalized(trimmedCandidate)
            guard trimmedCandidate.isEmpty == false else { continue }
            guard normalizedCandidate.isEmpty == false else { continue }
            guard seenNormalizedSuggestions.insert(normalizedCandidate).inserted else { continue }

            let candidateTokens = Set(SearchTextNormalizer.tokens(from: trimmedCandidate))
            guard normalizedCandidate.hasPrefix(normalizedQuery)
                || candidateTokens.contains(where: { $0.hasPrefix(normalizedQuery) })
                || normalizedCandidate.contains(normalizedQuery) else {
                continue
            }

            mergedSuggestions.append(trimmedCandidate)
            if mergedSuggestions.count >= limit {
                break
            }
        }

        return mergedSuggestions
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
            guard let self, self.isHistoryEnabled else { return }
            self.recordLocalPlayback(for: track)
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
                        // Only background-sync liked songs if 30+ minutes have passed since the
                        // last sync. This avoids a full YouTube fetch on every short session.
                        // Pull-to-refresh in LibraryView always forces a fresh sync regardless.
                        let autoSyncCooldown: TimeInterval = 1800
                        let recentlySynced = lastLikedSongsAccountSyncDate.map {
                            Date().timeIntervalSince($0) < autoSyncCooldown
                        } ?? false
                        if recentlySynced == false {
                            libraryStatusMessage = "Syncing all liked songs from YouTube..."
                            startLikedSongsHydration(forceRefresh: true)
                        } else {
                            libraryStatusMessage = libraryStatusMessageText(for: playlists, savedCollections: savedCollections)
                        }
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

    func setPlaybackRate(_ rate: Float) {
        playbackService.setPlaybackRate(rate)
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

    func resumePendingDownloads() {
        guard pendingDownloadResumeTask == nil else { return }
        guard downloadService.pendingRequestsNeedingProcessing.isEmpty == false else { return }

        pendingDownloadResumeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingDownloadResumeTask = nil }

            var consecutivePassesWithoutProgress = 0

            while Task.isCancelled == false {
                let pending = self.downloadService.pendingRequestsNeedingProcessing
                guard pending.isEmpty == false else { return }

                var startedAnyDownloads = false

                for request in pending {
                    guard Task.isCancelled == false else { return }
                    guard !self.downloadService.isDownloaded(request.track),
                          !self.downloadService.isDownloading(request.track) else { continue }

                    let didStart = await self.resolvePendingDownloadRequest(request)
                    startedAnyDownloads = startedAnyDownloads || didStart
                    try? await Task.sleep(nanoseconds: self.batchDownloadResolveSpacingNanoseconds)
                }

                if startedAnyDownloads {
                    consecutivePassesWithoutProgress = 0
                    continue
                }

                consecutivePassesWithoutProgress += 1
                guard consecutivePassesWithoutProgress < self.maxPendingDownloadRetryPassesWithoutProgress else {
                    return
                }

                try? await Task.sleep(nanoseconds: self.pendingDownloadRetryDelayNanoseconds)
            }
        }
    }

    func downloadTrack(
        _ track: Track,
        source: DownloadSource? = nil,
        sourceTrackIndex: Int? = nil
    ) {
        guard !downloadService.isDownloaded(track), !downloadService.isDownloading(track) else { return }

        let requestKey = track.youtubeVideoID ?? track.id
        downloadService.addPendingRequest(PendingDownloadRequest(
            trackKey: requestKey, track: track, source: source, sourceTrackIndex: sourceTrackIndex,
            requestedAt: Date()
        ))

        isDownloadingNowPlaying = true
        Task {
            let request = PendingDownloadRequest(
                trackKey: requestKey,
                track: track,
                source: source,
                sourceTrackIndex: sourceTrackIndex,
                requestedAt: Date()
            )
            _ = await resolvePendingDownloadRequest(request, surfaceErrors: true)
            await MainActor.run {
                self.isDownloadingNowPlaying = false
                self.resumePendingDownloads()
            }
        }
    }

    func downloadCollection(_ collection: MusicCollection) {
        let source = DownloadSource(id: collection.id, title: collection.title, kind: collection.kind)
        downloadService.beginPreparingSource(source)
        Task { @MainActor [weak self] in
            defer { DownloadService.shared.finishPreparingSource(source) }
            guard let self else { return }
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
        downloadService.beginPreparingSource(source)
        Task { @MainActor [weak self] in
            defer { DownloadService.shared.finishPreparingSource(source) }
            guard let self else { return }
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

        for item in pendingTracks {
            let key = item.element.youtubeVideoID ?? item.element.id
            downloadService.addPendingRequest(PendingDownloadRequest(
                trackKey: key, track: item.element, source: source,
                sourceTrackIndex: item.offset, requestedAt: Date()
            ))
        }

        for startIndex in stride(from: 0, to: pendingTracks.count, by: maxConcurrentBatchStreamResolutions) {
            let endIndex = min(startIndex + maxConcurrentBatchStreamResolutions, pendingTracks.count)
            let batch = Array(pendingTracks[startIndex..<endIndex])

            await withTaskGroup(of: Void.self) { group in
                for item in batch {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        let request = PendingDownloadRequest(
                            trackKey: item.element.youtubeVideoID ?? item.element.id,
                            track: item.element,
                            source: source,
                            sourceTrackIndex: item.offset,
                            requestedAt: Date()
                        )
                        _ = await self.resolvePendingDownloadRequest(request, surfaceErrors: true)
                    }
                }
            }

            if endIndex < pendingTracks.count {
                try? await Task.sleep(nanoseconds: batchDownloadResolveSpacingNanoseconds)
            }
        }

        resumePendingDownloads()
    }

    private func resolvePendingDownloadRequest(
        _ request: PendingDownloadRequest,
        surfaceErrors: Bool = false
    ) async -> Bool {
        guard !downloadService.isDownloaded(request.track),
              !downloadService.isDownloading(request.track) else { return false }

        downloadService.beginResolvingDownload(for: request.track)
        defer { downloadService.finishResolvingDownload(for: request.track) }

        do {
            guard let streamURL = try await playbackService.resolveStreamURL(for: request.track) else {
                return false
            }

            downloadService.startDownload(
                track: request.track,
                streamURL: streamURL,
                source: request.source,
                sourceTrackIndex: request.sourceTrackIndex
            )
            return true
        } catch {
            if surfaceErrors, errorMessage == nil {
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    func toggleLike(for track: Track) {
        let shouldLike = likedTrackIDs.contains(trackIdentifier(track)) == false
        applyLocalLikeState(shouldLike, for: track)
    }

    func recommendMoreLike(_ track: Track) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let extra = await self.smartRecommendations(
                limit: 14,
                excluding: Set(self.featuredTracks.map(self.trackIdentifier)),
                focusedTrack: track
            )
            guard extra.isEmpty == false else { return }
            let merged = self.curatedSuggestionTracks(
                self.deduplicatedTracks(extra + self.featuredTracks)
            )
            self.updateHomeContent(featuredTracks: merged)
        }
    }

    func recommendLessLike(_ track: Track) {
        let id = trackIdentifier(track)
        var updated = dislikedTrackIDs
        updated.insert(id)
        dislikedTrackIDs = updated
        UserDefaults.standard.set(Array(updated), forKey: dislikedTrackIDsKey)
        updateHomeContent(
            featuredTracks: featuredTracks.filter { trackIdentifier($0) != id },
            recentTracks: recentTracks.filter { trackIdentifier($0) != id }
        )
    }

    func switchAccount() async {
        await signOut()
        await signIn()
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

    func handleIncomingURL(_ url: URL) async {
        guard let sharedVideoID = sharedTrackID(from: url) else { return }

        do {
            let accessToken = await authorizedAccessTokenIfAvailable()
            if let track = try await catalogService.lookupTrack(videoID: sharedVideoID, accessToken: accessToken) {
                searchQuery = "\(track.artist) \(track.title)"
                var response = SearchResponse.empty
                response.trackCategory.items = [track]
                searchResults = response
                play(track: track, queue: [track])
                isPlayerPresented = true
                errorMessage = nil
                return
            }
        } catch {
            logger.error("Failed to open shared track", error: error)
        }

        searchQuery = sharedVideoID
        let response = await search(query: sharedVideoID)
        if let track = response.songs.first {
            play(track: track, queue: response.songs)
            isPlayerPresented = true
        } else {
            errorMessage = "MusicTube couldn't open that shared track."
        }
    }

    func handleIncomingUserActivity(_ userActivity: NSUserActivity) async {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL else {
            return
        }

        await handleIncomingURL(url)
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
        guard !sessionRestoreStarted else { return }
        sessionRestoreStarted = true
        logger.info("Restoring YouTube session from persisted storage")
        if let restored = await authService.restoreSession() {
            applyAuthorizedSession(restored)
            logger.info("Restored persisted YouTube session for user \(restored.user.email)")
        } else {
            logger.info("No persisted YouTube session could be restored")
            authState = .guest
        }

        syncLocalMusicProfileState()
        resumePendingDownloads()

        Task {
            await refreshDashboard()
        }
    }

    private func refreshRelatedTracksTask(for track: Track?) {
        relatedTracksTask?.cancel()
        relatedTracksTask = nil

        guard isAppInBackground == false else {
            isLoadingRelatedTracks = false
            return
        }

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

    private func cancelRelatedTracksRefresh() {
        relatedTracksTask?.cancel()
        relatedTracksTask = nil
        isLoadingRelatedTracks = false
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
        isSearchFieldFocused = false
        lastLikedSongsAccountSyncDate = nil
        accountLikedTrackIDs = []
        activeListeningSession = nil
        collaborativeRecommendationSeedTrackKeys = []
        dislikedTrackIDs = []
        UserDefaults.standard.removeObject(forKey: dislikedTrackIDsKey)
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
        collaborativeRecommendationSeedTrackKeys = []
    }

    private func buildHomeFromLoadedLibrary() async -> Bool {
        let snapshot = localMusicProfileStore.snapshot(for: currentProfileID)
        let candidateMixes = selectSuggestedMixSourcePlaylists(from: playlists)
        let likedPlaylist = likedSongsPlaylist
        let savedSongsPlaylist = savedSongsPlaylist

        // Capture synchronous fast-path data on the main actor before entering async context.
        let cachedLiked = likedPlaylist.flatMap { cachedPlaylistTracks(for: $0.id) } ?? []
        let localLiked = snapshot.likedTracks

        async let likedTracksFetch: [Track] = {
            if let likedPlaylist {
                // Use in-memory cache first (warm from a prior sync this session).
                if cachedLiked.isEmpty == false { return cachedLiked }
                // Fall back to locally persisted liked tracks — avoids a full API round-trip
                // on every launch and lets the home page load immediately.
                if localLiked.isEmpty == false { return localLiked }
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
        let context = recommendationSeedContext(focusedTrack: focusedTrack)
        guard context.queries.isEmpty == false else {
            return []
        }

        let accessToken = await authorizedAccessTokenIfAvailable()
        let resultBuckets = await withTaskGroup(of: RecommendationBucket?.self) { group in
            for query in context.queries.prefix(focusedTrack == nil ? 8 : 5) {
                group.addTask {
                    await self.loadRecommendationBucket(
                        for: query,
                        accessToken: accessToken,
                        limit: focusedTrack == nil ? 12 : 16
                    )
                }
            }

            var buckets: [RecommendationBucket] = []
            for await bucket in group {
                if let bucket {
                    buckets.append(bucket)
                }
            }
            return buckets
        }

        guard resultBuckets.isEmpty == false else { return [] }

        var collaborativeHitCounts: [String: Int] = [:]
        for bucket in resultBuckets {
            let uniqueBucketTrackKeys = Set(bucket.tracks.map(trackIdentifier))
            for trackKey in uniqueBucketTrackKeys {
                collaborativeHitCounts[trackKey, default: 0] += 1
            }
        }

        let rankedTracks = curatedSuggestionTracks(deduplicatedTracks(resultBuckets.flatMap(\.tracks)))
            .map { track in
                (
                    track: track,
                    score: recommendationScore(
                        for: track,
                        context: context,
                        collaborativeHitCount: collaborativeHitCounts[trackIdentifier(track), default: 0],
                        totalBucketCount: resultBuckets.count
                    )
                )
            }
            .sorted {
                if $0.score.total != $1.score.total {
                    return $0.score.total > $1.score.total
                }
                return $0.track.title.localizedCaseInsensitiveCompare($1.track.title) == .orderedAscending
            }

        var collected: [Track] = []
        var seen = excludedIdentifiers

        for rankedTrack in rankedTracks {
            let identifier = trackIdentifier(rankedTrack.track)
            guard seen.insert(identifier).inserted else { continue }
            guard rankedTrack.score.total > 0.08 || focusedTrack == nil else { continue }
            collected.append(rankedTrack.track)
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
        let pool = curated.isEmpty ? withoutShorts : curated
        return pool.filter { dislikedTrackIDs.contains(trackIdentifier($0)) == false }
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

    private func recommendationSeedContext(focusedTrack: Track?) -> RecommendationSeedContext {
        let snapshot = localMusicProfileStore.snapshot(for: currentProfileID)
        let savedSeedTracks = curatedSuggestionTracks(snapshot.savedTracks)
        let likedSeedTracks = curatedSuggestionTracks(snapshot.likedTracks)
        let behaviorSeedTracks = snapshot.behaviorInsights
            .sorted {
                if $0.playCount != $1.playCount {
                    return $0.playCount > $1.playCount
                }
                return $0.lastInteractedAt > $1.lastInteractedAt
            }
            .map(\.track)
        let topArtists = orderedUniqueQueries(
            snapshot.topArtists +
            savedSeedTracks.map(\.artist) +
            likedSeedTracks.map(\.artist) +
            behaviorSeedTracks.map(\.artist) +
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
        queries.append(contentsOf: recentSearches.prefix(4))
        queries.append(contentsOf: savedSeedTracks.prefix(3).map { "\($0.artist) \($0.title)" })
        queries.append(contentsOf: likedSeedTracks.prefix(3).map { "\($0.artist) songs" })
        queries.append(contentsOf: behaviorSeedTracks.prefix(3).map { "\($0.artist) \($0.title)" })
        queries.append(contentsOf: savedArtistCollections.prefix(3).map { "\($0.title) songs" })

        let behaviorInsightsByTrackKey = Dictionary(
            uniqueKeysWithValues: snapshot.behaviorInsights.map { (trackIdentifier($0.track), $0) }
        )
        let behaviorInsightsByArtist = Dictionary(grouping: snapshot.behaviorInsights) {
            normalizedRecommendationText($0.track.artist)
        }
        let keywordSources = recentSearches
            + topArtists
            + savedCollections.map(\.queryHint)
            + savedCollections.map(\.title)
            + savedCollections.map(\.subtitle)
            + savedSeedTracks.map(\.title)
            + likedSeedTracks.map(\.title)
            + behaviorSeedTracks.map(\.title)
            + [focusedTrack?.artist, focusedTrack?.title].compactMap { $0 }
        let downloadedTrackKeys = Set(downloadService.availableDownloads.map { trackIdentifier($0.track) })
        let collaborativeSeedTrackKeys = collaborativeRecommendationSeedTrackKeys
            .union(featuredTracks.map(trackIdentifier))
            .union(recentTracks.map(trackIdentifier))

        return RecommendationSeedContext(
            queries: orderedUniqueQueries(queries),
            preferredArtists: Set(topArtists.prefix(10).map(normalizedRecommendationText)),
            focusedArtist: focusedTrack.map { normalizedRecommendationText($0.artist) },
            focusedTitleTokens: Set(SearchTextNormalizer.tokens(from: focusedTrack?.title ?? "")),
            keywordTokens: Set(keywordSources.flatMap { SearchTextNormalizer.tokens(from: $0) }),
            behaviorInsightsByTrackKey: behaviorInsightsByTrackKey,
            behaviorInsightsByArtist: behaviorInsightsByArtist,
            likedTrackKeys: Set(snapshot.likedTracks.map(trackIdentifier)),
            savedTrackKeys: Set(snapshot.savedTracks.map(trackIdentifier)),
            downloadedTrackKeys: downloadedTrackKeys,
            collaborativeSeedTrackKeys: collaborativeSeedTrackKeys
        )
    }

    private func loadRecommendationBucket(
        for query: String,
        accessToken: String?,
        limit: Int
    ) async -> RecommendationBucket? {
        let normalizedQuery = SearchTextNormalizer.normalized(query)
        guard normalizedQuery.isEmpty == false else { return nil }

        if let cachedTracks = await recommendationCandidateCache.value(for: normalizedQuery), cachedTracks.isEmpty == false {
            return RecommendationBucket(query: query, tracks: cachedTracks)
        }

        guard let response = try? await catalogService.search(query: query, accessToken: accessToken) else {
            return nil
        }

        let tracks = Array(curatedSuggestionTracks(response.songs).prefix(limit))
        guard tracks.isEmpty == false else { return nil }
        await recommendationCandidateCache.set(tracks, for: normalizedQuery)
        return RecommendationBucket(query: query, tracks: tracks)
    }

    private func recommendationScore(
        for track: Track,
        context: RecommendationSeedContext,
        collaborativeHitCount: Int,
        totalBucketCount: Int
    ) -> RecommendationScoreComponents {
        let trackKey = trackIdentifier(track)
        let normalizedArtist = normalizedRecommendationText(track.artist)
        let candidateTokens = Set(SearchTextNormalizer.tokens(from: "\(track.artist) \(track.title)"))

        let collaborativeSeedMatch = context.collaborativeSeedTrackKeys.contains(trackKey) ? 1.0 : 0.0
        let collaborativeConsensus = totalBucketCount > 0
            ? min(1, Double(collaborativeHitCount) / Double(max(1, min(totalBucketCount, 3))))
            : 0
        let collaborativeScore = max(collaborativeSeedMatch, collaborativeConsensus)

        var contentScore = 0.0
        if context.preferredArtists.contains(normalizedArtist) {
            contentScore += 0.45
        }
        if let focusedArtist = context.focusedArtist, normalizedArtist == focusedArtist {
            contentScore += 0.35
        }
        let focusedOverlap = context.focusedTitleTokens.intersection(candidateTokens).count
        if focusedOverlap > 0 {
            contentScore += min(0.25, Double(focusedOverlap) * 0.1)
        }
        let keywordOverlap = context.keywordTokens.intersection(candidateTokens).count
        if keywordOverlap > 0 {
            contentScore += min(0.3, Double(keywordOverlap) * 0.06)
        }
        contentScore = min(1, contentScore)

        var behaviorScore = 0.0
        if context.likedTrackKeys.contains(trackKey) {
            behaviorScore += 0.3
        }
        if context.savedTrackKeys.contains(trackKey) {
            behaviorScore += 0.2
        }
        if context.downloadedTrackKeys.contains(trackKey) {
            behaviorScore += 0.2
        }

        if let insight = context.behaviorInsightsByTrackKey[trackKey] {
            behaviorScore += min(0.2, Double(insight.playCount) * 0.03)
            behaviorScore += min(0.12, Double(insight.repeatCount) * 0.04)
            behaviorScore += min(0.15, insight.averageListenRatio * 0.15)
            behaviorScore -= min(0.18, Double(insight.skipCount) * 0.05)
        } else if let artistInsights = context.behaviorInsightsByArtist[normalizedArtist], artistInsights.isEmpty == false {
            let aggregatePlayCount = artistInsights.reduce(0) { $0 + $1.playCount }
            let aggregateRepeatCount = artistInsights.reduce(0) { $0 + $1.repeatCount }
            let aggregateSkipCount = artistInsights.reduce(0) { $0 + $1.skipCount }
            let averageListenRatio = artistInsights.reduce(0.0) { $0 + $1.averageListenRatio } / Double(artistInsights.count)

            behaviorScore += min(0.18, Double(aggregatePlayCount) * 0.015)
            behaviorScore += min(0.12, Double(aggregateRepeatCount) * 0.03)
            behaviorScore += min(0.12, averageListenRatio * 0.12)
            behaviorScore -= min(0.12, Double(aggregateSkipCount) * 0.03)
        }

        behaviorScore = max(0, min(1, behaviorScore))

        return RecommendationScoreComponents(
            collaborative: collaborativeScore,
            contentSimilarity: contentScore,
            behavior: behaviorScore
        )
    }

    private func normalizedRecommendationText(_ value: String) -> String {
        SearchTextNormalizer.normalized(value)
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
            || snapshot.behaviorInsights.isEmpty == false
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
            || message.contains("invalid_grant")
            || message.contains("revoked")
    }

    private func applyAuthorizedSession(_ session: YouTubeSession) {
        self.session = session
        user = session.user
        authState = .signedIn
        logger.debug("Applied authorized session for user \(session.user.email)")
    }

    private func clearAuthorizationState() {
        session = nil
        user = nil
        authState = .guest
        clearRemoteState()
        syncLocalMusicProfileState()
        errorMessage = nil
        logger.info("Cleared authorized session state")
    }

    private func authorizedSessionIfAvailable(forceRefresh: Bool = false) async -> YouTubeSession? {
        guard session != nil else { return nil }

        if forceRefresh == false, let session, session.isExpired == false {
            return session
        }

        logger.debug(forceRefresh ? "Refreshing authorized session" : "Restoring authorized session")
        let refreshedSession = await authService.refreshSession()

        guard let refreshedSession else {
            logger.info("Authorized session refresh did not produce a usable session")
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

        logger.error("Authorization failure detected; signing out to recover cleanly", error: error)
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

    private func sharedTrackID(from url: URL) -> String? {
        let trimmedScheme = url.scheme?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if trimmedScheme == AppConfig.Sharing.appURLScheme,
           let directID = sharedTrackIDFromComponents(
                host: url.host,
                pathComponents: url.pathComponents,
                queryItems: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
           ) {
            return directID
        }

        guard let host = url.host?.lowercased(),
              AppConfig.Sharing.supportedWebHosts.contains(host) else {
            return nil
        }

        return sharedTrackIDFromComponents(
            host: url.host,
            pathComponents: url.pathComponents,
            queryItems: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        )
    }

    private func sharedTrackIDFromComponents(
        host: String?,
        pathComponents: [String],
        queryItems: [URLQueryItem]
    ) -> String? {
        let filteredPath = pathComponents.filter { $0 != "/" && $0.isEmpty == false }

        if let queryTrackID = queryItems.first(where: { ["track", "video", "v"].contains($0.name.lowercased()) })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           queryTrackID.isEmpty == false {
            return queryTrackID
        }

        if host?.lowercased() == "track", let firstPath = filteredPath.first {
            let decodedPath = firstPath.removingPercentEncoding ?? firstPath
            let trimmedPath = decodedPath.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedPath.isEmpty ? nil : trimmedPath
        }

        return nil
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

    private func handlePlaybackStateTransition(from previousState: PlaybackState, to nextState: PlaybackState) {
        let previousTrack = previousState.nowPlaying
        let nextTrack = nextState.nowPlaying

        if previousTrack != nextTrack || nextState.isPlaying || nextState.isResolvingStream {
            autoplayContinuationTask?.cancel()
            autoplayContinuationTask = nil
        }

        if previousTrack != nextTrack || shouldKeepWatchingPlaybackCompletion(for: nextState) == false {
            playbackCompletionWatchTask?.cancel()
            playbackCompletionWatchTask = nil
        }

        if previousTrack != nextTrack {
            if let previousTrack {
                finalizeListeningSession(for: previousTrack, using: previousState)
            }
            if let nextTrack {
                if isHistoryEnabled {
                    beginListeningSession(for: nextTrack, using: nextState)
                } else {
                    activeListeningSession = nil
                }
            } else {
                activeListeningSession = nil
            }
            return
        }

        guard let nextTrack else {
            autoplayContinuationTask?.cancel()
            autoplayContinuationTask = nil
            activeListeningSession = nil
            return
        }

        if isHistoryEnabled,
           activeListeningSession == nil,
           nextState.isPlaying || nextState.currentTime > 0 {
            beginListeningSession(for: nextTrack, using: nextState)
        } else if isHistoryEnabled == false {
            activeListeningSession = nil
        }

        if let activeListeningSession,
           trackIdentifier(activeListeningSession.track) == trackIdentifier(nextTrack),
           nextState.currentTime + 1 < previousState.currentTime {
            self.activeListeningSession = ActiveListeningSession(
                track: nextTrack,
                startingOffset: nextState.currentTime
            )
        }

        if shouldAttemptAutoplayContinuation(from: previousState, to: nextState, track: nextTrack) {
            scheduleAutoplayContinuation(after: nextTrack)
        }

        if shouldKeepWatchingPlaybackCompletion(for: nextState) {
            schedulePlaybackCompletionWatch(for: nextTrack, observedTime: nextState.currentTime)
        }
    }

    private func shouldAttemptAutoplayContinuation(
        from previousState: PlaybackState,
        to nextState: PlaybackState,
        track: Track
    ) -> Bool {
        guard playbackService.repeatMode == .off else { return false }
        guard previousState.isPlaying else { return false }
        guard nextState.isPlaying == false, nextState.isResolvingStream == false else { return false }
        guard nextState.playbackErrorMessage == nil else { return false }
        guard nextState.hasNextTrack == false else { return false }
        guard nextState.duration > 0 else { return false }

        let endThreshold = max(1.5, min(4, nextState.duration * 0.05))
        let didReachNaturalEnd = nextState.currentTime >= nextState.duration - endThreshold
        guard didReachNaturalEnd else { return false }

        if let queueIndex = playbackService.currentQueueIndex,
           queueIndex + 1 < playbackService.currentQueue.count {
            return true
        }

        return autoplayContinuationCandidates(after: track).isEmpty == false
    }

    private func scheduleAutoplayContinuation(after track: Track) {
        autoplayContinuationTask?.cancel()
        autoplayContinuationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, Task.isCancelled == false else { return }
            guard let currentTrack = self.playbackState.nowPlaying,
                  self.trackIdentifier(currentTrack) == self.trackIdentifier(track) else { return }
            guard self.playbackState.isPlaying == false,
                  self.playbackState.isResolvingStream == false,
                  self.playbackState.playbackErrorMessage == nil else { return }
            self.attemptAutoplayContinuation(after: track)
        }
    }

    private func shouldKeepWatchingPlaybackCompletion(for state: PlaybackState) -> Bool {
        guard playbackService.repeatMode != .one else { return false }
        guard state.nowPlaying != nil else { return false }
        guard state.playbackErrorMessage == nil else { return false }
        guard state.isResolvingStream == false else { return false }
        guard state.duration > 0 else { return false }

        let endThreshold = max(1.5, min(4, state.duration * 0.05))
        return state.currentTime >= state.duration - endThreshold
    }

    private func schedulePlaybackCompletionWatch(for track: Track, observedTime: TimeInterval) {
        playbackCompletionWatchTask?.cancel()
        playbackCompletionWatchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard let self, Task.isCancelled == false else { return }
            guard let currentTrack = self.playbackState.nowPlaying,
                  self.trackIdentifier(currentTrack) == self.trackIdentifier(track) else { return }
            guard self.playbackState.playbackErrorMessage == nil,
                  self.playbackState.isResolvingStream == false,
                  self.shouldKeepWatchingPlaybackCompletion(for: self.playbackState) else { return }

            let playheadAdvanced = self.playbackState.currentTime > observedTime + 0.2
            guard playheadAdvanced == false else { return }

            self.logger.debug("Playback completion watchdog advancing stalled end-of-track playback")
            self.attemptAutoplayContinuation(after: track)
        }
    }

    private func attemptAutoplayContinuation(after track: Track) {
        if let nextQueuedTrack = nextTrackInCurrentQueue(after: track) {
            self.logger.debug("Autoplay advancing to the next queued track")
            self.play(track: nextQueuedTrack.track, queue: nextQueuedTrack.queue)
            return
        }

        if playbackService.repeatMode == .all,
           let firstTrack = playbackService.currentQueue.first,
           playbackService.currentQueue.isEmpty == false {
            self.logger.debug("Autoplay wrapping to the start of the current queue")
            self.play(track: firstTrack, queue: playbackService.currentQueue)
            return
        }

        let candidates = self.autoplayContinuationCandidates(after: track)
        guard let nextTrack = candidates.first else { return }

        self.logger.debug("Autoplay continuing with \(nextTrack.artist) - \(nextTrack.title)")
        self.play(track: nextTrack, queue: candidates)
    }

    private func nextTrackInCurrentQueue(after track: Track) -> (track: Track, queue: [Track])? {
        let queue = playbackService.currentQueue
        guard queue.isEmpty == false else { return nil }

        if let queueIndex = playbackService.currentQueueIndex,
           queueIndex >= 0,
           queueIndex < queue.count - 1 {
            return (queue[queueIndex + 1], queue)
        }

        if let matchedIndex = queue.firstIndex(where: { trackIdentifier($0) == trackIdentifier(track) }),
           matchedIndex < queue.count - 1 {
            return (queue[matchedIndex + 1], queue)
        }

        return nil
    }

    private func autoplayContinuationCandidates(after track: Track) -> [Track] {
        let currentID = trackIdentifier(track)
        var candidates: [Track] = []

        func append(_ tracks: [Track]) {
            candidates.append(contentsOf: tracks.filter { trackIdentifier($0) != currentID })
        }

        if let queueIndex = playbackService.currentQueueIndex,
           queueIndex + 1 < playbackService.currentQueue.count {
            append(Array(playbackService.currentQueue.suffix(from: queueIndex + 1)))
        }

        append(relatedTracks)
        append(searchResults.songs)
        append(homeContent.featuredTracks)
        append(homeContent.recentTracks)
        append(historyTracks)

        return curatedSuggestionTracks(deduplicatedTracks(candidates))
            .filter { dislikedTrackIDs.contains(trackIdentifier($0)) == false }
    }

    private func beginListeningSession(for track: Track, using playbackState: PlaybackState) {
        activeListeningSession = ActiveListeningSession(
            track: track,
            startingOffset: max(0, playbackState.currentTime)
        )
    }

    private func finalizeListeningSession(for track: Track, using playbackState: PlaybackState) {
        guard let activeListeningSession else { return }
        guard trackIdentifier(activeListeningSession.track) == trackIdentifier(track) else { return }

        let listenedSeconds = max(0, playbackState.currentTime - activeListeningSession.startingOffset)
        self.activeListeningSession = nil

        guard isHistoryEnabled else { return }
        guard listenedSeconds > 0 else { return }

        let resolvedDuration = playbackState.duration > 0
            ? playbackState.duration
            : (track.duration ?? playbackState.nowPlaying?.duration ?? 0)
        let skipThreshold = resolvedDuration > 0
            ? min(30, max(10, resolvedDuration * 0.35))
            : 20
        let wasSkipped = listenedSeconds < skipThreshold

        _ = localMusicProfileStore.recordListeningBehavior(
            for: track,
            listenedSeconds: listenedSeconds,
            trackDuration: resolvedDuration > 0 ? resolvedDuration : nil,
            skipped: wasSkipped,
            profileID: currentProfileID
        )
        syncLocalMusicProfileState()
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

        // YouTube's playlist-list API returns an itemCount from playlist metadata, which is
        // often stale or lower than the real count (it doesn't include local-only liked tracks).
        // When we have a higher count from a previous full hydration (stored in playlistCache or
        // the local snapshot), keep that larger number so the UI doesn't visibly drop mid-session.
        let patchedRemote: [Playlist] = remoteCollections.map { playlist in
            guard playlist.kind == .likedMusic else { return playlist }
            let cachedCount = cachedPlaylistTracks(for: playlist.id)?.count
            let localCount = localMusicProfileStore.snapshot(for: currentProfileID).likedTracks.count
            let bestCount = max(playlist.itemCount, cachedCount ?? 0, localCount)
            guard bestCount > playlist.itemCount else { return playlist }
            return Playlist(
                id: playlist.id,
                title: playlist.title,
                description: playlist.description,
                artworkURL: playlist.artworkURL,
                itemCount: bestCount,
                kind: playlist.kind
            )
        }

        return prioritizeLibraryPlaylists(patchedRemote + localCollections)
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
            let key = SearchTextNormalizer.normalized(trimmed)
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
