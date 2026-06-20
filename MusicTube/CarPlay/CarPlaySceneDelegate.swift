import CarPlay
import UIKit

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private let manager = CarPlayManager()

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        connect(interfaceController: interfaceController)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        disconnect()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        AppContainer.shared.appState?.handleCarPlayDidBecomeActive()
    }

    private func connect(interfaceController: CPInterfaceController) {
        manager.attach(interfaceController: interfaceController, state: AppContainer.shared.appState)
        AppContainer.shared.carPlayManager = manager

        if let appState = AppContainer.shared.appState {
            appState.handleCarPlayConnected()
            manager.refresh(using: appState)
        }
    }

    private func disconnect() {
        AppContainer.shared.appState?.handleCarPlayDisconnected()
        manager.detach()

        if AppContainer.shared.carPlayManager === manager {
            AppContainer.shared.carPlayManager = nil
        }
    }
}
