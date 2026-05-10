import Foundation

/// Calls the configured AI model to generate personalized YouTube search queries
/// based on the user's listening history and taste profile.
/// Falls back silently to empty output when the key is absent or the request fails,
/// so the existing recommendation engine always has the final word.
actor AIRecommendationService {
    static let shared = AIRecommendationService()

    private struct QueryCacheEntry: Sendable {
        let queries: [String]
        let refreshedAt: Date
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = AppConfig.AI.timeoutSeconds
        config.timeoutIntervalForResource = AppConfig.AI.timeoutSeconds
        return URLSession(configuration: config)
    }()
    private let logger: any AppLogging = DefaultAppLogger(category: "AIRecommendationService")

    private var cachedQueriesByProfile: [String: QueryCacheEntry] = [:]
    private var cachedRelatedQueriesByTrack: [String: QueryCacheEntry] = [:]
    private let cacheLifetime: TimeInterval = 600  // 10 min

    // MARK: - Public interface

    /// Returns cached AI-generated queries if fresh, otherwise refetches.
    func queries(for profile: AITasteProfile) async -> [String] {
        guard AppConfig.AI.openAIKey?.isEmpty == false else { return [] }

        let now = Date()
        let cacheKey = cacheKey(for: profile)
        if let cached = cachedQueriesByProfile[cacheKey],
           now.timeIntervalSince(cached.refreshedAt) < cacheLifetime,
           cached.queries.isEmpty == false {
            return cached.queries
        }

        let fresh = await fetchQueries(for: profile)
        if !fresh.isEmpty {
            cachedQueriesByProfile[cacheKey] = QueryCacheEntry(queries: fresh, refreshedAt: now)
        }
        return cachedQueriesByProfile[cacheKey]?.queries ?? []
    }

    /// Generates contextual queries for a specific now-playing track.
    func relatedQueries(for track: AITrackRef, profile: AITasteProfile) async -> [String] {
        guard AppConfig.AI.openAIKey?.isEmpty == false else { return [] }

        let now = Date()
        let cacheKey = relatedCacheKey(for: track, profile: profile)
        if let cached = cachedRelatedQueriesByTrack[cacheKey],
           now.timeIntervalSince(cached.refreshedAt) < cacheLifetime,
           cached.queries.isEmpty == false {
            return cached.queries
        }

        let fresh = await fetchRelatedQueries(for: track, profile: profile)
        if !fresh.isEmpty {
            cachedRelatedQueriesByTrack[cacheKey] = QueryCacheEntry(queries: fresh, refreshedAt: now)
        }
        return cachedRelatedQueriesByTrack[cacheKey]?.queries ?? []
    }

    func invalidateCachedQueries() {
        cachedQueriesByProfile.removeAll()
        cachedRelatedQueriesByTrack.removeAll()
    }

    // MARK: - Private fetch

    private func fetchQueries(for profile: AITasteProfile, limit: Int = 8) async -> [String] {
        guard let key = AppConfig.AI.openAIKey, !key.isEmpty else { return [] }

        var profileLines: [String] = []
        if !profile.topArtists.isEmpty {
            profileLines.append("Top artists: \(profile.topArtists.prefix(6).joined(separator: ", "))")
        }
        if !profile.highAffinityTracks.isEmpty {
            let tracks = profile.highAffinityTracks.prefix(5).map { "\($0.artist) – \($0.title)" }.joined(separator: "; ")
            profileLines.append("Frequently completed songs: \(tracks)")
        }
        if !profile.recentTracks.isEmpty {
            let tracks = profile.recentTracks.prefix(4).map { "\($0.artist) – \($0.title)" }.joined(separator: "; ")
            profileLines.append("Recently played: \(tracks)")
        }
        if !profile.likedArtists.isEmpty {
            profileLines.append("Liked artists: \(profile.likedArtists.prefix(5).joined(separator: ", "))")
        }

        let systemPrompt = """
        You are a music discovery assistant for a YouTube-based music app.
        Generate exactly \(limit) YouTube search queries to help the user find new music they will love.
        Rules:
        - Return ONLY a valid JSON array of strings — no markdown, no explanation, no extra text.
        - Each query is a YouTube search term (e.g. "Fairuz official audio", "Arabic pop 2024", "Um Kulthum songs").
        - Mix specific artist queries with genre/mood queries for variety.
        - Do not repeat artists. Focus on the user's actual taste.
        """

        let userPrompt = profileLines.isEmpty
            ? "Generate \(limit) diverse music discovery queries for a general music listener."
            : "User taste profile:\n\(profileLines.joined(separator: "\n"))\n\nGenerate \(limit) YouTube search queries."

        return await callChatAPI(systemPrompt: systemPrompt, userPrompt: userPrompt, key: key, limit: limit)
    }

    private func fetchRelatedQueries(for track: AITrackRef, profile: AITasteProfile, limit: Int = 4) async -> [String] {
        guard let key = AppConfig.AI.openAIKey, !key.isEmpty else { return [] }

        let systemPrompt = """
        You are a music discovery assistant. Given a song currently playing, suggest related YouTube search queries.
        Return ONLY a valid JSON array of \(limit) strings — no markdown, no explanation.
        Each string is a YouTube search query. Prioritize similar artists, same genre, same era.
        """

        var contextLines = ["Currently playing: \(track.artist) – \(track.title)"]
        if !profile.topArtists.isEmpty {
            contextLines.append("User's top artists: \(profile.topArtists.prefix(4).joined(separator: ", "))")
        }

        let userPrompt = contextLines.joined(separator: "\n") + "\n\nSuggest \(limit) related YouTube search queries."
        return await callChatAPI(systemPrompt: systemPrompt, userPrompt: userPrompt, key: key, limit: limit)
    }

    private func callChatAPI(
        systemPrompt: String,
        userPrompt: String,
        key: String,
        limit: Int
    ) async -> [String] {
        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else { return [] }

        let body: [String: Any] = [
            "model": AppConfig.AI.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "max_tokens": 300,
            "temperature": 0.75
        ]

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("MusicTube", forHTTPHeaderField: "X-Title")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let statusCode = http?.statusCode ?? -1
            guard statusCode == 200 else {
                logger.error("AI query request failed with HTTP \(statusCode)", error: nil)
                return []
            }

            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choices = json["choices"] as? [[String: Any]],
                let message = choices.first?["message"] as? [String: Any],
                let content = message["content"] as? String
            else {
                logger.error("AI query response had an unexpected shape", error: nil)
                return []
            }

            // Parse the JSON array the model returned
            let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if let arrayData = cleaned.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: arrayData) as? [String] {
                return parsed.compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .prefix(limit)
                    .map { $0 }
            }
            logger.error("AI query response could not be parsed as a JSON string array", error: nil)
            return []
        } catch {
            logger.error("AI query request failed", error: error)
            return []
        }
    }

    private func cacheKey(for profile: AITasteProfile) -> String {
        let artists = profile.topArtists.map(normalize).joined(separator: "|")
        let likedArtists = profile.likedArtists.map(normalize).joined(separator: "|")
        let affinity = profile.highAffinityTracks
            .map { "\(normalize($0.artist))::\(normalize($0.title))" }
            .joined(separator: "|")
        let recent = profile.recentTracks
            .map { "\(normalize($0.artist))::\(normalize($0.title))" }
            .joined(separator: "|")
        return [artists, likedArtists, affinity, recent].joined(separator: "||")
    }

    private func relatedCacheKey(for track: AITrackRef, profile: AITasteProfile) -> String {
        [
            normalize(track.artist),
            normalize(track.title),
            cacheKey(for: profile)
        ].joined(separator: "||")
    }

    private func normalize(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

// MARK: - Value types (Sendable, no AppState dependency)

struct AITasteProfile: Sendable {
    let topArtists: [String]
    let likedArtists: [String]
    let highAffinityTracks: [AITrackRef]   // completion rate ≥ 80%
    let recentTracks: [AITrackRef]
}

struct AITrackRef: Sendable {
    let title: String
    let artist: String
}
