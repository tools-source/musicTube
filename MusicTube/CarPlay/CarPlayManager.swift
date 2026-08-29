import CarPlay
import UIKit

// MARK: - CarPlayManager
// A YouTube Music-style CarPlay experience.
//
// Design principles:
//  • Glanceable, artwork-first browse rows: Quick picks, Listen again, mixes,
//    library, and downloads.
//  • Four familiar tabs for quick scanning:
//    Home · Search · Library · Downloads.
//  • Rich Now Playing with queue, shuffle, repeat, like, and download controls.
//  • The currently playing track is highlighted wherever it appears.
//
// Performance principles (carried over from the original, unchanged):
//  • One template per tab, updated atomically.
//  • No per-item background tasks that fight each other.
//  • Artwork: gradient placeholder immediately → one batch fetch → one refresh.
//  • Never push CPNowPlayingTemplate.shared when it's already on the stack.

@MainActor
final class CarPlayManager: NSObject {
    private struct ArtworkTile {
        let image: UIImage
        let title: String?
        let subtitle: String?
    }

    // MARK: Outlets
    private weak var interfaceController: CPInterfaceController?
    private weak var appState: AppState?

    private var forYouTemplate: CPListTemplate?
    private var searchTabTemplate: CPListTemplate?
    private var libraryTemplate: CPListTemplate?
    private var downloadsTemplate: CPListTemplate?
    private var downloadFolderTemplates: [String: CPListTemplate] = [:]
    private var tabTemplate: CPTabBarTemplate?
    private var upNextTemplate: CPListTemplate?
    private var nowPlayingPushInProgress = false
    private var lastPresentedNowPlayingTrackID: String?
    private var lastSectionSignature: String?
    private var lastArtworkSignature: String?
    private var pendingArtworkSignature: String?
    private var artworkRefreshTask: Task<Void, Never>?
    private var artworkRetryTask: Task<Void, Never>?
    private var nowPlayingObserverAttached = false
    private let unassignedDownloadsTemplateKey = "__unassigned_downloads__"

    /// Square pixel size for every artwork rendition. One rendition is reused for both
    /// list thumbnails (which CarPlay downsizes) and carousel tiles, so each URL is
    /// fetched and decoded only once. Rendered at scale 1 for predictable memory.
    private let tileSide: CGFloat = 200

    /// The most images the system will show in a CPListImageRowItem carousel.
    private var maxGridImages: Int { max(1, Int(CPMaximumNumberOfGridImages)) }

    /// Reserve one item for the explicit Play All action on detail templates.
    private var maxDetailTrackRows: Int { max(1, Int(CPListTemplate.maximumItemCount) - 1) }

    // Artwork cache (URL → tileSide×tileSide UIImage)
    private let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 160
        return cache
    }()

    // MARK: Lifecycle

    func attach(interfaceController: CPInterfaceController, state: AppState? = nil) {
        self.interfaceController = interfaceController
        self.appState = state
        buildRoot()
    }

    func detach() {
        if nowPlayingObserverAttached {
            CPNowPlayingTemplate.shared.remove(self)
            nowPlayingObserverAttached = false
        }
        interfaceController = nil
        appState = nil
        forYouTemplate = nil
        searchTabTemplate = nil
        libraryTemplate = nil
        downloadsTemplate = nil
        downloadFolderTemplates = [:]
        tabTemplate = nil
        upNextTemplate = nil
        nowPlayingPushInProgress = false
        lastPresentedNowPlayingTrackID = nil
        lastSectionSignature = nil
        lastArtworkSignature = nil
        pendingArtworkSignature = nil
        artworkRefreshTask?.cancel()
        artworkRefreshTask = nil
        artworkRetryTask?.cancel()
        artworkRetryTask = nil
    }

    func refresh(using state: AppState) {
        self.appState = state
        guard tabTemplate != nil else { buildRoot(); return }

        updateNowPlayingControls(using: state)
        surfaceNowPlayingIfNeeded(using: state)

        let sectionSignature = self.sectionSignature(for: state)
        let needsSectionRefresh = sectionSignature != lastSectionSignature
        if needsSectionRefresh {
            lastSectionSignature = sectionSignature
            forYouTemplate?.updateSections(forYouSections(state))
            searchTabTemplate?.updateSections(searchTabSections(state))
            libraryTemplate?.updateSections(librarySections(state))
            downloadsTemplate?.updateSections(downloadSections(state))
            updateDownloadFolderTemplates(using: state)
        }

        scheduleArtworkRefreshIfNeeded(using: state)
    }

    private func scheduleArtworkRefreshIfNeeded(using state: AppState) {
        let downloadTracks = DownloadService.shared.downloads.flatMap { [$0.track, $0.localTrack] }
        let tracks = uniqueTracks(
            [state.nowPlaying].compactMap { $0 }
                + state.searchSuggestionTracks
                + state.relatedTracks
                + state.featuredTracks
                + state.recentTracks
                + state.historyTracks
                + downloadTracks
        ).prefix(96)
        var seenPlaylistIDs = Set<String>()
        let playlistCandidates = state.suggestedMixes
            + state.playlists
            + state.customPlaylists
            + [state.likedSongsPlaylist, state.savedSongsPlaylist].compactMap { $0 }
        let playlists = Array(playlistCandidates.filter { playlist in
            seenPlaylistIDs.insert(playlist.id).inserted
        }.prefix(32))
        let collections = Array(state.savedCollections.prefix(32))

        let artworkSignature = artworkSignature(
            tracks: Array(tracks),
            playlists: playlists,
            collections: collections
        )
        guard artworkSignature != lastArtworkSignature,
              artworkSignature != pendingArtworkSignature else { return }
        pendingArtworkSignature = artworkSignature

        artworkRefreshTask?.cancel()
        artworkRetryTask?.cancel()
        artworkRetryTask = nil
        artworkRefreshTask = Task { @MainActor [weak self, tracks = Array(tracks), playlists, collections, artworkSignature] in
            guard let self else { return }
            let loadedAllArtwork = await self.batchFetch(
                tracks: tracks,
                playlists: playlists,
                collections: collections
            )
            guard Task.isCancelled == false else {
                if self.pendingArtworkSignature == artworkSignature {
                    self.pendingArtworkSignature = nil
                }
                return
            }
            self.lastArtworkSignature = artworkSignature
            self.pendingArtworkSignature = nil
            // After artwork is cached, rebuild with real images
            self.forYouTemplate?.updateSections(self.forYouSections(state))
            self.searchTabTemplate?.updateSections(self.searchTabSections(state))
            self.libraryTemplate?.updateSections(self.librarySections(state))
            self.downloadsTemplate?.updateSections(self.downloadSections(state))
            self.updateDownloadFolderTemplates(using: state)
            if loadedAllArtwork == false {
                self.scheduleArtworkRetry(for: artworkSignature, state: state)
            }
        }
    }

    private func scheduleArtworkRetry(for signature: String, state: AppState) {
        artworkRetryTask?.cancel()
        artworkRetryTask = Task { @MainActor [weak self, weak state] in
            do {
                try await Task.sleep(nanoseconds: 46_000_000_000)
            } catch {
                return
            }
            guard let self, let state, self.lastArtworkSignature == signature else { return }
            self.lastArtworkSignature = nil
            self.scheduleArtworkRefreshIfNeeded(using: state)
        }
    }

    // MARK: Root build

    private func buildRoot() {
        guard let ic = interfaceController, tabTemplate == nil else { return }
        let state = appState

        let fy = makeListTemplate(
            title: "Listen Now",
            tabTitle: "Home",
            tabImage: UIImage(systemName: "house.fill"),
            sections: forYouSections(state))
        let search = makeListTemplate(
            title: "Search",
            tabTitle: "Search",
            tabImage: UIImage(systemName: "magnifyingglass"),
            sections: searchTabSections(state))
        let lib = makeListTemplate(
            title: "Library",
            tabTitle: "Library",
            tabImage: UIImage(systemName: "square.stack.fill"),
            sections: librarySections(state))
        let dl = makeListTemplate(
            title: "Downloads",
            tabTitle: "Downloads",
            tabImage: UIImage(systemName: "arrow.down.circle.fill"),
            sections: downloadSections(state))

        let tab = CPTabBarTemplate(templates: [fy, search, lib, dl])
        self.forYouTemplate    = fy
        self.searchTabTemplate = search
        self.libraryTemplate   = lib
        self.downloadsTemplate = dl
        self.tabTemplate       = tab
        self.lastSectionSignature = state.map(sectionSignature(for:))

        ic.setRootTemplate(tab, animated: false, completion: nil)
        configureNowPlayingTemplate()
        updateNowPlayingControls(using: state)

        surfaceNowPlayingIfNeeded(using: state, force: true)
        if let state {
            scheduleArtworkRefreshIfNeeded(using: state)
        }
    }

    private func makeListTemplate(
        title: String, tabTitle: String, tabImage: UIImage?,
        sections: [CPListSection]
    ) -> CPListTemplate {
        let t = CPListTemplate(title: title, sections: sections)
        t.tabTitle = tabTitle
        t.tabImage = tabImage
        return t
    }

    // MARK: For You sections

    private func forYouSections(_ state: AppState?) -> [CPListSection] {
        guard let state else {
            return [section("", [plain("Loading your music…")])]
        }
        guard state.authState != .restoring else {
            return [section("", [plain("Loading your music…")])]
        }

        var sections: [CPListSection] = []
        let quickActions = recommendedQuickActions(state)
        if quickActions.isEmpty == false {
            sections.append(section("For your drive", quickActions))
        }

        // ── Quick picks ────────────────────────────────────────────────────
        // A carousel of the strongest recommendations, the same way YT Music leads
        // its home screen. The remaining recommendations flow into the list below.
        let freshQueue = state.recommendationPlaybackQueue()
        let featured = freshQueue.isEmpty ? state.featuredTracks : freshQueue
        var recommendationList = featured
        if state.isLoading && featured.isEmpty {
            sections.append(section("Quick picks", [plain("Loading your picks…")]))
        } else if featured.isEmpty {
            let emptyMessage = state.homeStatusMessage ?? "Open Home on your iPhone to refresh recommendations."
            sections.append(section("Recommended for you", [plain(emptyMessage)]))
            recommendationList = []
        } else {
            let quickPicks = Array(featured.prefix(maxGridImages))
            if quickPicks.count >= 4 {
                sections.append(trackCarouselSection(title: "Quick picks", tracks: quickPicks, queue: featured, state: state))
                recommendationList = Array(featured.dropFirst(quickPicks.count))
            }
        }

        // ── Listen again ───────────────────────────────────────────────────
        let listenAgain = Array(state.historyTracks.prefix(maxGridImages))
        if listenAgain.count >= 4 {
            sections.append(trackCarouselSection(
                title: "Listen again",
                tracks: listenAgain,
                queue: state.historyTracks,
                state: state))
        }

        // ── Your mixes ─────────────────────────────────────────────────────
        if state.isLoadingPlaylists && state.suggestedMixes.isEmpty {
            sections.append(section("Your mixes", [plain("Loading mixes…")]))
        } else if state.suggestedMixes.isEmpty == false {
            let mixes = Array(state.suggestedMixes.prefix(maxGridImages))
            if mixes.count >= 2 {
                sections.append(playlistCarouselSection(title: "Your mixes", playlists: mixes, state: state))
            } else {
                sections.append(section("Your mixes", mixes.map { playlistRow($0, state: state) }))
            }
        }

        // ── Related to current playback ───────────────────────────────────
        if let nowPlaying = state.nowPlaying {
            if state.isLoadingRelatedTracks && state.relatedTracks.isEmpty {
                sections.append(section("Up next · related", [plain("Finding related songs…")]))
            } else if state.relatedTracks.isEmpty == false {
                let related = Array(state.relatedTracks.prefix(maxGridImages))
                if related.count >= 4 {
                    sections.append(trackCarouselSection(
                        title: "More like \(nowPlaying.title)",
                        tracks: related,
                        queue: state.relatedTracks,
                        state: state))
                } else {
                    sections.append(section(
                        "More like \(nowPlaying.title)",
                        related.map { trackRow($0, queue: state.relatedTracks, state: state) }))
                }
            }
        }

        // ── Recommended for you (the rest) ─────────────────────────────────
        if recommendationList.isEmpty == false {
            let visibleTracks = Array(recommendationList.prefix(24))
            let items = visibleTracks.map { trackRow($0, queue: featured, state: state) }
            sections.append(section("Recommended for you", items))
        }

        return sections.isEmpty ? [section("", [plain("No content yet.")])] : sections
    }

    private func recommendedQuickActions(_ state: AppState) -> [CPListItem] {
        var items: [CPListItem] = []

        let quickPickQueue = state.recommendationPlaybackQueue()
        if quickPickQueue.isEmpty == false {
            items.append(actionRow(
                text: "Play Quick Picks",
                detailText: quickPickQueue.count == 1
                    ? "Start your top pick"
                    : "Start \(quickPickQueue.count) fresh recommended songs",
                image: UIImage(systemName: "play.circle.fill")
            ) { [weak self, weak state] in
                guard let state else { return }
                let latestQueue = state.recommendationPlaybackQueue()
                let queue = latestQueue.isEmpty ? quickPickQueue : latestQueue
                guard let latestFirstPick = queue.first else { return }
                state.play(track: latestFirstPick, queue: queue)
                self?.showNowPlaying()
            })
        }

        if let firstHistory = state.historyTracks.first {
            items.append(actionRow(
                text: "Resume Last Played",
                detailText: compactSubtitle(firstHistory.title),
                image: UIImage(systemName: "clock.arrow.circlepath")
            ) { [weak self, weak state] in
                state?.play(track: firstHistory, queue: state?.historyTracks ?? [firstHistory])
                self?.showNowPlaying()
            })
        }

        return Array(items.prefix(3))
    }

    // MARK: Search tab

    private func searchTabSections(_ state: AppState?) -> [CPListSection] {
        var sections: [CPListSection] = []
        if let state {
            let suggestionRows = Array(state.searchSuggestionTracks.prefix(24))
            if suggestionRows.isEmpty == false {
                sections.append(section(
                    "Suggestions",
                    suggestionRows.map { trackRow($0, queue: state.searchSuggestionTracks, state: state) }
                ))
            } else if state.recentSearches.isEmpty == false {
                ensureSearchSuggestionsForCarPlay(state)
                sections.append(section("Suggestions", [
                    plain(state.isLoadingSearchSuggestions ? "Loading suggestions…" : "Preparing suggestions…")
                ]))
            }
        }

        let recents = Array((state?.recentSearches ?? []).prefix(12))
        if recents.isEmpty {
            sections.append(section("Recent Searches", [
                plain("Search on your iPhone. Recent searches appear here for quick replay.")
            ]))
        } else {
            let rows = recents.map { query -> CPListItem in
                let item = CPListItem(
                    text: query,
                    detailText: nil,
                    image: UIImage(systemName: "clock.arrow.circlepath"),
                    accessoryImage: nil,
                    accessoryType: .disclosureIndicator
                )
                item.handler = { [weak self] _, done in
                    defer { done() }
                    self?.runStoredSearch(query: query)
                }
                return item
            }
            sections.append(section("Recent Searches", rows))
        }

        return sections
    }

    private func ensureSearchSuggestionsForCarPlay(_ state: AppState) {
        guard state.isLoadingSearchSuggestions == false else { return }
        guard state.searchSuggestionTracks.isEmpty else { return }
        guard state.recentSearches.isEmpty == false else { return }

        Task { @MainActor [weak state] in
            _ = await state?.refreshSearchSuggestionTracks(limit: 24)
        }
    }

    /// Runs a one-tap search from a stored recent query and pushes the results.
    private func runStoredSearch(query: String) {
        guard let ic = interfaceController, let state = appState else { return }

        let loading = makeListTemplate(
            title: query, tabTitle: "", tabImage: nil,
            sections: [section("Results", [plain("Searching…")])])
        ic.pushTemplate(loading, animated: true, completion: nil)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let tracks = await state.carPlaySearchResults(for: query)
            guard tracks.isEmpty == false else {
                loading.updateSections([self.section("Results", [self.plain("No songs found for “\(query)”.")])])
                return
            }
            await self.batchFetch(tracks: Array(tracks.prefix(40)), playlists: [], collections: [])
            loading.updateSections([
                self.section(
                    "\(tracks.count) songs",
                    tracks.prefix(40).map { self.trackRow($0, queue: tracks, state: state) }
                )
            ])
        }
    }

    // MARK: Library sections

    private func librarySections(_ state: AppState?) -> [CPListSection] {
        guard let state else {
            return [section("", [plain("Loading your music…")])]
        }
        guard state.authState != .restoring else {
            return [section("", [plain("Loading your music…")])]
        }

        var sections: [CPListSection] = []
        let quickAccess = libraryQuickAccessItems(for: state)
        if quickAccess.isEmpty == false {
            sections.append(section("Quick Access", quickAccess))
        }

        if state.isLoadingPlaylists && state.playlists.isEmpty {
            sections.append(section("Library", [plain("Importing your library…")]))
            return sections
        }

        let skippedQuickAccessSections = Set([
            state.likedSongsPlaylist == nil ? nil : AppLibrarySection.likedSongs,
            state.savedSongsPlaylist == nil ? nil : AppLibrarySection.savedSongs
        ].compactMap { $0 })
        sections.append(contentsOf: state.librarySectionOrder
            .filter { skippedQuickAccessSections.contains($0) == false }
            .compactMap { librarySection($0, state: state) })
        return sections.isEmpty ? [section("Library", [plain("No content yet.")])] : sections
    }

    private func libraryQuickAccessItems(for state: AppState) -> [CPListItem] {
        var items: [CPListItem] = []

        if let likedSongs = state.likedSongsPlaylist {
            items.append(playlistRow(likedSongs, state: state))
        }

        if let savedSongs = state.savedSongsPlaylist {
            items.append(playlistRow(savedSongs, state: state))
        }

        if state.historyTracks.isEmpty == false {
            let item = CPListItem(
                text: "Recently Played",
                detailText: state.historyTracks.count == 1 ? "1 song" : "\(state.historyTracks.count) songs",
                image: cachedImage(state.historyTracks.first?.artworkURL) ?? musicPlaceholder,
                accessoryImage: nil,
                accessoryType: .disclosureIndicator
            )
            item.handler = { [weak self, weak state] _, done in
                defer { done() }
                guard let self, let state else { return }
                let tracks = Array(state.historyTracks.prefix(80))
                let template = self.makeListTemplate(
                    title: "Recently Played",
                    tabTitle: "",
                    tabImage: nil,
                    sections: [
                        self.section(
                            "Recently Played",
                            tracks.map { self.trackRow($0, queue: tracks, state: state) }
                        )
                    ]
                )
                self.interfaceController?.pushTemplate(template, animated: true, completion: nil)
            }
            items.append(item)
        }

        return Array(items.prefix(3))
    }

    // MARK: Downloads sections

    private func downloadSections(_ state: AppState?) -> [CPListSection] {
        let records = DownloadService.shared.downloads
        guard let state = state ?? self.appState else {
            return [section("Downloads", [plain("Connecting…")])]
        }

        var sections = [CPListSection]()
        guard records.isEmpty == false else {
            sections.append(section("Downloads",
                                    [plain("No downloads yet. Save songs from iPhone.")]))
            return sections
        }

        sections.append(section("Offline", [offlineSummaryRow(records: records)]))

        if DownloadService.shared.folders.isEmpty {
            let tracks = Array(records.reversed().map(\.localTrack))
            sections.append(section("Downloaded · \(tracks.count) songs",
                                    tracks.map { trackRow($0, queue: tracks, state: state) }))
            return sections
        }

        let allTracks = Array(records.reversed().map(\.localTrack))
        let folders = DownloadService.shared.folders
        let recentTracks = Array(allTracks.prefix(maxGridImages))

        if folders.count >= 2 {
            sections.append(folderCarouselSection(title: "Folders", folders: folders, state: state))
        } else {
            let folderItems = folders.map {
                downloadFolderRow(title: $0.name, folderID: $0.id, state: state)
            }
            sections.append(section("Folders", folderItems))
        }

        if recentTracks.isEmpty == false {
            sections.append(section("Recently Downloaded",
                                    recentTracks.map { trackRow($0, queue: allTracks, state: state) }))
        }

        return sections
    }

    private func offlineSummaryRow(records: [DownloadRecord]) -> CPListItem {
        let folderCount = DownloadService.shared.folders.count
        let size = formattedDownloadedSize(DownloadService.shared.totalDownloadedBytes)
        let songText = records.count == 1 ? "1 song" : "\(records.count) songs"
        let folderText = folderCount == 1 ? "1 folder" : "\(folderCount) folders"
        let item = CPListItem(
            text: "\(songText) offline",
            detailText: "\(size) · \(folderText)",
            image: UIImage(systemName: "arrow.down.circle.fill")
        )
        item.isEnabled = false
        return item
    }

    // MARK: Carousels

    /// Builds a captioned CPListImageRowItem using the non-deprecated iOS 26 elements API.
    /// Older OS versions fall back to image-only rows, preserving the same tap handlers.
    private func makeImageRowItem(text: String, tiles: [ArtworkTile]) -> CPListImageRowItem {
        if #available(iOS 26.0, *) {
            let elements = tiles.map {
                CPListImageRowItemRowElement(image: $0.image, title: $0.title, subtitle: $0.subtitle)
            }
            return CPListImageRowItem(text: text, elements: elements, allowsMultipleLines: false)
        }
        return CPListImageRowItem(text: text, images: tiles.map(\.image))
    }

    /// A headerless section holding a single horizontal artwork carousel of tracks.
    private func trackCarouselSection(title: String, tracks: [Track], queue: [Track], state: AppState) -> CPListSection {
        let tiles = Array(tracks.prefix(maxGridImages))
        let row = makeImageRowItem(
            text: title,
            tiles: tiles.map {
                ArtworkTile(
                    image: cachedImage($0.artworkURL) ?? musicPlaceholder,
                    title: $0.title,
                    subtitle: compactSubtitle($0.artist)
                )
            }
        )
        // handler fires on row-title tap (no index) — play from the start of the carousel.
        // Uses tiles as the queue so upcoming songs follow carousel order, not a broader list.
        row.handler = { [weak self] _, done in
            defer { done() }
            guard !tiles.isEmpty else { return }
            state.play(track: tiles[0], queue: tiles)
            self?.showNowPlaying()
        }
        // listImageRowHandler fires with the exact tapped index (works on iOS 26 with new API).
        // Uses tiles as the queue so tile[index+1], tile[index+2]… are the next songs.
        row.listImageRowHandler = { [weak self] _, index, done in
            defer { done() }
            guard index >= 0, index < tiles.count else { return }
            state.play(track: tiles[index], queue: tiles)
            self?.showNowPlaying()
        }
        return section("", [row])
    }

    /// A headerless section holding a single horizontal artwork carousel of playlists/mixes.
    private func playlistCarouselSection(title: String, playlists: [Playlist], state: AppState) -> CPListSection {
        let tiles = Array(playlists.prefix(maxGridImages))
        let row = makeImageRowItem(
            text: title,
            tiles: tiles.map {
                ArtworkTile(
                    image: cachedImage($0.artworkURL) ?? mixPlaceholder,
                    title: $0.title,
                    subtitle: playlistSubtitle($0)
                )
            }
        )
        row.handler = { [weak self] _, done in
            defer { done() }
            guard !tiles.isEmpty else { return }
            self?.openPlaylist(tiles[0], state: state)
        }
        row.listImageRowHandler = { [weak self] _, index, done in
            defer { done() }
            guard index >= 0, index < tiles.count else { return }
            self?.openPlaylist(tiles[index], state: state)
        }
        return section("", [row])
    }

    /// A headerless section holding a single horizontal artwork carousel of collections.
    private func collectionCarouselSection(title: String, collections: [MusicCollection], state: AppState) -> CPListSection {
        let tiles = Array(collections.prefix(maxGridImages))
        let row = makeImageRowItem(
            text: title,
            tiles: tiles.map {
                ArtworkTile(
                    image: cachedImage($0.artworkURL) ?? mixPlaceholder,
                    title: $0.title,
                    subtitle: collectionSubtitle($0)
                )
            }
        )
        row.handler = { [weak self] _, done in
            defer { done() }
            guard !tiles.isEmpty else { return }
            self?.openCollection(tiles[0], state: state)
        }
        row.listImageRowHandler = { [weak self] _, index, done in
            defer { done() }
            guard index >= 0, index < tiles.count else { return }
            self?.openCollection(tiles[index], state: state)
        }
        return section("", [row])
    }

    private func folderCarouselSection(title: String, folders: [DownloadFolder], state: AppState) -> CPListSection {
        let tiles = Array(folders.prefix(maxGridImages))
        let row = makeImageRowItem(
            text: title,
            tiles: tiles.map {
                let count = downloadTracks(in: $0.id).count
                return ArtworkTile(
                    image: folderArtworkImage(for: $0.id),
                    title: $0.name,
                    subtitle: count == 1 ? "1 song" : "\(count) songs"
                )
            }
        )
        row.handler = { [weak self] _, done in
            defer { done() }
            guard !tiles.isEmpty else { return }
            let folder = tiles[0]
            self?.openDownloadFolder(title: folder.name, folderID: folder.id, state: state)
        }
        row.listImageRowHandler = { [weak self] _, index, done in
            defer { done() }
            guard index >= 0, index < tiles.count else { return }
            let folder = tiles[index]
            self?.openDownloadFolder(title: folder.name, folderID: folder.id, state: state)
        }
        return section("", [row])
    }

    // MARK: Item builders

    private func trackRow(_ track: Track, queue: [Track], state: AppState) -> CPListItem {
        let img  = cachedImage(track.artworkURL) ?? musicPlaceholder
        let item = CPListItem(text: track.title, detailText: trackDetailText(track), image: img)
        item.isPlaying = isCurrentTrack(track, state: state)
        item.playingIndicatorLocation = .trailing
        item.handler = { [weak self] _, done in
            defer { done() }
            state.play(track: track, queue: queue)
            self?.showNowPlaying()
        }
        return item
    }

    private func playlistRow(_ playlist: Playlist, state: AppState) -> CPListItem {
        let img  = cachedImage(playlist.artworkURL) ?? mixPlaceholder
        let item = CPListItem(text: playlist.title,
                              detailText: playlistSubtitle(playlist),
                              image: img,
                              accessoryImage: nil,
                              accessoryType: .disclosureIndicator)
        item.handler = { [weak self] _, done in
            defer { done() }
            self?.openPlaylist(playlist, state: state)
        }
        return item
    }

    private func collectionRow(_ collection: MusicCollection, state: AppState) -> CPListItem {
        let img = cachedImage(collection.artworkURL) ?? mixPlaceholder
        let item = CPListItem(
            text: collection.title,
            detailText: collectionSubtitle(collection),
            image: img,
            accessoryImage: nil,
            accessoryType: .disclosureIndicator
        )
        item.handler = { [weak self] _, done in
            defer { done() }
            self?.openCollection(collection, state: state)
        }
        return item
    }

    private func actionRow(
        text: String,
        detailText: String? = nil,
        image: UIImage? = nil,
        handler: @escaping () -> Void
    ) -> CPListItem {
        let item = CPListItem(text: text, detailText: detailText, image: image)
        item.handler = { _, done in
            defer { done() }
            handler()
        }
        return item
    }

    private func downloadFolderRow(title: String, folderID: String?, state: AppState) -> CPListItem {
        let tracks = downloadTracks(in: folderID)
        let subtitle = tracks.count == 1 ? "1 song" : "\(tracks.count) songs"
        let item = CPListItem(
            text: title,
            detailText: subtitle,
            image: folderArtworkImage(for: folderID),
            accessoryImage: nil,
            accessoryType: .disclosureIndicator
        )
        item.handler = { [weak self] _, done in
            defer { done() }
            self?.openDownloadFolder(title: title, folderID: folderID, state: state)
        }
        return item
    }

    private func plain(_ text: String) -> CPListItem {
        let item = CPListItem(text: text, detailText: nil)
        item.isEnabled = false
        return item
    }

    private func section(_ header: String, _ items: [any CPSelectableListItem]) -> CPListSection {
        CPListSection(items: items, header: header.isEmpty ? nil : header,
                      sectionIndexTitle: nil)
    }

    private func librarySection(_ sectionID: AppLibrarySection, state: AppState) -> CPListSection? {
        switch sectionID {
        case .quickActions:
            return section(
                sectionID.title,
                [
                    actionRow(
                        text: "Refresh Library",
                        detailText: "Reload your YouTube and on-device library",
                        image: UIImage(systemName: "arrow.clockwise")
                    ) {
                        Task { await state.refreshLibrary(forceRefresh: true) }
                    },
                    plain("Create playlists from your iPhone.")
                ]
            )
        case .history:
            let tracks = Array(state.historyTracks.prefix(maxGridImages))
            guard tracks.isEmpty == false else { return nil }
            if tracks.count >= 4 {
                return trackCarouselSection(title: sectionID.title, tracks: tracks, queue: state.historyTracks, state: state)
            }
            return section(sectionID.title, tracks.map { trackRow($0, queue: state.historyTracks, state: state) })
        case .likedSongs:
            return section(sectionID.title, likedSongsItems(for: state))
        case .savedSongs:
            return section(sectionID.title, savedSongsItems(for: state))
        case .customPlaylists:
            return customPlaylistsSection(for: state)
        case .savedCollections:
            return savedCollectionsSection(for: state)
        }
    }

    // MARK: Playlist detail

    private func openPlaylist(_ playlist: Playlist, state: AppState) {
        guard let ic = interfaceController else { return }

        // Loading placeholder template
        let loading = makeListTemplate(
            title: playlist.title, tabTitle: "", tabImage: nil,
            sections: [section(playlist.title, [plain("Loading tracks…")])])
        guard ic.topTemplate !== loading else { return }
        ic.pushTemplate(loading, animated: true, completion: nil)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let tracks = await state.loadPlaylistItems(for: playlist)
            guard tracks.isEmpty == false else {
                loading.updateSections([self.section(playlist.title,
                                                      [self.plain("No tracks in this playlist.")])])
                return
            }

            let visibleTracks = self.detailTracks(from: tracks)
            await self.batchFetch(tracks: visibleTracks, playlists: [], collections: [])
            let header = tracks.count == 1 ? "1 Song" : "\(tracks.count) Songs"
            loading.updateSections([
                self.section("Actions", [self.playAllRow(tracks: tracks, state: state)]),
                self.section(
                    header,
                    visibleTracks.map { self.trackRow($0, queue: tracks, state: state) }
                )
            ])
        }
    }

    private func openCollection(_ collection: MusicCollection, state: AppState) {
        guard let ic = interfaceController else { return }

        let loading = makeListTemplate(
            title: collection.title,
            tabTitle: "",
            tabImage: nil,
            sections: [section(collection.title, [plain("Loading tracks…")])]
        )
        guard ic.topTemplate !== loading else { return }
        ic.pushTemplate(loading, animated: true, completion: nil)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let tracks = await state.loadCollectionItems(for: collection)
            guard tracks.isEmpty == false else {
                loading.updateSections([self.section(collection.title, [self.plain("No tracks found.")])])
                return
            }

            let visibleTracks = self.detailTracks(from: tracks)
            await self.batchFetch(tracks: visibleTracks, playlists: [], collections: [])
            let header = tracks.count == 1 ? "1 Song" : "\(tracks.count) Songs"
            loading.updateSections([
                self.section("Actions", [self.playAllRow(tracks: tracks, state: state)]),
                self.section(
                    header,
                    visibleTracks.map { self.trackRow($0, queue: tracks, state: state) }
                )
            ])
        }
    }

    private func openDownloadFolder(title: String, folderID: String?, state: AppState) {
        guard let ic = interfaceController else { return }
        let tracks = downloadTracks(in: folderID)

        let template = makeListTemplate(
            title: title,
            tabTitle: "",
            tabImage: nil,
            sections: downloadFolderSections(title: title, folderID: folderID, state: state)
        )
        downloadFolderTemplates[downloadTemplateKey(for: folderID)] = template
        ic.pushTemplate(template, animated: true, completion: nil)

        Task { @MainActor [weak self, weak template, tracks] in
            guard let self, let template else { return }
            await self.batchFetch(tracks: self.detailTracks(from: tracks), playlists: [], collections: [])
            guard Task.isCancelled == false else { return }
            template.updateSections(self.downloadFolderSections(title: title, folderID: folderID, state: state))
        }
    }

    // MARK: Now Playing

    private func configureNowPlayingTemplate() {
        let template = CPNowPlayingTemplate.shared
        if nowPlayingObserverAttached == false {
            template.add(self)
            nowPlayingObserverAttached = true
        }
        template.isUpNextButtonEnabled = true
        template.upNextTitle = "Up Next"
    }

    private func surfaceNowPlayingIfNeeded(using state: AppState?, force: Bool = false) {
        guard let track = state?.nowPlaying else {
            lastPresentedNowPlayingTrackID = nil
            return
        }
        guard let ic = interfaceController else { return }

        let identifier = trackIdentifier(track)
        guard force || lastPresentedNowPlayingTrackID != identifier else { return }
        lastPresentedNowPlayingTrackID = identifier

        // Do not hijack browsing when playback changes elsewhere. Keep the Now Playing
        // template updated, and only auto-surface on first CarPlay connection or while
        // the driver is already viewing Now Playing.
        guard force || ic.topTemplate === CPNowPlayingTemplate.shared else { return }

        Task { @MainActor [weak self] in
            await Task.yield()
            self?.showNowPlaying()
        }
    }

    private func showNowPlaying() {
        guard let ic = interfaceController, !nowPlayingPushInProgress else { return }
        configureNowPlayingTemplate()
        updateNowPlayingControls(using: appState)
        let target = CPNowPlayingTemplate.shared
        guard ic.topTemplate !== target else { return }

        // If the Up Next queue is sitting on top of Now Playing, pop it to reveal
        // Now Playing rather than pushing a duplicate template instance (which crashes).
        if let upNext = upNextTemplate, ic.topTemplate === upNext {
            upNextTemplate = nil
            ic.popTemplate(animated: true, completion: nil)
            return
        }

        nowPlayingPushInProgress = true
        ic.pushTemplate(target, animated: true) { [weak self] _, _ in
            self?.nowPlayingPushInProgress = false
        }
    }

    private func updateNowPlayingControls(using state: AppState?) {
        guard let state, let nowPlayingTrack = state.nowPlaying else {
            CPNowPlayingTemplate.shared.updateNowPlayingButtons([])
            return
        }

        let downloadService = DownloadService.shared
        let isLiked = state.isTrackLiked(nowPlayingTrack)
        let isDownloaded = downloadService.isDownloaded(nowPlayingTrack)
        let isDownloading = downloadService.isDownloading(nowPlayingTrack)
        let engine = state.playbackEngine

        // Shuffle — custom image so it can reflect on/off state.
        let shuffleButton = CPNowPlayingImageButton(
            image: nowPlayingSymbol("shuffle")
        ) { [weak self, weak state] _ in
            state?.toggleShuffle()
            guard let self, let state else { return }
            self.updateNowPlayingControls(using: state)
        }
        shuffleButton.isSelected = engine.shuffleMode

        // Repeat — glyph reflects mode (off/all → repeat, one → repeat.1).
        let repeatSymbolName = engine.repeatMode == .one ? "repeat.1" : "repeat"
        let repeatButton = CPNowPlayingImageButton(
            image: nowPlayingSymbol(repeatSymbolName)
        ) { [weak self, weak state] _ in
            state?.cycleRepeatMode()
            guard let self, let state else { return }
            self.updateNowPlayingControls(using: state)
        }
        repeatButton.isSelected = engine.repeatMode != .off

        let likeButton = CPNowPlayingImageButton(
            image: nowPlayingSymbol(isLiked ? "heart.fill" : "heart")
        ) { [weak self, weak state] _ in
            guard let track = state?.nowPlaying else { return }
            state?.toggleLike(for: track)
            guard let self, let state else { return }
            self.updateNowPlayingControls(using: state)
        }
        likeButton.isSelected = isLiked

        let downloadSymbolName: String
        if isDownloaded {
            downloadSymbolName = "arrow.down.circle"
        } else if isDownloading {
            downloadSymbolName = "arrow.down.circle.fill"
        } else {
            downloadSymbolName = "arrow.down.circle"
        }
        let downloadButton = CPNowPlayingImageButton(
            image: nowPlayingSymbol(downloadSymbolName)
        ) { [weak self, weak state] _ in
            state?.downloadNowPlaying()
            guard let self, let state else { return }
            self.updateNowPlayingControls(using: state)
        }
        downloadButton.isEnabled = !isDownloaded && !isDownloading
        downloadButton.isSelected = isDownloaded

        CPNowPlayingTemplate.shared.updateNowPlayingButtons([
            shuffleButton,
            repeatButton,
            likeButton,
            downloadButton
        ])
    }

    /// Builds the "Up Next" queue list shown when the Now Playing queue button is tapped.
    private func queueSections(state: AppState) -> [CPListSection] {
        let queue = state.playbackEngine.currentQueue
        guard queue.isEmpty == false else {
            return [section("Up Next", [plain("Your queue is empty.")])]
        }

        let currentIndex = min(max(state.playbackEngine.currentQueueIndex ?? 0, 0), queue.count - 1)
        let currentTrack = queue[currentIndex]
        let currentItem = CPListItem(
            text: currentTrack.title,
            detailText: currentTrack.artist.isEmpty ? trackDetailText(currentTrack) : currentTrack.artist,
            image: cachedImage(currentTrack.artworkURL) ?? musicPlaceholder
        )
        currentItem.isPlaying = true
        currentItem.playingIndicatorLocation = .trailing
        currentItem.handler = { [weak self] _, done in
            defer { done() }
            state.play(track: currentTrack, queue: queue)
            self?.updateNowPlayingControls(using: state)
        }

        let upcoming = queue.enumerated().dropFirst(currentIndex + 1).prefix(79)
        let upcomingItems = upcoming.map { _, track -> CPListItem in
            let item = CPListItem(
                text: track.title,
                detailText: track.artist.isEmpty ? trackDetailText(track) : track.artist,
                image: cachedImage(track.artworkURL) ?? musicPlaceholder
            )
            item.handler = { [weak self] _, done in
                defer { done() }
                state.play(track: track, queue: queue)
                self?.updateNowPlayingControls(using: state)
                // Navigation back to Now Playing is handled by surfaceNowPlayingIfNeeded via refresh().
            }
            return item
        }

        let remainingCount = max(queue.count - currentIndex - 1, 0)
        var sections = [section("Playing Now", [currentItem])]
        if upcomingItems.isEmpty {
            sections.append(section("Up Next", [plain("End of queue.")]))
        } else {
            sections.append(section("Up Next · \(remainingCount)", Array(upcomingItems)))
        }
        return sections
    }

    private func presentUpNextQueue() {
        guard let ic = interfaceController, let state = appState else { return }
        let template = makeListTemplate(
            title: "Up Next", tabTitle: "", tabImage: nil,
            sections: queueSections(state: state))
        upNextTemplate = template
        ic.pushTemplate(template, animated: true, completion: nil)

        let queue = Array(state.playbackEngine.currentQueue.prefix(80))
        guard queue.isEmpty == false else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.batchFetch(tracks: queue, playlists: [], collections: [])
            template.updateSections(self.queueSections(state: state))
        }
    }

    private func updateDownloadFolderTemplates(using state: AppState) {
        for (key, template) in downloadFolderTemplates {
            let folderID = key == unassignedDownloadsTemplateKey ? nil : key
            template.updateSections(
                downloadFolderSections(
                    title: template.title ?? "Downloads",
                    folderID: folderID,
                    state: state
                )
            )
        }
    }

    private func sectionSignature(for state: AppState) -> String {
        let downloads = DownloadService.shared.downloads
        let folders = DownloadService.shared.folders
        let parts: [String] = [
            "auth:\(state.authState)",
            "now:\(state.nowPlaying.map(trackIdentifier) ?? "-")",
            "loading:\(state.isLoading)-\(state.isLoadingPlaylists)-\(state.isLoadingRelatedTracks)",
            "mix:\(state.suggestedMixes.map(\.id).joined(separator: ","))",
            "featured:\(state.featuredTracks.prefix(30).map(trackIdentifier).joined(separator: ","))",
            "recent:\(state.recentTracks.prefix(30).map(trackIdentifier).joined(separator: ","))",
            "searchSuggestions:\(state.searchSuggestionTracks.prefix(24).map(trackIdentifier).joined(separator: ","))",
            "searchSuggestionsLoading:\(state.isLoadingSearchSuggestions)",
            "related:\(state.relatedTracks.prefix(12).map(trackIdentifier).joined(separator: ","))",
            "history:\(state.historyTracks.prefix(12).map(trackIdentifier).joined(separator: ","))",
            "liked:\(state.likedTrackIDs.sorted().prefix(40).joined(separator: ","))",
            "listened:\(state.substantiallyListenedTrackIDs.sorted().prefix(40).joined(separator: ","))",
            "prefs:\(state.userPreferenceProfile.selectedTags.map(\.id).sorted().joined(separator: ","))",
            "searches:\(state.recentSearches.prefix(12).joined(separator: ","))",
            "library:\(state.librarySectionOrder.map(\.rawValue).joined(separator: ","))",
            "playlists:\(state.playlists.map { "\($0.id):\($0.itemCount)" }.joined(separator: ","))",
            "collections:\(state.savedCollections.map { "\($0.id):\($0.itemCount)" }.joined(separator: ","))",
            "downloads:\(downloads.map { "\($0.id):\($0.folderID ?? "-")" }.joined(separator: ","))",
            "folders:\(folders.map { "\($0.id):\($0.name)" }.joined(separator: ","))"
        ]
        return parts.joined(separator: "|")
    }

    private func artworkSignature(
        tracks: [Track],
        playlists: [Playlist],
        collections: [MusicCollection]
    ) -> String {
        let urls = Set(
            tracks.compactMap(\.artworkURL) +
            playlists.compactMap(\.artworkURL) +
            collections.compactMap(\.artworkURL)
        )
        return urls
            .map(\.absoluteString)
            .sorted()
            .joined(separator: "|")
    }

    private func downloadFolderSections(title: String, folderID: String?, state: AppState) -> [CPListSection] {
        let tracks = downloadTracks(in: folderID)
        guard tracks.isEmpty == false else {
            let emptyMessage = folderID == nil ? "No downloads yet." : "This folder is empty."
            return [section(title, [plain(emptyMessage)])]
        }

        let header = tracks.count == 1
            ? "\(title) · 1 song"
            : "\(title) · \(tracks.count) songs"

        return [
            section("Actions", [playAllRow(tracks: tracks, state: state)]),
            section(
                header,
                detailTracks(from: tracks).map { trackRow($0, queue: tracks, state: state) }
            )
        ]
    }

    private func detailTracks(from tracks: [Track]) -> [Track] {
        Array(tracks.prefix(maxDetailTrackRows))
    }

    private func downloadTracks(in folderID: String?) -> [Track] {
        orderedDownloadRecords(in: folderID).map(\.localTrack)
    }

    private func orderedDownloadRecords(in folderID: String?) -> [DownloadRecord] {
        let service = DownloadService.shared
        let records = service.downloads(in: folderID)
        let sourceID = folderID.flatMap { folderID in
            service.folders.first(where: { $0.id == folderID })?.sourceID
        }

        guard let sourceID else {
            return Array(records.reversed())
        }

        return records.sorted { lhs, rhs in
            let lhsIndex = lhs.source?.id == sourceID ? (lhs.sourceTrackIndex ?? Int.max) : Int.max
            let rhsIndex = rhs.source?.id == sourceID ? (rhs.sourceTrackIndex ?? Int.max) : Int.max
            if lhsIndex != rhsIndex {
                return lhsIndex < rhsIndex
            }
            return lhs.downloadedAt < rhs.downloadedAt
        }
    }

    private func downloadTemplateKey(for folderID: String?) -> String {
        folderID ?? unassignedDownloadsTemplateKey
    }

    private func folderArtworkImage(for folderID: String?) -> UIImage {
        guard let artworkURL = DownloadService.shared.artworkURL(for: folderID),
              let image = cachedImage(artworkURL) else {
            return mixPlaceholder
        }
        return image
    }

    private func uniqueTracks(_ tracks: [Track]) -> [Track] {
        var seen = Set<String>()
        return tracks.filter { track in
            seen.insert(trackIdentifier(track)).inserted
        }
    }

    private func trackIdentifier(_ track: Track) -> String {
        track.youtubeVideoID ?? track.id
    }

    private func isCurrentTrack(_ track: Track, state: AppState) -> Bool {
        guard let current = state.nowPlaying else { return false }
        return trackIdentifier(current) == trackIdentifier(track)
    }

    // MARK: Artwork

    private func cachedImage(_ url: URL?) -> UIImage? {
        guard let url else { return nil }
        let key = url as NSURL
        if let image = cache.object(forKey: key) {
            return image
        }
        if let sharedImage = ImageCache.shared.image(for: url, maxPixelSize: ArtworkPixelSize.list) {
            cache.setObject(sharedImage, forKey: key)
            return sharedImage
        }
        return nil
    }

    @discardableResult
    private func batchFetch(
        tracks: [Track],
        playlists: [Playlist],
        collections: [MusicCollection]
    ) async -> Bool {
        let urls = Set(
            tracks.compactMap(\.artworkURL) +
            playlists.compactMap(\.artworkURL) +
            collections.compactMap(\.artworkURL)
        )
        await withTaskGroup(of: Void.self) { g in
            for url in urls {
                guard cache.object(forKey: url as NSURL) == nil else { continue }
                g.addTask { [weak self] in
                    guard let self else { return }
                    guard let raw = await ArtworkRepository.shared.image(
                        for: url,
                        maxPixelSize: ArtworkPixelSize.list
                    ) else { return }
                    let sized = await self.squareImage(raw, side: self.tileSide)
                    await MainActor.run {
                        self.cache.setObject(sized, forKey: url as NSURL)
                    }
                }
            }
        }
        return urls.allSatisfy { cachedImage($0) != nil }
    }

    private func likedSongsItems(for state: AppState) -> [any CPSelectableListItem] {
        if state.isLoadingPlaylists && state.playlists.isEmpty {
            return [plain("Syncing liked songs...")]
        }

        if let likedSongs = state.likedSongsPlaylist {
            var items: [any CPSelectableListItem] = [playlistRow(likedSongs, state: state)]
            if state.isSyncingLikedSongs {
                items.append(plain("Importing the rest of your YouTube liked songs..."))
            }
            return items
        }

        return [plain("Tap the heart on a song to keep it here.")]
    }

    private func savedSongsItems(for state: AppState) -> [any CPSelectableListItem] {
        if let savedSongs = state.savedSongsPlaylist {
            return [playlistRow(savedSongs, state: state)]
        }

        return [plain("Save songs on your iPhone and they'll show up here.")]
    }

    private func customPlaylistsSection(for state: AppState) -> CPListSection {
        let playlists = state.customPlaylists
        guard playlists.isEmpty == false else {
            return section(AppLibrarySection.customPlaylists.title,
                           [plain("Create playlists and add tracks from your iPhone.")])
        }
        if playlists.count >= 2 {
            return playlistCarouselSection(title: AppLibrarySection.customPlaylists.title, playlists: playlists, state: state)
        }
        return section(AppLibrarySection.customPlaylists.title, playlists.map { playlistRow($0, state: state) })
    }

    private func savedCollectionsSection(for state: AppState) -> CPListSection {
        let collections = state.savedCollections
        guard collections.isEmpty == false else {
            return section(AppLibrarySection.savedCollections.title,
                           [plain("Save playlists, albums, and artists from Search for quick access later.")])
        }
        if collections.count >= 2 {
            return collectionCarouselSection(title: AppLibrarySection.savedCollections.title, collections: collections, state: state)
        }
        return section(AppLibrarySection.savedCollections.title, collections.map { collectionRow($0, state: state) })
    }

    private func collectionSubtitle(_ collection: MusicCollection) -> String {
        let kindLabel: String
        switch collection.kind {
        case .playlist:
            kindLabel = "Playlist"
        case .album:
            kindLabel = "Album"
        case .artist:
            kindLabel = "Artist"
        }

        guard collection.itemCount > 0 else {
            return kindLabel
        }

        let itemLabel = collection.itemCount == 1 ? "1 item" : "\(collection.itemCount) items"
        return "\(kindLabel) · \(itemLabel)"
    }

    private func compactSubtitle(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return trimmed.count > 42 ? "\(trimmed.prefix(39))…" : trimmed
    }

    private func formattedDownloadedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = bytes >= 1_073_741_824 ? [.useGB] : [.useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.includesCount = true
        return formatter.string(fromByteCount: bytes)
    }

    private func playAllRow(tracks: [Track], state: AppState) -> CPListItem {
        let songCount = tracks.count == 1 ? "1 song" : "\(tracks.count) songs"
        return actionRow(
            text: "Play All",
            detailText: songCount,
            image: UIImage(systemName: "play.circle.fill")
        ) { [weak self, weak state] in
            guard let firstTrack = tracks.first, let state else { return }
            if state.playbackEngine.shuffleMode {
                state.toggleShuffle()
            }
            state.play(track: firstTrack, queue: tracks)
            self?.showNowPlaying()
        }
    }

    private func squareImage(_ image: UIImage, side: CGFloat) -> UIImage {
        let sz = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: sz, format: format).image { _ in
            let r  = image.size.width / image.size.height
            let dr: CGRect = r > 1
                ? CGRect(x: -(side * r - side) / 2, y: 0, width: side * r, height: side)
                : CGRect(x: 0, y: -(side / r - side) / 2, width: side, height: side / r)
            image.draw(in: dr)
        }
    }

    // MARK: Placeholders

    private lazy var musicPlaceholder: UIImage = gradientIcon(
        symbol: "music.note",
        colors: [UIColor(red: 1, green: 0.23, blue: 0.42, alpha: 1),
                 UIColor(red: 0.55, green: 0.08, blue: 0.28, alpha: 1)])

    private lazy var mixPlaceholder: UIImage = gradientIcon(
        symbol: "music.note.list",
        colors: [UIColor(red: 0.25, green: 0.47, blue: 1, alpha: 1),
                 UIColor(red: 0.08, green: 0.22, blue: 0.7, alpha: 1)])

    private func gradientIcon(symbol: String, colors: [UIColor]) -> UIImage {
        let side = tileSide
        let sz = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: sz, format: format).image { ctx in
            let cgc = ctx.cgContext
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: sz), cornerRadius: side * 0.18).addClip()
            let cs = CGColorSpaceCreateDeviceRGB()
            if let g = CGGradient(colorsSpace: cs,
                                   colors: colors.map(\.cgColor) as CFArray,
                                   locations: [0, 1]) {
                cgc.drawLinearGradient(g, start: .zero,
                                       end: CGPoint(x: side, y: side), options: [])
            }
            let glyphPointSize = side * 0.36
            let cfg = UIImage.SymbolConfiguration(pointSize: glyphPointSize, weight: .medium)
            if let ico = UIImage(systemName: symbol, withConfiguration: cfg)?
                    .withTintColor(.white, renderingMode: .alwaysOriginal) {
                let o = CGPoint(x: (side - ico.size.width) / 2,
                                y: (side - ico.size.height) / 2)
                ico.draw(in: CGRect(origin: o, size: ico.size))
            }
        }
    }

    /// A template SF Symbol image for Now Playing buttons. CarPlay recolors these for
    /// the active theme and highlights them when the button's `isSelected` is set.
    private func nowPlayingSymbol(_ name: String) -> UIImage {
        UIImage(systemName: name) ?? UIImage()
    }

    // MARK: Helpers

    private func playlistSubtitle(_ p: Playlist) -> String {
        let n = p.itemCount
        switch p.kind {
        case .likedMusic: return n == 1 ? "1 song"   : "\(n) songs"
        case .uploads:    return n == 1 ? "1 upload" : "\(n) uploads"
        case .savedSongs: return n == 1 ? "1 saved song" : "\(n) saved songs"
        case .custom:     return n == 1 ? "1 track"  : "\(n) tracks"
        case .standard:   return n == 1 ? "1 track"  : "\(n) tracks"
        }
    }

    private func trackDetailText(_ track: Track) -> String? {
        var parts = [track.artist, track.formattedDuration].compactMap { value -> String? in
            guard let value, value.isEmpty == false else { return nil }
            return value
        }
        if appState?.isTrackLiked(track) == true {
            parts.append("Liked")
        }
        if appState?.isTrackSubstantiallyListened(track) == true {
            parts.append("Listened")
        }
        guard parts.isEmpty == false else { return nil }
        return parts.joined(separator: " · ")
    }
}

// MARK: - CPNowPlayingTemplateObserver

extension CarPlayManager: CPNowPlayingTemplateObserver {
    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor [weak self] in self?.presentUpNextQueue() }
    }

    nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        // Album/artist button is not enabled; no-op.
    }
}
