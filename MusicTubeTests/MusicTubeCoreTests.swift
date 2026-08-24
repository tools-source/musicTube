import AVFoundation
import XCTest
@testable import MusicTube

final class MusicTubeCoreTests: XCTestCase {
    @MainActor
    func testRootErrorMessageBindingDoesNotRecurse() {
        let appState = AppState.makeDefault()
        let root = RootViewModel(appState: appState)

        appState.errorMessage = "Playback failed"
        XCTAssertEqual(root.errorMessage, "Playback failed")

        root.errorMessage = nil
        XCTAssertNil(appState.errorMessage)
    }

    @MainActor
    func testRemotePlaybackItemDoesNotWaitForDurationMetadata() {
        let remoteURL = URL(string: "https://example.com/two-hour-track.m4a")!
        let remoteItem = PlaybackService.makePlayerItem(for: remoteURL)

        XCTAssertFalse(remoteItem.automaticallyLoadedAssetKeys.contains("duration"))
        XCTAssertTrue(remoteItem.automaticallyLoadedAssetKeys.contains("playable"))
    }

    func testLongGooglevideoStreamsUseBoundedRangeLoader() throws {
        let longStreamURL = try XCTUnwrap(URL(string:
            "https://rr1---sn.example.googlevideo.com/videoplayback?clen=55354532&mime=audio%2Fmp4"
        ))
        let loader = try XCTUnwrap(BoundedHTTPStreamLoader(sourceURL: longStreamURL))

        XCTAssertEqual(loader.asset.url.scheme, "musictube-stream")
        XCTAssertEqual(BoundedHTTPStreamLoader.maximumRangeLength, 512 * 1_024)
        XCTAssertNotNil(BoundedHTTPStreamLoader(sourceURL: URL(string:
            "https://rr1---sn.example.googlevideo.com/videoplayback?mime=video%2Fmp4&c=TVHTML5"
        )!))
        XCTAssertNil(BoundedHTTPStreamLoader(sourceURL: URL(string: "https://example.com/audio.m4a")!))
    }

    func testProoflessLongMobileAudioURLRequiresProgressiveFallback() throws {
        let restrictedURL = try XCTUnwrap(URL(string:
            "https://rr1---sn.example.googlevideo.com/videoplayback?clen=55354532&c=IOS&mime=audio%2Fmp4"
        ))
        let proofedURL = try XCTUnwrap(URL(string:
            "https://rr1---sn.example.googlevideo.com/videoplayback?clen=55354532&c=IOS&pot=proof"
        ))
        let shortURL = try XCTUnwrap(URL(string:
            "https://rr1---sn.example.googlevideo.com/videoplayback?clen=900000&c=ANDROID_VR"
        ))
        let tvURL = try XCTUnwrap(URL(string:
            "https://rr1---sn.example.googlevideo.com/videoplayback?clen=55354532&c=TVHTML5"
        ))

        XCTAssertTrue(PlaybackService.isLikelyProofRestrictedAudioURL(restrictedURL))
        XCTAssertFalse(PlaybackService.isLikelyProofRestrictedAudioURL(proofedURL))
        XCTAssertFalse(PlaybackService.isLikelyProofRestrictedAudioURL(shortURL))
        XCTAssertFalse(PlaybackService.isLikelyProofRestrictedAudioURL(tvURL))
    }

    func testDownloadsPreferRemoteExtractionWithLocalFallback() {
        XCTAssertEqual(PlaybackService.downloadExtractionMethods, [.remote, .local])
    }

    func testInteractivePlaybackPrefersRemoteExtractionWithLocalFallback() {
        XCTAssertEqual(PlaybackService.playbackExtractionMethods, [.remote, .local])
    }

    func testYouTubeTrackDurationWinsOverPaddedStreamDuration() {
        let duration = PlaybackService.preferredAuthoritativeDuration(
            trackDuration: 203,
            streamDurations: [406]
        )

        XCTAssertEqual(duration, 203)
    }

    func testGoogleVideoURLDurationIsUsedWhenMetadataIsMissing() throws {
        let streamURL = try XCTUnwrap(URL(string:
            "https://rr1---sn.example.googlevideo.com/videoplayback?mime=audio%2Fmp4&dur=203.417&clen=4000000"
        ))

        let urlDuration = try XCTUnwrap(PlaybackService.durationFromStreamURL(streamURL))
        let preferredDuration = try XCTUnwrap(
            PlaybackService.preferredAuthoritativeDuration(
                trackDuration: nil,
                streamURLs: [streamURL]
            )
        )

        XCTAssertEqual(urlDuration, 203.417, accuracy: 0.001)
        XCTAssertEqual(preferredDuration, 203.417, accuracy: 0.001)
    }

    @MainActor
    func testSleepTimerExpiresAndClearsItsVisibleState() async throws {
        let appState = AppState.makeDefault()
        appState.setSleepTimer(duration: 0.05)

        XCTAssertNotNil(appState.sleepTimerEndDate)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertNil(appState.sleepTimerEndDate)
        XCTAssertNil(appState.sleepTimerTask)
    }

    @MainActor
    func testSleepTimerReconcilesAnOverdueDeadlineAndCanBeCancelled() throws {
        let appState = AppState.makeDefault()
        appState.setSleepTimer(duration: 60)
        let endDate = try XCTUnwrap(appState.sleepTimerEndDate)

        appState.reconcileSleepTimer(now: endDate.addingTimeInterval(1))
        XCTAssertNil(appState.sleepTimerEndDate)
        XCTAssertNil(appState.sleepTimerTask)

        appState.setSleepTimer(duration: 60)
        appState.cancelSleepTimer()
        XCTAssertNil(appState.sleepTimerEndDate)
        XCTAssertNil(appState.sleepTimerTask)
    }

    func testQueryValidationTrimsAndRejectsInvalidInput() throws {
        XCTAssertEqual(try QueryValidator.validateSearchQuery("  Massive Attack  "), "Massive Attack")
        XCTAssertThrowsError(try QueryValidator.validateSearchQuery("   "))
        XCTAssertThrowsError(
            try QueryValidator.validateSearchQuery(String(repeating: "a", count: AppConfig.Search.maxQueryLength + 1))
        )
    }

    func testArabicSearchNormalizationIsDeterministic() {
        XCTAssertEqual(SearchTextNormalizer.normalized("  إِلَى السَّماء  "), "الي السماء")
        XCTAssertEqual(SearchTextNormalizer.tokens(from: "Beyoncé — Halo"), ["beyonce", "halo"])
    }

    func testUnavailableAndShortFormTracksAreFiltered() {
        let unavailable = Track(title: "[Deleted video]", artist: "", youtubeVideoID: "deleted")
        let short = Track(title: "Song #Shorts", artist: "Artist", duration: 30, youtubeVideoID: "short")
        let song = Track(title: "Full Song", artist: "Artist", duration: 210, youtubeVideoID: "song")

        XCTAssertEqual([unavailable, short, song].playableOnly().map(\.id), [short.id, song.id])
        XCTAssertEqual([short, song].withoutShorts().map(\.id), [song.id])
    }

    func testTrackSynthesizesArtworkFromYouTubeVideoID() throws {
        let track = Track(title: "Song", artist: "Artist", youtubeVideoID: "video-id")
        XCTAssertEqual(
            track.artworkURL?.absoluteString,
            "https://i.ytimg.com/vi/video-id/hqdefault.jpg"
        )

        let persistedJSON = """
        {
          "id": "persisted-track",
          "title": "Persisted Song",
          "artist": "Artist",
          "youtubeVideoID": "persisted-video",
          "tags": []
        }
        """
        let decoded = try JSONDecoder().decode(Track.self, from: Data(persistedJSON.utf8))
        XCTAssertEqual(
            decoded.artworkURL?.absoluteString,
            "https://i.ytimg.com/vi/persisted-video/hqdefault.jpg"
        )
    }

    func testAICurationDefaultsOnAndPreservesExplicitOptOut() {
        let suiteName = "MusicTubeCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var settings = DataUsageSettings(defaults: defaults)
        XCTAssertTrue(settings.personalizedAICuration)

        settings.personalizedAICuration = false
        XCTAssertFalse(defaults.bool(forKey: "Privacy.personalizedAICuration"))

        settings = DataUsageSettings(defaults: defaults)
        
        XCTAssertFalse(settings.personalizedAICuration)
        
        settings.resetToDefaults()
        XCTAssertTrue(settings.personalizedAICuration)
    }

    func testRecommendationEngineDeduplicatesContentAndExcludesDislikesAndRecents() async {
        let engine = RecommendationEngine()
        let recent = Track(title: "Recent", artist: "Artist", duration: 180, youtubeVideoID: "recent")
        let disliked = Track(title: "Disliked", artist: "Artist", duration: 180, youtubeVideoID: "disliked")
        let original = Track(title: "Song", artist: "Singer", duration: 201, youtubeVideoID: "one")
        let duplicateUpload = Track(title: "Song", artist: "Singer", duration: 202, youtubeVideoID: "two")

        let results = await engine.recommendations(
            for: RecommendationRequest(
                candidates: [recent, disliked, original, duplicateUpload],
                recentTracks: [recent],
                likedTracks: [],
                dislikedTrackIDs: [disliked.playbackKey],
                preferences: .empty,
                focusedTrack: nil,
                limit: 10
            )
        )

        XCTAssertEqual(results.map(\.playbackKey), [original.playbackKey])
    }

    func testRecommendationEngineSeparatesQuranFromMusic() async {
        let engine = RecommendationEngine()
        let focusedQuran = Track(title: "Surah Al-Kahf Quran Recitation", artist: "Reciter", youtubeVideoID: "focus")
        let recitation = Track(title: "Surah Maryam Tilawah", artist: "Reciter", youtubeVideoID: "quran")
        let song = Track(title: "Summer Song", artist: "Band", youtubeVideoID: "music")

        let results = await engine.recommendations(
            for: RecommendationRequest(
                candidates: [song, recitation],
                recentTracks: [],
                likedTracks: [],
                dislikedTrackIDs: [],
                preferences: .empty,
                focusedTrack: focusedQuran,
                limit: 10
            )
        )

        XCTAssertEqual(results.map(\.playbackKey), [recitation.playbackKey])
    }

    func testRecommendationEnginePreservesArtistAffinity() async {
        let engine = RecommendationEngine()
        let preferredArtistTrack = Track(title: "Known Favorite", artist: "Favorite Artist", youtubeVideoID: "liked")
        let matchingCandidate = Track(title: "Deep Cut", artist: "Favorite Artist", youtubeVideoID: "match")
        let unrelatedCandidate = Track(title: "Popular Song", artist: "Another Artist", youtubeVideoID: "other")

        let results = await engine.recommendations(
            for: RecommendationRequest(
                candidates: [unrelatedCandidate, matchingCandidate],
                recentTracks: [],
                likedTracks: [preferredArtistTrack],
                dislikedTrackIDs: [],
                preferences: .empty,
                focusedTrack: nil,
                limit: 10
            )
        )

        XCTAssertEqual(results.first?.playbackKey, matchingCandidate.playbackKey)
    }

    func testRecommendationEngineUsesSavedAndFocusedAffinities() async {
        let engine = RecommendationEngine()
        let saved = Track(title: "Saved", artist: "Saved Artist", youtubeVideoID: "saved")
        let focused = Track(title: "Focus", artist: "Focus Artist", youtubeVideoID: "focus")
        let neutral = Track(title: "Neutral", artist: "Other", youtubeVideoID: "neutral")
        let savedMatch = Track(title: "Saved Match", artist: "Saved Artist", youtubeVideoID: "saved-match")
        let focusedMatch = Track(title: "Focused Match", artist: "Focus Artist", youtubeVideoID: "focus-match")

        let results = await engine.recommendations(
            for: RecommendationRequest(
                candidates: [neutral, savedMatch, focusedMatch],
                recentTracks: [],
                likedTracks: [],
                savedTracks: [saved],
                dislikedTrackIDs: [],
                preferences: .empty,
                focusedTrack: focused,
                limit: 3
            )
        )

        XCTAssertEqual(results.first?.playbackKey, focusedMatch.playbackKey)
        XCTAssertEqual(results.dropFirst().first?.playbackKey, savedMatch.playbackKey)
    }

    func testRecommendationEngineKeepsUnknownContextAndStableOrdering() async {
        let engine = RecommendationEngine()
        let first = Track(title: "First", artist: "Artist A", youtubeVideoID: "first")
        let second = Track(title: "Second", artist: "Artist B", youtubeVideoID: "second")

        let results = await engine.recommendations(
            for: RecommendationRequest(
                candidates: [first, second],
                recentTracks: [],
                likedTracks: [],
                dislikedTrackIDs: [],
                preferences: .empty,
                focusedTrack: nil,
                limit: 2
            )
        )

        XCTAssertEqual(results.map(\.playbackKey), ["first", "second"])
    }

    func testRecommendationEngineHandlesEmptyInputAndLimit() async {
        let engine = RecommendationEngine()
        let tracks = (0..<5).map {
            Track(title: "Track \($0)", artist: "Artist", youtubeVideoID: "track-\($0)")
        }
        let empty = await engine.recommendations(
            for: RecommendationRequest(
                candidates: [],
                recentTracks: [],
                likedTracks: [],
                dislikedTrackIDs: [],
                preferences: .empty,
                focusedTrack: nil,
                limit: 10
            )
        )
        let limited = await engine.recommendations(
            for: RecommendationRequest(
                candidates: tracks,
                recentTracks: [],
                likedTracks: [],
                dislikedTrackIDs: [],
                preferences: .empty,
                focusedTrack: nil,
                limit: 2
            )
        )

        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(limited.count, 2)
    }

    @MainActor
    func testSearchViewModelCancelsPreviousRequest() async throws {
        let source = MockSearchDataSource(mode: .cancellable)
        let model = SearchViewModel(
            appState: .makeDefault(),
            dataSource: source,
            debounceNanoseconds: 0
        )

        model.setQuery("first", immediately: true)
        try await Task.sleep(nanoseconds: 20_000_000)
        model.setQuery("second", immediately: true)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(model.snapshot.results.songs.first?.title, "second")
        XCTAssertEqual(source.cancelledQueries, ["first"])
    }

    @MainActor
    func testSearchViewModelIgnoresStaleResponse() async throws {
        let source = MockSearchDataSource(mode: .ignoresCancellation)
        let model = SearchViewModel(
            appState: .makeDefault(),
            dataSource: source,
            debounceNanoseconds: 0
        )

        model.setQuery("slow", immediately: true)
        try await Task.sleep(nanoseconds: 10_000_000)
        model.setQuery("fast", immediately: true)
        try await Task.sleep(nanoseconds: 220_000_000)

        XCTAssertEqual(model.snapshot.results.songs.first?.title, "fast")
        XCTAssertFalse(model.snapshot.isSearching)
    }

    @MainActor
    func testSearchAutocompletePreservesLocalSuggestionsWhenRemoteIsEmpty() async throws {
        let source = MockSearchDataSource(
            mode: .cancellable,
            localAutocompleteSuggestions: ["Halo", "Halo Beyonce"],
            remoteAutocompleteSuggestions: []
        )
        let model = SearchViewModel(
            appState: .makeDefault(),
            dataSource: source,
            debounceNanoseconds: 0
        )

        model.setQuery("halo", immediately: true)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(model.snapshot.autocompleteSuggestions, ["Halo", "Halo Beyonce"])
        XCTAssertFalse(model.snapshot.isLoadingAutocomplete)
    }

    @MainActor
    func testRelatedRankingKeepsSparseFocusedSearchCandidates() {
        let appState = AppState.makeDefault()
        let focused = Track(title: "Focus", artist: "Original Artist", youtubeVideoID: "focus")
        let first = Track(title: "Different One", artist: "Another Artist", youtubeVideoID: "one")
        let second = Track(title: "Different Two", artist: "Third Artist", youtubeVideoID: "two")

        let ranked = appState.rankedRelatedCandidates([first, second], to: focused, limit: 10)

        XCTAssertEqual(ranked.map(\.playbackKey), ["one", "two"])
    }

    @MainActor
    func testRelatedQueriesOnlyAddRecitationQualifierForQuran() {
        let appState = AppState.makeDefault()
        let arabicSong = Track(
            title: "مهما يلوعني الحنين",
            artist: "أيوب طارش",
            youtubeVideoID: "song"
        )
        let recitation = Track(
            title: "سورة الكهف",
            artist: "مشاري العفاسي",
            youtubeVideoID: "quran"
        )

        XCTAssertFalse(appState.focusedRelatedQueries(for: arabicSong).contains { $0.contains("تلاوة") })
        XCTAssertTrue(appState.focusedRelatedQueries(for: recitation).contains { $0.contains("تلاوة") })
    }

    func testDownloadConcurrencyPolicyAdaptsToEnvironment() {
        let normalWiFi = DownloadConcurrencyEnvironment(
            isLowPowerModeEnabled: false,
            isCellular: false,
            isExpensiveNetwork: false,
            isLowDataMode: false,
            isInBackground: false,
            isThermallyConstrained: false
        )
        XCTAssertEqual(DownloadConcurrencyPolicy.limit(default: 3, environment: normalWiFi), 3)

        var constrained = DownloadConcurrencyEnvironment(
            isLowPowerModeEnabled: true,
            isCellular: false,
            isExpensiveNetwork: false,
            isLowDataMode: false,
            isInBackground: false,
            isThermallyConstrained: false
        )
        XCTAssertEqual(DownloadConcurrencyPolicy.limit(default: 3, environment: constrained), 1)

        constrained = DownloadConcurrencyEnvironment(
            isLowPowerModeEnabled: false,
            isCellular: true,
            isExpensiveNetwork: true,
            isLowDataMode: false,
            isInBackground: false,
            isThermallyConstrained: false
        )
        XCTAssertEqual(DownloadConcurrencyPolicy.limit(default: 3, environment: constrained), 1)

        constrained = DownloadConcurrencyEnvironment(
            isLowPowerModeEnabled: false,
            isCellular: false,
            isExpensiveNetwork: true,
            isLowDataMode: false,
            isInBackground: false,
            isThermallyConstrained: false
        )
        XCTAssertEqual(DownloadConcurrencyPolicy.limit(default: 3, environment: constrained), 2)
    }

    func testDownloadBatchPlannerDeduplicatesAndPreservesSourceOrder() {
        let first = Track(title: "First", artist: "Artist", youtubeVideoID: "first")
        let duplicate = Track(title: "First duplicate", artist: "Artist", youtubeVideoID: "first")
        let existing = Track(title: "Existing", artist: "Artist", youtubeVideoID: "existing")
        let last = Track(title: "Last", artist: "Artist", youtubeVideoID: "last")

        let candidates = DownloadBatchPlanner.candidates(
            from: [first, duplicate, existing, last],
            excluding: [existing.playbackKey]
        )

        XCTAssertEqual(candidates.map(\.track.playbackKey), ["first", "last"])
        XCTAssertEqual(candidates.map(\.sourceTrackIndex), [0, 3])
    }
}

@MainActor
private final class MockSearchDataSource: SearchDataSource {
    enum Mode {
        case cancellable
        case ignoresCancellation
    }

    let mode: Mode
    private(set) var cancelledQueries: [String] = []
    private let localAutocompleteSuggestions: [String]
    private let remoteAutocompleteSuggestions: [String]

    init(
        mode: Mode,
        localAutocompleteSuggestions: [String] = [],
        remoteAutocompleteSuggestions: [String] = []
    ) {
        self.mode = mode
        self.localAutocompleteSuggestions = localAutocompleteSuggestions
        self.remoteAutocompleteSuggestions = remoteAutocompleteSuggestions
    }

    func fetchSearchResults(for query: String) async throws -> SearchResponse {
        switch mode {
        case .cancellable:
            do {
                try await Task.sleep(
                    nanoseconds: query == "first" ? 200_000_000 : 5_000_000
                )
            } catch {
                cancelledQueries.append(query)
                throw error
            }
        case .ignoresCancellation:
            let delay: UInt64 = query == "slow" ? 150_000_000 : 5_000_000
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) {
                    continuation.resume()
                }
            }
        }

        return SearchResponse(
            songs: [Track(title: query, artist: "Test", youtubeVideoID: query)],
            playlists: [],
            albums: [],
            artists: [],
            nextSongsContinuationToken: nil
        )
    }

    func fetchMoreSearchResults(query: String, continuation: String) async throws -> SearchResponse {
        .empty
    }

    func autocompleteSuggestions(
        for query: String,
        limit: Int,
        includeRemote: Bool
    ) async -> [String] {
        Array(
            (includeRemote ? remoteAutocompleteSuggestions : localAutocompleteSuggestions)
                .prefix(limit)
        )
    }

    func recentSearchTrackSuggestions(limit: Int) async -> [Track] {
        []
    }
}
