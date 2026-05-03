import AVFoundation
import Foundation

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

struct DownloadRecord: Codable, Identifiable, Sendable {
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
        let streamURL: URL
        let source: DownloadSource?
        let sourceTrackIndex: Int?
        let queuePosition: Int
    }

    static let shared = DownloadService()
    private let logger: any AppLogging
    private let maxConcurrentActiveDownloads = AppConfig.Downloads.maxConcurrentActiveDownloads

    /// Shared background session identifier — must match the one passed to the
    /// background URLSession so iOS can reconnect events after app relaunch.
    nonisolated static let backgroundSessionIdentifier = "com.musictube.downloads.background"

    nonisolated static var downloadsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("MusicTubeDownloads", isDirectory: true)
    }

    @Published private(set) var downloads: [DownloadRecord] = []
    @Published private(set) var folders: [DownloadFolder] = []
    @Published private(set) var activeDownloads: [String: ActiveDownload] = [:]
    @Published private(set) var lastError: DownloadServiceError?
    @Published private(set) var pendingRequests: [PendingDownloadRequest] = []
    @Published private(set) var preparingSourceIDs: Set<String> = []
    @Published private(set) var resolvingTrackKeys: Set<String> = []

    /// Keyed by track key; stores the underlying URLSessionDownloadTask.
    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    private var pendingDownloads: [PendingDownload] = []
    private var nextQueuePosition = 0
    private var inventoryRefreshTask: Task<Void, Never>?
    private var hasRestoredBackgroundSessionTasks = false

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
        config.allowsCellularAccess = true
        config.timeoutIntervalForResource = 3600  // allow up to 1 hour for very long songs
        config.sessionSendsLaunchEvents = true    // wake app when download completes
        config.isDiscretionary = false            // start immediately, not opportunistically
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
        createDirectoryIfNeeded()
        loadMetadata()
        loadFolders()
        pruneOrphanedRecords()
        migrateSourceFoldersIfNeeded()
        loadPendingRequests()
        refreshDownloadsFromDisk()
        // Touch the session on init so the system can reconnect any in-flight
        // background tasks from a previous app session.
        _ = urlSession
        restoreBackgroundSessionTasks()
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

    func pendingRequestCount(for source: DownloadSource) -> Int {
        pendingRequests.filter {
            $0.source?.id == source.id && !isDownloaded($0.track)
        }.count
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

    func folder(for record: DownloadRecord) -> DownloadFolder? {
        guard let folderID = record.folderID else { return nil }
        return folders.first(where: { $0.id == folderID })
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
            source: source,
            sourceTrackIndex: sourceTrackIndex,
            queuePosition: nextQueuePosition
        )
        nextQueuePosition += 1
        pendingDownloads.append(pending)
        startQueuedDownloadsIfNeeded()
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
        pendingRequests.removeAll { $0.trackKey == key }
        savePendingRequests()
        startQueuedDownloadsIfNeeded()
        logger.debug("Cancelled download for \(track.title)")
    }

    func deleteDownload(_ record: DownloadRecord) {
        do {
            try FileManager.default.removeItem(at: record.localURL)
        } catch {
            lastError = .deletion(error)
        }
        downloads.removeAll { $0.id == record.id }
        saveMetadata()
    }

    func deleteDownload(for track: Track) {
        guard let record = downloadedRecord(for: track) else { return }
        deleteDownload(record)
    }

    func deleteAllDownloads() {
        for (key, task) in downloadTasks {
            taskMetadata.removeValue(forKey: task.taskIdentifier)
            task.cancel()
            downloadTasks.removeValue(forKey: key)
        }
        downloadTasks.removeAll()
        taskMetadata.removeAll()
        pendingDownloads.removeAll()
        activeDownloads.removeAll()
        resolvingTrackKeys.removeAll()

        try? FileManager.default.removeItem(at: Self.downloadsDirectory)
        downloads = []
        folders = []
        pendingRequests = []
        preparingSourceIDs = []
        createDirectoryIfNeeded()
        saveMetadata()
        saveFolders()
        savePendingRequests()
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
        var staleRecords: [DownloadRecord] = []
        let queue = records.compactMap { record in
            if isLocalFileAvailable(for: record) {
                return record.localTrack
            }

            staleRecords.append(record)
            return record.track
        }
        if staleRecords.isEmpty == false {
            removeDownloads(staleRecords, removeFiles: false)
        }
        return queue
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

    private func createDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(
                at: Self.downloadsDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            lastError = .directoryCreation(error)
        }
    }

    private func loadMetadata() {
        guard let data = try? Data(contentsOf: metadataURL),
              let records = try? JSONDecoder().decode([DownloadRecord].self, from: data)
        else { return }
        downloads = records
    }

    private func loadFolders() {
        guard let data = try? Data(contentsOf: foldersURL),
              let decodedFolders = try? JSONDecoder().decode([DownloadFolder].self, from: data)
        else { return }

        folders = decodedFolders.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
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

    private func pruneOrphanedRecords() {
        let available = downloads.filter { isLocalFileAvailable(for: $0) }
        if available.count != downloads.count {
            downloads = available
            saveMetadata()
        }
    }

    private func saveMetadata() {
        do {
            let data = try JSONEncoder().encode(downloads)
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            lastError = .metadataPersistence(error)
        }
    }

    private func saveFolders() {
        do {
            let data = try JSONEncoder().encode(folders)
            try data.write(to: foldersURL, options: .atomic)
        } catch {
            lastError = .folderPersistence(error)
        }
    }

    private func loadPendingRequests() {
        guard let data = try? Data(contentsOf: pendingRequestsURL),
              let requests = try? JSONDecoder().decode([PendingDownloadRequest].self, from: data)
        else { return }
        let downloadedKeys = Set(downloads.map { trackKey($0.track) })
        pendingRequests = requests.filter { !downloadedKeys.contains($0.trackKey) }
    }

    private func savePendingRequests() {
        guard let data = try? JSONEncoder().encode(pendingRequests) else { return }
        try? data.write(to: pendingRequestsURL, options: .atomic)
    }

    private func storedTaskDescription(for pending: PendingDownload) -> String? {
        let metadata = StoredDownloadTaskMetadata(
            key: pending.id,
            track: pending.track,
            source: pending.source,
            sourceTrackIndex: pending.sourceTrackIndex,
            queuePosition: pending.queuePosition
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

    private func isLocalFileAvailable(for record: DownloadRecord) -> Bool {
        guard FileManager.default.fileExists(atPath: record.localURL.path) else {
            return false
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: record.localURL.path)[.size] as? Int64) ?? 0
        return fileSize > 0
    }

    private func removeDownloads(_ records: [DownloadRecord], removeFiles: Bool) {
        for record in records {
            if removeFiles, FileManager.default.fileExists(atPath: record.localURL.path) {
                do {
                    try FileManager.default.removeItem(at: record.localURL)
                } catch {
                    lastError = .deletion(error)
                }
            }
        }

        let recordIDs = Set(records.map(\.id))
        downloads.removeAll { recordIDs.contains($0.id) }
        saveMetadata()
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

    private func startQueuedDownloadsIfNeeded() {
        while activeDownloads.count < maxConcurrentActiveDownloads, pendingDownloads.isEmpty == false {
            let pending = pendingDownloads.removeFirst()
            let key = pending.id

            activeDownloads[key] = ActiveDownload(
                id: key,
                track: pending.track,
                source: pending.source,
                sourceTrackIndex: pending.sourceTrackIndex,
                queuePosition: pending.queuePosition,
                progress: 0,
                isFailed: false
            )
            logger.info("Starting background download for \(pending.track.title)")

            let task = urlSession.downloadTask(with: pending.streamURL)
            task.taskDescription = storedTaskDescription(for: pending)
            taskMetadata[task.taskIdentifier] = (
                key: key,
                track: pending.track,
                source: pending.source,
                sourceTrackIndex: pending.sourceTrackIndex
            )
            downloadTasks[key] = task
            task.resume()
        }
    }

    // MARK: - Delegate-driven completion handlers (called from @MainActor)

    private func handleDownloadFinished(taskID: Int, tempURL: URL, response: URLResponse?) {
        guard let meta = taskMetadata.removeValue(forKey: taskID) else { return }
        let key = meta.key
        let track = meta.track
        let source = meta.source
        let sourceTrackIndex = meta.sourceTrackIndex

        defer {
            activeDownloads.removeValue(forKey: key)
            downloadTasks.removeValue(forKey: key)
            startQueuedDownloadsIfNeeded()
            // Clean up the temp copy if something went wrong.
            try? FileManager.default.removeItem(at: tempURL)
        }

        let fileExtension = preferredExtension(for: response)
        let fileName = "\(key).\(fileExtension)"
        let destURL = Self.downloadsDirectory.appendingPathComponent(fileName)

        do {
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: tempURL, to: destURL)

            let fileSize = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0
            guard fileSize > 0 else {
                try? FileManager.default.removeItem(at: destURL)
                logger.error("Discarded empty download for \(track.title)", error: nil)
                AppContainer.shared.appState?.resumePendingDownloads()
                return
            }

            let folderID = source.map { ensureFolder(for: $0).id }
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
            downloads.append(record)
            saveMetadata()
            pendingRequests.removeAll { $0.trackKey == key }
            savePendingRequests()
            logger.info("Finished background download for \(track.title)")
        } catch {
            lastError = .fileSystem(error)
            logger.error("Failed to move download file for \(track.title)", error: error)
        }
    }

    private func handleProgress(taskID: Int, progress: Double) {
        guard let meta = taskMetadata[taskID] else { return }
        let clamped = min(max(progress, 0), 0.98)
        let previous = activeDownloads[meta.key]?.progress ?? 0
        guard clamped - previous >= 0.01 else { return }
        activeDownloads[meta.key]?.progress = clamped
    }

    private func handleTaskError(taskID: Int, error: Error) {
        guard let meta = taskMetadata.removeValue(forKey: taskID) else { return }
        let key = meta.key
        activeDownloads[key]?.isFailed = true
        activeDownloads.removeValue(forKey: key)
        downloadTasks.removeValue(forKey: key)
        startQueuedDownloadsIfNeeded()
        AppContainer.shared.appState?.resumePendingDownloads()
        logger.error("Background download error for \(meta.track.title)", error: error)
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadService: URLSessionDownloadDelegate {

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
        Task { @MainActor [weak self] in
            self?.handleProgress(taskID: taskID, progress: progress)
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

    /// Called after all background-session events are delivered. We call the system-provided
    /// completion handler so iOS can update the app snapshot and release the wake lock.
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}
