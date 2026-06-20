import Foundation
import OSLog

/// Lightweight internal telemetry for network and cache activity.
/// Writes to the unified logging subsystem only — never stores PII or sends data off-device.
/// The debug accessor `NetworkLogger.snapshot` is gated to DEBUG builds.
actor NetworkLogger {
    static let shared = NetworkLogger()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MusicTube", category: "NetworkMetrics")

    private(set) var apiRequestCount: Int = 0
    private(set) var cacheHits: Int = 0
    private(set) var cacheMisses: Int = 0
    private(set) var downloadQueueSize: Int = 0
    private(set) var syncEventCount: Int = 0

    private init() {}

    func recordAPIRequest(endpoint: String) {
        apiRequestCount += 1
        logger.debug("api_request endpoint=\(endpoint, privacy: .private) total=\(self.apiRequestCount, privacy: .public)")
    }

    func recordCacheHit(key: String) {
        cacheHits += 1
        logger.debug("cache_hit key=\(key, privacy: .private) ratio=\(self.hitRatio, privacy: .public)")
    }

    func recordCacheMiss(key: String) {
        cacheMisses += 1
        logger.debug("cache_miss key=\(key, privacy: .private) ratio=\(self.hitRatio, privacy: .public)")
    }

    func updateDownloadQueueSize(_ count: Int) {
        downloadQueueSize = count
        logger.debug("download_queue size=\(count, privacy: .public)")
    }

    func recordSyncEvent(description: String) {
        syncEventCount += 1
        logger.info("sync event=\(description, privacy: .private) total=\(self.syncEventCount, privacy: .public)")
    }

    private var hitRatio: String {
        let total = cacheHits + cacheMisses
        guard total > 0 else { return "n/a" }
        return String(format: "%.1f%%", Double(cacheHits) / Double(total) * 100)
    }

    // MARK: Debug Snapshot (DEBUG builds only)

#if DEBUG
    struct Snapshot: Sendable {
        let apiRequests: Int
        let cacheHits: Int
        let cacheMisses: Int
        let downloadQueueSize: Int
        let syncEvents: Int
        var cacheHitRatio: Double {
            let total = cacheHits + cacheMisses
            guard total > 0 else { return 0 }
            return Double(cacheHits) / Double(total)
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            apiRequests: apiRequestCount,
            cacheHits: cacheHits,
            cacheMisses: cacheMisses,
            downloadQueueSize: downloadQueueSize,
            syncEvents: syncEventCount
        )
    }
#endif
}
