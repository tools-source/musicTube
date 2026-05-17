import Foundation

struct Track: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let title: String
    let artist: String
    let artworkURL: URL?
    let duration: TimeInterval?
    let youtubeVideoID: String?
    let streamURL: URL?
    let viewCount: Int?

    init(
        id: String = UUID().uuidString,
        title: String,
        artist: String,
        artworkURL: URL? = nil,
        duration: TimeInterval? = nil,
        youtubeVideoID: String? = nil,
        streamURL: URL? = nil,
        viewCount: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.duration = duration
        self.youtubeVideoID = youtubeVideoID
        self.streamURL = streamURL
        self.viewCount = viewCount
    }

    var formattedViewCount: String? {
        guard let viewCount, viewCount > 0 else { return nil }
        return "\(Self.abbreviatedCount(viewCount)) views"
    }

    var musicTubeShareURL: URL? {
        guard let youtubeVideoID else { return nil }
        var components = URLComponents(
            url: AppConfig.Sharing.webShareBaseURL,
            resolvingAgainstBaseURL: false
        )
        var queryItems = [
            URLQueryItem(name: "track", value: youtubeVideoID),
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "artist", value: artist)
        ]
        if let artworkURL {
            queryItems.append(URLQueryItem(name: "artwork", value: artworkURL.absoluteString))
        }
        components?.queryItems = queryItems
        return components?.url
    }

    var musicTubeDeepLinkURL: URL? {
        guard let youtubeVideoID else { return nil }
        var components = URLComponents()
        components.scheme = AppConfig.Sharing.appURLScheme
        components.host = "track"
        components.path = "/\(youtubeVideoID)"
        return components.url
    }

    var youtubeWatchURL: URL? {
        guard let youtubeVideoID else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/watch"
        components.queryItems = [URLQueryItem(name: "v", value: youtubeVideoID)]
        return components.url
    }

    var youtubeEmbedURL: URL? {
        guard let youtubeVideoID else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/embed/\(youtubeVideoID)"
        components.queryItems = [
            URLQueryItem(name: "playsinline", value: "1"),
            URLQueryItem(name: "autoplay", value: "1")
        ]
        return components.url
    }

    var playbackKey: String {
        youtubeVideoID ?? id
    }

    var formattedDuration: String? {
        Self.formatDuration(duration)
    }

    static func formatDuration(_ duration: TimeInterval?) -> String? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }

        let totalSeconds = Int(duration.rounded())
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }

        return String(format: "%d:%02d", minutes, seconds)
    }

    private static func abbreviatedCount(_ value: Int) -> String {
        let suffixes: [(threshold: Double, suffix: String)] = [
            (1_000_000_000, "B"),
            (1_000_000, "M"),
            (1_000, "K")
        ]

        let doubleValue = Double(value)
        for item in suffixes where doubleValue >= item.threshold {
            let shortened = doubleValue / item.threshold
            let rounded = shortened >= 10 || shortened.rounded() == shortened
                ? String(format: "%.0f", shortened)
                : String(format: "%.1f", shortened)
            return "\(rounded)\(item.suffix)"
        }

        return String(value)
    }
}

enum PlaylistKind: String, Hashable, Sendable {
    case standard
    case likedMusic
    case uploads
    case savedSongs
    case custom
}

struct Playlist: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let description: String
    let artworkURL: URL?
    let itemCount: Int
    let kind: PlaylistKind
}

enum MusicCollectionKind: String, Codable, Hashable, Sendable {
    case playlist
    case album
    case artist
}

struct MusicCollection: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let sourceID: String
    let title: String
    let subtitle: String
    let description: String
    let artworkURL: URL?
    let itemCount: Int
    let kind: MusicCollectionKind
    let queryHint: String

    init(
        id: String? = nil,
        sourceID: String,
        title: String,
        subtitle: String = "",
        description: String = "",
        artworkURL: URL? = nil,
        itemCount: Int = 0,
        kind: MusicCollectionKind,
        queryHint: String? = nil
    ) {
        self.sourceID = sourceID
        self.title = title
        self.subtitle = subtitle
        self.description = description
        self.artworkURL = artworkURL
        self.itemCount = itemCount
        self.kind = kind
        self.queryHint = queryHint ?? [title, subtitle]
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
        self.id = id ?? "\(kind.rawValue):\(sourceID)"
    }
}

struct SearchResponse: Hashable, Sendable {
    struct Category<Item: Hashable & Sendable>: Hashable, Sendable {
        var items: [Item]
        var continuationToken: String?
        var isLoading: Bool

        init(
            items: [Item] = [],
            continuationToken: String? = nil,
            isLoading: Bool = false
        ) {
            self.items = items
            self.continuationToken = continuationToken
            self.isLoading = isLoading
        }

        var isEmpty: Bool {
            items.isEmpty
        }
    }

    var trackCategory: Category<Track>
    var playlistCategory: Category<MusicCollection>
    var albumCategory: Category<MusicCollection>
    var artistCategory: Category<MusicCollection>

    init(
        trackCategory: Category<Track> = .init(),
        playlistCategory: Category<MusicCollection> = .init(),
        albumCategory: Category<MusicCollection> = .init(),
        artistCategory: Category<MusicCollection> = .init()
    ) {
        self.trackCategory = trackCategory
        self.playlistCategory = playlistCategory
        self.albumCategory = albumCategory
        self.artistCategory = artistCategory
    }

    init(
        songs: [Track],
        playlists: [MusicCollection],
        albums: [MusicCollection],
        artists: [MusicCollection],
        nextSongsContinuationToken: String?
    ) {
        self.init(
            trackCategory: Category(items: songs, continuationToken: nextSongsContinuationToken),
            playlistCategory: Category(items: playlists),
            albumCategory: Category(items: albums),
            artistCategory: Category(items: artists)
        )
    }

    static let empty = SearchResponse()

    var songs: [Track] {
        get { trackCategory.items }
        set { trackCategory.items = newValue }
    }

    var playlists: [MusicCollection] {
        get { playlistCategory.items }
        set { playlistCategory.items = newValue }
    }

    var albums: [MusicCollection] {
        get { albumCategory.items }
        set { albumCategory.items = newValue }
    }

    var artists: [MusicCollection] {
        get { artistCategory.items }
        set { artistCategory.items = newValue }
    }

    var nextSongsContinuationToken: String? {
        get { trackCategory.continuationToken }
        set { trackCategory.continuationToken = newValue }
    }

    var isEmpty: Bool {
        trackCategory.isEmpty && playlistCategory.isEmpty && albumCategory.isEmpty && artistCategory.isEmpty
    }

    var totalResultCount: Int {
        trackCategory.items.count + playlistCategory.items.count + albumCategory.items.count + artistCategory.items.count
    }
}

extension Track {
    var isLikelyShortFormVideo: Bool {
        let searchText = normalizedMusicClassificationText
        if searchText.contains("shorts") || searchText.contains("#shorts") {
            return true
        }

        guard let duration else { return false }
        return duration > 0 && duration < 60
    }

    var isClearlyNonMusicContent: Bool {
        let searchText = normalizedMusicClassificationText
        let titleLower = title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        let educationalPrefixes = ["how to ", "how i "]
        for prefix in educationalPrefixes where titleLower.hasPrefix(prefix) { return true }

        let negativeKeywords = [
            "news", "breaking", "podcast", "interview", "episode", "sermon",
            "preaching", "speech", "lecture", "reaction", "review", "tutorial",
            "walkthrough", "gameplay", "vlog", "unboxing", "livestream",
            "trailer", "trending", "channel intro", "behind the scenes",
            "beginner's guide", "beginner guide", "complete guide", "guide to ",
            "introduction to ", "step by step", "tips and tricks",
            " explained ", "explained:", "history of ", "science of ",
            "full course", "crash course", "study tips", "exam prep",
            "اخبار", "الأخبار", "عاجل", "نشرة", "برنامج", "حلقة",
            "مباشر", "لقاء", "مقابلة", "الفضائية", "فضائية", "قناة",
            "تعلن", "شركة", "تخفيض", "نفط", "طيران"
        ]

        return negativeKeywords.contains { searchText.contains($0) }
    }

    var isEligibleForMusicSuggestions: Bool {
        !isLikelyShortFormVideo && !isClearlyNonMusicContent
    }

    var isQuranOrRecitation: Bool {
        let searchText = normalizedMusicClassificationText
        let arabicText = "\(title) \(artist)"
        let latinTokens = Set(
            searchText
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.isEmpty == false }
        )

        let exactLatinQuranTokens: Set<String> = [
            "quran", "koran", "surah", "sura", "surat", "tilawah",
            "tajweed", "mushaf", "mishary", "sudais", "afasy"
        ]

        if latinTokens.isDisjoint(with: exactLatinQuranTokens) == false {
            return true
        }

        if latinTokens.contains("ayah") || latinTokens.contains("ayat") {
            return latinTokens.contains("quran")
                || latinTokens.contains("koran")
                || latinTokens.contains("surah")
                || latinTokens.contains("sura")
                || latinTokens.contains("surat")
        }

        let strongArabicQuranKeywords = [
            "سورة", "سوره", "قران", "قرآن", "القران", "القرآن", "تلاوة",
            "تلاوه", "ترتيل", "تجويد", "مصحف", "آيات", "ايات",
            "جزء عم", "الجزء", "الحرم المكي", "الحرم المدني",
            "السديس", "العفاسي", "ماهر المعيقلي"
        ]

        return strongArabicQuranKeywords.contains {
            searchText.contains($0) || arabicText.contains($0)
        }
    }

    private var normalizedMusicClassificationText: String {
        "\(title) \(artist)"
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

extension Array where Element == Playlist {
    func mixAlbumCandidates(limit: Int = 8) -> [Playlist] {
        Array(suggestedMixCandidates().prefix(limit))
    }

    func suggestedMixCandidates() -> [Playlist] {
        let standardPlaylists = filter { playlist in
            (playlist.kind == .standard || playlist.kind == .custom) && playlist.itemCount > 0
        }

        let fallbackCollections = filter { playlist in
            playlist.kind == .uploads && playlist.itemCount > 0
        }

        let candidates = standardPlaylists.isEmpty ? fallbackCollections : standardPlaylists

        return candidates.sorted { lhs, rhs in
            if lhs.suggestedMixScore != rhs.suggestedMixScore {
                return lhs.suggestedMixScore > rhs.suggestedMixScore
            }

            if lhs.itemCount != rhs.itemCount {
                return lhs.itemCount > rhs.itemCount
            }

            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}

private extension Playlist {
    var suggestedMixScore: Int {
        let searchableText = "\(title) \(description)".lowercased()
        let weightedKeywords: [(String, Int)] = [
            ("mix", 5),
            ("radio", 4),
            ("for you", 4),
            ("daily", 3),
            ("discover", 3),
            ("favorite", 2),
            ("favourite", 2),
            ("hits", 2),
            ("vibes", 2),
            ("chill", 1),
            ("party", 1)
        ]

        return weightedKeywords.reduce(into: 0) { partialResult, keyword in
            if searchableText.contains(keyword.0) {
                partialResult += keyword.1
            }
        }
    }
}
