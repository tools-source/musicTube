import UIKit

/// UIApplicationDelegate adopted via @UIApplicationDelegateAdaptor in MusicTubeApp.
/// Its only responsibility today is forwarding background URLSession completion handlers
/// to DownloadService so downloads that finish while the app is suspended are processed.
final class AppDelegate: NSObject, UIApplicationDelegate {

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
}
