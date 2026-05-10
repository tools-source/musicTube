import Foundation

final class YouTubeAPIService: MusicCatalogProviding {
    enum YouTubeAPIError: LocalizedError {
        case invalidSearchQuery(QueryValidationError)
        case authenticationFailure
        case rateLimited(retryAfter: TimeInterval?)
        case networkError(URLError)
        case invalidResponse(statusCode: Int, message: String?)
        case decodingError(DecodingError)
        case notFound
        case serviceError(String)

        var errorDescription: String? {
            switch self {
            case .invalidSearchQuery(let error):
                return error.localizedDescription
            case .authenticationFailure:
                return "Your YouTube session expired. Please sign in again."
            case .rateLimited:
                return "YouTube is rate limiting requests right now. Please try again in a moment."
            case .networkError(let error):
                return error.localizedDescription
            case .invalidResponse(_, let message):
                return message ?? "YouTube returned an unexpected response."
            case .decodingError:
                return "MusicTube couldn't read YouTube's response."
            case .notFound:
                return "The requested YouTube item could not be found."
            case .serviceError(let message):
                return message
            }
        }

        var isRetryable: Bool {
            switch self {
            case .networkError, .rateLimited:
                return true
            case .invalidResponse(let statusCode, _):
                return [500, 502, 503, 504].contains(statusCode)
            default:
                return false
            }
        }
    }

    typealias APIError = YouTubeAPIError

    private struct InnerTubeTrackPage {
        let tracks: [Track]
        let continuationToken: String?
    }

    private let urlSession: URLSession
    private let apiKeys: [String]
    private let logger: any AppLogging
    private let searchCache = CacheStore<String, SearchResponse>(
        ttl: AppConfig.Search.cacheTTL,
        maxEntries: AppConfig.Search.maxCachedQueries
    )
    private let likedMusicPlaylistID = AppConfig.YouTube.likedMusicPlaylistID
    private let likedMusicPreviewLimit = AppConfig.YouTube.likedMusicPreviewLimit
    private let innerTubeClientVersion = AppConfig.YouTube.innerTubeClientVersion

    private var innerTubeSearchURL: URL {
        var components = URLComponents(
            url: AppConfig.YouTube.innerTubeSearchEndpoint,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "key", value: validatedAPIKey),
            URLQueryItem(name: "prettyPrint", value: "false")
        ].compactMap { $0.value == nil ? nil : $0 }

        return components?.url ?? AppConfig.YouTube.innerTubeSearchEndpoint
    }

    init(
        urlSession: URLSession = .shared,
        apiKeys: [String] = AppConfig.YouTube.apiKeys,
        logger: any AppLogging = DefaultAppLogger(category: "YouTubeAPIService")
    ) {
        self.urlSession = urlSession
        self.apiKeys = apiKeys
        self.logger = logger
    }

    func loadHome(accessToken: String) async throws -> (featured: [Track], recent: [Track]) {
        do {
            logger.debug("Loading personalized home content")
            let home = try await loadAuthorizedHome(accessToken: accessToken)
            logger.info("Loaded personalized home content")
            return home
        } catch {
            logger.error("Failed to load personalized home content", error: error)
            throw mapAPIError(error)
        }
    }

    func search(query: String, accessToken: String?) async throws -> SearchResponse {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return .empty }

        let validatedQuery: String
        do {
            validatedQuery = try QueryValidator.validateSearchQuery(trimmedQuery)
        } catch let error as QueryValidationError {
            throw APIError.invalidSearchQuery(error)
        }

        let cacheKey = normalizedSearchCacheKey(for: validatedQuery)
        if let cachedResults = await searchCache.value(for: cacheKey) {
            logger.debug("Returning cached search results for query: \(validatedQuery)")
            return cachedResults
        }

        do {
            logger.debug("Starting search for query: \(validatedQuery)")
            let results = try await performSearch(query: validatedQuery, accessToken: accessToken)
            await searchCache.set(results, for: cacheKey)
            logger.info("Completed search for query: \(validatedQuery)")
            return results
        } catch {
            logger.error("Search failed for query: \(validatedQuery)", error: error)
            throw mapAPIError(error)
        }
    }

    func loadMoreSearchResults(query: String, continuation: String, accessToken: String?) async throws -> SearchResponse {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return .empty }

        let validatedQuery: String
        do {
            validatedQuery = try QueryValidator.validateSearchQuery(trimmedQuery)
        } catch let error as QueryValidationError {
            throw APIError.invalidSearchQuery(error)
        }

        do {
            logger.debug("Loading more search results for query: \(validatedQuery)")
            let page = try await fetchTrackSearchPageViaInnerTube(
                query: validatedQuery,
                continuationToken: continuation,
                maxResults: AppConfig.Search.resultsPerPage
            )

            return SearchResponse(
                trackCategory: .init(
                    items: page.tracks,
                    continuationToken: page.continuationToken
                )
            )
        } catch {
            logger.error("Failed to load more search results for query: \(validatedQuery)", error: error)
            throw mapAPIError(error)
        }
    }

    private func performSearch(query: String, accessToken: String?) async throws -> SearchResponse {
        async let trackSearchTask: Result<InnerTubeTrackPage, Error> = {
            do {
                return .success(try await performTrackSearch(query: query, accessToken: accessToken))
            } catch {
                return .failure(error)
            }
        }()
        async let collectionSearchTask: (playlists: [MusicCollection], albums: [MusicCollection], artists: [MusicCollection]) = {
            (try? await performCollectionSearch(query: query)) ??
                (playlists: [], albums: [], artists: [])
        }()

        let trackSearchResult = await trackSearchTask
        let trackPage: InnerTubeTrackPage
        let trackSearchError: Error?
        switch trackSearchResult {
        case .success(let page):
            trackPage = page
            trackSearchError = nil
        case .failure(let error):
            trackPage = InnerTubeTrackPage(tracks: [], continuationToken: nil)
            trackSearchError = error
        }

        let collections = await collectionSearchTask
        let response = SearchResponse(
            trackCategory: .init(
                items: trackPage.tracks,
                continuationToken: trackPage.continuationToken
            ),
            playlistCategory: .init(items: collections.playlists),
            albumCategory: .init(items: collections.albums),
            artistCategory: .init(items: collections.artists)
        )

        if response.isEmpty, let trackSearchError {
            throw trackSearchError
        }

        return response
    }

    private func performTrackSearch(query: String, accessToken: String?) async throws -> InnerTubeTrackPage {
        if let innerTubePage = try? await fetchTrackSearchPageViaInnerTube(
            query: query,
            continuationToken: nil,
            maxResults: AppConfig.Search.resultsPerPage
        ), innerTubePage.tracks.isEmpty == false {
            return innerTubePage
        }

        if let accessToken {
            do {
                let musicResults = try await fetchSearchResults(
                    query: query,
                    accessToken: accessToken,
                    maxResults: AppConfig.Search.resultsPerPage
                )
                if musicResults.isEmpty == false {
                    return InnerTubeTrackPage(tracks: musicResults, continuationToken: nil)
                }
            } catch {
                if let fallbackResults = try? await firstNonEmptyAPIKeyResult({ apiKey in
                    try await fetchSearchResults(
                        query: query,
                        apiKey: apiKey,
                        maxResults: AppConfig.Search.resultsPerPage
                    )
                }) {
                    return InnerTubeTrackPage(tracks: fallbackResults, continuationToken: nil)
                }

                throw error
            }
        }

        if let fallbackResults = try? await firstNonEmptyAPIKeyResult({ apiKey in
            try await fetchSearchResults(
                query: query,
                apiKey: apiKey,
                maxResults: AppConfig.Search.resultsPerPage
            )
        }) {
            return InnerTubeTrackPage(tracks: fallbackResults, continuationToken: nil)
        }

        return InnerTubeTrackPage(tracks: [], continuationToken: nil)
    }

    func loadPlaylists(accessToken: String) async throws -> [Playlist] {
        do {
            async let userPlaylists = fetchUserPlaylists(accessToken: accessToken)
            async let relatedPlaylists = fetchRelatedPlaylists(accessToken: accessToken)

            var loadErrors: [Error] = []

            let related: RelatedPlaylists?
            do {
                related = try await relatedPlaylists
            } catch {
                if isAuthenticationFailure(error) {
                    throw error
                }
                related = nil
                loadErrors.append(error)
            }

            let resolvedCollections: [Playlist]
            do {
                resolvedCollections = try await fetchSystemCollections(related: related, accessToken: accessToken)
            } catch {
                if isAuthenticationFailure(error) {
                    throw error
                }
                resolvedCollections = []
                loadErrors.append(error)
            }

            let resolvedUserPlaylists: [Playlist]
            do {
                resolvedUserPlaylists = try await userPlaylists
            } catch {
                if isAuthenticationFailure(error) {
                    throw error
                }
                resolvedUserPlaylists = []
                loadErrors.append(error)
            }

            let resolvedLikedTracks: [Track]
            do {
                resolvedLikedTracks = try await fetchLikedMusicTracks(
                    accessToken: accessToken,
                    relatedPlaylists: related,
                    maxItems: nil
                )
            } catch {
                if isAuthenticationFailure(error) {
                    throw error
                }
                resolvedLikedTracks = []
                loadErrors.append(error)
            }

            var resolvedPlaylists = resolvedCollections + resolvedUserPlaylists

            if let fallbackLikedMusicPlaylist = makeLikedMusicPlaylist(
                from: resolvedLikedTracks,
                fallbackPlaylist: resolvedPlaylists.first(where: { $0.kind == .likedMusic })
            ) {
                if let existingIndex = resolvedPlaylists.firstIndex(where: { $0.kind == .likedMusic }) {
                    resolvedPlaylists[existingIndex] = fallbackLikedMusicPlaylist
                } else {
                    resolvedPlaylists.insert(fallbackLikedMusicPlaylist, at: 0)
                }
            } else if resolvedPlaylists.contains(where: { $0.kind == .likedMusic }) == false {
                // Keep a stable liked-songs slot so library hydration can still attempt account sync
                // even when likes metadata endpoints return sparse/empty payloads.
                resolvedPlaylists.insert(
                    Playlist(
                        id: related?.likes ?? likedMusicPlaylistID,
                        title: "Liked Songs",
                        description: "Music-only items from your likes",
                        artworkURL: nil,
                        itemCount: 0,
                        kind: .likedMusic
                    ),
                    at: 0
                )
            }

            let prioritizedPlaylists = prioritizedLibraryPlaylists(resolvedPlaylists)
            if prioritizedPlaylists.isEmpty, let loadError = loadErrors.first {
                throw loadError
            }

            return prioritizedPlaylists
        } catch {
            throw mapAPIError(error)
        }
    }

    private func loadAuthorizedHome(accessToken: String) async throws -> (featured: [Track], recent: [Track]) {
        async let userPlaylistsTask = fetchUserPlaylists(accessToken: accessToken)
        async let relatedPlaylistsTask = fetchRelatedPlaylists(accessToken: accessToken)

        var loadErrors: [Error] = []

        let relatedPlaylists: RelatedPlaylists?
        do {
            relatedPlaylists = try await relatedPlaylistsTask
        } catch {
            relatedPlaylists = nil
            loadErrors.append(error)
        }

        let likedTracks: [Track]
        do {
            likedTracks = try await fetchLikedMusicTracks(
                accessToken: accessToken,
                relatedPlaylists: relatedPlaylists,
                maxItems: 50
            )
        } catch {
            likedTracks = []
            loadErrors.append(error)
        }

        let userPlaylists: [Playlist]
        do {
            userPlaylists = try await userPlaylistsTask
        } catch {
            userPlaylists = []
            loadErrors.append(error)
        }

        let systemCollections: [Playlist]
        do {
            systemCollections = try await fetchSystemCollections(related: relatedPlaylists, accessToken: accessToken)
        } catch {
            systemCollections = []
            loadErrors.append(error)
        }

        let playlistSources = prioritizedLibraryPlaylists(systemCollections + userPlaylists)
        let mixAlbums = selectSuggestedMixes(from: playlistSources, limit: 8)
        let tracksByPlaylist = await fetchTracks(
            for: mixAlbums,
            accessToken: accessToken,
            maxItemsPerPlaylist: 36
        )

        let mixTracks = mixAlbums.flatMap { randomizedTracks(from: tracksByPlaylist[$0.id] ?? [], limit: 16) }
        let seedTracks = deduplicatedTracks(likedTracks + mixTracks)

        guard seedTracks.isEmpty == false else {
            if let loadError = loadErrors.first {
                throw loadError
            }
            return ([], [])
        }

        let personalizedTracks: [Track]
        do {
            personalizedTracks = try await fetchPersonalizedMusic(
                seedTracks: seedTracks,
                accessToken: accessToken
            )
        } catch {
            personalizedTracks = []
            loadErrors.append(error)
        }

        let featuredPool = deduplicatedTracks(
            personalizedTracks.shuffled() + likedTracks.shuffled() + mixTracks.shuffled()
        )
        let featured = Array(featuredPool.prefix(36))
        let featuredIDs = Set(featured.map(trackIdentifier))
        let recent = Array(
            deduplicatedTracks(mixTracks.shuffled() + personalizedTracks.shuffled() + likedTracks.shuffled())
                .filter { featuredIDs.contains(trackIdentifier($0)) == false }
                .prefix(30)
        )

        if featured.isEmpty, recent.isEmpty, let loadError = loadErrors.first {
            throw loadError
        }

        return (featured, recent)
    }

    func loadPlaylistItems(for playlist: Playlist, accessToken: String?) async throws -> [Track] {
        do {
            if playlist.kind == .likedMusic, let accessToken {
                let relatedPlaylists = try? await fetchRelatedPlaylists(accessToken: accessToken)
                return try await fetchLikedMusicTracks(
                    accessToken: accessToken,
                    relatedPlaylists: relatedPlaylists,
                    maxItems: nil
                )
            }

            if let accessToken {
                let authorizedTracks = try? await fetchPlaylistItems(
                    for: playlist,
                    accessToken: accessToken,
                    maxItems: 200
                )
                if let authorizedTracks, authorizedTracks.isEmpty == false {
                    return authorizedTracks
                }
            }

            if let apiTracks = try? await firstNonEmptyAPIKeyResult({ apiKey in
                try await fetchPlaylistItems(
                    playlistID: playlist.id,
                    apiKey: apiKey,
                    maxItems: 200
                )
            }) {
                return apiTracks
            }

            let webTracks = try await fetchPlaylistItemsViaWeb(
                playlistID: playlist.id,
                maxItems: 200
            )
            if webTracks.isEmpty == false {
                return webTracks
            }

            return []
        } catch {
            throw mapAPIError(error)
        }
    }

    func lookupTrack(videoID: String, accessToken: String?) async throws -> Track? {
        let trimmedVideoID = videoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedVideoID.isEmpty == false else { return nil }

        if let accessToken,
           let authorizedTrack = try? await fetchTrack(videoID: trimmedVideoID, accessToken: accessToken) {
            return authorizedTrack
        }

        if let apiTrack = try? await firstAPIKeyResult({ apiKey in
            try await fetchTrack(videoID: trimmedVideoID, apiKey: apiKey)
        }) {
            return apiTrack
        }

        let youtube = YouTube(videoID: trimmedVideoID)
        if let metadata = try? await youtube.metadata {
            return Track(
                id: trimmedVideoID,
                title: metadata.title.isEmpty ? "YouTube Video" : metadata.title,
                artist: "YouTube",
                artworkURL: metadata.thumbnail?.url,
                youtubeVideoID: trimmedVideoID
            )
        }

        return Track(
            id: trimmedVideoID,
            title: "YouTube Video",
            artist: "YouTube",
            youtubeVideoID: trimmedVideoID
        )
    }

    func loadCollectionItems(for collection: MusicCollection, accessToken: String?) async throws -> [Track] {
        do {
            switch collection.kind {
            case .playlist, .album:
                do {
                    if let accessToken {
                        let tracks = try await fetchPlaylistItems(
                            playlistID: collection.sourceID,
                            accessToken: accessToken,
                            maxItems: 500
                        )
                        if tracks.isEmpty == false {
                            return tracks
                        }
                    }

                    if let tracks = try await firstNonEmptyAPIKeyResult({ apiKey in
                        try await fetchPlaylistItems(
                            playlistID: collection.sourceID,
                            apiKey: apiKey,
                            maxItems: 500
                        )
                    }) {
                        return tracks
                    }
                } catch {
                    let webTracks = try await fetchPlaylistItemsViaWeb(
                        playlistID: collection.sourceID,
                        maxItems: 500
                    )
                    if webTracks.isEmpty == false {
                        return webTracks
                    }
                }

                let webTracks = try await fetchPlaylistItemsViaWeb(
                    playlistID: collection.sourceID,
                    maxItems: 500
                )
                if webTracks.isEmpty == false {
                    return webTracks
                }

                let fallbackTracks = try await fallbackTracks(for: collection, limit: 80)
                return fallbackTracks

            case .artist:
                do {
                    return try await fetchArtistTracks(
                        for: collection,
                        accessToken: accessToken,
                        maxItems: 60
                    )
                } catch {
                    let fallbackTracks = try await fallbackTracks(for: collection, limit: 60)
                    if fallbackTracks.isEmpty == false {
                        return fallbackTracks
                    }

                    return []
                }
            }
        } catch {
            throw mapAPIError(error)
        }
    }

    private func fetchUserPlaylists(accessToken: String) async throws -> [Playlist] {
        var playlists: [Playlist] = []
        var nextPageToken: String?

        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/playlists")!
            var queryItems = [
                URLQueryItem(name: "part", value: "snippet,contentDetails"),
                URLQueryItem(name: "mine", value: "true"),
                URLQueryItem(name: "maxResults", value: "50")
            ]

            if let nextPageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: nextPageToken))
            }

            components.queryItems = authorizedQueryItems(queryItems)

            let request = authorizedRequest(url: components.url!, accessToken: accessToken)
            let (data, urlResponse) = try await urlSession.data(for: request)
            let response = try decodeResponse(PlaylistSearchResponse.self, from: data, response: urlResponse)

            playlists.append(contentsOf: response.items.map(playlist(from:)))
            nextPageToken = response.nextPageToken
        } while nextPageToken != nil && playlists.count < 200

        return playlists
    }

    private func fetchSystemCollections(related: RelatedPlaylists?, accessToken: String) async throws -> [Playlist] {
        guard let related else {
            return []
        }

        let playlistIDs = [related.likes, related.uploads].compactMap { $0 }
        guard playlistIDs.isEmpty == false else {
            return []
        }

        let playlists = try await fetchPlaylists(ids: playlistIDs, accessToken: accessToken)
        let order = Dictionary(uniqueKeysWithValues: playlistIDs.enumerated().map { ($1, $0) })

        return playlists
            .map { playlist in
                if playlist.id == related.likes {
                    return Playlist(
                        id: playlist.id,
                        title: "Liked Songs",
                        description: "Music-only items from your likes",
                        artworkURL: playlist.artworkURL,
                        itemCount: playlist.itemCount,
                        kind: .likedMusic
                    )
                }

                if playlist.id == related.uploads {
                    return Playlist(
                        id: playlist.id,
                        title: "Uploads",
                        description: playlist.description,
                        artworkURL: playlist.artworkURL,
                        itemCount: playlist.itemCount,
                        kind: .uploads
                    )
                }

                return playlist
            }
            .sorted { lhs, rhs in
                order[lhs.id, default: .max] < order[rhs.id, default: .max]
            }
    }

    private func fetchPlaylists(ids: [String], accessToken: String) async throws -> [Playlist] {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/playlists")!
        components.queryItems = authorizedQueryItems(
            [
                URLQueryItem(name: "part", value: "snippet,contentDetails"),
                URLQueryItem(name: "id", value: ids.joined(separator: ",")),
                URLQueryItem(name: "maxResults", value: String(ids.count))
            ]
        )

        let request = authorizedRequest(url: components.url!, accessToken: accessToken)
        let (data, urlResponse) = try await urlSession.data(for: request)
        let response = try decodeResponse(PlaylistSearchResponse.self, from: data, response: urlResponse)
        return response.items.map(playlist(from:))
    }

    private func fetchPlaylistItemsViaWeb(
        playlistID: String,
        maxItems: Int
    ) async throws -> [Track] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/playlist"
        components.queryItems = [URLQueryItem(name: "list", value: playlistID)]

        guard let playlistURL = components.url else {
            return []
        }

        var request = URLRequest(url: playlistURL)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await urlSession.data(for: request)
        guard let html = String(data: data, encoding: .utf8),
              let object = extractYouTubeInitialData(fromHTML: html) else {
            return []
        }

        let renderers = collectObjects(matchingKey: "playlistVideoRenderer", in: object)
        let tracks = renderers.compactMap(track(fromPlaylistVideoRenderer:))
        return Array(deduplicatedTracks(tracks).prefix(maxItems))
    }

    private func track(fromPlaylistVideoRenderer renderer: [String: Any]) -> Track? {
        guard let videoID = renderer["videoId"] as? String else { return nil }

        let rawTitle = text(from: renderer["title"]) ?? "YouTube Track"
        let rawArtist =
            text(from: renderer["shortBylineText"]) ??
            text(from: renderer["longBylineText"]) ??
            text(from: renderer["ownerText"]) ??
            "YouTube"

        let parsedDuration = text(from: renderer["lengthText"]).flatMap(parseDurationSeconds)
        let artist = cleanArtistName(rawArtist)
        let title = cleanTrackTitle(rawTitle, channelName: artist)

        return Track(
            id: videoID,
            title: title,
            artist: artist,
            artworkURL: bestThumbnailURL(from: renderer["thumbnail"]),
            duration: parsedDuration.map(TimeInterval.init),
            youtubeVideoID: videoID
        )
    }

    private func extractYouTubeInitialData(fromHTML html: String) -> Any? {
        guard let markerRange = html.range(of: "ytInitialData = ") else { return nil }
        let jsonStart = markerRange.upperBound
        guard let openingBraceIndex = html[jsonStart...].firstIndex(of: "{") else { return nil }
        guard let jsonString = balancedJSONObjectString(in: html, startingAt: openingBraceIndex) else {
            return nil
        }

        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func balancedJSONObjectString(in text: String, startingAt startIndex: String.Index) -> String? {
        var index = startIndex
        var depth = 0
        var isInsideString = false
        var isEscaping = false

        while index < text.endIndex {
            let character = text[index]

            if isInsideString {
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else {
                if character == "\"" {
                    isInsideString = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[startIndex...index])
                    }
                }
            }

            index = text.index(after: index)
        }

        return nil
    }

    private func fetchMostPopularMusic(apiKey: String) async throws -> [Track] {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "chart", value: "mostPopular"),
            URLQueryItem(name: "videoCategoryId", value: "10"),
            URLQueryItem(name: "regionCode", value: "US"),
            URLQueryItem(name: "maxResults", value: "25"),
            URLQueryItem(name: "key", value: apiKey)
        ]

        let (data, urlResponse) = try await urlSession.data(from: components.url!)
        let response = try decodeResponse(VideoSearchResponse.self, from: data, response: urlResponse)

        return response.items.compactMap { item in
            guard let videoID = item.id.videoID ?? item.id.raw else { return nil }
            guard isLiveSearchResult(snippet: item.snippet) == false else { return nil }
            return Track(
                id: videoID,
                title: item.snippet.title,
                artist: item.snippet.channelTitle,
                artworkURL: item.snippet.thumbnails.bestURL,
                youtubeVideoID: videoID
            )
        }
    }

    private func fetchSearchResults(
        query: String,
        apiKey: String,
        maxResults: Int,
        musicOnly: Bool = true
    ) async throws -> [Track] {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")!
        var queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "safeSearch", value: "moderate"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(maxResults)),
            URLQueryItem(name: "key", value: apiKey)
        ]
        if musicOnly {
            queryItems.insert(URLQueryItem(name: "videoCategoryId", value: "10"), at: 2)
        }
        components.queryItems = queryItems

        let (data, urlResponse) = try await urlSession.data(from: components.url!)
        let response = try decodeResponse(VideoSearchResponse.self, from: data, response: urlResponse)

        return response.items.compactMap(musicSearchTrack(from:))
    }

    private func fetchSearchResults(
        query: String,
        accessToken: String,
        maxResults: Int,
        musicOnly: Bool = true
    ) async throws -> [Track] {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")!
        var queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "safeSearch", value: "moderate"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(maxResults))
        ]
        if musicOnly {
            queryItems.insert(URLQueryItem(name: "videoCategoryId", value: "10"), at: 2)
        }
        components.queryItems = authorizedQueryItems(queryItems)

        let request = authorizedRequest(url: components.url!, accessToken: accessToken)
        let (data, urlResponse) = try await urlSession.data(for: request)
        let response = try decodeResponse(VideoSearchResponse.self, from: data, response: urlResponse)
        return response.items.compactMap(musicSearchTrack(from:))
    }

    private func fetchPersonalizedMusic(seedTracks: [Track], accessToken: String) async throws -> [Track] {
        guard seedTracks.isEmpty == false else {
            return []
        }
        let seedArtists = Array(orderedUniqueStrings(seedTracks.shuffled().map(\.artist)).prefix(4))

        guard seedArtists.isEmpty == false else {
            return Array(deduplicatedTracks(seedTracks.shuffled()).prefix(25))
        }

        let excludedIDs = Set(seedTracks.compactMap(\.youtubeVideoID))
        let querySuffixes = [
            "official audio",
            "album",
            "audio",
            "topic"
        ]
        let recommendations = await withTaskGroup(of: [Track].self) { group in
            for (index, artist) in seedArtists.enumerated() {
                let suffix = querySuffixes[index % querySuffixes.count]
                group.addTask { [self] in
                    let query = "\(artist) \(suffix)"
                    let results: [Track]
                    if let innerTubeResults = try? await fetchSearchResultsViaInnerTube(query: query, maxResults: 8),
                       innerTubeResults.isEmpty == false {
                        results = innerTubeResults
                    } else {
                        results = (try? await fetchSearchResults(
                            query: query,
                            accessToken: accessToken,
                            maxResults: 8,
                            musicOnly: true
                        )) ?? []
                    }

                    return results.filter { track in
                        guard let videoID = track.youtubeVideoID else { return true }
                        return excludedIDs.contains(videoID) == false
                    }
                }
            }

            var collected: [Track] = []
            for await tracks in group {
                collected.append(contentsOf: tracks)
            }
            return collected
        }

        let deduped = deduplicatedTracks(recommendations.shuffled())
        if deduped.isEmpty {
            return Array(deduplicatedTracks(seedTracks.shuffled()).prefix(25))
        }

        return Array(deduped.prefix(25))
    }

    private func fetchFallbackDiscoveryTracks() async throws -> [Track] {
        let fallbackQueries = [
            "new music official audio",
            "top songs official audio",
            "new album official audio",
            "latest hits official audio",
            "best songs audio",
            "best albums 2026"
        ].shuffled()

        var collectedTracks: [Track] = []
        for query in fallbackQueries.prefix(3) {
            let results = try await fetchSearchResultsViaInnerTube(query: query, maxResults: 12)
            collectedTracks.append(contentsOf: results)
        }

        return Array(deduplicatedTracks(collectedTracks.shuffled()).prefix(25))
    }

    private func fetchRelatedPlaylists(accessToken: String) async throws -> RelatedPlaylists? {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/channels")!
        components.queryItems = authorizedQueryItems(
            [
                URLQueryItem(name: "part", value: "contentDetails"),
                URLQueryItem(name: "mine", value: "true"),
                URLQueryItem(name: "maxResults", value: "1")
            ]
        )

        let request = authorizedRequest(url: components.url!, accessToken: accessToken)
        let (data, urlResponse) = try await urlSession.data(for: request)
        let response = try decodeResponse(ChannelSearchResponse.self, from: data, response: urlResponse)
        return response.items.first?.contentDetails?.relatedPlaylists
    }

    private func filterMusicTracks(_ tracks: [Track], accessToken: String) async throws -> [Track] {
        let videoIDs = tracks.compactMap(\.youtubeVideoID)
        guard videoIDs.isEmpty == false else {
            return []
        }

        var musicVideoIDs: Set<String> = []

        for batch in videoIDs.chunked(into: 50) {
            var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")!
            components.queryItems = authorizedQueryItems(
                [
                    URLQueryItem(name: "part", value: "snippet,contentDetails"),
                    URLQueryItem(name: "id", value: batch.joined(separator: ",")),
                    URLQueryItem(name: "maxResults", value: String(batch.count))
                ]
            )

            let request = authorizedRequest(url: components.url!, accessToken: accessToken)
            let (data, urlResponse) = try await urlSession.data(for: request)
            let response = try decodeResponse(VideoMetadataResponse.self, from: data, response: urlResponse)

            for item in response.items {
                let title = item.snippet.title ?? ""
                let channel = item.snippet.channelTitle ?? ""
                let duration: TimeInterval?
                if let durationText = item.contentDetails?.duration,
                   let seconds = parseISO8601DurationSeconds(durationText) {
                    duration = TimeInterval(seconds)
                } else {
                    duration = nil
                }

                guard isLikelyLikedMusicCandidate(
                    title: title,
                    artist: channel,
                    categoryID: item.snippet.categoryID,
                    duration: duration
                ) else {
                    continue
                }
                musicVideoIDs.insert(item.id)
            }
        }

        let filtered = tracks.filter { track in
            guard let videoID = track.youtubeVideoID else { return false }
            return musicVideoIDs.contains(videoID)
        }

        // Defensive fallback: if metadata fetching produced zero matches but we had
        // input tracks, return the original list. Prevents an empty UI when a videos.list
        // call returns an unexpected payload — better to show liked items than nothing.
        if filtered.isEmpty && tracks.isEmpty == false && musicVideoIDs.isEmpty {
            return tracks
        }
        return filtered
    }

    private var validatedAPIKeys: [String] {
        var seen: Set<String> = []

        return apiKeys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false && $0.hasPrefix("YOUR_") == false }
            .filter { seen.insert($0).inserted }
    }

    private var validatedAPIKey: String? {
        validatedAPIKeys.first
    }

    private func mapAPIError(_ error: Error) -> APIError {
        if let apiError = error as? APIError {
            return apiError
        }

        if let validationError = error as? QueryValidationError {
            return .invalidSearchQuery(validationError)
        }

        if let urlError = error as? URLError {
            return .networkError(urlError)
        }

        if let decodingError = error as? DecodingError {
            return .decodingError(decodingError)
        }

        return .serviceError(error.localizedDescription)
    }

    private func isAuthenticationFailure(_ error: Error) -> Bool {
        if case .authenticationFailure = mapAPIError(error) {
            return true
        }

        return error.localizedDescription.isInsufficientAuthenticationScopesError
    }

    private func normalizedSearchCacheKey(for query: String) -> String {
        query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func firstNonEmptyAPIKeyResult<T>(
        _ operation: (String) async throws -> [T]
    ) async throws -> [T]? {
        var lastError: Error?

        for apiKey in validatedAPIKeys {
            do {
                let result = try await operation(apiKey)
                if result.isEmpty == false {
                    return result
                }
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }

        return nil
    }

    private func firstAPIKeyResult<T>(
        _ operation: (String) async throws -> T?
    ) async throws -> T? {
        var lastError: Error?

        for apiKey in validatedAPIKeys {
            do {
                if let result = try await operation(apiKey) {
                    return result
                }
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }

        return nil
    }

    private func authorizedQueryItems(_ items: [URLQueryItem]) -> [URLQueryItem] {
        // Do not attach an API key to OAuth-authenticated requests.
        // Google rejects requests when the Bearer token and API key belong to
        // different Cloud projects, which breaks private library endpoints such
        // as liked songs. Public fallback requests still use the configured keys.
        items
    }

    private func playlist(from item: PlaylistItem) -> Playlist {
        Playlist(
            id: item.id,
            title: item.snippet.title,
            description: item.snippet.description ?? "",
            artworkURL: item.snippet.thumbnails?.bestURL,
            itemCount: item.contentDetails?.itemCount ?? 0,
            kind: .standard
        )
    }

    private func track(from item: VideoItem) -> Track? {
        guard let videoID = item.id.videoID ?? item.id.raw else { return nil }
        guard isLiveSearchResult(snippet: item.snippet) == false else { return nil }
        let artist = cleanArtistName(item.snippet.channelTitle)
        let title = cleanTrackTitle(item.snippet.title, channelName: artist)
        return Track(
            id: videoID,
            title: title,
            artist: artist,
            artworkURL: item.snippet.thumbnails.bestURL,
            youtubeVideoID: videoID
        )
    }

    private func musicSearchTrack(from item: VideoItem) -> Track? {
        guard let videoID = item.id.videoID ?? item.id.raw else { return nil }
        guard isLiveSearchResult(snippet: item.snippet) == false else { return nil }
        return buildMusicSearchTrack(
            videoID: videoID,
            rawTitle: item.snippet.title,
            rawArtist: item.snippet.channelTitle,
            artworkURL: item.snippet.thumbnails.bestURL,
            duration: nil
        )
    }

    private func performCollectionSearch(query: String) async throws -> (playlists: [MusicCollection], albums: [MusicCollection], artists: [MusicCollection]) {
        let object = try await fetchInnerTubeSearchPayload(query: query)
        let playlistRenderers = collectObjects(matchingKey: "playlistRenderer", in: object)
        let channelRenderers = collectObjects(matchingKey: "channelRenderer", in: object)
        let lockupViewModels = collectObjects(matchingKey: "lockupViewModel", in: object)

        var playlists = deduplicatedCollections(
            (playlistRenderers
                .compactMap { musicCollection(fromInnerTubePlaylistRenderer: $0) }
                .filter { $0.kind == .playlist }) +
            lockupViewModels.compactMap { musicCollection(fromInnerTubeLockupViewModel: $0) }
                .filter { $0.kind == .playlist }
        )
        var albums = deduplicatedCollections(
            (playlistRenderers
                .compactMap { musicCollection(fromInnerTubePlaylistRenderer: $0) }
                .filter { $0.kind == .album }) +
            lockupViewModels.compactMap { musicCollection(fromInnerTubeLockupViewModel: $0) }
                .filter { $0.kind == .album }
        )
        let artists = deduplicatedCollections(
            channelRenderers.compactMap(musicCollection(fromInnerTubeChannelRenderer:))
        )

        if albums.count < 6 {
            let albumPayload = try? await fetchInnerTubeSearchPayload(query: "\(query) album")
            if let albumPayload {
                let albumRenderers = collectObjects(matchingKey: "playlistRenderer", in: albumPayload)
                let albumLockups = collectObjects(matchingKey: "lockupViewModel", in: albumPayload)
                albums = deduplicatedCollections(
                    albums +
                    albumRenderers.compactMap {
                        musicCollection(fromInnerTubePlaylistRenderer: $0, forceAlbum: true)
                    } +
                    albumLockups.compactMap {
                        musicCollection(fromInnerTubeLockupViewModel: $0, forceAlbum: true)
                    }
                )
            }
        }

        if playlists.count > 12 {
            playlists = Array(playlists.prefix(12))
        }
        if albums.count > 12 {
            albums = Array(albums.prefix(12))
        }

        return (playlists, albums, artists)
    }

    private func fetchSearchResultsViaInnerTube(query: String, maxResults: Int) async throws -> [Track] {
        try await fetchTrackSearchPageViaInnerTube(
            query: query,
            continuationToken: nil,
            maxResults: maxResults
        ).tracks
    }

    private func fetchTrackSearchPageViaInnerTube(
        query: String,
        continuationToken: String?,
        maxResults: Int
    ) async throws -> InnerTubeTrackPage {
        let object = try await fetchInnerTubeSearchPayload(
            query: continuationToken == nil ? query : nil,
            continuationToken: continuationToken
        )
        let renderers = collectObjects(matchingKey: "videoRenderer", in: object)
        let tracks = renderers.compactMap(track(fromInnerTubeVideoRenderer:))

        return InnerTubeTrackPage(
            tracks: Array(deduplicatedTracks(tracks).prefix(maxResults)),
            continuationToken: firstContinuationToken(in: object)
        )
    }

    private func fetchRelaxedSearchResultsViaInnerTube(
        query: String,
        maxResults: Int
    ) async throws -> [Track] {
        let object = try await fetchInnerTubeSearchPayload(query: query)
        let renderers = collectObjects(matchingKey: "videoRenderer", in: object)
        let tracks = renderers.compactMap(relaxedTrack(fromInnerTubeVideoRenderer:))
        return Array(deduplicatedTracks(tracks).prefix(maxResults))
    }

    // MARK: - YouTube Music InnerTube (WEB_REMIX)

    /// Fetches the user's actual YouTube Music "Liked Music" playlist (browseId VLLM)
    /// using the same InnerTube WEB_REMIX endpoint the YouTube Music app uses.
    /// This returns the music-only liked songs the user sees in their YouTube Music app,
    /// rather than the broader YouTube "Likes" playlist that includes Shorts and non-music.
    private func fetchYouTubeMusicLikedTracks(accessToken: String, maxItems: Int?) async throws -> [Track] {
        var collected: [Track] = []
        var continuation: String?
        let target = maxItems ?? Int.max

        repeat {
            let payload = try await fetchYouTubeMusicBrowsePayload(
                browseID: continuation == nil ? "VLLM" : nil,
                continuationToken: continuation,
                accessToken: accessToken
            )
            let renderers = collectObjects(matchingKey: "musicResponsiveListItemRenderer", in: payload)
            let pageTracks = renderers.compactMap(track(fromMusicResponsiveListItem:))

            guard pageTracks.isEmpty == false || continuation != nil else {
                break
            }

            collected.append(contentsOf: pageTracks)
            continuation = nextMusicContinuationToken(in: payload)
        } while continuation != nil && collected.count < target

        return Array(deduplicatedTracks(collected).prefix(target))
    }

    private func fetchYouTubeMusicBrowsePayload(
        browseID: String?,
        continuationToken: String?,
        accessToken: String
    ) async throws -> Any {
        var components = URLComponents(string: "https://music.youtube.com/youtubei/v1/browse")!
        var queryItems = [URLQueryItem(name: "alt", value: "json"), URLQueryItem(name: "prettyPrint", value: "false")]
        if let continuationToken {
            queryItems.append(URLQueryItem(name: "ctoken", value: continuationToken))
            queryItems.append(URLQueryItem(name: "continuation", value: continuationToken))
            queryItems.append(URLQueryItem(name: "type", value: "next"))
        }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        request.setValue(youtubeMusicClientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue("67", forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        var payload: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "WEB_REMIX",
                    "clientVersion": youtubeMusicClientVersion,
                    "hl": "en",
                    "gl": "US"
                ],
                "user": [:] as [String: Any]
            ]
        ]
        if let browseID {
            payload["browseId"] = browseID
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await urlSession.data(for: request)
        try validateStatusCode(for: response, data: data)
        return try JSONSerialization.jsonObject(with: data)
    }

    private var youtubeMusicClientVersion: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return "1.\(formatter.string(from: Date())).01.00"
    }

    private func nextMusicContinuationToken(in object: Any) -> String? {
        let nextContinuations = collectObjects(matchingKey: "nextContinuationData", in: object)
        if let token = nextContinuations.first?["continuation"] as? String, token.isEmpty == false {
            return token
        }
        let continuationItems = collectObjects(matchingKey: "continuationItemRenderer", in: object)
        for item in continuationItems {
            if let endpoint = item["continuationEndpoint"] as? [String: Any],
               let command = endpoint["continuationCommand"] as? [String: Any],
               let token = command["token"] as? String, token.isEmpty == false {
                return token
            }
        }
        return nil
    }

    /// Parses one row from a YouTube Music playlist into a Track.
    /// MRLIR layout: flexColumns[0] = title (with watchEndpoint videoId), flexColumns[1] = artist/album/duration.
    private func track(fromMusicResponsiveListItem renderer: [String: Any]) -> Track? {
        guard let flexColumns = renderer["flexColumns"] as? [[String: Any]],
              let titleColumn = flexColumns.first?["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
              let titleText = titleColumn["text"] as? [String: Any],
              let titleRuns = titleText["runs"] as? [[String: Any]],
              let firstTitleRun = titleRuns.first,
              let title = firstTitleRun["text"] as? String,
              let endpoint = firstTitleRun["navigationEndpoint"] as? [String: Any],
              let watch = endpoint["watchEndpoint"] as? [String: Any],
              let videoID = watch["videoId"] as? String,
              videoID.isEmpty == false
        else {
            return nil
        }

        var artist = "YouTube"
        if flexColumns.count > 1,
           let artistColumn = flexColumns[1]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
           let artistText = artistColumn["text"] as? [String: Any],
           let artistRuns = artistText["runs"] as? [[String: Any]] {
            // Concatenate runs that look like artist names — skip separators (" • ") and durations.
            let artistParts: [String] = artistRuns.compactMap { run in
                guard let text = run["text"] as? String else { return nil }
                if text == " • " || text == " · " { return nil }
                if text.range(of: #"^\d+:\d+$"#, options: .regularExpression) != nil { return nil }
                if run["navigationEndpoint"] is [String: Any] { return text }
                return nil
            }
            if artistParts.isEmpty == false {
                artist = artistParts.joined(separator: ", ")
            } else if let firstArtistText = artistRuns.first?["text"] as? String {
                artist = firstArtistText
            }
        }

        let artworkURL: URL? = {
            guard let thumbnailWrapper = renderer["thumbnail"] as? [String: Any],
                  let musicThumbnail = thumbnailWrapper["musicThumbnailRenderer"] as? [String: Any],
                  let thumbnailObj = musicThumbnail["thumbnail"] as? [String: Any],
                  let thumbnails = thumbnailObj["thumbnails"] as? [[String: Any]],
                  let last = thumbnails.last,
                  let urlString = last["url"] as? String
            else { return nil }
            return URL(string: urlString)
        }()

        let cleanedArtist = cleanArtistName(artist)
        let cleanedTitle = cleanTrackTitle(title, channelName: cleanedArtist)

        return Track(
            id: videoID,
            title: cleanedTitle,
            artist: cleanedArtist,
            artworkURL: artworkURL,
            youtubeVideoID: videoID
        )
    }

    private func fetchInnerTubeSearchPayload(query: String? = nil, continuationToken: String? = nil) async throws -> Any {
        var request = URLRequest(url: innerTubeSearchURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue(innerTubeClientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue("1", forHTTPHeaderField: "X-Youtube-Client-Name")

        var payload: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "WEB",
                    "clientVersion": innerTubeClientVersion
                ]
            ]
        ]

        if let query, query.isEmpty == false {
            payload["query"] = query
        }
        if let continuationToken, continuationToken.isEmpty == false {
            payload["continuation"] = continuationToken
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await urlSession.data(for: request)
        try validateStatusCode(for: response, data: data)

        return try JSONSerialization.jsonObject(with: data)
    }

    private func firstContinuationToken(in object: Any) -> String? {
        let continuations = collectObjects(matchingKey: "continuationItemRenderer", in: object)
        return continuations.first.flatMap { continuation in
            ((continuation["continuationEndpoint"] as? [String: Any])?["continuationCommand"] as? [String: Any])?["token"] as? String
        }
    }

    private func collectObjects(matchingKey key: String, in object: Any) -> [[String: Any]] {
        if let dictionary = object as? [String: Any] {
            var matches: [[String: Any]] = []
            if let match = dictionary[key] as? [String: Any] {
                matches.append(match)
            }

            for value in dictionary.values {
                matches.append(contentsOf: collectObjects(matchingKey: key, in: value))
            }
            return matches
        }

        if let array = object as? [Any] {
            return array.flatMap { collectObjects(matchingKey: key, in: $0) }
        }

        return []
    }

    private func track(fromInnerTubeVideoRenderer renderer: [String: Any]) -> Track? {
        guard let videoID = renderer["videoId"] as? String else { return nil }
        guard isLiveSearchResult(renderer: renderer) == false else { return nil }

        let rawTitle = text(from: renderer["title"]) ?? "YouTube Track"
        let rawArtist =
            text(from: renderer["longBylineText"]) ??
            text(from: renderer["ownerText"]) ??
            text(from: renderer["shortBylineText"]) ??
            "YouTube"

        let parsedDuration = text(from: renderer["lengthText"]).flatMap(parseDurationSeconds)
        let viewCount = parseViewCount(from:
            text(from: renderer["viewCountText"]) ??
            text(from: renderer["shortViewCountText"])
        )
        return buildMusicSearchTrack(
            videoID: videoID,
            rawTitle: rawTitle,
            rawArtist: rawArtist,
            artworkURL: bestThumbnailURL(from: renderer["thumbnail"]),
            duration: parsedDuration.map(TimeInterval.init),
            viewCount: viewCount
        )
    }

    private func relaxedTrack(fromInnerTubeVideoRenderer renderer: [String: Any]) -> Track? {
        guard let videoID = renderer["videoId"] as? String else { return nil }
        guard isLiveSearchResult(renderer: renderer) == false else { return nil }

        let rawTitle = text(from: renderer["title"]) ?? "YouTube Track"
        let rawArtist =
            text(from: renderer["longBylineText"]) ??
            text(from: renderer["ownerText"]) ??
            text(from: renderer["shortBylineText"]) ??
            "YouTube"

        guard isNonMusicContent(title: rawTitle, channel: rawArtist) == false else { return nil }
        guard looksLikeShorts(title: rawTitle) == false else { return nil }

        let parsedDuration = text(from: renderer["lengthText"]).flatMap(parseDurationSeconds)
        let artist = cleanArtistName(rawArtist)
        let title = cleanTrackTitle(rawTitle, channelName: artist)
        let viewCount = parseViewCount(from:
            text(from: renderer["viewCountText"]) ??
            text(from: renderer["shortViewCountText"])
        )

        return Track(
            id: videoID,
            title: title,
            artist: artist,
            artworkURL: bestThumbnailURL(from: renderer["thumbnail"]),
            duration: parsedDuration.map(TimeInterval.init),
            youtubeVideoID: videoID,
            viewCount: viewCount
        )
    }

    private func musicCollection(fromInnerTubePlaylistRenderer renderer: [String: Any], forceAlbum: Bool? = nil) -> MusicCollection? {
        guard let playlistID = renderer["playlistId"] as? String else { return nil }

        let title = text(from: renderer["title"]) ?? "Playlist"
        let subtitle =
            text(from: renderer["shortBylineText"]) ??
            text(from: renderer["longBylineText"]) ??
            "YouTube"
        let description = text(from: renderer["descriptionSnippet"]) ?? subtitle
        let itemCount = parseCount(
            from: text(from: renderer["videoCountText"]) ??
                text(from: renderer["videoCountShortText"]) ??
                text(from: renderer["thumbnailOverlays"])
        )
        let artworkURL = extractThumbnailURL(from: renderer)
        let resolvedIsAlbum = forceAlbum ?? isLikelyAlbum(title: title, subtitle: subtitle, description: description)
        let kind: MusicCollectionKind = resolvedIsAlbum ? .album : .playlist

        return MusicCollection(
            sourceID: playlistID,
            title: title,
            subtitle: subtitle,
            description: description,
            artworkURL: artworkURL,
            itemCount: itemCount,
            kind: kind,
            queryHint: [title, subtitle].filter { $0.isEmpty == false }.joined(separator: " ")
        )
    }

    private func musicCollection(fromInnerTubeLockupViewModel renderer: [String: Any], forceAlbum: Bool? = nil) -> MusicCollection? {
        guard let sourceID = renderer["contentId"] as? String, sourceID.isEmpty == false else { return nil }
        guard let contentType = renderer["contentType"] as? String, contentType == "LOCKUP_CONTENT_TYPE_PLAYLIST" else {
            return nil
        }

        let title = lockupTitle(from: renderer) ?? "Playlist"
        let metadataParts = lockupMetadataParts(from: renderer)
        let subtitle = metadataParts.first ?? "YouTube"
        let description = metadataParts.joined(separator: " · ")
        let itemCount = parseCount(from: extractLooseText(from: renderer["contentImage"]))
        let artworkURL = extractThumbnailURL(from: renderer["contentImage"])
        let resolvedIsAlbum = forceAlbum ?? sourceID.hasPrefix("OLAK") || isLikelyAlbum(
            title: title,
            subtitle: subtitle,
            description: description
        )
        let kind: MusicCollectionKind = resolvedIsAlbum ? .album : .playlist

        return MusicCollection(
            sourceID: sourceID,
            title: title,
            subtitle: subtitle,
            description: description,
            artworkURL: artworkURL,
            itemCount: itemCount,
            kind: kind,
            queryHint: [title, subtitle, resolvedIsAlbum ? "album" : "playlist"]
                .filter { $0.isEmpty == false }
                .joined(separator: " ")
        )
    }

    private func musicCollection(fromInnerTubeChannelRenderer renderer: [String: Any]) -> MusicCollection? {
        guard let channelID = renderer["channelId"] as? String else { return nil }

        let title = cleanArtistName(text(from: renderer["title"]) ?? "Artist")
        let subtitle = text(from: renderer["subscriberCountText"]) ?? "Artist"
        let description = text(from: renderer["descriptionSnippet"]) ?? subtitle
        let artworkURL = extractThumbnailURL(from: renderer)

        guard isNonMusicContent(title: description, channel: title) == false else { return nil }

        return MusicCollection(
            sourceID: channelID,
            title: title,
            subtitle: subtitle,
            description: description,
            artworkURL: artworkURL,
            itemCount: 0,
            kind: .artist,
            queryHint: title
        )
    }

    private func text(from object: Any?) -> String? {
        guard let dictionary = object as? [String: Any] else { return nil }

        if let content = dictionary["content"] as? String, content.isEmpty == false {
            return content
        }

        if let simpleText = dictionary["simpleText"] as? String, simpleText.isEmpty == false {
            return simpleText
        }

        if let runs = dictionary["runs"] as? [[String: Any]] {
            let joined = runs.compactMap { $0["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }

        return nil
    }

    private func lockupTitle(from renderer: [String: Any]) -> String? {
        (((renderer["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any])?["title"] as? [String: Any])?["content"] as? String
    }

    private func lockupMetadataParts(from renderer: [String: Any]) -> [String] {
        guard
            let metadata = renderer["metadata"] as? [String: Any],
            let lockupMetadata = metadata["lockupMetadataViewModel"] as? [String: Any],
            let metadataContainer = lockupMetadata["metadata"] as? [String: Any],
            let contentMetadata = metadataContainer["contentMetadataViewModel"] as? [String: Any],
            let rows = contentMetadata["metadataRows"] as? [[String: Any]]
        else {
            return []
        }

        return rows.flatMap { row in
            let parts = row["metadataParts"] as? [[String: Any]] ?? []
            return parts.compactMap { part in
                text(from: part["text"])
            }
        }
    }

    private func extractLooseText(from object: Any?) -> String? {
        if let text = text(from: object), text.isEmpty == false {
            return text
        }

        if let string = object as? String, string.isEmpty == false {
            return string
        }

        if let dictionary = object as? [String: Any] {
            for value in dictionary.values {
                if let nested = extractLooseText(from: value), nested.isEmpty == false {
                    return nested
                }
            }
        }

        if let array = object as? [Any] {
            for value in array {
                if let nested = extractLooseText(from: value), nested.isEmpty == false {
                    return nested
                }
            }
        }

        return nil
    }

    private func bestThumbnailURL(from object: Any?) -> URL? {
        guard
            let dictionary = object as? [String: Any],
            let thumbnails = dictionary["thumbnails"] as? [[String: Any]],
            let lastThumbnail = thumbnails.last,
            let urlString = lastThumbnail["url"] as? String
        else {
            return nil
        }

        return URL(string: urlString)
    }

    private func extractThumbnailURL(from object: Any?) -> URL? {
        if let url = bestThumbnailURL(from: object) {
            return url
        }

        if let dictionary = object as? [String: Any] {
            for value in dictionary.values {
                if let url = extractThumbnailURL(from: value) {
                    return url
                }
            }
        }

        if let array = object as? [Any] {
            for value in array {
                if let url = extractThumbnailURL(from: value) {
                    return url
                }
            }
        }

        return nil
    }

    private func parseCount(from text: String?) -> Int {
        guard let text else { return 0 }
        let digits = text.unicodeScalars.filter(CharacterSet.decimalDigits.contains)
        let numericString = String(String.UnicodeScalarView(digits))
        return Int(numericString) ?? 0
    }

    private func parseViewCount(from text: String?) -> Int? {
        guard let text, !text.isEmpty else { return nil }
        let cleaned = text
            .lowercased()
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "views", with: "")
            .replacingOccurrences(of: "مشاهدة", with: "")
            .trimmingCharacters(in: .whitespaces)
        let multiplier: Double
        let numStr: String
        if cleaned.hasSuffix("b") { multiplier = 1_000_000_000; numStr = String(cleaned.dropLast()) }
        else if cleaned.hasSuffix("m") { multiplier = 1_000_000; numStr = String(cleaned.dropLast()) }
        else if cleaned.hasSuffix("k") { multiplier = 1_000; numStr = String(cleaned.dropLast()) }
        else { multiplier = 1; numStr = cleaned.filter { $0.isNumber || $0 == "." } }
        guard let value = Double(numStr.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        return Int(value * multiplier)
    }

    private func isLikelyAlbum(title: String, subtitle: String, description: String) -> Bool {
        let searchableText = "\(title) \(subtitle) \(description)".lowercased()
        if searchableText.contains("album") {
            return true
        }

        if searchableText.contains(" - topic") && searchableText.contains("playlist") == false {
            return true
        }

        return false
    }

    private func authorizedRequest(url: URL, accessToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func fetchLikedMusicPlaylist(accessToken: String) async throws -> Playlist? {
        let likedTracks = try await fetchLikedMusicTracks(accessToken: accessToken, maxItems: 12)
        return makeLikedMusicPlaylist(from: likedTracks)
    }

    private func fetchLikedMusicTracks(
        accessToken: String,
        relatedPlaylists: RelatedPlaylists? = nil,
        maxItems: Int?
    ) async throws -> [Track] {
        // Preferred path: YouTube Music's own private "Liked Music" (LM) playlist via the
        // WEB_REMIX InnerTube browse endpoint. This matches what the YouTube Music app shows.
        // Falls back to the broader YouTube Likes playlist when the music endpoint rejects auth.
        do {
            let musicTracks = try await fetchYouTubeMusicLikedTracks(
                accessToken: accessToken,
                maxItems: maxItems
            )
            logger.info("YouTube Music VLLM browse returned \(musicTracks.count) liked tracks")
            if musicTracks.isEmpty == false {
                return limitedTracks(musicTracks, maxItems: maxItems)
            }
        } catch {
            if isAuthenticationFailure(error) {
                logger.error("YouTube Music liked-songs fetch needs a broader OAuth scope; forcing reauthorization", error: error)
                throw APIError.authenticationFailure
            }
            logger.error("YouTube Music VLLM browse failed; falling back to Data API", error: error)
        }

        let effectiveRelatedPlaylists: RelatedPlaylists?
        if let relatedPlaylists {
            effectiveRelatedPlaylists = relatedPlaylists
        } else {
            effectiveRelatedPlaylists = try? await fetchRelatedPlaylists(accessToken: accessToken)
        }

        var candidates: [[Track]] = []
        var lastError: Error?

        if let likesPlaylistID = effectiveRelatedPlaylists?.likes {
            do {
                let likesPlaylist = Playlist(
                    id: likesPlaylistID,
                    title: "Liked Songs",
                    description: "Music-only items from your likes",
                    artworkURL: nil,
                    itemCount: maxItems ?? 0,
                    kind: .likedMusic
                )

                let playlistTracks = try await fetchLikedMusicTracksFromLikesPlaylist(
                    likesPlaylist: likesPlaylist,
                    accessToken: accessToken,
                    maxItems: maxItems
                )
                logger.info("Likes playlist fallback returned \(playlistTracks.count) tracks")
                if playlistTracks.isEmpty == false {
                    candidates.append(playlistTracks)
                }
            } catch {
                logger.error("Likes playlist fallback failed", error: error)
                lastError = error
            }
        }

        do {
            let ratedTracks = try await fetchLikedMusicTracksByRating(
                accessToken: accessToken,
                maxItems: maxItems
            )
            logger.info("myRating=like fallback returned \(ratedTracks.count) tracks")
            if ratedTracks.isEmpty == false {
                candidates.append(ratedTracks)
            }
        } catch {
            logger.error("myRating=like fallback failed", error: error)
            lastError = lastError ?? error
        }

        let mergedTracks = deduplicatedTracks(candidates.flatMap { $0 })
        if mergedTracks.isEmpty == false {
            logger.info("Liked music final count: \(mergedTracks.count) tracks")
            return limitedTracks(mergedTracks, maxItems: maxItems)
        }

        if let lastError {
            logger.error("All liked-music fetch paths failed; rethrowing", error: lastError)
            throw lastError
        }

        logger.error("Liked-music fetch returned an empty array without an explicit error", error: nil)
        return []
    }

    private func fetchLikedMusicTracksFromLikesPlaylist(
        likesPlaylist: Playlist,
        accessToken: String,
        maxItems: Int?
    ) async throws -> [Track] {
        var tracks: [Track] = []
        var nextPageToken: String?
        let targetCount = maxItems ?? Int.max

        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/playlistItems")!
            var queryItems = [
                URLQueryItem(name: "part", value: "snippet,contentDetails"),
                URLQueryItem(name: "playlistId", value: likesPlaylist.id),
                URLQueryItem(name: "maxResults", value: "50")
            ]

            if let nextPageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: nextPageToken))
            }

            components.queryItems = authorizedQueryItems(queryItems)

            let request = authorizedRequest(url: components.url!, accessToken: accessToken)
            let (data, urlResponse) = try await urlSession.data(for: request)
            let response = try decodeResponse(PlaylistItemsResponse.self, from: data, response: urlResponse)

            let pageTracks: [Track] = response.items.compactMap { item in
                guard let videoID = item.snippet.resourceID?.videoID ?? item.contentDetails?.videoID else { return nil }

                let rawArtist = item.snippet.videoOwnerChannelTitle ??
                    item.snippet.channelTitle ??
                    "YouTube"
                let artist = cleanArtistName(rawArtist)
                let title = cleanTrackTitle(item.snippet.title, channelName: artist)

                return Track(
                    id: item.id,
                    title: title,
                    artist: artist,
                    artworkURL: item.snippet.thumbnails?.bestURL,
                    youtubeVideoID: videoID
                )
            }

            let filteredPageTracks = pageTracks.isEmpty
                ? []
                : ((try? await filterMusicTracks(pageTracks, accessToken: accessToken)) ?? pageTracks)

            tracks = deduplicatedTracks(tracks + filteredPageTracks)
            nextPageToken = response.nextPageToken
        } while nextPageToken != nil && tracks.count < targetCount

        return limitedTracks(tracks, maxItems: maxItems)
    }

    private func fetchLikedMusicTracksByRating(accessToken: String, maxItems: Int?) async throws -> [Track] {
        var tracks: [Track] = []
        var nextPageToken: String?
        let targetCount = maxItems ?? Int.max

        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")!
            var queryItems = [
                URLQueryItem(name: "part", value: "snippet,contentDetails"),
                URLQueryItem(name: "myRating", value: "like"),
                URLQueryItem(name: "maxResults", value: "50")
            ]

            if let nextPageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: nextPageToken))
            }

            components.queryItems = authorizedQueryItems(queryItems)

            let request = authorizedRequest(url: components.url!, accessToken: accessToken)
            let (data, urlResponse) = try await urlSession.data(for: request)
            let response = try decodeResponse(VideoSearchResponse.self, from: data, response: urlResponse)

            let pageTracks = response.items.compactMap { item -> Track? in
                let duration: TimeInterval?
                if let durationText = item.contentDetails?.duration,
                   let seconds = parseISO8601DurationSeconds(durationText) {
                    duration = TimeInterval(seconds)
                } else {
                    duration = nil
                }

                guard isLikelyLikedMusicCandidate(
                    title: item.snippet.title,
                    artist: item.snippet.channelTitle,
                    categoryID: item.snippet.categoryID,
                    duration: duration
                ) else {
                    return nil
                }

                guard let videoID = item.id.videoID ?? item.id.raw else { return nil }
                let artist = cleanArtistName(item.snippet.channelTitle)
                let title = cleanTrackTitle(item.snippet.title, channelName: artist)

                return Track(
                    id: videoID,
                    title: title,
                    artist: artist,
                    artworkURL: item.snippet.thumbnails.bestURL,
                    duration: duration,
                    youtubeVideoID: videoID
                )
            }

            tracks = deduplicatedTracks(tracks + pageTracks)
            nextPageToken = response.nextPageToken
        } while nextPageToken != nil && tracks.count < targetCount

        return limitedTracks(tracks, maxItems: maxItems)
    }

    private func fetchTracks(
        for playlists: [Playlist],
        accessToken: String,
        maxItemsPerPlaylist: Int
    ) async -> [String: [Track]] {
        await withTaskGroup(of: (String, [Track]).self) { group in
            for playlist in playlists {
                group.addTask { [self] in
                    let tracks = (try? await fetchPlaylistItems(
                        for: playlist,
                        accessToken: accessToken,
                        maxItems: maxItemsPerPlaylist
                    )) ?? []
                    return (playlist.id, tracks)
                }
            }

            var tracksByPlaylist: [String: [Track]] = [:]
            for await (playlistID, tracks) in group {
                tracksByPlaylist[playlistID] = tracks
            }

            return tracksByPlaylist
        }
    }

    private func fetchPlaylistItems(
        for playlist: Playlist,
        accessToken: String,
        maxItems: Int
    ) async throws -> [Track] {
        try await fetchPlaylistItems(
            playlistID: playlist.id,
            accessToken: accessToken,
            maxItems: maxItems
        )
    }

    private func fetchPlaylistItems(
        playlistID: String,
        accessToken: String,
        maxItems: Int
    ) async throws -> [Track] {
        try await fetchPlaylistItems(
            playlistID: playlistID,
            queryItems: authorizedQueryItems([]),
            accessToken: accessToken,
            maxItems: maxItems
        )
    }

    private func fetchPlaylistItems(
        playlistID: String,
        apiKey: String,
        maxItems: Int
    ) async throws -> [Track] {
        try await fetchPlaylistItems(
            playlistID: playlistID,
            queryItems: [URLQueryItem(name: "key", value: apiKey)],
            accessToken: nil,
            maxItems: maxItems
        )
    }

    private func fetchPlaylistItems(
        playlistID: String,
        queryItems additionalQueryItems: [URLQueryItem],
        accessToken: String?,
        maxItems: Int
    ) async throws -> [Track] {
        var entries: [PlaylistEntry] = []
        var nextPageToken: String?

        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/playlistItems")!
            var queryItems = [
                URLQueryItem(name: "part", value: "snippet,contentDetails"),
                URLQueryItem(name: "playlistId", value: playlistID),
                URLQueryItem(name: "maxResults", value: "50")
            ]
            queryItems.append(contentsOf: additionalQueryItems)

            if let nextPageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: nextPageToken))
            }

            components.queryItems = queryItems

            let data: Data
            let urlResponse: URLResponse
            if let accessToken {
                let request = authorizedRequest(url: components.url!, accessToken: accessToken)
                (data, urlResponse) = try await urlSession.data(for: request)
            } else {
                (data, urlResponse) = try await urlSession.data(from: components.url!)
            }
            let response = try decodeResponse(PlaylistItemsResponse.self, from: data, response: urlResponse)

            entries.append(contentsOf: response.items)
            nextPageToken = response.nextPageToken
        } while nextPageToken != nil && entries.count < maxItems

        let tracks: [Track] = entries.prefix(maxItems).compactMap { item in
            guard let videoID = item.snippet.resourceID?.videoID ?? item.contentDetails?.videoID else { return nil }

            let rawArtist = item.snippet.videoOwnerChannelTitle ??
                item.snippet.channelTitle ??
                "YouTube"
            let artist = cleanArtistName(rawArtist)
            let title = cleanTrackTitle(item.snippet.title, channelName: artist)

            return Track(
                id: item.id,
                title: title,
                artist: artist,
                artworkURL: item.snippet.thumbnails?.bestURL,
                youtubeVideoID: videoID
            )
        }

        return tracks
    }

    private func fetchTrack(videoID: String, accessToken: String) async throws -> Track? {
        try await fetchTrack(
            videoID: videoID,
            queryItems: authorizedQueryItems([]),
            accessToken: accessToken
        )
    }

    private func fetchTrack(videoID: String, apiKey: String) async throws -> Track? {
        try await fetchTrack(
            videoID: videoID,
            queryItems: [URLQueryItem(name: "key", value: apiKey)],
            accessToken: nil
        )
    }

    private func fetchTrack(
        videoID: String,
        queryItems additionalQueryItems: [URLQueryItem],
        accessToken: String?
    ) async throws -> Track? {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")!
        var queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "id", value: videoID),
            URLQueryItem(name: "maxResults", value: "1")
        ]
        queryItems.append(contentsOf: additionalQueryItems)
        components.queryItems = queryItems

        let data: Data
        let urlResponse: URLResponse
        if let accessToken {
            let request = authorizedRequest(url: components.url!, accessToken: accessToken)
            (data, urlResponse) = try await urlSession.data(for: request)
        } else {
            (data, urlResponse) = try await urlSession.data(from: components.url!)
        }

        let response = try decodeResponse(VideoMetadataResponse.self, from: data, response: urlResponse)
        guard let item = response.items.first else { return nil }
        return directTrack(from: item)
    }

    private func limitedTracks(_ tracks: [Track], maxItems: Int?) -> [Track] {
        guard let maxItems else { return tracks }
        return Array(tracks.prefix(maxItems))
    }

    private func fetchArtistTracks(
        for collection: MusicCollection,
        accessToken: String?,
        maxItems: Int
    ) async throws -> [Track] {
        if let accessToken {
            let results = try await fetchArtistTracks(
                query: collection.queryHint,
                channelID: collection.sourceID,
                accessToken: accessToken,
                maxItems: maxItems
            )
            if results.isEmpty == false {
                return results
            }
        }

        if let results = try await firstNonEmptyAPIKeyResult({ apiKey in
            try await fetchArtistTracks(
                query: collection.queryHint,
                channelID: collection.sourceID,
                apiKey: apiKey,
                maxResults: maxItems
            )
        }) {
            return results
        }

        let fallbackPage = try await performTrackSearch(query: "\(collection.title) official audio", accessToken: accessToken)
        return Array(fallbackPage.tracks.prefix(maxItems))
    }

    private func fetchArtistTracks(
        query: String,
        channelID: String,
        accessToken: String,
        maxItems: Int
    ) async throws -> [Track] {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "safeSearch", value: "moderate"),
            URLQueryItem(name: "videoCategoryId", value: "10"),
            URLQueryItem(name: "channelId", value: channelID),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(maxItems))
        ]

        let request = authorizedRequest(url: components.url!, accessToken: accessToken)
        let (data, urlResponse) = try await urlSession.data(for: request)
        let response = try decodeResponse(VideoSearchResponse.self, from: data, response: urlResponse)
        return response.items.compactMap(musicSearchTrack(from:))
    }

    private func fetchArtistTracks(
        query: String,
        channelID: String,
        apiKey: String,
        maxResults: Int
    ) async throws -> [Track] {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "safeSearch", value: "moderate"),
            URLQueryItem(name: "videoCategoryId", value: "10"),
            URLQueryItem(name: "channelId", value: channelID),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(maxResults)),
            URLQueryItem(name: "key", value: apiKey)
        ]

        let (data, urlResponse) = try await urlSession.data(from: components.url!)
        let response = try decodeResponse(VideoSearchResponse.self, from: data, response: urlResponse)
        return response.items.compactMap(musicSearchTrack(from:))
    }

    private func prioritizedLibraryPlaylists(_ playlists: [Playlist]) -> [Playlist] {
        let deduplicated = deduplicatedPlaylists(playlists)
        let likedPlaylists = deduplicated.filter { $0.kind == .likedMusic }
        let remainingPlaylists = deduplicated.filter { $0.kind != .likedMusic }
        return likedPlaylists + remainingPlaylists
    }

    private func fallbackTracks(for collection: MusicCollection, limit: Int) async throws -> [Track] {
        let kindHint: String
        switch collection.kind {
        case .playlist:
            kindHint = "playlist"
        case .album:
            kindHint = "album"
        case .artist:
            kindHint = "songs"
        }

        let queries = fallbackQueries(
            title: collection.title,
            subtitle: collection.subtitle.isEmpty ? collection.queryHint : collection.subtitle,
            kindHint: kindHint
        )

        return try await fallbackTracks(queries: queries, limit: limit)
    }

    private func fallbackTracks(
        queries: [String],
        limit: Int
    ) async throws -> [Track] {
        for query in queries {
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedQuery.isEmpty == false else { continue }

            let page = try await performTrackSearch(query: trimmedQuery, accessToken: nil)
            if page.tracks.isEmpty == false {
                return Array(page.tracks.prefix(limit))
            }

            let relaxedTracks = try await fetchRelaxedSearchResultsViaInnerTube(
                query: trimmedQuery,
                maxResults: limit
            )
            if relaxedTracks.isEmpty == false {
                return Array(relaxedTracks.prefix(limit))
            }
        }

        return []
    }

    private func fallbackQueries(title: String, subtitle: String, kindHint: String) -> [String] {
        let titleParts = [title, subtitle]
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            }
            .filter { $0.isEmpty == false }

        let base = titleParts.joined(separator: " ")
        let titleOnly = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let variants = [
            base,
            "\(base) \(kindHint)",
            "\(titleOnly) \(kindHint)",
            "\(titleOnly) official audio",
            "\(titleOnly) full album"
        ]

        return orderedUniqueStrings(variants)
    }

    private func isQuotaOrTransientAPIError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("quota")
            || message.contains("daily limit")
            || message.contains("rate limit")
            || message.contains("backend error")
            || message.contains("temporarily unavailable")
            || message.contains("timed out")
            || message.contains("network connection was lost")
            || message.contains("offline")
            || message.contains("status 429")
            || message.contains("status 500")
            || message.contains("status 502")
            || message.contains("status 503")
    }

    private func deduplicatedPlaylists(_ playlists: [Playlist]) -> [Playlist] {
        var seenIDs: Set<String> = []
        return playlists.filter { playlist in
            seenIDs.insert(playlist.id).inserted
        }
    }

    private func deduplicatedTracks(_ tracks: [Track]) -> [Track] {
        var seenIDs: Set<String> = []
        return tracks.filter { track in
            let dedupeID = track.youtubeVideoID ?? track.id
            return seenIDs.insert(dedupeID).inserted
        }
    }

    private func deduplicatedCollections(_ collections: [MusicCollection]) -> [MusicCollection] {
        var seenIDs: Set<String> = []
        return collections.filter { collection in
            seenIDs.insert(collection.id).inserted
        }
    }

    private func orderedUniqueStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { return false }
            return seen.insert(trimmed.lowercased()).inserted
        }
    }

    private func selectSuggestedMixes(from playlists: [Playlist], limit: Int) -> [Playlist] {
        let candidates = playlists.suggestedMixCandidates()
        guard candidates.isEmpty == false else { return [] }

        let poolSize = min(candidates.count, max(limit * 2, limit))
        return Array(candidates.prefix(poolSize).shuffled().prefix(limit))
    }

    private func randomizedTracks(from tracks: [Track], limit: Int) -> [Track] {
        guard tracks.isEmpty == false else { return [] }
        return Array(tracks.shuffled().prefix(limit))
    }

    private func trackIdentifier(_ track: Track) -> String {
        track.youtubeVideoID ?? track.id
    }

    private func makeLikedMusicPlaylist(
        from tracks: [Track],
        fallbackPlaylist: Playlist? = nil
    ) -> Playlist? {
        guard tracks.isEmpty == false || fallbackPlaylist != nil else { return nil }

        return Playlist(
            id: fallbackPlaylist?.id ?? likedMusicPlaylistID,
            title: "Liked Songs",
            description: "Music-only items from your likes",
            artworkURL: tracks.first?.artworkURL ?? fallbackPlaylist?.artworkURL,
            itemCount: max(tracks.count, fallbackPlaylist?.itemCount ?? 0),
            kind: .likedMusic
        )
    }

    private func decodeResponse<T: Decodable>(_ type: T.Type, from data: Data, response: URLResponse) throws -> T {
        try validateStatusCode(for: response, data: data)

        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as DecodingError {
            throw APIError.decodingError(error)
        }
    }

    private func validateStatusCode(for response: URLResponse, data: Data) throws {
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode
        let retryAfter = retryAfterInterval(from: httpResponse)
        let sanitizedMessage = sanitizedErrorMessage(from: data)

        if let statusCode, (200 ..< 300).contains(statusCode) == false {
            switch statusCode {
            case 401:
                throw APIError.authenticationFailure
            case 403:
                if sanitizedMessage?.isInsufficientAuthenticationScopesError == true {
                    throw APIError.authenticationFailure
                }
                throw APIError.invalidResponse(statusCode: statusCode, message: sanitizedMessage ?? "YouTube denied that request.")
            case 404:
                throw APIError.notFound
            case 429:
                throw APIError.rateLimited(retryAfter: retryAfter)
            default:
                throw APIError.invalidResponse(statusCode: statusCode, message: sanitizedMessage)
            }
        }

        if let sanitizedMessage {
            throw APIError.serviceError(sanitizedMessage)
        }
    }

    private func retryAfterInterval(from response: HTTPURLResponse?) -> TimeInterval? {
        guard let value = response?.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let interval = TimeInterval(value) {
            return interval
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"

        guard let retryDate = formatter.date(from: value) else { return nil }
        return max(retryDate.timeIntervalSinceNow, 0)
    }

    private func sanitizedErrorMessage(from data: Data) -> String? {
        guard let apiError = try? JSONDecoder().decode(GoogleAPIErrorEnvelope.self, from: data),
              let message = apiError.error?.message,
              message.isEmpty == false else {
            return nil
        }

        return message.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}

private struct VideoSearchResponse: Decodable {
    let items: [VideoItem]
    let nextPageToken: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([VideoItem].self, forKey: .items) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
    }

    private enum CodingKeys: String, CodingKey {
        case items
        case nextPageToken
    }
}

private extension String {
    var isInsufficientAuthenticationScopesError: Bool {
        localizedCaseInsensitiveContains("insufficient authentication scopes")
    }
}

private struct VideoMetadataResponse: Decodable {
    let items: [VideoMetadataItem]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([VideoMetadataItem].self, forKey: .items) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case items
    }
}

private struct VideoMetadataItem: Decodable {
    let id: String
    let snippet: VideoMetadataSnippet
    let contentDetails: VideoContentDetails?
}

private struct VideoContentDetails: Decodable {
    let duration: String?
}

private struct VideoMetadataSnippet: Decodable {
    let categoryID: String?
    let title: String?
    let channelTitle: String?
    let thumbnails: ThumbnailCollection?
    let liveBroadcastContent: String?

    enum CodingKeys: String, CodingKey {
        case categoryID = "categoryId"
        case title
        case channelTitle
        case thumbnails
        case liveBroadcastContent
    }
}

private struct PlaylistSearchResponse: Decodable {
    let items: [PlaylistItem]
    let nextPageToken: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([PlaylistItem].self, forKey: .items) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
    }

    private enum CodingKeys: String, CodingKey {
        case items
        case nextPageToken
    }
}

private struct ChannelSearchResponse: Decodable {
    let items: [ChannelItem]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([ChannelItem].self, forKey: .items) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case items
    }
}

private struct ChannelItem: Decodable {
    let contentDetails: ChannelContentDetails?
}

private struct ChannelContentDetails: Decodable {
    let relatedPlaylists: RelatedPlaylists?
}

private struct RelatedPlaylists: Decodable {
    let likes: String?
    let uploads: String?
}

private struct PlaylistItem: Decodable {
    let id: String
    let snippet: PlaylistSnippet
    let contentDetails: PlaylistContentDetails?
}

private struct PlaylistContentDetails: Decodable {
    let itemCount: Int?
}

private struct PlaylistItemsResponse: Decodable {
    let items: [PlaylistEntry]
    let nextPageToken: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([PlaylistEntry].self, forKey: .items) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
    }

    private enum CodingKeys: String, CodingKey {
        case items
        case nextPageToken
    }
}

private struct PlaylistEntry: Decodable {
    let id: String
    let snippet: PlaylistEntrySnippet
    let contentDetails: PlaylistEntryContentDetails?
}

private struct PlaylistSnippet: Decodable {
    let title: String
    let description: String?
    let thumbnails: ThumbnailCollection?
}

private struct PlaylistEntrySnippet: Decodable {
    let title: String
    let channelTitle: String?
    let videoOwnerChannelTitle: String?
    let resourceID: PlaylistEntryResourceID?
    let thumbnails: ThumbnailCollection?

    enum CodingKeys: String, CodingKey {
        case title
        case channelTitle
        case videoOwnerChannelTitle
        case resourceID = "resourceId"
        case thumbnails
    }
}

private struct PlaylistEntryResourceID: Decodable {
    let videoID: String?

    enum CodingKeys: String, CodingKey {
        case videoID = "videoId"
    }
}

private struct PlaylistEntryContentDetails: Decodable {
    let videoID: String?

    enum CodingKeys: String, CodingKey {
        case videoID = "videoId"
    }
}

private struct VideoItem: Decodable {
    let id: VideoIdentifier
    let snippet: Snippet
    let contentDetails: VideoContentDetails?
}

private struct VideoIdentifier: Decodable {
    let raw: String?
    let videoID: String?

    enum CodingKeys: String, CodingKey {
        case raw
        case videoID = "videoId"
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            raw = try container.decodeIfPresent(String.self, forKey: .raw)
            videoID = try container.decodeIfPresent(String.self, forKey: .videoID)
        } else {
            let single = try decoder.singleValueContainer()
            raw = try? single.decode(String.self)
            videoID = nil
        }
    }
}

private struct Snippet: Decodable {
    let title: String
    let channelTitle: String
    let thumbnails: ThumbnailCollection
    let categoryID: String?
    let liveBroadcastContent: String?

    enum CodingKeys: String, CodingKey {
        case title
        case channelTitle
        case thumbnails
        case categoryID = "categoryId"
        case liveBroadcastContent
    }
}

private struct ThumbnailCollection: Decodable {
    let high: Thumbnail?
    let medium: Thumbnail?
    let `default`: Thumbnail?

    var bestURL: URL? {
        high?.url ?? medium?.url ?? `default`?.url
    }
}

private struct Thumbnail: Decodable {
    let url: URL?

    private enum CodingKeys: String, CodingKey {
        case url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let urlString = try container.decodeIfPresent(String.self, forKey: .url)
        url = urlString.flatMap(Self.normalizedRemoteURL(from:))
    }

    private static func normalizedRemoteURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        if trimmed.hasPrefix("//") {
            return URL(string: "https:\(trimmed)")
        }

        return URL(string: trimmed)
    }
}

private struct GoogleAPIErrorEnvelope: Decodable {
    let error: GoogleAPIError?
}

private struct GoogleAPIError: Decodable {
    let message: String?
    let code: Int?
}

// MARK: - Music Content Helpers

private extension YouTubeAPIService {
    func directTrack(from item: VideoMetadataItem) -> Track? {
        guard let rawTitle = item.snippet.title, rawTitle.isEmpty == false else { return nil }

        let rawArtist = item.snippet.channelTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = rawArtist?.isEmpty == false ? cleanArtistName(rawArtist!) : "YouTube"
        let title = cleanTrackTitle(rawTitle, channelName: artist)

        return Track(
            id: item.id,
            title: title,
            artist: artist,
            artworkURL: item.snippet.thumbnails?.bestURL,
            youtubeVideoID: item.id
        )
    }

    func buildMusicSearchTrack(
        videoID: String,
        rawTitle: String,
        rawArtist: String,
        artworkURL: URL?,
        duration: TimeInterval?,
        viewCount: Int? = nil
    ) -> Track? {
        guard isNonMusicContent(title: rawTitle, channel: rawArtist) == false else { return nil }
        guard isStrictMusicSearchCandidate(title: rawTitle, artist: rawArtist, duration: duration) else {
            return nil
        }

        let artist = cleanArtistName(rawArtist)
        let title = cleanTrackTitle(rawTitle, channelName: artist)
        let track = Track(
            id: videoID,
            title: title,
            artist: artist,
            artworkURL: artworkURL,
            duration: duration,
            youtubeVideoID: videoID,
            viewCount: viewCount
        )

        return track.isEligibleForMusicSuggestions ? track : nil
    }

    func isLiveSearchResult(snippet: Snippet) -> Bool {
        switch snippet.liveBroadcastContent?.lowercased() {
        case "live", "upcoming":
            return true
        default:
            return false
        }
    }

    func isLiveSearchResult(renderer: [String: Any]) -> Bool {
        if renderer["upcomingEventData"] != nil {
            return true
        }

        if let overlayText = text(from: renderer["thumbnailOverlays"])?.lowercased(),
           overlayText.contains("live") || overlayText.contains("upcoming") {
            return true
        }

        if let badges = renderer["badges"] as? [Any],
           badges.contains(where: { badge in
               let badgeText = text(from: badge)?.lowercased() ?? ""
               return badgeText.contains("live") || badgeText.contains("upcoming")
           }) {
            return true
        }

        let durationText = text(from: renderer["lengthText"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        return durationText == nil
    }

    func isStrictMusicSearchCandidate(title: String, artist: String, duration: TimeInterval?) -> Bool {
        let titleLower = title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let searchText = "\(title) \(artist)"
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        // Reject educational / informational content up-front
        let educationalPrefixes = ["how to ", "how i "]
        for prefix in educationalPrefixes where titleLower.hasPrefix(prefix) { return false }
        let educationalKeywords = [
            "beginner's guide", "beginner guide", "complete guide", "full guide",
            "guide to ", "introduction to ", "step by step", "tips and tricks",
            "explained:", " explained ", "history of ", "science of ",
            "study tips", "full course", "crash course", "exam prep"
        ]
        if educationalKeywords.contains(where: titleLower.contains) { return false }

        let videoKeywords = [
            "official music video", "music video", "official video", "video clip",
            "lyric video", "lyrics video", "lyrics", "visualizer",
            "live session", "live performance", "concert", "performance", "session"
        ]
        if videoKeywords.contains(where: searchText.contains) {
            return false
        }

        if searchText.contains("shorts") || searchText.contains("#shorts") {
            return false
        }

        if let duration {
            if duration < 60 || duration > 900 {
                return false
            }
        }

        var score = 0
        if searchText.contains("official audio") || searchText.contains("[audio]") || searchText.contains("(audio)") {
            score += 5
        }
        if searchText.contains("album") || searchText.contains("ep") {
            score += 2
        }
        if artist.lowercased().contains("topic") {
            score += 4
        }
        if let duration {
            switch duration {
            case 90 ... 540:
                score += 3
            case 60 ... 780:
                score += 1
            default:
                break
            }
        }

        return score > 0
    }

    /// Returns true when the video is clearly non-music (kids songs, gaming, vlogs, etc.)
    func isNonMusicContent(title: String, channel: String) -> Bool {
        let t = title.lowercased()
        let ch = channel.lowercased()

        // Kids / nursery content
        let kidsKeywords = [
            "nursery rhyme", "baby shark", "kids song", "children's song", "children song",
            "cocomelon", "super simple songs", "little baby bum", "blippi", "ms rachel",
            "toddler song", "abc song", "phonics song", "wheels on the bus",
            "if you're happy", "finger family", "johny johny", "five little",
            "old macdonald", "twinkle twinkle", "baa baa", "itsy bitsy",
            "pinkfong", "moonbug", "dave and ava", "little angel"
        ]
        for kw in kidsKeywords where t.contains(kw) || ch.contains(kw) { return true }

        // Gaming content
        let gamingKeywords = [
            "gameplay", "let's play", "lets play", "playthrough", "walkthrough",
            "minecraft", "roblox", "fortnite", "among us", "gta v", "call of duty",
            "game review", "gaming montage"
        ]
        for kw in gamingKeywords where t.contains(kw) { return true }

        // Vlog / lifestyle
        let vlogKeywords = [
            "daily vlog", "weekly vlog", "room tour", "morning routine", "night routine",
            "get ready with me", "grwm", "what i eat in a day",
            "unboxing video", "haul video", "try on haul"
        ]
        for kw in vlogKeywords where t.contains(kw) { return true }

        // Educational / tutorial content
        let educationalPrefixes = ["how to ", "how i "]
        for prefix in educationalPrefixes where t.hasPrefix(prefix) { return true }
        let educationalKeywords = [
            "beginner's guide", "beginner guide", "complete guide", "full guide",
            "guide to ", "introduction to ", "step by step", "tips and tricks",
            "explained:", " explained ", "explanation:", "history of ", "science of ",
            "study tips", "full course", "crash course", "lesson plan", "exam prep"
        ]
        for kw in educationalKeywords where t.contains(kw) { return true }

        // Educational channel signals
        let educationalChannelKeywords = ["academy", "university", "college", "education"]
        for kw in educationalChannelKeywords where ch.contains(kw) { return true }

        // Channel-level signals
        let nonMusicChannelSuffixes = ["gaming", "gamer", "plays", "vlogs"]
        for suffix in nonMusicChannelSuffixes where ch.hasSuffix(suffix) { return true }

        return false
    }

    /// Liked songs need a broader definition than search results.
    /// Many valid YouTube likes are tagged outside category 10
    /// (for example lyric videos, visualizers, live sessions, or VEVO uploads).
    func isLikelyLikedMusicCandidate(
        title: String,
        artist: String,
        categoryID: String?,
        duration: TimeInterval?
    ) -> Bool {
        guard isNonMusicContent(title: title, channel: artist) == false else { return false }
        guard looksLikeShorts(title: title) == false else { return false }

        if let duration {
            if duration < 60 || duration > 5_400 {
                return false
            }
        }

        if categoryID == "10" {
            return true
        }

        let normalized = "\(title) \(artist)"
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let artistNormalized = artist
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        let strongMusicSignals = [
            "official audio", "(audio)", "[audio]", "lyric video", "lyrics",
            "visualizer", "official video", "music video", "topic",
            "vevo", "acoustic", "remix", "album", "ep", "soundtrack",
            "live session", "live performance", "session"
        ]

        if strongMusicSignals.contains(where: normalized.contains) {
            return true
        }

        if artistNormalized.contains("topic") || artistNormalized.contains("vevo") {
            return true
        }

        if let duration, duration >= 90 && duration <= 900 {
            return true
        }

        return false
    }

    func looksLikeShorts(title: String) -> Bool {
        let normalized = title.lowercased()
        return normalized.contains("shorts") || normalized.contains("#shorts")
    }

    /// Parses ISO 8601 duration strings ("PT4M32S", "PT1H2M3S", "PT45S") to total seconds.
    func parseISO8601DurationSeconds(_ text: String) -> Int? {
        guard text.hasPrefix("PT") else { return nil }
        let body = text.dropFirst(2)
        var total = 0
        var current = ""
        for char in body {
            if char.isNumber {
                current.append(char)
            } else {
                guard let value = Int(current) else { return nil }
                switch char {
                case "H": total += value * 3_600
                case "M": total += value * 60
                case "S": total += value
                default: return nil
                }
                current = ""
            }
        }
        return total
    }

    /// Returns true when the duration looks like an actual song (60s–30min).
    /// Excludes Shorts (<60s) and obvious long-form non-music content.
    /// Upper bound is generous to accommodate extended remixes, traditional/classical
    /// pieces, and live performances that are still legitimately music.
    func isLikelySongDuration(_ seconds: Int) -> Bool {
        seconds >= 60 && seconds <= 1_800
    }

    /// Parses "M:SS" or "H:MM:SS" duration strings to total seconds.
    func parseDurationSeconds(_ text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3_600 + parts[1] * 60 + parts[2]
        default: return nil
        }
    }

    /// Cleans YouTube video titles: strips "Artist - " prefix and common qualifiers.
    func cleanTrackTitle(_ raw: String, channelName: String) -> String {
        var title = raw

        // Strip exact "Channel - " prefix first (most reliable)
        let exactPrefix = channelName + " - "
        if title.hasPrefix(exactPrefix) {
            title = String(title.dropFirst(exactPrefix.count))
        } else if let dashRange = title.range(of: " - ") {
            // General "Artist - Title" split when artist part is a plausible short name
            let leftCount = title.distance(from: title.startIndex, to: dashRange.lowerBound)
            let right = String(title[dashRange.upperBound...])
            if leftCount <= 50, !right.isEmpty {
                title = right
            }
        }

        // Remove trailing YouTube qualifiers (applied repeatedly to handle stacked ones)
        let qualifiers: [String] = [
            "(Official Music Video)", "[Official Music Video]",
            "(Official Video)", "[Official Video]",
            "(Official Audio)", "[Official Audio]",
            "(Lyric Video)", "[Lyric Video]",
            "(Lyrics Video)", "[Lyrics Video]",
            "(Lyrics)", "[Lyrics]",
            "(Audio)", "[Audio]",
            "(Live Session)", "[Live Session]",
            "(Live Performance)", "[Live Performance]",
            "(HD)", "[HD]", "(4K)", "[4K]", "(HQ)", "[HQ]",
            "(Official)", "[Official]",
            "- Official Music Video", "- Official Video", "- Official Audio",
            "- Lyric Video", "- Lyrics", "- Audio"
        ]

        var changed = true
        while changed {
            changed = false
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            for q in qualifiers {
                if trimmed.lowercased().hasSuffix(q.lowercased()) {
                    title = String(trimmed.dropLast(q.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                    break
                }
            }
        }

        let result = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? raw : result
    }

    /// Cleans YouTube channel names: removes "- Topic" and "VEVO" suffixes.
    func cleanArtistName(_ raw: String) -> String {
        var name = raw
        if name.hasSuffix(" - Topic") { name = String(name.dropLast(8)) }
        if name.uppercased().hasSuffix("VEVO") {
            name = String(name.dropLast(4)).trimmingCharacters(in: .whitespaces)
        }
        if name.hasSuffix(" Official") { name = String(name.dropLast(9)) }
        let result = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? raw : result
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, isEmpty == false else { return [] }

        var chunks: [[Element]] = []
        var startIndex = 0

        while startIndex < count {
            let endIndex = Swift.min(startIndex + size, count)
            chunks.append(Array(self[startIndex ..< endIndex]))
            startIndex = endIndex
        }

        return chunks
    }
}
