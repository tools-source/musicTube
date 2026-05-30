import Combine
import Foundation
import Network

/// Monitors current network path properties and publishes changes to subscribers.
/// Uses NWPathMonitor so the OS delivers updates without polling.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isConnected: Bool = true
    @Published private(set) var isCellular: Bool = false
    @Published private(set) var isLowDataMode: Bool = false
    @Published private(set) var isExpensive: Bool = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.musictube.network-monitor", qos: .utility)

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handle(path: path)
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    private func handle(path: NWPath) {
        isConnected  = path.status == .satisfied
        isCellular   = path.usesInterfaceType(.cellular)
        isExpensive  = path.isExpensive
        isLowDataMode = path.isConstrained
    }

    /// True when the OS Low Data Mode flag is set OR the user has enabled Data Saver in-app.
    var effectiveLowDataMode: Bool {
        isLowDataMode || DataUsageSettings.shared.dataSaverMode
    }
}
