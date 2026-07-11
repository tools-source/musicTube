import Foundation

struct LibrarySnapshot: Equatable, Sendable {
    var likedSongs: Playlist?
    var playlists: [Playlist]
    var downloadedCount: Int
    var downloadedArtworkURL: URL?
    var collections: [MusicCollection]
    var history: [Track]
    var isLoading: Bool
    var nowPlayingKey: String?

    static let empty = LibrarySnapshot(
        likedSongs: nil,
        playlists: [],
        downloadedCount: 0,
        downloadedArtworkURL: nil,
        collections: [],
        history: [],
        isLoading: false,
        nowPlayingKey: nil
    )
}
