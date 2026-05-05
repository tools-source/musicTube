import AppIntents
import SwiftUI

@main
struct MusicTubeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appDelegate.appState)
                .task {
                    // AppState registers itself in AppContainer during init (AppDelegate creates
                    // it eagerly). Re-refresh here in case CarPlay connected before this view appeared.
                    AppContainer.shared.carPlayManager?.refresh(using: appDelegate.appState)
                }
                .onReceive(appDelegate.appState.$playlists) { playlists in
                    guard playlists.isEmpty == false else { return }
                    MusicTubeShortcuts.updateAppShortcutParameters()
                }
        }
    }
}
