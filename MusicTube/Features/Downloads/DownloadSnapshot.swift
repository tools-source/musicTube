import Foundation

struct DownloadProgressPresentation: Identifiable, Equatable, Sendable {
    let id: String
    let track: Track
    let progress: Double
    let isPaused: Bool
    let isFailed: Bool
    let bytesDownloaded: Int64
    let totalExpectedBytes: Int64
}

struct DownloadSnapshot: Equatable, Sendable {
    var downloading: [DownloadProgressPresentation]
    var downloaded: [DownloadRecord]
    var folders: [DownloadFolder]
    var selectedFolderID: String?
    var needsAttentionMessage: String?
    var totalDownloadedBytes: Int64
    var nowPlayingKey: String?
    var isPlaying: Bool

    static let empty = DownloadSnapshot(
        downloading: [],
        downloaded: [],
        folders: [],
        selectedFolderID: nil,
        needsAttentionMessage: nil,
        totalDownloadedBytes: 0,
        nowPlayingKey: nil,
        isPlaying: false
    )
}
