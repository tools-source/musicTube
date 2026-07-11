import Foundation

struct PlayerSnapshot: Equatable, Sendable {
    var track: Track?
    var currentTime: TimeInterval
    var duration: TimeInterval
    var bufferedTime: TimeInterval
    var isPlaying: Bool
    var isBuffering: Bool
    var hasPrevious: Bool
    var hasNext: Bool
    var shuffleEnabled: Bool
    var repeatMode: PlaybackService.RepeatMode
    var queue: [IndexedTrackPresentation]
    var related: [Track]
    var isLoadingRelated: Bool
    var isLiked: Bool
    var isDownloaded: Bool
    var isDownloading: Bool
    var downloadProgress: Double
    var sleepTimerEndDate: Date?

    static let empty = PlayerSnapshot(
        track: nil,
        currentTime: 0,
        duration: 0,
        bufferedTime: 0,
        isPlaying: false,
        isBuffering: false,
        hasPrevious: false,
        hasNext: false,
        shuffleEnabled: false,
        repeatMode: .off,
        queue: [],
        related: [],
        isLoadingRelated: false,
        isLiked: false,
        isDownloaded: false,
        isDownloading: false,
        downloadProgress: 0,
        sleepTimerEndDate: nil
    )
}
