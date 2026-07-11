import Foundation

enum SearchResultTab: String, CaseIterable, Sendable {
    case songs = "Songs"
    case albums = "Albums"
    case artists = "Artists"
}

enum SongSortOption: String, CaseIterable, Sendable {
    case `default` = "Default"
    case unheard = "Unheard"
    case mostViewed = "Most Viewed"
    case shortest = "Shortest"
    case longest = "Longest"
}

struct IndexedTrackPresentation: Identifiable, Equatable, Sendable {
    let index: Int
    let track: Track

    var id: String { track.playbackKey }
}

struct SearchSnapshot: Equatable, Sendable {
    var query: String
    var results: SearchResponse
    var recentSearches: [String]
    var autocompleteSuggestions: [String]
    var suggestedTracks: [IndexedTrackPresentation]
    var visibleSongs: [IndexedTrackPresentation]
    var availableTabs: [SearchResultTab]
    var selectedTab: SearchResultTab
    var sortOption: SongSortOption
    var discoveryArtists: [String]
    var discoveryMixes: [Playlist]
    var nowPlayingKey: String?
    var isPlaying: Bool
    var hasNowPlaying: Bool
    var isSearching: Bool
    var isRecognizingMusic: Bool
    var isLoadingAutocomplete: Bool
    var isLoadingSuggestedTracks: Bool
    var isLoadingMoreSuggestedTracks: Bool
    var isLoadingMoreResults: Bool
    var hasMoreSuggestedTracks: Bool

    static let empty = SearchSnapshot(
        query: "",
        results: .empty,
        recentSearches: [],
        autocompleteSuggestions: [],
        suggestedTracks: [],
        visibleSongs: [],
        availableTabs: SearchResultTab.allCases,
        selectedTab: .songs,
        sortOption: .default,
        discoveryArtists: [],
        discoveryMixes: [],
        nowPlayingKey: nil,
        isPlaying: false,
        hasNowPlaying: false,
        isSearching: false,
        isRecognizingMusic: false,
        isLoadingAutocomplete: false,
        isLoadingSuggestedTracks: false,
        isLoadingMoreSuggestedTracks: false,
        isLoadingMoreResults: false,
        hasMoreSuggestedTracks: true
    )
}
