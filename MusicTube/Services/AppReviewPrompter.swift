import Combine
import StoreKit
import UIKit

@MainActor
final class AppReviewPrompter: ObservableObject {
    static let shared = AppReviewPrompter()

    @Published var isShowingPrePrompt = false

    private let defaults: UserDefaults
    private let firstLaunchDateKey = "musictube.review.firstLaunchDate"
    private let launchCountKey = "musictube.review.launchCount"
    private let playbackCountKey = "musictube.review.successfulPlaybackCount"
    private let completedDownloadCountKey = "musictube.review.completedDownloadCount"
    private let significantEventCountKey = "musictube.review.significantEventCount"
    private let lastPromptDateKey = "musictube.review.lastPromptDate"
    private let promptedVersionKey = "musictube.review.promptedVersion"
    private let optedOutKey = "musictube.review.optedOut"
    private let nextEligibleLaunchCountKey = "musictube.review.nextEligibleLaunchCount"
    private let laterUntilDateKey = "musictube.review.laterUntilDate"

    private let minimumLaunches = 3
    private let minimumPlaybacks = 5
    private let minimumCompletedDownloads = 1
    private let minimumDaysSinceFirstLaunch: TimeInterval = 24 * 60 * 60
    private let promptCooldown: TimeInterval = 90 * 24 * 60 * 60
    private let laterCooldown: TimeInterval = 14 * 24 * 60 * 60
    private let laterLaunchDelay = 3
    private var hasPendingEligiblePrompt = false

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func recordAppLaunch() {
        if defaults.object(forKey: firstLaunchDateKey) == nil {
            defaults.set(Date(), forKey: firstLaunchDateKey)
        }

        defaults.set(defaults.integer(forKey: launchCountKey) + 1, forKey: launchCountKey)
        markEligibleIfNeeded()
    }

    func recordPlaybackStarted() {
        defaults.set(defaults.integer(forKey: playbackCountKey) + 1, forKey: playbackCountKey)
        markEligibleIfNeeded()
    }

    func recordDownloadCompleted() {
        defaults.set(defaults.integer(forKey: completedDownloadCountKey) + 1, forKey: completedDownloadCountKey)
        markEligibleIfNeeded()
    }

    func recordSignificantEvent() {
        defaults.set(defaults.integer(forKey: significantEventCountKey) + 1, forKey: significantEventCountKey)
        markEligibleIfNeeded()
    }

    func evaluatePresentation(
        isPlaybackActive: Bool,
        isPlayerPresented: Bool,
        hasActiveDownloads: Bool
    ) {
        guard hasPendingEligiblePrompt else {
            markEligibleIfNeeded()
            return
        }
        guard isShowingPrePrompt == false else { return }
        guard isPlaybackActive == false, isPlayerPresented == false, hasActiveDownloads == false else { return }

        isShowingPrePrompt = true
        hasPendingEligiblePrompt = false
    }

    func requestNativeReview() {
        isShowingPrePrompt = false

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            return
        }

        SKStoreReviewController.requestReview(in: scene)
        defaults.set(Date(), forKey: lastPromptDateKey)
        defaults.set(currentAppVersion, forKey: promptedVersionKey)
        defaults.set(0, forKey: significantEventCountKey)
    }

    func remindLater() {
        isShowingPrePrompt = false
        hasPendingEligiblePrompt = false
        defaults.set(Date().addingTimeInterval(laterCooldown), forKey: laterUntilDateKey)
        defaults.set(defaults.integer(forKey: launchCountKey) + laterLaunchDelay, forKey: nextEligibleLaunchCountKey)
    }

    func optOut() {
        isShowingPrePrompt = false
        hasPendingEligiblePrompt = false
        defaults.set(true, forKey: optedOutKey)
    }

    private func markEligibleIfNeeded() {
        guard isEligibleForPrompt else { return }
        hasPendingEligiblePrompt = true
    }

    private var isEligibleForPrompt: Bool {
        guard defaults.bool(forKey: optedOutKey) == false else { return false }
        guard defaults.integer(forKey: launchCountKey) >= minimumLaunches else { return false }
        guard defaults.integer(forKey: playbackCountKey) >= minimumPlaybacks else { return false }
        guard defaults.integer(forKey: completedDownloadCountKey) >= minimumCompletedDownloads else { return false }
        guard defaults.integer(forKey: launchCountKey) >= defaults.integer(forKey: nextEligibleLaunchCountKey) else {
            return false
        }

        let now = Date()
        if let firstLaunchDate = defaults.object(forKey: firstLaunchDateKey) as? Date,
           now.timeIntervalSince(firstLaunchDate) < minimumDaysSinceFirstLaunch {
            return false
        }

        if let laterUntil = defaults.object(forKey: laterUntilDateKey) as? Date,
           now < laterUntil {
            return false
        }

        if let lastPromptDate = defaults.object(forKey: lastPromptDateKey) as? Date,
           now.timeIntervalSince(lastPromptDate) < promptCooldown {
            return false
        }

        return defaults.string(forKey: promptedVersionKey) != currentAppVersion
    }

    private var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
}
