import UIKit

/// UIApplicationDelegate adopted via @UIApplicationDelegateAdaptor in MusicTubeApp.
/// Owns AppState so it is created before any scene delegate (including CarPlay) connects.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// Created here so CarPlay can access AppState even when the phone UI hasn't appeared yet.
    /// AppState.init() registers itself in AppContainer, making it available to CarPlaySceneDelegate.
    private(set) var appState: AppState = AppState.makeDefault()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Start auth restoration immediately so CarPlay (and Lock Screen) have valid state
        // even when the phone UI hasn't appeared yet. RootView's own restoreSession() call
        // becomes a no-op thanks to the guard in AppState.
        Task {
            await appState.restoreSession()
        }
        return true
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
