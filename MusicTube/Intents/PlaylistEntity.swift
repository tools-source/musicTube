import AppIntents

struct PlaylistEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playlist")
    static var defaultQuery = PlaylistEntityQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: title))
    }
}

struct PlaylistEntityQuery: EntityQuery, EntityStringQuery {

    func entities(for identifiers: [String]) async throws -> [PlaylistEntity] {
        await MainActor.run {
            (AppContainer.shared.appState?.playlists ?? [])
                .filter { identifiers.contains($0.id) }
                .map { PlaylistEntity(id: $0.id, title: $0.title) }
        }
    }

    func suggestedEntities() async throws -> [PlaylistEntity] {
        await MainActor.run {
            (AppContainer.shared.appState?.playlists ?? [])
                .map { PlaylistEntity(id: $0.id, title: $0.title) }
        }
    }

    func entities(matching string: String) async throws -> [PlaylistEntity] {
        await MainActor.run {
            let lower = string.lowercased()
            return (AppContainer.shared.appState?.playlists ?? [])
                .filter { $0.title.lowercased().contains(lower) }
                .map { PlaylistEntity(id: $0.id, title: $0.title) }
        }
    }
}
