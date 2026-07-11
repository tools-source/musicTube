import Foundation

struct RecommendationRequest: Sendable {
    let candidates: [Track]
    let recentTracks: [Track]
    let likedTracks: [Track]
    let savedTracks: [Track]
    let dislikedTrackIDs: Set<String>
    let preferences: UserPreferenceProfile
    let focusedTrack: Track?
    let excludedTrackIDs: Set<String>
    let limit: Int

    init(
        candidates: [Track],
        recentTracks: [Track],
        likedTracks: [Track],
        savedTracks: [Track] = [],
        dislikedTrackIDs: Set<String>,
        preferences: UserPreferenceProfile,
        focusedTrack: Track?,
        excludedTrackIDs: Set<String> = [],
        limit: Int
    ) {
        self.candidates = candidates
        self.recentTracks = recentTracks
        self.likedTracks = likedTracks
        self.savedTracks = savedTracks
        self.dislikedTrackIDs = dislikedTrackIDs
        self.preferences = preferences
        self.focusedTrack = focusedTrack
        self.excludedTrackIDs = excludedTrackIDs
        self.limit = max(0, limit)
    }
}

actor RecommendationEngine {
    static let shared = RecommendationEngine()
    private var resultCache: [String: [Track]] = [:]

    func recommendations(for request: RecommendationRequest) -> [Track] {
        guard request.limit > 0 else { return [] }
        let key = cacheKey(for: request)
        if let cached = resultCache[key] { return cached }

        let focusedContext = request.focusedTrack?.listeningContentContext
        let focusedIsQuran = request.focusedTrack?.isQuranOrRecitation
        let recentIDs = Set(request.recentTracks.map(\.playbackKey))
        let likedIDs = Set(request.likedTracks.map(\.playbackKey))
        let savedIDs = Set(request.savedTracks.map(\.playbackKey))
        let likedArtists = frequencyMap(request.likedTracks.map(\.artist))
        let savedArtists = frequencyMap(request.savedTracks.map(\.artist))
        let recentArtists = frequencyMap(request.recentTracks.map(\.artist))
        let preferenceTokens = Set(
            request.preferences.normalizedKeywords.flatMap { SearchTextNormalizer.tokens(from: $0) }
        )

        var seenIDs = request.excludedTrackIDs
        var seenSignatures: Set<String> = []
        var ranked: [(track: Track, score: Double, ordinal: Int)] = []

        for (ordinal, track) in request.candidates.enumerated() {
            let id = track.playbackKey
            guard request.dislikedTrackIDs.contains(id) == false else { continue }
            guard recentIDs.contains(id) == false else { continue }
            guard seenIDs.insert(id).inserted else { continue }

            let signature = contentSignature(for: track)
            guard seenSignatures.insert(signature).inserted else { continue }
            guard isContextCompatible(track, focusedContext: focusedContext, focusedIsQuran: focusedIsQuran) else {
                continue
            }

            let artistKey = SearchTextNormalizer.normalized(track.artist)
            let candidateTokens = Set(SearchTextNormalizer.tokens(from: "\(track.artist) \(track.title) \(track.tags.joined(separator: " "))"))
            let preferenceOverlap = preferenceTokens.intersection(candidateTokens).count
            var score = Double(likedArtists[artistKey, default: 0]) * 4
            score += Double(savedArtists[artistKey, default: 0]) * 3
            score += Double(recentArtists[artistKey, default: 0]) * 1.5
            score += Double(preferenceOverlap) * 1.25
            if likedIDs.contains(id) { score += 6 }
            if savedIDs.contains(id) { score += 5 }
            if let focusedTrack = request.focusedTrack,
               artistKey == SearchTextNormalizer.normalized(focusedTrack.artist) {
                score += 8
            }
            score += contextScore(candidate: track, focusedTrack: request.focusedTrack)
            ranked.append((track, score, ordinal))
        }

        let result = ranked
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.ordinal < $1.ordinal
            }
            .prefix(request.limit)
            .map(\.track)
        resultCache[key] = result
        trimCacheIfNeeded()
        return result
    }

    private func frequencyMap(_ artists: [String]) -> [String: Int] {
        artists.reduce(into: [:]) { result, artist in
            let key = SearchTextNormalizer.normalized(artist)
            guard key.isEmpty == false else { return }
            result[key, default: 0] += 1
        }
    }

    private func contentSignature(for track: Track) -> String {
        let title = SearchTextNormalizer.normalized(track.title)
        let artist = SearchTextNormalizer.normalized(track.artist)
        let durationBucket = track.duration.map { String(Int(($0 / 2).rounded())) } ?? "?"
        return "\(title)|\(artist)|\(durationBucket)"
    }

    private func isContextCompatible(
        _ candidate: Track,
        focusedContext: ListeningContentContext?,
        focusedIsQuran: Bool?
    ) -> Bool {
        if let focusedIsQuran {
            return candidate.isQuranOrRecitation == focusedIsQuran
        }

        guard let focusedContext, focusedContext != .unknown else { return true }
        let candidateContext = candidate.listeningContentContext
        guard candidateContext != .unknown else { return true }

        switch (focusedContext, candidateContext) {
        case (.music, .religious), (.religious, .music):
            return false
        default:
            return true
        }
    }

    private func contextScore(candidate: Track, focusedTrack: Track?) -> Double {
        guard let focusedTrack else { return 0 }
        var score = 0.0
        let focusedContext = focusedTrack.listeningContentContext
        let candidateContext = candidate.listeningContentContext
        if focusedContext != .unknown, candidateContext == focusedContext {
            score += 3
        }

        let focusedArabic = containsArabic(focusedTrack.title + " " + focusedTrack.artist)
        let candidateArabic = containsArabic(candidate.title + " " + candidate.artist)
        if focusedArabic == candidateArabic {
            score += 2
        } else {
            score -= 1
        }

        let focusedTokens = Set(SearchTextNormalizer.tokens(from: focusedTrack.title))
        let candidateTokens = Set(SearchTextNormalizer.tokens(from: candidate.title))
        score += Double(focusedTokens.intersection(candidateTokens).count) * 0.75
        return score
    }

    private func containsArabic(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            (0x0600...0x06FF).contains($0.value) || (0x0750...0x077F).contains($0.value)
        }
    }

    private func cacheKey(for request: RecommendationRequest) -> String {
        let values = [
            request.candidates.map(\.playbackKey).joined(separator: ","),
            request.recentTracks.map(\.playbackKey).joined(separator: ","),
            request.likedTracks.map(\.playbackKey).joined(separator: ","),
            request.savedTracks.map(\.playbackKey).joined(separator: ","),
            request.dislikedTrackIDs.sorted().joined(separator: ","),
            request.excludedTrackIDs.sorted().joined(separator: ","),
            request.preferences.normalizedKeywords.joined(separator: ","),
            request.focusedTrack?.playbackKey ?? "",
            String(request.limit)
        ]
        return values.joined(separator: "|")
    }

    private func trimCacheIfNeeded() {
        while resultCache.count > 32, let key = resultCache.keys.first {
            resultCache.removeValue(forKey: key)
        }
    }
}
