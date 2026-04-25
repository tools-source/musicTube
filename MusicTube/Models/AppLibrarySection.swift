import Foundation

enum AppLibrarySection: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case quickActions
    case history
    case likedSongs
    case savedSongs
    case customPlaylists
    case savedCollections

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quickActions:
            return "Quick Actions"
        case .history:
            return "History"
        case .likedSongs:
            return "Liked Songs"
        case .savedSongs:
            return "Saved Songs"
        case .customPlaylists:
            return "Your Playlists"
        case .savedCollections:
            return "Saved Collections"
        }
    }

    static var defaultOrder: [AppLibrarySection] {
        [.quickActions, .history, .likedSongs, .savedSongs, .customPlaylists, .savedCollections]
    }

    static func normalizedOrder(from storedValues: [String]) -> [AppLibrarySection] {
        var seen: Set<AppLibrarySection> = []
        let resolved = storedValues.compactMap(Self.init(rawValue:)).filter { seen.insert($0).inserted }
        return resolved + defaultOrder.filter { seen.contains($0) == false }
    }
}
