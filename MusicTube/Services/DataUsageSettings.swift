import Combine
import Foundation

/// Persisted user preferences that gate network access patterns.
/// All reads/writes are on the app's private UserDefaults suite.
/// Changes automatically publish through Combine so downstream services can react.
final class DataUsageSettings: ObservableObject {
    static let shared = DataUsageSettings()

    private enum Key: String {
        case dataSaverMode         = "DataUsage.dataSaverMode"
        case allowStreamOnCellular = "DataUsage.allowStreamOnCellular"
        case allowDownloadOnCellular = "DataUsage.allowDownloadOnCellular"
        case highQualityOnWiFiOnly = "DataUsage.highQualityOnWiFiOnly"
        case autoSyncOnWiFiOnly    = "DataUsage.autoSyncOnWiFiOnly"
        case personalizedAICuration = "Privacy.personalizedAICuration"
    }

    private let defaults: UserDefaults

    // MARK: Published Settings

    @Published var dataSaverMode: Bool {
        didSet { defaults.set(dataSaverMode, forKey: Key.dataSaverMode.rawValue) }
    }

    /// When false, the app refuses to start any audio stream on a cellular connection.
    @Published var allowStreamOnCellular: Bool {
        didSet { defaults.set(allowStreamOnCellular, forKey: Key.allowStreamOnCellular.rawValue) }
    }

    /// When false, background URLSession tasks are blocked from running over cellular.
    @Published var allowDownloadOnCellular: Bool {
        didSet { defaults.set(allowDownloadOnCellular, forKey: Key.allowDownloadOnCellular.rawValue) }
    }

    /// When true, stream/artwork quality is reduced on cellular regardless of allowStreamOnCellular.
    @Published var highQualityOnWiFiOnly: Bool {
        didSet { defaults.set(highQualityOnWiFiOnly, forKey: Key.highQualityOnWiFiOnly.rawValue) }
    }

    /// When true, library syncs (liked songs, playlists) are deferred until a Wi-Fi connection is available.
    @Published var autoSyncOnWiFiOnly: Bool {
        didSet { defaults.set(autoSyncOnWiFiOnly, forKey: Key.autoSyncOnWiFiOnly.rawValue) }
    }

    /// Explicit opt-in. When enabled, compact taste signals are sent to the configured
    /// MusicTube curation backend. This defaults to false for every installation.
    @Published var personalizedAICuration: Bool {
        didSet { defaults.set(personalizedAICuration, forKey: Key.personalizedAICuration.rawValue) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        dataSaverMode         = defaults.bool(forKey: Key.dataSaverMode.rawValue)
        allowStreamOnCellular = defaults.object(forKey: Key.allowStreamOnCellular.rawValue) == nil
            ? true
            : defaults.bool(forKey: Key.allowStreamOnCellular.rawValue)
        allowDownloadOnCellular = defaults.object(forKey: Key.allowDownloadOnCellular.rawValue) == nil
            ? true
            : defaults.bool(forKey: Key.allowDownloadOnCellular.rawValue)
        highQualityOnWiFiOnly = defaults.bool(forKey: Key.highQualityOnWiFiOnly.rawValue)
        autoSyncOnWiFiOnly    = defaults.bool(forKey: Key.autoSyncOnWiFiOnly.rawValue)
        personalizedAICuration = defaults.bool(forKey: Key.personalizedAICuration.rawValue)
    }

    // MARK: Computed Policy

    /// True if any network restriction is active (useful for coarse-grained feature gating).
    var isRestrictedMode: Bool {
        dataSaverMode || highQualityOnWiFiOnly
    }

    /// Returns whether a download task should be allowed to use cellular given current settings
    /// and the observed network state.
    func canDownload(onCellular isCellular: Bool) -> Bool {
        guard !dataSaverMode else { return false }
        if isCellular { return allowDownloadOnCellular }
        return true
    }

    /// Returns whether audio streaming is permitted given current settings and network state.
    func canStream(onCellular isCellular: Bool) -> Bool {
        if isCellular { return allowStreamOnCellular }
        return true
    }

    func resetToDefaults() {
        dataSaverMode = false
        allowStreamOnCellular = true
        allowDownloadOnCellular = true
        highQualityOnWiFiOnly = false
        autoSyncOnWiFiOnly = false
        personalizedAICuration = false
    }
}
