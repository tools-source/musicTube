import Foundation
import OSLog

struct AppConfig {
    enum YouTube {
        static let apiKeyInfoDictionaryKey = "YOUTUBE_API_KEY"
        static let innerTubeSearchEndpoint = URL(string: "https://www.youtube.com/youtubei/v1/search")!
        static let innerTubeClientVersion = "2.20260114.08.00"
        static let likedMusicPlaylistID = "liked-music"
        static let likedMusicPreviewLimit = 40
    }

    enum Search {
        static let maxQueryLength = 100
        static let resultsPerPage = 24
        static let cacheTTL: TimeInterval = 300
        static let maxCachedQueries = 80
        static let debounceNanoseconds: UInt64 = 220_000_000
        static let visibleSongPageSize = 8
    }

    enum Cache {
        static let trackListTTL: TimeInterval = 300
    }

    enum Playback {
        static let startupForwardBufferDuration: TimeInterval = 4
        static let steadyStateForwardBufferDuration: TimeInterval = 18
        static let startupWaitTimeoutNanoseconds: UInt64 = 3_000_000_000
    }

    enum Downloads {
        static let maxConcurrentStreamResolutions = 3
        static let batchResolveSpacingNanoseconds: UInt64 = 250_000_000
    }

    enum Library {
        static let localLikedPlaylistID = "local-liked-songs"
        static let localSavedSongsPlaylistID = "local-saved-songs"
        static let localReplayMixPlaylistID = "local-replay-mix"
        static let localFavoritesMixPlaylistID = "local-favorites-mix"
        static let deviceProfileID = "device-local-profile"
        static let likedSongsSyncCooldown: TimeInterval = 300
    }
}

enum QueryValidationError: LocalizedError {
    case empty
    case tooLong(maxLength: Int)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Enter something to search for."
        case .tooLong(let maxLength):
            return "Searches are limited to \(maxLength) characters."
        }
    }
}

struct QueryValidator {
    static func validateSearchQuery(_ query: String) throws -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.isEmpty == false else {
            throw QueryValidationError.empty
        }

        guard trimmed.count <= AppConfig.Search.maxQueryLength else {
            throw QueryValidationError.tooLong(maxLength: AppConfig.Search.maxQueryLength)
        }

        return trimmed
    }
}

protocol AppLogging {
    func debug(_ message: String)
    func info(_ message: String)
    func error(_ message: String, error: Error?)
}

struct DefaultAppLogger: AppLogging {
    private let logger: Logger

    init(category: String, subsystem: String = Bundle.main.bundleIdentifier ?? "MusicTube") {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    func error(_ message: String, error: Error? = nil) {
        if let error {
            logger.error("\(message, privacy: .public): \(error.localizedDescription, privacy: .public)")
        } else {
            logger.error("\(message, privacy: .public)")
        }
    }
}

actor CacheStore<Key: Hashable, Value> {
    private struct Entry {
        let value: Value
        let expiresAt: Date
    }

    private var store: [Key: Entry] = [:]
    private let ttl: TimeInterval
    private let maxEntries: Int?

    init(ttl: TimeInterval, maxEntries: Int? = nil) {
        self.ttl = ttl
        self.maxEntries = maxEntries
    }

    func value(for key: Key) -> Value? {
        guard let entry = store[key] else { return nil }
        guard entry.expiresAt > Date() else {
            store.removeValue(forKey: key)
            return nil
        }

        return entry.value
    }

    func set(_ value: Value, for key: Key) {
        store[key] = Entry(
            value: value,
            expiresAt: Date().addingTimeInterval(ttl)
        )

        trimExpiredEntries()
        trimOverflowIfNeeded()
    }

    func removeValue(for key: Key) {
        store.removeValue(forKey: key)
    }

    func removeAll() {
        store.removeAll()
    }

    private func trimExpiredEntries() {
        let now = Date()
        store = store.filter { $0.value.expiresAt > now }
    }

    private func trimOverflowIfNeeded() {
        guard let maxEntries, store.count > maxEntries else { return }

        let overflowKeys = store
            .sorted { $0.value.expiresAt < $1.value.expiresAt }
            .prefix(store.count - maxEntries)
            .map(\.key)

        for key in overflowKeys {
            store.removeValue(forKey: key)
        }
    }
}

protocol AuthProviding {
    /// Restores a previously persisted session when one is still valid or refreshable.
    func restoreSession() async -> YouTubeSession?
    /// Forces a token refresh for the current persisted session, if possible.
    func refreshSession() async -> YouTubeSession?
    /// Starts the interactive YouTube sign-in flow and returns a new authorized session.
    func signIn() async throws -> YouTubeSession
    /// Clears any persisted credentials and local auth session state.
    func signOut() async
}

protocol MusicCatalogProviding {
    /// Loads personalized home content for an authenticated YouTube account.
    func loadHome(accessToken: String) async throws -> (featured: [Track], recent: [Track])
    /// Searches songs, playlists, albums, and artists for the given query.
    func search(query: String, accessToken: String?) async throws -> SearchResponse
    /// Loads the next page of song results for a previously issued search query.
    /// - Parameters:
    ///   - query: The original validated search query.
    ///   - continuation: The continuation token returned by the previous search response.
    ///   - accessToken: Optional OAuth token for authenticated YouTube requests.
    func loadMoreSearchResults(query: String, continuation: String, accessToken: String?) async throws -> SearchResponse
    /// Loads playlists visible to the authenticated user, including system collections.
    func loadPlaylists(accessToken: String) async throws -> [Playlist]
    /// Loads the tracks contained in a playlist for an authenticated user.
    func loadPlaylistItems(for playlist: Playlist, accessToken: String) async throws -> [Track]
    /// Loads tracks contained in a saved collection, with guest fallbacks when available.
    func loadCollectionItems(for collection: MusicCollection, accessToken: String?) async throws -> [Track]
}

@MainActor
protocol PlaybackControlling: AnyObject {
    var nowPlaying: Track? { get }
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }
    func play(track: Track)
    func resume()
    func pause()
    func seek(to time: TimeInterval)
}
