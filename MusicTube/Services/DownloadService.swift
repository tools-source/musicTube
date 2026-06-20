import AVFoundation
import Combine
import Foundation
import UserNotifications

struct DownloadSource: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let title: String
    let kind: MusicCollectionKind

    var displayKind: String {
        switch kind {
        case .playlist: return "Playlist"
        case .album: return "Album"
        case .artist: return "Artist"
        }
    }
}

// MARK: - DownloadRecord

struct DownloadRecord: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let track: Track
    let fileName: String
    let downloadedAt: Date
    var fileSizeBytes: Int64
    var folderID: String?
    var source: DownloadSource?
    var sourceTrackIndex: Int?
    var hasCustomFolderSelection: Bool?

    var localURL: URL {
        DownloadService.downloadsDirectory.appendingPathComponent(fileName)
    }

    var localTrack: Track {
        Track(
            id: track.id,
            title: track.title,
            artist: track.artist,
            artworkURL: track.artworkURL,
            duration: track.duration,
            youtubeVideoID: track.youtubeVideoID,
            streamURL: localURL
        )
    }
}

struct DownloadFolder: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    let createdAt: Date
    var sourceID: String?
}

/// A download that has been requested but whose stream URL has not yet been
/// resolved (or whose URLSession task has not yet started). Persisted to disk
/// so that "Download All" jobs survive a force-close or crash.
struct PendingDownloadRequest: Codable, Sendable {
    let trackKey: String
    let track: Track
    let source: DownloadSource?
    let sourceTrackIndex: Int?
    let requestedAt: Date
}

private struct StoredDownloadTaskMetadata: Codable {
    let key: String
    let track: Track
    let source: DownloadSource?
    let sourceTrackIndex: Int?
    let queuePosition: Int
}

// MARK: - ActiveDownload

struct ActiveDownload: Identifiable {
    let id: String
    let track: Track
    let source: DownloadSource?
    let sourceTrackIndex: Int?
    let queuePosition: Int
    var progress: Double
    var isFailed: Bool
    /// True when the user paused this download. The URLSession task is cancelled
    /// (producing resume data) and removed from the running set, freeing a slot for
    /// other downloads, but the entry stays visible in the active list so it can resume.
    var isPaused: Bool = false
    var bytesDownloaded: Int64 = 0
    var totalExpectedBytes: Int64 = 0
    var startedAt: Date = Date()
    /// Exponential-moving-average download speed (bytes/sec). Updated on each
    /// progress threshold crossing; 0 until the first crossing fires.
    var speedBytesPerSec: Double = 0
    /// Timestamp of the last progress-threshold crossing, used to compute delta speed.
    var lastProgressAt: Date = Date()
}

enum DownloadServiceError: LocalizedError {
    case network(Error)
    case missingTemporaryFile
    case fileSystem(Error)
    case directoryCreation(Error)
    case metadataPersistence(Error)
    case folderPersistence(Error)
    case deletion(Error)

    var errorDescription: String? {
        switch self {
        case .network(let error):
            return "Download failed: \(error.localizedDescription)"
        case .missingTemporaryFile:
            return "Download finished without a file to save."
        case .fileSystem(let error):
            return "MusicTube couldn't save the download: \(error.localizedDescription)"
        case .directoryCreation(let error):
            return "MusicTube couldn't create the downloads folder: \(error.localizedDescription)"
        case .metadataPersistence(let error):
            return "MusicTube couldn't save download metadata: \(error.localizedDescription)"
        case .folderPersistence(let error):
            return "MusicTube couldn't save download folders: \(error.localizedDescription)"
        case .deletion(let error):
            return "MusicTube couldn't remove the download: \(error.localizedDescription)"
        }
    }
}

private actor DownloadPersistence {
    private var latestDownloadsSaveGeneration = 0
    private var latestFoldersSaveGeneration = 0
    private var latestPendingRequestsSaveGeneration = 0

    func createDirectoryIfNeeded(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: nil
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(resourceValues)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    func loadDownloads(from url: URL) -> [DownloadRecord] {
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([DownloadRecord].self, from: data) else {
            return []
        }
        return records
    }

    func loadFolders(from url: URL) -> [DownloadFolder] {
        guard let data = try? Data(contentsOf: url),
              let folders = try? JSONDecoder().decode([DownloadFolder].self, from: data) else {
            return []
        }
        return folders
    }

    func loadPendingRequests(from url: URL) -> [PendingDownloadRequest] {
        guard let data = try? Data(contentsOf: url),
              let requests = try? JSONDecoder().decode([PendingDownloadRequest].self, from: data) else {
            return []
        }
        return requests
    }

    func saveDownloads(_ downloads: [DownloadRecord], to url: URL, generation: Int) throws {
        guard generation >= latestDownloadsSaveGeneration else { return }
        latestDownloadsSaveGeneration = generation
        let data = try JSONEncoder().encode(downloads)
        try data.write(to: url, options: .atomic)
    }

    func saveFolders(_ folders: [DownloadFolder], to url: URL, generation: Int) throws {
        guard generation >= latestFoldersSaveGeneration else { return }
        latestFoldersSaveGeneration = generation
        let data = try JSONEncoder().encode(folders)
        try data.write(to: url, options: .atomic)
    }

    func savePendingRequests(_ requests: [PendingDownloadRequest], to url: URL, generation: Int) throws {
        guard generation >= latestPendingRequestsSaveGeneration else { return }
        latestPendingRequestsSaveGeneration = generation
        let data = try JSONEncoder().encode(requests)
        try data.write(to: url, options: .atomic)
    }

    func deleteItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func deleteDirectory(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    func moveItemReplacing(sourceURL: URL, destinationURL: URL) throws -> Int64 {
        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        return (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? 0
    }
}

// MARK: - DownloadService

@MainActor
final class DownloadService: NSObject, ObservableObject {
    private struct RefreshedInventory {
        let records: [DownloadRecord]
        let didChange: Bool
        let recordIDs: [String]
    }

    private struct PendingDownload: Identifiable {
        let id: String
        let track: Track
        let streamURL: URL?
        let resumeData: Data?
        let source: DownloadSource?
        let sourceTrackIndex: Int?
        let queuePosition: Int
    }

    static let shared = DownloadService()
    private let logger: any AppLogging
    private let maxConcurrentActiveDownloads = AppConfig.Downloads.maxConcurrentActiveDownloads
    private let dataUsageSettings = DataUsageSettings.shared
    private let networkMonitor = NetworkMonitor.shared

    /// Shared background session identifier — must match the one passed to the
    /// background URLSession so iOS can reconnect events after app relaunch.
    nonisolated static let backgroundSessionIdentifier = "com.musictube.downloads.background"

    nonisolated static var downloadsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("MusicTubeDownloads", isDirectory: true)
    }

    @Published private(set) var downloads: [DownloadRecord] = []
    @Published private(set) var folders: [DownloadFolder] = []
    @Published private(set) var activeDownloads: [String: ActiveDownload] = [:] {
        didSet {
            Task { await NetworkLogger.shared.updateDownloadQueueSize(activeDownloads.count) }
        }
    }
    @Published private(set) var lastError: DownloadServiceError?
    @Published private(set) var pendingRequests: [PendingDownloadRequest] = []
    @Published private(set) var preparingSourceIDs: Set<String> = []
    @Published private(set) var resolvingTrackKeys: Set<String> = []

    private let persistence = DownloadPersistence()
    /// Keyed by track key; stores the underlying URLSessionDownloadTask. Only holds
    /// RUNNING tasks — a paused download is removed from here (its slot is freed).
    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    /// Resume data captured when a download is paused, keyed by track key. Used to
    /// continue the transfer from where it left off (no re-download, no corruption).
    private var pausedResumeData: [String: Data] = [:]
    /// Original stream URL per active download, so a paused transfer can restart from
    /// scratch if the server didn't return resume data.
    private var activeStreamURLs: [String: URL] = [:]
    private var pendingDownloads: [PendingDownload] = []
    private var nextQueuePosition = 0
    /// Titles of downloads completed since the queue was last idle. Lets a single
    /// "downloads finished" notification summarise a whole batch instead of firing
    /// once per song.
    private var completedDownloadTitlesSinceIdle: [String] = []
    private var downloadFinishedNotifyTask: Task<Void, Never>?
    private static let downloadFinishedNotificationCategory = "musictube.downloadFinished"
    /// Read by the notification delegate to route a tap to the Downloads tab.
    /// `nonisolated` because the `UNUserNotificationCenterDelegate` callback that reads
    /// these compile-time constants runs outside the main actor.
    nonisolated static let downloadFinishedNavigationKey = "navigate"
    nonisolated static let downloadFinishedNavigationValue = "downloads"
    private var inventoryRefreshTask: Task<Void, Never>?
    private var downloadRefreshCycleTask: Task<Void, Never>?
    private var hasRestoredBackgroundSessionTasks = false
    private var downloadsSaveGeneration = 0
    private var foldersSaveGeneration = 0
    private var pendingRequestsSaveGeneration = 0
    private var policyCancellables: Set<AnyCancellable> = []
    private var policySuspendedDownloadKeys: Set<String> = []
    private let downloadRefreshCycleIntervalNanoseconds: UInt64 = 10_000_000_000

    /// Maps URLSessionTask.taskIdentifier → (trackKey, Track, DownloadSource?) so delegate
    /// callbacks (which only know the task) can find the relevant track metadata.
    private var taskMetadata: [Int: (key: String, track: Track, source: DownloadSource?, sourceTrackIndex: Int?)] = [:]

    /// Called by the AppDelegate after iOS delivers background-session events so the
    /// system knows we've finished processing them.
    var backgroundCompletionHandler: (() -> Void)?

    /// Background URLSession — transfers survive screen lock and app backgrounding.
    /// Uses a delegate queue so callbacks arrive off the main thread; all mutations are
    /// dispatched back to the @MainActor via Task { @MainActor in }.
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: Self.backgroundSessionIdentifier
        )
        // Per-request policy is applied when each task is created. Keeping the session
        // permissive allows a Settings change to take effect without rebuilding the
        // background session (which would disconnect restored tasks).
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 3600
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.networkServiceType = .responsiveData
        config.httpMaximumConnectionsPerHost = maxConcurrentActiveDownloads
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private var metadataURL: URL {
        Self.downloadsDirectory.appendingPathComponent("metadata.json")
    }

    private var foldersURL: URL {
        Self.downloadsDirectory.appendingPathComponent("folders.json")
    }

    private var pendingRequestsURL: URL {
        Self.downloadsDirectory.appendingPathComponent("pending_requests.json")
    }

    init(logger: any AppLogging = DefaultAppLogger(category: "DownloadService")) {
        self.logger = logger
        super.init()
        Task { @MainActor [weak self] in
            await self?.bootstrapFromDisk()
        }
        // Touch the session on init so the system can reconnect any in-flight
        // background tasks from a previous app session.
        _ = urlSession
        restoreBackgroundSessionTasks()
        observeDownloadPolicy()
    }

    func isDownloaded(_ track: Track) -> Bool {
        let key = trackKey(track)
        return downloads.contains { trackKey($0.track) == key }
    }

    func isDownloading(_ track: Track) -> Bool {
        let key = trackKey(track)
        return activeDownloads[key] != nil
            || pendingDownloads.contains(where: { $0.id == key })
            || resolvingTrackKeys.contains(key)
    }

    func downloadProgress(for track: Track) -> Double {
        activeDownloads[trackKey(track)]?.progress ?? 0
    }

    func downloadedRecord(for track: Track) -> DownloadRecord? {
        let key = trackKey(track)
        return downloads.first { trackKey($0.track) == key }
    }

    var availableDownloads: [DownloadRecord] {
        return downloads
    }

    func downloads(in folderID: String?) -> [DownloadRecord] {
        return downloads.filter { $0.folderID == folderID }
    }

    func downloads(for sourceID: String) -> [DownloadRecord] {
        return downloads.filter { $0.source?.id == sourceID }
    }

    var downloadSources: [DownloadSource] {
        let grouped = Dictionary(grouping: downloads) { $0.source }
        return grouped.keys
            .compactMap { $0 }
            .sorted { lhs, rhs in
                lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    func isDownloading(source: DownloadSource) -> Bool {
        preparingSourceIDs.contains(source.id)
            || activeDownloads.values.contains { $0.source?.id == source.id }
            || pendingDownloads.contains { $0.source?.id == source.id }
            || pendingRequests.contains {
                $0.source?.id == source.id && !isDownloaded($0.track)
            }
    }

    func downloadCount(for source: DownloadSource) -> Int {
        downloads(for: source.id).count
    }

    func downloadCount(for source: DownloadSource, matching tracks: [Track]) -> Int {
        guard tracks.isEmpty == false else { return downloadCount(for: source) }
        return tracks.reduce(0) { count, track in
            count + (isDownloaded(track) ? 1 : 0)
        }
    }

    func pendingRequestCount(for source: DownloadSource) -> Int {
        pendingRequests.filter {
            $0.source?.id == source.id && !isDownloaded($0.track)
        }.count
    }

    func aggregateProgress(for source: DownloadSource, totalCount: Int) -> Double {
        guard totalCount > 0 else { return 0 }
        let completedCount = downloads(for: source.id).count
        let activeProgress = activeDownloads.values
            .filter { $0.source?.id == source.id }
            .reduce(0) { $0 + $1.progress }
        return min(max((Double(completedCount) + activeProgress) / Double(totalCount), 0), 1)
    }

    func aggregateProgress(for source: DownloadSource, totalCount: Int, matching tracks: [Track]) -> Double {
        guard tracks.isEmpty == false else {
            return aggregateProgress(for: source, totalCount: totalCount)
        }

        let resolvedTotalCount = max(totalCount, tracks.count)
        guard resolvedTotalCount > 0 else { return 0 }

        let completedCount = downloadCount(for: source, matching: tracks)
        let activeProgress = activeDownloads.values
            .filter { $0.source?.id == source.id }
            .reduce(0) { $0 + $1.progress }
        return min(max((Double(completedCount) + activeProgress) / Double(resolvedTotalCount), 0), 1)
    }

    func hasPendingRequest(_ request: PendingDownloadRequest) -> Bool {
        pendingRequests.contains { $0.trackKey == request.trackKey }
    }

    func isPreparing(source: DownloadSource) -> Bool {
        preparingSourceIDs.contains(source.id)
    }

    func beginPreparingSource(_ source: DownloadSource) {
        preparingSourceIDs.insert(source.id)
    }

    func finishPreparingSource(_ source: DownloadSource) {
        preparingSourceIDs.remove(source.id)
    }

    func beginResolvingDownload(for track: Track) {
        resolvingTrackKeys.insert(trackKey(track))
    }

    func finishResolvingDownload(for track: Track) {
        resolvingTrackKeys.remove(trackKey(track))
    }

    func addPendingRequest(_ request: PendingDownloadRequest) {
        guard !pendingRequests.contains(where: { $0.trackKey == request.trackKey }) else { return }
        guard !isDownloaded(request.track) else { return }
        pendingRequests.append(request)
        savePendingRequests()
    }

    var pendingRequestsNeedingProcessing: [PendingDownloadRequest] {
        guard hasRestoredBackgroundSessionTasks else { return [] }
        return pendingRequests.filter { req in
            !isDownloaded(req.track) && !isDownloading(req.track)
        }
    }

    var availableRunningDownloadSlots: Int {
        max(AppPowerBudget.activeDownloadLimit(default: maxConcurrentActiveDownloads) - downloadTasks.count, 0)
    }

    func folder(for record: DownloadRecord) -> DownloadFolder? {
        guard let folderID = record.folderID else { return nil }
        return folders.first(where: { $0.id == folderID })
    }

    func artworkURL(for folderID: String?) -> URL? {
        downloads
            .filter { $0.folderID == folderID }
            .sorted { lhs, rhs in
                switch (lhs.sourceTrackIndex, rhs.sourceTrackIndex) {
                case let (lhsIndex?, rhsIndex?) where lhsIndex != rhsIndex:
                    return lhsIndex < rhsIndex
                default:
                    return lhs.downloadedAt < rhs.downloadedAt
                }
            }
            .compactMap { $0.track.artworkURL }
            .first
    }

    func startDownload(
        track: Track,
        streamURL: URL,
        source: DownloadSource? = nil,
        sourceTrackIndex: Int? = nil
    ) {
        let key = trackKey(track)
        guard activeDownloads[key] == nil, !isDownloaded(track) else { return }
        guard pendingDownloads.contains(where: { $0.id == key }) == false else { return }

        lastError = nil
        if let source {
            _ = ensureFolder(for: source)
        }

        let pending = PendingDownload(
            id: key,
            track: track,
            streamURL: streamURL,
            resumeData: nil,
            source: source,
            sourceTrackIndex: sourceTrackIndex,
            queuePosition: nextQueuePosition
        )
        nextQueuePosition += 1
        pendingDownloads.append(pending)
        startQueuedDownloadsIfNeeded()
        startDownloadRefreshCycleIfNeeded()
    }

    func cancelDownload(for track: Track) {
        let key = trackKey(track)
        pendingDownloads.removeAll { $0.id == key }
        if let task = downloadTasks[key] {
            // Remove from metadata before cancelling so the error delegate doesn't fire.
            taskMetadata.removeValue(forKey: task.taskIdentifier)
            task.cancel()
        }
        downloadTasks.removeValue(forKey: key)
        activeDownloads.removeValue(forKey: key)
        pausedResumeData.removeValue(forKey: key)
        activeStreamURLs.removeValue(forKey: key)
        resolvingTrackKeys.remove(key)
        pendingRequests.removeAll { $0.trackKey == key }
        savePendingRequests()
        startQueuedDownloadsIfNeeded()
        stopDownloadRefreshCycleIfIdle()
        logger.info("[Download] cancelled=\(track.title) active=\(activeDownloads.count) queued=\(pendingDownloads.count)")
    }

    /// True if this track is actively downloading but paused by the user.
    func isPaused(_ track: Track) -> Bool {
        activeDownloads[trackKey(track)]?.isPaused == true
    }

    /// Pauses an in-flight download. The URLSession task is cancelled while producing
    /// resume data so the partial transfer is preserved (no corruption), and its slot
    /// is freed so other queued/active downloads can use the bandwidth.
    func pauseDownload(for track: Track) {
        let key = trackKey(track)
        guard let task = downloadTasks[key], activeDownloads[key]?.isPaused != true else { return }

        // Reflect the paused state immediately for the UI.
        activeDownloads[key]?.isPaused = true
        // Drop the metadata so the cancellation does not fire the failure delegate.
        taskMetadata.removeValue(forKey: task.taskIdentifier)
        downloadTasks.removeValue(forKey: key)

        task.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data { self.pausedResumeData[key] = data }
                // A slot just freed up — let other queued downloads start.
                self.startQueuedDownloadsIfNeeded()
                self.stopDownloadRefreshCycleIfIdle()
            }
        })
        logger.info("[Download] paused=\(track.title) running=\(downloadTasks.count)")
    }

    /// Resumes a paused download, continuing from the captured resume data when the
    /// server supports it, or restarting from the original stream URL otherwise.
    func resumeDownload(for track: Track) {
        let key = trackKey(track)
        guard var entry = activeDownloads[key], entry.isPaused else { return }

        let resumeData = pausedResumeData.removeValue(forKey: key)
        let streamURL = activeStreamURLs[key]
        guard resumeData != nil || streamURL != nil else {
            // Nothing to resume from — re-queue through the normal pending path.
            activeDownloads.removeValue(forKey: key)
            AppContainer.shared.appState?.resumePendingDownloads()
            return
        }

        entry.isPaused = false
        activeDownloads[key] = entry

        let pending = PendingDownload(
            id: key,
            track: entry.track,
            streamURL: streamURL,
            resumeData: resumeData,
            source: entry.source,
            sourceTrackIndex: entry.sourceTrackIndex,
            queuePosition: entry.queuePosition
        )
        pendingDownloads.removeAll { $0.id == key }
        pendingDownloads.insert(pending, at: 0)
        startQueuedDownloadsIfNeeded()
        startDownloadRefreshCycleIfNeeded()
        logger.info("[Download] resume queued=\(track.title) running=\(downloadTasks.count)")
    }

    func cancelDownloads(for source: DownloadSource) {
        preparingSourceIDs.remove(source.id)
        pendingDownloads.removeAll { $0.source?.id == source.id }

        let activeKeys = activeDownloads.values
            .filter { $0.source?.id == source.id }
            .map(\.id)

        for key in activeKeys {
            if let task = downloadTasks[key] {
                taskMetadata.removeValue(forKey: task.taskIdentifier)
                task.cancel()
            }
            downloadTasks.removeValue(forKey: key)
            activeDownloads.removeValue(forKey: key)
            pausedResumeData.removeValue(forKey: key)
            activeStreamURLs.removeValue(forKey: key)
            resolvingTrackKeys.remove(key)
        }

        let resolvingKeys = pendingRequests
            .filter { $0.source?.id == source.id }
            .map(\.trackKey)
        resolvingKeys.forEach { resolvingTrackKeys.remove($0) }
        pendingRequests.removeAll { $0.source?.id == source.id }
        savePendingRequests()
        startQueuedDownloadsIfNeeded()
        stopDownloadRefreshCycleIfIdle()
        logger.debug("Cancelled downloads for \(source.title)")
    }

    func deleteDownload(_ record: DownloadRecord) {
        removeFileIfNeeded(at: record.localURL, mapError: DownloadServiceError.deletion)
        downloads.removeAll { $0.id == record.id }
        saveMetadata()
    }

    func deleteDownload(for track: Track) {
        guard let record = downloadedRecord(for: track) else { return }
        deleteDownload(record)
    }

    /// Cancels all active and pending downloads without deleting already-downloaded files.
    func cancelAllDownloads() {
        for (key, task) in downloadTasks {
            taskMetadata.removeValue(forKey: task.taskIdentifier)
            task.cancel()
            downloadTasks.removeValue(forKey: key)
        }
        downloadTasks.removeAll()
        taskMetadata.removeAll()
        pausedResumeData.removeAll()
        activeStreamURLs.removeAll()
        pendingDownloads.removeAll()
        activeDownloads.removeAll()
        resolvingTrackKeys.removeAll()
        policySuspendedDownloadKeys.removeAll()
        pendingRequests = []
        preparingSourceIDs = []
        savePendingRequests()
        stopDownloadRefreshCycleIfIdle()
    }

    func deleteAllDownloads() async {
        for (key, task) in downloadTasks {
            taskMetadata.removeValue(forKey: task.taskIdentifier)
            task.cancel()
            downloadTasks.removeValue(forKey: key)
        }
        downloadTasks.removeAll()
        taskMetadata.removeAll()
        pausedResumeData.removeAll()
        activeStreamURLs.removeAll()
        pendingDownloads.removeAll()
        activeDownloads.removeAll()
        resolvingTrackKeys.removeAll()
        policySuspendedDownloadKeys.removeAll()
        downloads = []
        folders = []
        pendingRequests = []
        preparingSourceIDs = []

        do {
            try await persistence.deleteDirectory(at: Self.downloadsDirectory)
            try await persistence.createDirectoryIfNeeded(at: Self.downloadsDirectory)
            downloadsSaveGeneration += 1
            foldersSaveGeneration += 1
            pendingRequestsSaveGeneration += 1
            try await persistence.saveDownloads([], to: metadataURL, generation: downloadsSaveGeneration)
            try await persistence.saveFolders([], to: foldersURL, generation: foldersSaveGeneration)
            try await persistence.savePendingRequests([], to: pendingRequestsURL, generation: pendingRequestsSaveGeneration)
        } catch {
            lastError = .deletion(error)
        }
    }

    func createFolder(named name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false else { return }

        let folder = DownloadFolder(
            id: "download-folder-\(UUID().uuidString)",
            name: trimmedName,
            createdAt: Date(),
            sourceID: nil
        )

        folders.insert(folder, at: 0)
        saveFolders()
    }

    func renameFolder(_ folder: DownloadFolder, to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false else { return }
        guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }

        folders[index].name = trimmedName
        saveFolders()
    }

    func deleteFolder(_ folder: DownloadFolder) {
        let recordsInFolder = downloads.filter { $0.folderID == folder.id }
        removeDownloads(recordsInFolder, removeFiles: true)
        folders.removeAll { $0.id == folder.id }
        saveFolders()
    }

    func moveFolder(id draggedFolderID: String, to targetFolderID: String) {
        guard draggedFolderID != targetFolderID,
              let sourceIndex = folders.firstIndex(where: { $0.id == draggedFolderID }),
              let targetIndex = folders.firstIndex(where: { $0.id == targetFolderID }) else {
            return
        }

        var reorderedFolders = folders
        let movedFolder = reorderedFolders.remove(at: sourceIndex)
        reorderedFolders.insert(movedFolder, at: targetIndex)
        folders = reorderedFolders
        saveFolders()
    }

    func moveDownload(_ record: DownloadRecord, to folderID: String?) {
        guard let index = downloads.firstIndex(where: { $0.id == record.id }) else { return }
        downloads[index].folderID = folderID
        downloads[index].hasCustomFolderSelection = true
        saveMetadata()
    }

    func ensureFolder(for source: DownloadSource) -> DownloadFolder {
        if let existingFolder = folder(for: source) {
            return existingFolder
        }

        let folder = DownloadFolder(
            id: "download-folder-\(UUID().uuidString)",
            name: source.title.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: Date(),
            sourceID: source.id
        )

        folders.insert(folder, at: 0)
        saveFolders()
        return folder
    }

    func playbackQueue(from records: [DownloadRecord]) -> [Track] {
        records.map(\.localTrack)
    }

    func refreshDownloadsFromDisk() {
        inventoryRefreshTask?.cancel()

        let snapshot = downloads
        inventoryRefreshTask = Task { [weak self] in
            let refreshed = await Task.detached(priority: .utility) {
                Self.refreshInventory(for: snapshot)
            }.value

            guard let self else { return }
            guard Task.isCancelled == false else { return }
            guard self.downloads.map(\.id) == refreshed.recordIDs else { return }

            if refreshed.didChange {
                self.downloads = refreshed.records
                self.saveMetadata()
            }
        }
    }

    var totalDownloadedBytes: Int64 {
        downloads.reduce(0) { $0 + $1.fileSizeBytes }
    }

    var totalDownloadedMB: Double {
        Double(totalDownloadedBytes) / 1_048_576
    }

    // MARK: - Private helpers

    private func trackKey(_ track: Track) -> String {
        track.youtubeVideoID ?? track.id
    }

    private func preferredExtension(for response: URLResponse?) -> String {
        guard let mime = response?.mimeType else { return "m4a" }
        if mime.contains("webm") { return "webm" }
        if mime.contains("mp4") || mime.contains("m4a") { return "m4a" }
        return "m4a"
    }

    private func bootstrapFromDisk() async {
        do {
            try await persistence.createDirectoryIfNeeded(at: Self.downloadsDirectory)
        } catch {
            lastError = .directoryCreation(error)
            return
        }

        downloads = await persistence.loadDownloads(from: metadataURL)
        folders = await persistence.loadFolders(from: foldersURL)

        let downloadedKeys = Set(downloads.map { trackKey($0.track) })
        pendingRequests = await persistence.loadPendingRequests(from: pendingRequestsURL)
            .filter { !downloadedKeys.contains($0.trackKey) }

        migrateSourceFoldersIfNeeded()
        refreshDownloadsFromDisk()
    }

    private func migrateSourceFoldersIfNeeded() {
        var didChangeFolders = false
        var didChangeDownloads = false

        for source in uniqueDownloadSources {
            let folder = existingOrNewFolder(for: source, didChangeFolders: &didChangeFolders)

            for index in downloads.indices where downloads[index].source?.id == source.id {
                let hasCustomFolderSelection = downloads[index].hasCustomFolderSelection ?? false
                if hasCustomFolderSelection {
                    continue
                }

                if downloads[index].folderID != folder.id {
                    downloads[index].folderID = folder.id
                    didChangeDownloads = true
                }

                if downloads[index].hasCustomFolderSelection != false {
                    downloads[index].hasCustomFolderSelection = false
                    didChangeDownloads = true
                }
            }
        }

        if didChangeFolders {
            saveFolders()
        }

        if didChangeDownloads {
            saveMetadata()
        }
    }

    private func saveMetadata() {
        let snapshot = downloads
        let url = metadataURL
        downloadsSaveGeneration += 1
        let generation = downloadsSaveGeneration

        Task { [weak self, persistence] in
            do {
                try await persistence.saveDownloads(snapshot, to: url, generation: generation)
            } catch {
                await MainActor.run {
                    guard let self, self.downloadsSaveGeneration == generation else { return }
                    self.lastError = .metadataPersistence(error)
                }
            }
        }
    }

    private func saveFolders() {
        let snapshot = folders
        let url = foldersURL
        foldersSaveGeneration += 1
        let generation = foldersSaveGeneration

        Task { [weak self, persistence] in
            do {
                try await persistence.saveFolders(snapshot, to: url, generation: generation)
            } catch {
                await MainActor.run {
                    guard let self, self.foldersSaveGeneration == generation else { return }
                    self.lastError = .folderPersistence(error)
                }
            }
        }
    }

    private func savePendingRequests() {
        let snapshot = pendingRequests
        let url = pendingRequestsURL
        pendingRequestsSaveGeneration += 1
        let generation = pendingRequestsSaveGeneration

        Task { [weak self, persistence] in
            do {
                try await persistence.savePendingRequests(snapshot, to: url, generation: generation)
            } catch {
                await MainActor.run {
                    guard let self, self.pendingRequestsSaveGeneration == generation else { return }
                    self.lastError = .metadataPersistence(error)
                }
            }
        }
    }

    private func removeFileIfNeeded(
        at url: URL,
        mapError: @escaping (Error) -> DownloadServiceError
    ) {
        Task { [weak self, persistence] in
            do {
                try await persistence.deleteItem(at: url)
            } catch {
                let nsError = error as NSError
                guard nsError.domain != NSCocoaErrorDomain || nsError.code != NSFileNoSuchFileError else {
                    return
                }
                await MainActor.run {
                    self?.lastError = mapError(error)
                }
            }
        }
    }

    private func storedTaskDescription(for pending: PendingDownload) -> String? {
        storedTaskDescription(
            key: pending.id,
            track: pending.track,
            source: pending.source,
            sourceTrackIndex: pending.sourceTrackIndex,
            queuePosition: pending.queuePosition
        )
    }

    private func storedTaskDescription(
        key: String,
        track: Track,
        source: DownloadSource?,
        sourceTrackIndex: Int?,
        queuePosition: Int
    ) -> String? {
        let metadata = StoredDownloadTaskMetadata(
            key: key,
            track: track,
            source: source,
            sourceTrackIndex: sourceTrackIndex,
            queuePosition: queuePosition
        )
        guard let data = try? JSONEncoder().encode(metadata) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func storedTaskMetadata(from taskDescription: String?) -> StoredDownloadTaskMetadata? {
        guard
            let taskDescription,
            let data = taskDescription.data(using: .utf8)
        else {
            return nil
        }
        return try? JSONDecoder().decode(StoredDownloadTaskMetadata.self, from: data)
    }

    private func restoreBackgroundSessionTasks() {
        urlSession.getAllTasks { [weak self] tasks in
            Task { @MainActor [weak self] in
                guard let self else { return }

                var restoredActiveDownloads: [String: ActiveDownload] = [:]
                var restoredDownloadTasks: [String: URLSessionDownloadTask] = [:]
                var restoredTaskMetadata: [Int: (key: String, track: Track, source: DownloadSource?, sourceTrackIndex: Int?)] = [:]
                var highestQueuePosition = self.nextQueuePosition

                for case let task as URLSessionDownloadTask in tasks {
                    guard let metadata = self.storedTaskMetadata(from: task.taskDescription) else { continue }

                    restoredTaskMetadata[task.taskIdentifier] = (
                        key: metadata.key,
                        track: metadata.track,
                        source: metadata.source,
                        sourceTrackIndex: metadata.sourceTrackIndex
                    )
                    restoredDownloadTasks[metadata.key] = task
                    restoredActiveDownloads[metadata.key] = ActiveDownload(
                        id: metadata.key,
                        track: metadata.track,
                        source: metadata.source,
                        sourceTrackIndex: metadata.sourceTrackIndex,
                        queuePosition: metadata.queuePosition,
                        progress: 0,
                        isFailed: false
                    )
                    highestQueuePosition = max(highestQueuePosition, metadata.queuePosition + 1)
                }

                self.taskMetadata = restoredTaskMetadata
                self.downloadTasks = restoredDownloadTasks
                self.activeDownloads = restoredActiveDownloads
                self.nextQueuePosition = highestQueuePosition
                self.hasRestoredBackgroundSessionTasks = true
                AppContainer.shared.appState?.resumePendingDownloads()
            }
        }
    }

    private func removeDownloads(_ records: [DownloadRecord], removeFiles: Bool) {
        if removeFiles {
            for record in records {
                removeFileIfNeeded(at: record.localURL, mapError: DownloadServiceError.deletion)
            }
        }

        let recordIDs = Set(records.map(\.id))
        downloads.removeAll { recordIDs.contains($0.id) }
        saveMetadata()
    }

    private func upsertCompletedDownload(
        _ record: DownloadRecord,
        trackKey key: String,
        replacingDestination destinationURL: URL
    ) {
        if let existingIndex = downloads.firstIndex(where: { trackKey($0.track) == key }) {
            let existing = downloads[existingIndex]
            if existing.localURL != destinationURL {
                removeFileIfNeeded(at: existing.localURL, mapError: DownloadServiceError.deletion)
            }

            let preservesCustomFolder = existing.hasCustomFolderSelection == true
            let updatedRecord = DownloadRecord(
                id: existing.id,
                track: record.track,
                fileName: record.fileName,
                downloadedAt: record.downloadedAt,
                fileSizeBytes: record.fileSizeBytes,
                folderID: preservesCustomFolder ? existing.folderID : record.folderID,
                source: record.source,
                sourceTrackIndex: record.sourceTrackIndex,
                hasCustomFolderSelection: preservesCustomFolder
            )
            downloads[existingIndex] = updatedRecord
        } else {
            downloads.append(record)
        }
    }

    nonisolated private static func refreshInventory(for records: [DownloadRecord]) -> RefreshedInventory {
        var refreshedRecords: [DownloadRecord] = []
        var didChange = false

        for var record in records {
            let path = record.localURL.path
            guard
                let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                let fileSize = attributes[.size] as? Int64,
                fileSize > 0
            else {
                didChange = true
                continue
            }

            if record.fileSizeBytes != fileSize {
                record.fileSizeBytes = fileSize
                didChange = true
            }

            refreshedRecords.append(record)
        }

        return RefreshedInventory(
            records: refreshedRecords,
            didChange: didChange,
            recordIDs: records.map(\.id)
        )
    }

    private var uniqueDownloadSources: [DownloadSource] {
        let grouped = Dictionary(grouping: downloads.compactMap(\.source)) { $0.id }
        return grouped.values
            .compactMap(\.first)
            .sorted { lhs, rhs in
                lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    private func folder(for source: DownloadSource) -> DownloadFolder? {
        folders.first(where: { $0.sourceID == source.id })
    }

    private func existingOrNewFolder(
        for source: DownloadSource,
        didChangeFolders: inout Bool
    ) -> DownloadFolder {
        if let existingFolder = folder(for: source) {
            return existingFolder
        }

        let folder = DownloadFolder(
            id: "download-folder-\(UUID().uuidString)",
            name: source.title.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: Date(),
            sourceID: source.id
        )
        folders.insert(folder, at: 0)
        didChangeFolders = true
        return folder
    }

    private func startDownloadRefreshCycleIfNeeded() {
        guard downloadRefreshCycleTask == nil else { return }
        guard downloadTasks.isEmpty == false || pendingDownloads.isEmpty == false else { return }

        downloadRefreshCycleTask = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(nanoseconds: self?.downloadRefreshCycleIntervalNanoseconds ?? 10_000_000_000)
                guard let self, Task.isCancelled == false else { return }

                self.refreshRunningDownloads()

                if self.downloadTasks.isEmpty, self.pendingDownloads.isEmpty {
                    self.downloadRefreshCycleTask = nil
                    return
                }
            }
        }
    }

    private func stopDownloadRefreshCycleIfIdle() {
        guard downloadTasks.isEmpty, pendingDownloads.isEmpty else { return }
        downloadRefreshCycleTask?.cancel()
        downloadRefreshCycleTask = nil
    }

    private func refreshRunningDownloads() {
        for (key, task) in Array(downloadTasks) {
            guard let entry = activeDownloads[key],
                  entry.isPaused == false,
                  entry.progress < 0.98 else {
                continue
            }

            refreshRunningDownload(key: key, task: task, entry: entry)
        }
    }

    private func refreshRunningDownload(
        key: String,
        task: URLSessionDownloadTask,
        entry: ActiveDownload
    ) {
        taskMetadata.removeValue(forKey: task.taskIdentifier)
        downloadTasks.removeValue(forKey: key)

        task.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.activeDownloads[key] != nil,
                      self.isDownloaded(entry.track) == false else {
                    self.pausedResumeData.removeValue(forKey: key)
                    self.startQueuedDownloadsIfNeeded()
                    self.stopDownloadRefreshCycleIfIdle()
                    return
                }

                let pending = PendingDownload(
                    id: key,
                    track: entry.track,
                    streamURL: self.activeStreamURLs[key],
                    resumeData: data,
                    source: entry.source,
                    sourceTrackIndex: entry.sourceTrackIndex,
                    queuePosition: entry.queuePosition
                )
                self.pendingDownloads.removeAll { $0.id == key }
                self.pendingDownloads.insert(pending, at: 0)
                self.startQueuedDownloadsIfNeeded()
                self.stopDownloadRefreshCycleIfIdle()
                self.logger.info("[Download] refreshed running transfer=\(entry.track.title)")
            }
        })
    }

    private func startQueuedDownloadsIfNeeded() {
        guard dataUsageSettings.canDownload(onCellular: networkMonitor.isCellular) else { return }
        // Gate on the number of RUNNING tasks, not activeDownloads.count — paused
        // entries remain in activeDownloads but have freed their slot, so they must
        // not block queued downloads from starting.
        let activeLimit = AppPowerBudget.activeDownloadLimit(default: maxConcurrentActiveDownloads)
        while downloadTasks.count < activeLimit, pendingDownloads.isEmpty == false {
            let pending = pendingDownloads.removeFirst()
            let key = pending.id

            if var existing = activeDownloads[key] {
                existing.isPaused = false
                existing.isFailed = false
                activeDownloads[key] = existing
            } else {
                activeDownloads[key] = ActiveDownload(
                    id: key,
                    track: pending.track,
                    source: pending.source,
                    sourceTrackIndex: pending.sourceTrackIndex,
                    queuePosition: pending.queuePosition,
                    progress: 0,
                    isFailed: false
                )
            }
            logger.info("[Download] active=\(activeDownloads.count) queued=\(pendingDownloads.count) starting=\(pending.track.title)")

            let task: URLSessionDownloadTask
            if let resumeData = pending.resumeData {
                task = urlSession.downloadTask(withResumeData: resumeData)
            } else if let streamURL = pending.streamURL {
                task = urlSession.downloadTask(with: downloadRequest(for: streamURL))
            } else {
                activeDownloads.removeValue(forKey: key)
                continue
            }
            task.taskDescription = storedTaskDescription(for: pending)
            taskMetadata[task.taskIdentifier] = (
                key: key,
                track: pending.track,
                source: pending.source,
                sourceTrackIndex: pending.sourceTrackIndex
            )
            downloadTasks[key] = task
            if let streamURL = pending.streamURL {
                activeStreamURLs[key] = streamURL
            }
            task.priority = URLSessionTask.highPriority
            task.resume()
        }

        startDownloadRefreshCycleIfNeeded()
    }

    private func downloadRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        let allowsCellular = dataUsageSettings.allowDownloadOnCellular && !dataUsageSettings.dataSaverMode
        request.allowsCellularAccess = allowsCellular
        request.allowsExpensiveNetworkAccess = allowsCellular
        request.allowsConstrainedNetworkAccess = !dataUsageSettings.dataSaverMode
        return request
    }

    private func observeDownloadPolicy() {
        Publishers.CombineLatest3(
            dataUsageSettings.$dataSaverMode,
            dataUsageSettings.$allowDownloadOnCellular,
            networkMonitor.$isCellular
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _, _, _ in
            guard let self else { return }
            self.applyDownloadPolicy()
        }
        .store(in: &policyCancellables)
    }

    private func applyDownloadPolicy() {
        let isAllowed = dataUsageSettings.canDownload(onCellular: networkMonitor.isCellular)
        if isAllowed {
            for key in policySuspendedDownloadKeys {
                downloadTasks[key]?.resume()
            }
            policySuspendedDownloadKeys.removeAll()
            startQueuedDownloadsIfNeeded()
            return
        }

        for (key, task) in downloadTasks where task.state == .running {
            task.suspend()
            policySuspendedDownloadKeys.insert(key)
        }
    }

    // MARK: - Delegate-driven completion handlers (called from @MainActor)

    private func handleDownloadFinished(taskID: Int, tempURL: URL, response: URLResponse?) {
        guard let meta = taskMetadata.removeValue(forKey: taskID) else { return }
        let key = meta.key
        let track = meta.track
        let source = meta.source
        let sourceTrackIndex = meta.sourceTrackIndex

        let fileExtension = preferredExtension(for: response)
        let fileName = "\(key).\(fileExtension)"
        let destURL = Self.downloadsDirectory.appendingPathComponent(fileName)

        Task { [weak self, persistence] in
            let moveResult: Result<Int64, Error>
            do {
                try await persistence.createDirectoryIfNeeded(at: Self.downloadsDirectory)
                let fileSize = try await persistence.moveItemReplacing(
                    sourceURL: tempURL,
                    destinationURL: destURL
                )
                moveResult = .success(fileSize)
            } catch {
                moveResult = .failure(error)
            }

            await MainActor.run {
                guard let self else { return }

                defer {
                    self.activeDownloads.removeValue(forKey: key)
                    self.downloadTasks.removeValue(forKey: key)
                    self.pausedResumeData.removeValue(forKey: key)
                    self.activeStreamURLs.removeValue(forKey: key)
                    self.startQueuedDownloadsIfNeeded()
                    AppContainer.shared.appState?.resumePendingDownloads()
                    self.stopDownloadRefreshCycleIfIdle()
                    self.removeFileIfNeeded(at: tempURL, mapError: DownloadServiceError.fileSystem)
                }

                switch moveResult {
                case .success(let fileSize):
                    guard fileSize > 0 else {
                        self.removeFileIfNeeded(at: destURL, mapError: DownloadServiceError.fileSystem)
                        self.logger.error("Discarded empty download for \(track.title)", error: nil)
                        return
                    }

                    let folderID = source.map { self.ensureFolder(for: $0).id }
                    let record = DownloadRecord(
                        id: UUID().uuidString,
                        track: track,
                        fileName: fileName,
                        downloadedAt: Date(),
                        fileSizeBytes: fileSize,
                        folderID: folderID,
                        source: source,
                        sourceTrackIndex: sourceTrackIndex,
                        hasCustomFolderSelection: false
                    )
                    self.upsertCompletedDownload(
                        record,
                        trackKey: key,
                        replacingDestination: destURL
                    )
                    self.saveMetadata()
                    self.pendingRequests.removeAll { $0.trackKey == key }
                    self.savePendingRequests()
                    self.registerCompletedDownloadForNotification(track.title)
                    AppReviewPrompter.shared.recordDownloadCompleted()
                    self.logger.info("[Download] completed=\(track.title) active=\(self.activeDownloads.count) queued=\(self.pendingDownloads.count)")

                case .failure(let error):
                    self.lastError = .fileSystem(error)
                    self.logger.error("Failed to move download file for \(track.title)", error: error)
                }
            }
        }
    }

    // MARK: - Completion notifications

    /// Records a finished download and (re)arms a short debounce. The notification is
    /// only posted once the queue has fully drained, so a "Download All" batch produces
    /// a single summary alert rather than one per track.
    private func registerCompletedDownloadForNotification(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        completedDownloadTitlesSinceIdle.append(trimmed.isEmpty ? "1 song" : trimmed)

        downloadFinishedNotifyTask?.cancel()
        downloadFinishedNotifyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self, Task.isCancelled == false else { return }

            // Wait until nothing is in flight or queued before announcing completion.
            guard self.activeDownloads.isEmpty,
                  self.pendingDownloads.isEmpty,
                  self.pendingRequests.isEmpty else { return }

            let titles = self.completedDownloadTitlesSinceIdle
            self.completedDownloadTitlesSinceIdle = []
            guard titles.isEmpty == false else { return }
            await self.postDownloadsFinishedNotification(titles: titles)
        }
    }

    private func postDownloadsFinishedNotification(titles: [String]) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
            || settings.authorizationStatus == .ephemeral else {
            return
        }

        let content = UNMutableNotificationContent()
        content.sound = .default
        content.categoryIdentifier = Self.downloadFinishedNotificationCategory
        content.userInfo = [Self.downloadFinishedNavigationKey: Self.downloadFinishedNavigationValue]

        if titles.count == 1 {
            content.title = "Download complete"
            content.body = "\"\(titles[0])\" is ready to play offline."
        } else {
            content.title = "Downloads complete"
            content.body = "\(titles.count) songs are ready to play offline."
        }

        let request = UNNotificationRequest(
            identifier: "musictube.downloadFinished.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    private func handleProgress(
        taskID: Int,
        progress: Double,
        bytesDownloaded: Int64,
        totalExpectedBytes: Int64
    ) {
        guard let meta = taskMetadata[taskID] else { return }
        let clamped = min(max(progress, 0), 0.98)
        let previous = activeDownloads[meta.key]?.progress ?? 0
        guard clamped - previous >= 0.005 else { return }   // 0.5% threshold

        // Single atomic copy-modify-store so @Published fires exactly once per
        // filtered tick instead of three separate times (progress + bytes fields).
        if var entry = activeDownloads[meta.key] {
            // Rolling-average speed — weight recent deltas more heavily than the
            // lifetime average (which gets diluted by background-suspension gaps).
            let timeDelta = Date().timeIntervalSince(entry.lastProgressAt)
            let bytesDelta = max(0, bytesDownloaded - entry.bytesDownloaded)
            if timeDelta >= 0.1, bytesDelta > 0 {
                let instant = Double(bytesDelta) / timeDelta
                entry.speedBytesPerSec = entry.speedBytesPerSec > 0
                    ? entry.speedBytesPerSec * 0.6 + instant * 0.4   // EMA α = 0.4
                    : instant
                entry.lastProgressAt = Date()
            }
            entry.progress = clamped
            entry.bytesDownloaded = bytesDownloaded
            entry.totalExpectedBytes = totalExpectedBytes
            activeDownloads[meta.key] = entry
        }
        logger.debug("[Download] active=\(activeDownloads.count) progress=\(Int(clamped * 100))%")
    }

    private func handleTaskError(taskID: Int, error: Error) {
        guard let meta = taskMetadata.removeValue(forKey: taskID) else { return }
        let key = meta.key
        activeDownloads[key]?.isFailed = true
        activeDownloads.removeValue(forKey: key)
        downloadTasks.removeValue(forKey: key)
        pausedResumeData.removeValue(forKey: key)
        activeStreamURLs.removeValue(forKey: key)
        pendingDownloads.removeAll { $0.id == key }
        resolvingTrackKeys.remove(key)
        pendingRequests.removeAll { $0.trackKey == key }
        savePendingRequests()
        startQueuedDownloadsIfNeeded()
        AppContainer.shared.appState?.resumePendingDownloads()
        stopDownloadRefreshCycleIfIdle()
        logger.error("Background download error for \(meta.track.title)", error: error)
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadService: URLSessionDownloadDelegate {

    nonisolated func urlSession(
        _ session: URLSession,
        taskIsWaitingForConnectivity task: URLSessionTask
    ) {
        let taskID = task.taskIdentifier
        Task { @MainActor [weak self] in
            guard let self, let meta = self.taskMetadata[taskID] else { return }
            self.logger.info("[Download] waiting for connectivity=\(meta.track.title)")
        }
    }

    /// Called on the session's delegate queue (NOT on MainActor) when a download finishes.
    /// We immediately copy the temp file to a stable location because iOS deletes it the
    /// moment this method returns.
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Move to a temp path we own before the system reclaims `location`.
        let safeCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: safeCopy)
        } catch {
            // If the move fails the file is gone — nothing we can do.
            return
        }

        let taskID = downloadTask.taskIdentifier
        let response = downloadTask.response
        Task { @MainActor [weak self] in
            self?.handleDownloadFinished(taskID: taskID, tempURL: safeCopy, response: response)
        }
    }

    /// Periodic progress updates — called off the main thread.
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let taskID = downloadTask.taskIdentifier
        // DispatchQueue.main is more reliable than RunLoop.main during background execution.
        Task { @MainActor [weak self] in
            self?.handleProgress(
                taskID: taskID,
                progress: progress,
                bytesDownloaded: totalBytesWritten,
                totalExpectedBytes: totalBytesExpectedToWrite
            )
        }
    }

    /// Called when a task finishes with an error (network failure, cancellation, etc.).
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }  // success path handled in didFinishDownloadingTo
        // Ignore cancellation errors — we triggered those ourselves in cancelDownload().
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }

        let taskID = task.taskIdentifier
        Task { @MainActor [weak self] in
            self?.handleTaskError(taskID: taskID, error: error)
        }
    }

    /// Called after all background-session events are delivered. Calls the system
    /// completion handler so iOS can update the app snapshot and release the wake lock.
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            await AppContainer.shared.appState?.resumePendingDownloadsForBackgroundEvents()
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}
