import Foundation

struct HomeSnapshot: Equatable, Sendable {
    var continueListening: [Track]
    var madeForYou: [IndexedTrackPresentation]
    var recentlyPlayed: [Track]
    var mixes: [Playlist]
    var contextualTracks: [Track]
    var statusMessage: String?
    var recommendationBlurb: String?
    var nowPlayingKey: String?
    var isPlaying: Bool
    var isLoading: Bool
    var hasLoaded: Bool
    var displayName: String?

    static let empty = HomeSnapshot(
        continueListening: [],
        madeForYou: [],
        recentlyPlayed: [],
        mixes: [],
        contextualTracks: [],
        statusMessage: nil,
        recommendationBlurb: nil,
        nowPlayingKey: nil,
        isPlaying: false,
        isLoading: false,
        hasLoaded: false,
        displayName: nil
    )
}
