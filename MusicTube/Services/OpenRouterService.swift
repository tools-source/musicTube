import Foundation
import OSLog

/// Optional taste-aware curation routed through a developer-controlled backend.
///
/// No provider credential is stored in the app. When the endpoint is absent, invalid,
/// or disabled by the listener, the caller's deterministic recommendation order remains
/// the source of truth.
actor OpenRouterService {
    struct TasteSignals: Codable, Sendable, Hashable {
        var topArtists: [String]
        var lovedTracks: [String]
        var recentSearches: [String]
        var preferenceKeywords: [String]
        var skippedArtists: [String]
        var focusedTrack: String?

        var isEmpty: Bool {
            topArtists.isEmpty
                && lovedTracks.isEmpty
                && recentSearches.isEmpty
                && preferenceKeywords.isEmpty
                && focusedTrack == nil
        }
    }

    struct TrackBrief: Codable, Sendable, Equatable {
        let id: String
        let title: String
        let artist: String
    }

    struct RerankResult: Sendable, Equatable {
        let orderedIDs: [String]
        let blurb: String?

        static let empty = RerankResult(orderedIDs: [], blurb: nil)
    }

    private enum Operation: String, Encodable {
        case seed
        case rerank
    }

    private struct CurationRequest: Encodable {
        let operation: Operation
        let signals: TasteSignals
        let candidates: [TrackBrief]?
    }

    private struct CurationResponse: Decodable {
        var queries: [String]?
        var order: [String]?
        var blurb: String?
    }

    private let endpoint: URL?
    private let session: URLSession
    private let logger = Logger(subsystem: "MusicTube", category: "AICuration")
    private var cachedSeeds: (signature: Int, date: Date, queries: [String])?
    private let cacheTTL = AppConfig.AICuration.cacheTTL

    init(
        endpoint: URL? = AppConfig.AICuration.endpointURL,
        session: URLSession? = nil
    ) {
        self.endpoint = endpoint

        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = AppConfig.AICuration.requestTimeout
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func suggestedSeedQueries(for signals: TasteSignals) async -> [String] {
        guard signals.isEmpty == false else { return [] }

        let signature = signals.hashValue
        if let cachedSeeds,
           cachedSeeds.signature == signature,
           Date().timeIntervalSince(cachedSeeds.date) < cacheTTL {
            return cachedSeeds.queries
        }

        guard let response = await request(
            CurationRequest(operation: .seed, signals: signals, candidates: nil)
        ) else {
            return []
        }

        let queries = (response.queries ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .reduce(into: [String]()) { unique, query in
                if unique.contains(where: { $0.caseInsensitiveCompare(query) == .orderedSame }) == false {
                    unique.append(query)
                }
            }
        let limited = Array(queries.prefix(AppConfig.AICuration.maxSeedQueries))
        cachedSeeds = (signature, Date(), limited)
        return limited
    }

    func rerank(_ candidates: [TrackBrief], for signals: TasteSignals) async -> RerankResult {
        guard candidates.count > 1 else { return .empty }

        let pool = Array(candidates.prefix(AppConfig.AICuration.maxRerankCandidates))
        guard let response = await request(
            CurationRequest(operation: .rerank, signals: signals, candidates: pool)
        ) else {
            return .empty
        }

        let validIDs = Set(pool.map(\.id))
        let order = (response.order ?? []).filter { validIDs.contains($0) }
        let blurb = response.blurb?.trimmingCharacters(in: .whitespacesAndNewlines)
        return RerankResult(orderedIDs: order, blurb: blurb?.isEmpty == false ? blurb : nil)
    }

    private func request(_ payload: CurationRequest) async -> CurationResponse? {
        guard let endpoint else { return nil }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = AppConfig.AICuration.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppConfig.AICuration.clientVersion, forHTTPHeaderField: "X-MusicTube-Client-Version")

        do {
            request.httpBody = try JSONEncoder().encode(payload)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  data.count <= AppConfig.AICuration.maxResponseBytes else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                logger.error("AI curation proxy HTTP \(code, privacy: .public)")
                return nil
            }
            return try JSONDecoder().decode(CurationResponse.self, from: data)
        } catch {
            if (error as? URLError)?.code != .cancelled {
                logger.error("AI curation proxy failed: \(error.localizedDescription, privacy: .private)")
            }
            return nil
        }
    }
}
