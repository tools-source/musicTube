import UIKit
import UserNotifications

/// UIApplicationDelegate adopted via @UIApplicationDelegateAdaptor in MusicTubeApp.
/// Owns AppState so it is created before any scene delegate (including CarPlay) connects.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// Created here so CarPlay can access AppState even when the phone UI hasn't appeared yet.
    /// AppState.init() registers itself in AppContainer, making it available to CarPlaySceneDelegate.
    private(set) var appState: AppState = AppState.makeDefault()
    private(set) lazy var coordinator = AppCoordinator(appState: appState)

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        application.beginReceivingRemoteControlEvents()
        _ = coordinator

        // Receive notification taps so a "download finished" alert can open the Downloads tab.
        UNUserNotificationCenter.current().delegate = self

        // Start auth restoration immediately so CarPlay (and Lock Screen) have valid state
        // even when the phone UI hasn't appeared yet. RootView's own restoreSession() call
        // becomes a no-op thanks to the guard in AppState.
        Task {
            await appState.restoreSession()
        }

        // Eagerly initialize singletons that observe background state.
        _ = NetworkMonitor.shared
        AppReviewPrompter.shared.recordAppLaunch()

        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        application.endReceivingRemoteControlEvents()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        coordinator.applicationDidBecomeActive()
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // Only handle the session we own.
        guard identifier == DownloadService.backgroundSessionIdentifier else {
            completionHandler()
            return
        }

        // Store the handler; DownloadService will call it after processing all
        // queued delegate events (urlSessionDidFinishEvents fires last).
        Task { @MainActor in
            DownloadService.shared.backgroundCompletionHandler = completionHandler
        }
    }

    func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb else {
            return false
        }

        Task {
            await appState.handleIncomingUserActivity(userActivity)
        }
        return true
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Show download/recognition alerts even while the app is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// Routes a tapped "download finished" notification to the Downloads tab.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let shouldOpenDownloads = userInfo[DownloadService.downloadFinishedNavigationKey] as? String
            == DownloadService.downloadFinishedNavigationValue

        // Notification delegate callbacks are delivered on the main thread.
        MainActor.assumeIsolated {
            if shouldOpenDownloads {
                AppContainer.shared.appState?.selectedMainTab = .downloads
            }
        }
        completionHandler()
    }
}
