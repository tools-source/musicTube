import Foundation

struct UserInteraction: Codable, Hashable, Sendable, Identifiable {
    let trackId: String
    var skipCount: Int
    var completePlayCount: Int
    var saveCount: Int
    var lastPlayed: Date

    var id: String { trackId }

    init(
        trackId: String,
        skipCount: Int = 0,
        completePlayCount: Int = 0,
        saveCount: Int = 0,
        lastPlayed: Date = .distantPast
    ) {
        self.trackId = trackId
        self.skipCount = skipCount
        self.completePlayCount = completePlayCount
        self.saveCount = saveCount
        self.lastPlayed = lastPlayed
    }
}

@MainActor
final class InteractionTracker {
    static let shared = InteractionTracker()

    private struct StoragePayload: Codable, Sendable {
        var interactionsByTrackID: [String: UserInteraction] = [:]
        var knownTracksByID: [String: Track] = [:]
    }

    private actor PersistenceWriter {
        private let defaults: UserDefaults
        private let storageKey: String
        private var latestGeneration = 0

        init(defaults: UserDefaults, storageKey: String) {
            self.defaults = defaults
            self.storageKey = storageKey
        }

        func persist(_ payload: StoragePayload, generation: Int) {
            guard generation >= latestGeneration else { return }
            latestGeneration = generation
            guard let data = try? JSONEncoder().encode(payload) else { return }
            defaults.set(data, forKey: storageKey)
        }

        func clear(generation: Int) {
            guard generation >= latestGeneration else { return }
            latestGeneration = generation
            defaults.removeObject(forKey: storageKey)
        }
    }

    private static let storageKey = "musictube.interactionTracker.v1"
    private static let maxKnownTrackCount = 600
    private let defaults: UserDefaults
    private let persistenceWriter: PersistenceWriter
    private var interactionsByTrackID: [String: UserInteraction]
    private var knownTracksByID: [String: Track]
    private var knownTrackOrder: [String]
    private var persistenceGeneration = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        persistenceWriter = PersistenceWriter(defaults: defaults, storageKey: Self.storageKey)
        if
            let data = defaults.data(forKey: Self.storageKey),
            let payload = try? JSONDecoder().decode(StoragePayload.self, from: data)
        {
            interactionsByTrackID = payload.interactionsByTrackID
            knownTracksByID = payload.knownTracksByID.filter { Self.hasRecommendationMetadata($0.value) }
        } else if
            let data = defaults.data(forKey: Self.storageKey),
            let legacyInteractions = try? JSONDecoder().decode([String: UserInteraction].self, from: data)
        {
            interactionsByTrackID = legacyInteractions
            knownTracksByID = [:]
        } else {
            interactionsByTrackID = [:]
            knownTracksByID = [:]
        }
        knownTrackOrder = Array(knownTracksByID.keys)
        trimKnownTracksIfNeeded()
    }

    func registerTrack(_ track: Track) {
        guard Self.hasRecommendationMetadata(track) else { return }
        guard storeKnownTrack(track) else { return }
        persist()
    }

    func registerTracks(_ tracks: [Track]) {
        guard tracks.isEmpty == false else { return }
        var didChange = false
        for track in tracks {
            guard Self.hasRecommendationMetadata(track) else { continue }
            didChange = storeKnownTrack(track) || didChange
        }
        guard didChange else { return }
        persist()
    }

    func allInteractions() -> [UserInteraction] {
        Array(interactionsByTrackID.values)
    }

    func clearAllData() {
        interactionsByTrackID.removeAll()
        knownTracksByID.removeAll()
        knownTrackOrder.removeAll()
        defaults.removeObject(forKey: Self.storageKey)
        persistenceGeneration += 1
        let generation = persistenceGeneration
        let persistenceWriter = persistenceWriter
        Task(priority: .utility) {
            await persistenceWriter.clear(generation: generation)
        }
    }

    func logSkip(trackId: String) {
        guard trackId.isEmpty == false else { return }
        updateInteraction(for: trackId) { interaction in
            interaction.skipCount += 1
            interaction.lastPlayed = Date()
        }
    }

    func logCompletePlay(trackId: String) {
        guard trackId.isEmpty == false else { return }
        updateInteraction(for: trackId) { interaction in
            interaction.completePlayCount += 1
            interaction.lastPlayed = Date()
        }
    }

    func logSave(trackId: String) {
        guard trackId.isEmpty == false else { return }
        updateInteraction(for: trackId) { interaction in
            interaction.saveCount += 1
            interaction.lastPlayed = Date()
        }
    }

    func calculateAffinityScore(for trackId: String) -> Double {
        guard let interaction = interactionsByTrackID[trackId] else { return 0 }
        return Self.affinityScore(for: interaction, now: Date())
    }

    func findSimilarContent(targetTrack: Track, fullCatalog: [Track]) -> [Track] {
        guard let targetAcoustics = AcousticVector(track: targetTrack) else { return [] }
        let targetTags = Set(normalizedTags(from: targetTrack.tags))

        return fullCatalog
            .compactMap { candidate -> (track: Track, distance: Double, tagOverlap: Int)? in
                guard candidate.playbackKey != targetTrack.playbackKey else { return nil }
                guard let candidateAcoustics = AcousticVector(track: candidate) else { return nil }

                // Euclidean distance ranks acoustic closeness in a normalized 3D space:
                // tempo is scaled into 0...1, while danceability/energy already live there.
                let tempoDelta = targetAcoustics.normalizedTempo - candidateAcoustics.normalizedTempo
                let danceDelta = targetAcoustics.danceability - candidateAcoustics.danceability
                let energyDelta = targetAcoustics.energy - candidateAcoustics.energy
                let distance = sqrt((tempoDelta * tempoDelta) + (danceDelta * danceDelta) + (energyDelta * energyDelta))
                let tagOverlap = targetTags.intersection(normalizedTags(from: candidate.tags)).count
                return (candidate, distance, tagOverlap)
            }
            .sorted {
                if $0.distance != $1.distance {
                    return $0.distance < $1.distance
                }
                if $0.tagOverlap != $1.tagOverlap {
                    return $0.tagOverlap > $1.tagOverlap
                }
                return $0.track.title.localizedCaseInsensitiveCompare($1.track.title) == .orderedAscending
            }
            .prefix(10)
            .map(\.track)
    }

    func getRecommendationsFromSimilarProfiles(
        userHistory: [UserInteraction],
        globalTrendingTracks: [Track]
    ) -> [Track] {
        let now = Date()
        let listenedTrackIDs = Set(userHistory.map(\.trackId))
        var tagWeights: [String: Double] = [:]

        for interaction in userHistory {
            guard let track = knownTracksByID[interaction.trackId] else { continue }
            let affinity = max(0, Self.affinityScore(for: interaction, now: now))
            guard affinity > 0 else { continue }

            for tag in normalizedTags(from: track.tags) {
                tagWeights[tag, default: 0] += affinity
            }
        }

        guard tagWeights.isEmpty == false else { return [] }
        let preferredTags = Set(
            tagWeights
                .sorted { $0.value > $1.value }
                .prefix(8)
                .map(\.key)
        )

        return globalTrendingTracks
            .filter { listenedTrackIDs.contains($0.playbackKey) == false }
            .map { track -> (track: Track, score: Double) in
                let tags = normalizedTags(from: track.tags)
                // Collaborative filtering is localized here by projecting the user's
                // strongest historical tag weights onto globally trending candidates.
                let tagScore = tags.reduce(0) { $0 + (tagWeights[$1] ?? 0) }
                let overlapBoost = Double(preferredTags.intersection(tags).count) * 1.5
                let popularityBoost = log10(Double(max(track.viewCount ?? 0, 0)) + 10) * 0.05
                return (track, tagScore + overlapBoost + popularityBoost)
            }
            .filter { $0.score > 0 }
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }
                return $0.track.title.localizedCaseInsensitiveCompare($1.track.title) == .orderedAscending
            }
            .prefix(10)
            .map(\.track)
    }

    private func updateInteraction(
        for trackId: String,
        mutate: (inout UserInteraction) -> Void
    ) {
        var interaction = interactionsByTrackID[trackId] ?? UserInteraction(trackId: trackId)
        mutate(&interaction)
        interactionsByTrackID[trackId] = interaction
        persist()
    }

    private func persist() {
        trimKnownTracksIfNeeded()
        let payload = StoragePayload(
            interactionsByTrackID: interactionsByTrackID,
            knownTracksByID: knownTracksByID
        )
        persistenceGeneration += 1
        let generation = persistenceGeneration
        let persistenceWriter = persistenceWriter
        Task(priority: .utility) {
            await persistenceWriter.persist(payload, generation: generation)
        }
    }

    @discardableResult
    private func storeKnownTrack(_ track: Track) -> Bool {
        let key = track.playbackKey
        guard knownTracksByID[key] != track else { return false }
        knownTracksByID[key] = track
        knownTrackOrder.removeAll { $0 == key }
        knownTrackOrder.append(key)
        trimKnownTracksIfNeeded()
        return true
    }

    private func trimKnownTracksIfNeeded() {
        guard knownTrackOrder.count > Self.maxKnownTrackCount else { return }
        let retainedOrder = Array(knownTrackOrder.suffix(Self.maxKnownTrackCount))
        let retainedKeys = Set(retainedOrder)
        knownTracksByID = knownTracksByID.filter { retainedKeys.contains($0.key) }
        knownTrackOrder = retainedOrder
    }

    private static func affinityScore(for interaction: UserInteraction, now: Date) -> Double {
        let saveWeight = 5.0
        let completePlayWeight = 2.0
        let skipPenaltyWeight = 3.0

        // Saves are the strongest explicit positive signal; complete plays show
        // implicit satisfaction; early skips are a negative intent signal.
        let positiveScore = (Double(interaction.saveCount) * saveWeight)
            + (Double(interaction.completePlayCount) * completePlayWeight)
        let negativeScore = Double(interaction.skipCount) * skipPenaltyWeight
        let rawAffinity = positiveScore - negativeScore

        // Exponential time decay keeps recent behavior dominant without throwing
        // away old taste. At 30 days the signal is about 36.8% of its original value.
        let ageInDays = max(0, now.timeIntervalSince(interaction.lastPlayed) / 86_400)
        let decay = exp(-ageInDays / 30)
        return rawAffinity * decay
    }

    private static func hasRecommendationMetadata(_ track: Track) -> Bool {
        track.tags.isEmpty == false
            || track.tempoBPM != nil
            || track.danceability != nil
            || track.energy != nil
    }

    private func normalizedTags(from tags: [String]) -> Set<String> {
        Set(
            tags
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { $0.isEmpty == false }
        )
    }

    private struct AcousticVector {
        let normalizedTempo: Double
        let danceability: Double
        let energy: Double

        init?(track: Track) {
            guard
                let tempoBPM = track.tempoBPM,
                let danceability = track.danceability,
                let energy = track.energy
            else {
                return nil
            }

            // 200 BPM gives a practical upper bound for mainstream music/recitation
            // comparisons while keeping tempo numerically comparable to 0...1 metrics.
            normalizedTempo = min(max(Double(tempoBPM) / 200, 0), 1)
            self.danceability = min(max(danceability, 0), 1)
            self.energy = min(max(energy, 0), 1)
        }
    }
}
