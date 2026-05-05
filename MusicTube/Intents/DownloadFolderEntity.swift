import AppIntents

struct DownloadFolderEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Download Folder")
    static var defaultQuery = DownloadFolderEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name))
    }
}

struct DownloadFolderEntityQuery: EntityQuery, EntityStringQuery {

    func entities(for identifiers: [String]) async throws -> [DownloadFolderEntity] {
        await MainActor.run {
            DownloadService.shared.folders
                .filter { identifiers.contains($0.id) }
                .map { DownloadFolderEntity(id: $0.id, name: $0.name) }
        }
    }

    func suggestedEntities() async throws -> [DownloadFolderEntity] {
        await MainActor.run {
            DownloadService.shared.folders
                .map { DownloadFolderEntity(id: $0.id, name: $0.name) }
        }
    }

    func entities(matching string: String) async throws -> [DownloadFolderEntity] {
        await MainActor.run {
            let lower = string.lowercased()
            return DownloadService.shared.folders
                .filter { $0.name.lowercased().contains(lower) }
                .map { DownloadFolderEntity(id: $0.id, name: $0.name) }
        }
    }
}
