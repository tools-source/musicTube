import SwiftUI

// MARK: - Mood Section Model

private struct HomeMoodSection: Identifiable {
    let id: String
    let name: String
    let tracks: [Track]
}

/// Identifiable payload for the "See all" sheet so presentation + data are atomic.
struct SeeAllPayload: Identifiable {
    let id = UUID()
    let title: String
    let tracks: [Track]
}

// MARK: - HomeView

struct HomeView: View {
    @EnvironmentObject private var appState: AppState

    @State private var selectedMoodID: String? = nil      // nil = "All"
    // A single Identifiable payload drives the "See all" sheet. Using `.sheet(item:)`
    // instead of a separate bool + title/tracks state avoids the SwiftUI race where
    // the sheet renders before the title/tracks state has propagated → blank page.
    @State private var seeAllPayload: SeeAllPayload?
    @State private var recommendedVisibleCount = 10
    @State private var lastRecommendedLoadTriggerCount = 0
    @State private var showAccountSheet = false
    @State private var cachedMoods: [HomeMoodSection] = []
    @State private var cachedRecommendedTracks: [Track] = []

    // MARK: Body

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    greetingHeader
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 16)

                    moodFilterChips
                        .padding(.bottom, 20)

                    if let message = appState.homeStatusMessage {
                        statusCard(message)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 20)
                    }

                    // Daily Mixes
                    if appState.suggestedMixes.isEmpty == false, isMixesVisible {
                        dailyMixSection
                            .padding(.bottom, 28)
                    }

                    // Dynamic Mood Sections
                    ForEach(visibleMoodSections) { moodSection in
                        homeMoodSection(moodSection)
                            .padding(.bottom, 28)
                    }

                    // Trending For You
                    if isRecommendedVisible, cachedRecommendedTracks.isEmpty == false || !appState.hasLoadedHome {
                        trendingForYouSection
                            .padding(.bottom, 28)
                    }
                }
                .padding(.bottom, appState.nowPlaying == nil ? 100 : 180)
            }
            .navigationBarHidden(true)
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(playlist: playlist)
            }
            .refreshable {
                await appState.refreshDashboard(forceRefresh: true)
            }
            .task {
                recompute()
                if !appState.hasLoadedHome, !appState.isLoading, !appState.isLoadingPlaylists {
                    await appState.refreshDashboard()
                }
                recompute()
            }
            .onChange(of: selectedMoodID) { _, _ in
                recommendedVisibleCount = 10
                lastRecommendedLoadTriggerCount = 0
                recompute()
            }
            .onChange(of: appState.featuredTracks) { _, _ in recompute() }
            .onChange(of: appState.recentTracks) { _, _ in recompute() }
            .onChange(of: appState.historyTracks) { _, _ in recompute() }
            .background(AppTheme.screenBackground.ignoresSafeArea())
            .sheet(item: $seeAllPayload) { payload in
                TrackListSheet(title: payload.title, tracks: payload.tracks)
                    .environmentObject(appState)
            }
            .sheet(isPresented: $showAccountSheet) {
                HomeAccountSheet()
                    .environmentObject(appState)
                    .presentationDetents([.height(220)])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(24)
            }
        }
    }

    // MARK: - Derived state

    private var heroTrack: Track? {
        appState.nowPlayingTrack ?? appState.historyTracks.first
    }

    private var heroQueue: [Track] {
        let queue = appState.playbackEngine.currentQueue
        if appState.nowPlayingTrack != nil, queue.isEmpty == false {
            return queue
        }
        return appState.historyTracks
    }

    private var isMixesVisible: Bool {
        selectedMoodID == nil || selectedMoodID == "playlists"
    }

    private var isRecommendedVisible: Bool {
        selectedMoodID == nil || selectedMoodID == "featured"
    }

    private var visibleMoodSections: [HomeMoodSection] {
        if let id = selectedMoodID {
            return cachedMoods.filter { $0.id == id }
        }
        return cachedMoods
    }

    // MARK: - Recompute

    private func recompute() {
        // Combine the taste signals, then de-duplicate so a song that appears in both
        // the recommendations and the play history can't show up twice in a mood row.
        let allTracks = dedupedForSections(
            appState.featuredTracks + appState.historyTracks + appState.recentTracks
        )
        cachedMoods = computeMoods(from: allTracks)
        cachedRecommendedTracks = dedupedForSections(appState.featuredTracks)
    }

    /// De-duplicates by stable video ID first, then by normalized title+artist so the
    /// same song re-uploaded under a different ID doesn't repeat within a section.
    private func dedupedForSections(_ tracks: [Track]) -> [Track] {
        var seenIDs: Set<String> = []
        var seenSignatures: Set<String> = []
        var result: [Track] = []
        for track in tracks {
            guard seenIDs.insert(track.playbackKey).inserted else { continue }
            let title = track.title
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if title.isEmpty == false {
                let artist = track.artist
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .lowercased()
                let durationBucket = track.duration.map { String(Int(($0 / 2).rounded())) } ?? "?"
                guard seenSignatures.insert("\(title)|\(artist)|\(durationBucket)").inserted else { continue }
            }
            result.append(track)
        }
        return result
    }

    private func computeMoods(from tracks: [Track]) -> [HomeMoodSection] {
        guard tracks.isEmpty == false else { return [] }
        var sections: [HomeMoodSection] = []
        let seen = tracks

        let worshipTracks = seen.filter { isWorship($0) && $0.isQuranOrRecitation == false && isArabic($0) == false }
        if worshipTracks.count >= 4 {
            sections.append(HomeMoodSection(id: "worship", name: "Worship", tracks: Array(worshipTracks.prefix(20))))
        }

        // Genre clusters from artist/title signals
        let hipHopTracks = seen.filter { isHipHop($0) }
        if hipHopTracks.count >= 4 {
            sections.append(HomeMoodSection(id: "hiphop", name: "Hip-Hop", tracks: Array(hipHopTracks.prefix(20))))
        }

        return sections
    }

    // MARK: - Greeting Header

    private var greetingHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.secondaryText)
                Text(displayName)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(AppTheme.primaryText)
            }

            Spacer()

            if appState.isYouTubeConnected == false {
                Button {
                    Task { await appState.signIn() }
                } label: {
                    Text("Connect")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.primaryText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(AppTheme.controlFill))
                }
                .buttonStyle(.plain)
            } else if let user = appState.user {
                Button { showAccountSheet = true } label: {
                    ZStack {
                        Circle()
                            .fill(Color(red: 0.85, green: 0.22, blue: 0.22))
                            .frame(width: 42, height: 42)
                        Text(initials(from: user.name))
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var displayName: String {
        if let name = appState.user?.name.components(separatedBy: " ").first, name.isEmpty == false {
            return name
        }
        return "Guest"
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Good morning,"
        case 12..<17: return "Good afternoon,"
        case 17..<21: return "Good evening,"
        default:      return "Good night,"
        }
    }

    private func initials(from name: String) -> String {
        let parts = name.components(separatedBy: " ").filter { !$0.isEmpty }
        return parts.prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    // MARK: - Mood Filter Chips

    private var moodFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "All", isSelected: selectedMoodID == nil) {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { selectedMoodID = nil }
                }
                FilterChip(title: "Mixes", isSelected: selectedMoodID == "playlists") {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { selectedMoodID = "playlists" }
                }
                ForEach(cachedMoods) { mood in
                    FilterChip(title: mood.name, isSelected: selectedMoodID == mood.id) {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { selectedMoodID = mood.id }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 2)
        }
    }

    // MARK: - Continue Listening Hero

    @ViewBuilder
    private var continueListeningHero: some View {
        if let track = heroTrack {
            ContinueListeningHeroCard(
                track: track,
                remainingCount: max(0, heroQueue.count - 1),
                isPlaying: appState.nowPlayingTrack?.playbackKey == track.playbackKey && appState.isPlaying,
                isCurrentTrack: appState.nowPlayingTrack?.playbackKey == track.playbackKey
            ) {
                let isCurrent = appState.nowPlayingTrack?.playbackKey == track.playbackKey
                if isCurrent, appState.isPlaying {
                    // Same song already playing → open the full player / preview sheet.
                    // Do NOT toggle playback or restart it.
                    appState.isPlayerPresented = true
                } else if isCurrent {
                    // Same song but paused → resume; the mini player already reflects it.
                    appState.togglePlayback()
                } else {
                    // A different song → start playback; the mini player appears/updates.
                    appState.play(track: track, queue: heroQueue)
                }
            }
        }
    }

    // MARK: - Recently Played

    private var recentlyPlayedSection: some View {
        let tracks = Array(appState.historyTracks.prefix(12))
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Recently Played", showSeeAll: tracks.count > 6) {
                seeAllPayload = SeeAllPayload(title: "Recently Played", tracks: appState.historyTracks)
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(tracks) { track in
                        RecentTrackCard(track: track) {
                            appState.play(track: track, queue: tracks)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Daily Mixes

    private var dailyMixSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Daily Mixes", showSeeAll: false) {}
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(appState.suggestedMixes) { playlist in
                        NavigationLink(value: playlist) {
                            MixCard(playlist: playlist)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Mood Section

    private func homeMoodSection(_ section: HomeMoodSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: section.name, showSeeAll: section.tracks.count > 6) {
                seeAllPayload = SeeAllPayload(title: section.name, tracks: section.tracks)
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(section.tracks.prefix(10))) { track in
                        RecentTrackCard(track: track) {
                            appState.play(track: track, queue: section.tracks)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Trending For You

    @ViewBuilder
    private var trendingForYouSection: some View {
        let tracks = Array(cachedRecommendedTracks.prefix(recommendedVisibleCount))
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: "Recommended For You", showSeeAll: cachedRecommendedTracks.count > 6) {
                seeAllPayload = SeeAllPayload(title: "Recommended For You", tracks: cachedRecommendedTracks)
            }
                .padding(.horizontal, 20)

            if tracks.isEmpty == false {
                // Render whatever we already have (restored cache or local seed) right
                // away — never hide ready recommendations behind a loading skeleton while
                // the background refresh runs.
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.playbackKey) { index, track in
                        TrackSwipeActionsView(
                            onMore: { appState.recommendMoreLike(track) },
                            onLess: { appState.recommendLessLike(track) }
                        ) {
                            RecommendedRow(
                                track: track,
                                isCurrentTrack: appState.nowPlaying?.playbackKey == track.playbackKey,
                                isPlaying: appState.isPlaying
                            ) {
                                appState.play(track: track, queue: cachedRecommendedTracks)
                            }
                        }
                        .onAppear {
                            handleRecommendedRowAppearance(
                                index: index,
                                displayedCount: tracks.count,
                                totalCount: cachedRecommendedTracks.count
                            )
                        }

                        if index < tracks.count - 1 {
                            Divider()
                                .overlay(AppTheme.divider)
                                .padding(.leading, 76)
                        }
                    }
                }
                .padding(.horizontal, 20)
            } else if !appState.hasLoadedHome || appState.isLoading {
                skeletonList
                    .padding(.horizontal, 20)
            } else {
                emptyStateCard("Your recommendations will appear here as you listen.")
                    .padding(.horizontal, 20)
            }
        }
    }

    private func handleRecommendedRowAppearance(index: Int, displayedCount: Int, totalCount: Int) {
        guard index >= displayedCount - 2 else { return }
        guard displayedCount != lastRecommendedLoadTriggerCount else { return }
        lastRecommendedLoadTriggerCount = displayedCount

        if recommendedVisibleCount < totalCount {
            recommendedVisibleCount = min(recommendedVisibleCount + 20, totalCount)
        } else {
            Task { await appState.loadMoreRecommendedTracksIfNeeded() }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(title: String, showSeeAll: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(AppTheme.primaryText)
            Spacer()
            if showSeeAll {
                Button("See all", action: action)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.accent)
            }
        }
    }

    private func emptyStateCard(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(AppTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppTheme.cardFill)
            )
    }

    private func statusCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
                .padding(.top, 2)

            Text(text)
                .font(.footnote)
                .foregroundStyle(AppTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.cardFill)
        )
    }

    private var skeletonList: some View {
        VStack(spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppTheme.controlFill)
                        .frame(width: 52, height: 52)
                        .shimmering()
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(AppTheme.controlFill)
                            .frame(height: 12)
                            .shimmering()
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(AppTheme.cardFill)
                            .frame(width: 100, height: 10)
                            .shimmering()
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Genre Detection

    private func isArabic(_ track: Track) -> Bool {
        let text = "\(track.title) \(track.artist)"
        return text.unicodeScalars.contains {
            (0x0600...0x06FF).contains($0.value) || (0x0750...0x077F).contains($0.value)
        }
    }

    private func isWorship(_ track: Track) -> Bool {
        if track.isQuranOrRecitation { return true }
        let text = "\(track.title) \(track.artist)".lowercased()
        let keywords = ["worship", "praise", "jesus", "god is", "holy spirit", "awakening", "hillsong", "bethel", "elevation worship", "nasheed", "نشيد", "ابتهال"]
        return keywords.contains { text.contains($0) }
    }

    private func isHipHop(_ track: Track) -> Bool {
        let text = "\(track.title) \(track.artist)".lowercased()
        let keywords = ["hip hop", "hip-hop", "rap", "trap", "freestyle", "drill", "flow", "lyrics", "verse"]
        return keywords.contains { text.contains($0) }
    }

}

// MARK: - ContinueListeningHeroCard

private struct ContinueListeningHeroCard: View {
    @EnvironmentObject private var appState: AppState

    let track: Track
    let remainingCount: Int
    let isPlaying: Bool
    let isCurrentTrack: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                // Artwork background
                AsyncArtworkView(url: track.artworkURL, cornerRadius: 0)
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .clipped()

                // Gradient overlay
                LinearGradient(
                    colors: [.clear, .black.opacity(0.78)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Content
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(isPlaying ? "Now Playing" : "Continue Listening", systemImage: isPlaying ? "speaker.wave.2.fill" : "play.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.75))
                            .textCase(.uppercase)

                        Text(track.title)
                            .font(.headline.bold())
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(track.artist)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)

                        if remainingCount > 0 {
                            Text("\(remainingCount) more \(remainingCount == 1 ? "track" : "tracks") in queue")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }

                    Spacer(minLength: 0)

                    ZStack {
                        Circle()
                            .fill(.white)
                            .frame(width: 56, height: 56)
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.black)
                            .offset(x: isPlaying ? 0 : 2)
                    }
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                    .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isPlaying)
                }
                .padding(18)
            }
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 20, y: 8)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    isCurrentTrack
                        ? AppTheme.accent.opacity(0.5)
                        : Color.white.opacity(0.08),
                    lineWidth: 1.5
                )
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isCurrentTrack)
    }
}

// MARK: - RecentTrackCard

private struct RecentTrackCard: View {
    @EnvironmentObject private var appState: AppState

    let track: Track
    let onTap: () -> Void

    private var isCurrentTrack: Bool {
        appState.nowPlaying?.playbackKey == track.playbackKey
    }

    private var isCurrentlyPlaying: Bool {
        isCurrentTrack && appState.isPlaying
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    AsyncArtworkView(url: track.artworkURL, cornerRadius: 12)
                        .frame(width: 120, height: 120)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(
                                    isCurrentTrack ? AppTheme.accent.opacity(0.55) : Color.clear,
                                    lineWidth: 2
                                )
                        )

                    if isCurrentlyPlaying {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(Circle().fill(AppTheme.accent))
                            .padding(6)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isCurrentTrack ? AppTheme.accent : AppTheme.primaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(track.artist)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.tertiaryText)
                        .lineLimit(1)

                    TrackEngagementBadges(track: track)
                }
            }
            .frame(width: 120)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isCurrentTrack)
        .task(id: track.playbackKey) {
            appState.prefetchPlayback(for: [track])
        }
    }
}

// MARK: - FilterChip

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? AppTheme.inverseText : AppTheme.primaryText)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(isSelected ? AppTheme.inverseFill : AppTheme.controlFillStrong)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - MixCard

private struct MixCard: View {
    let playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncArtworkView(url: playlist.artworkURL, cornerRadius: 14)
                .frame(width: 148, height: 148)

            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)

                Text(subtitleText)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(width: 148, alignment: .leading)
    }

    private var subtitleText: String {
        let count = playlist.itemCount
        switch playlist.kind {
        case .likedMusic: return count == 1 ? "1 song" : "\(count) songs"
        case .uploads:    return count == 1 ? "1 upload" : "\(count) uploads"
        case .savedSongs: return count == 1 ? "1 saved song" : "\(count) saved songs"
        case .custom:     return count == 1 ? "1 track" : "\(count) tracks"
        case .standard:   return count == 1 ? "1 track" : "\(count) tracks"
        }
    }
}

// MARK: - TrackListSheet

struct TrackListSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let title: String
    let tracks: [Track]

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                if tracks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(AppTheme.tertiaryText)
                        Text("Nothing here yet")
                            .font(.headline)
                            .foregroundStyle(AppTheme.primaryText)
                        Text("Songs will appear here as you listen.")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                    .padding(.horizontal, 32)
                }
                VStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        let isCurrentTrack = appState.nowPlaying?.playbackKey == track.playbackKey
                        let isPlaying = isCurrentTrack && appState.isPlaying

                        HStack(spacing: 12) {
                            Button {
                                appState.play(track: track, queue: tracks)
                            } label: {
                                HStack(spacing: 12) {
                                    Text("\(index + 1)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(isCurrentTrack ? AppTheme.accent : AppTheme.tertiaryText)
                                        .frame(width: 20, alignment: .trailing)

                                    AsyncArtworkView(url: track.artworkURL, cornerRadius: 8)
                                        .frame(width: 44, height: 44)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .strokeBorder(
                                                    isCurrentTrack ? AppTheme.accent.opacity(0.5) : Color.clear,
                                                    lineWidth: 2
                                                )
                                        )

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(track.title)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(isCurrentTrack ? AppTheme.accent : AppTheme.primaryText)
                                            .lineLimit(1)
                                            .allowsTightening(true)
                                            .truncationMode(.tail)
                                            .layoutPriority(1)

                                        HStack(spacing: 4) {
                                            if isPlaying {
                                                Image(systemName: "speaker.wave.2.fill")
                                                    .font(.caption2.weight(.semibold))
                                                    .foregroundStyle(AppTheme.accent)
                                                Text("Playing")
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(AppTheme.accent)
                                                    .lineLimit(1)
                                            } else if isCurrentTrack {
                                                Image(systemName: "speaker.fill")
                                                    .font(.caption2.weight(.semibold))
                                                    .foregroundStyle(AppTheme.accent.opacity(0.7))
                                                Text("Paused")
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(AppTheme.accent.opacity(0.7))
                                                    .lineLimit(1)
                                            }
                                            TrackEngagementBadges(track: track)

                                            if let duration = track.formattedDuration {
                                                Text(duration)
                                                    .font(.caption)
                                                    .foregroundStyle(AppTheme.tertiaryText)
                                                    .lineLimit(1)
                                                    .fixedSize(horizontal: true, vertical: false)
                                            }
                                        }
                                        .fixedSize(horizontal: true, vertical: false)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            HomeTrackButtons(
                                track: track,
                                onPlay: { appState.play(track: track, queue: tracks) },
                                buttonSize: 32
                            )
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(
                            isCurrentTrack
                                ? AppTheme.accent.opacity(0.06)
                                : Color.clear
                        )
                        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isCurrentTrack)
                        .task(id: track.playbackKey) {
                            appState.prefetchPlayback(for: [track])
                        }

                        if index < tracks.count - 1 {
                            Divider()
                                .overlay(AppTheme.divider)
                                .padding(.leading, 92)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(AppTheme.accent)
                }
            }
            .background(AppTheme.screenBackground.ignoresSafeArea())
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - RecommendedRow

struct RecommendedRow: View {
    let track: Track
    let isCurrentTrack: Bool
    let isPlaying: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    AsyncArtworkView(url: track.artworkURL, cornerRadius: 10)
                        .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isCurrentTrack ? AppTheme.accent : AppTheme.primaryText)
                            .lineLimit(1)
                            .allowsTightening(true)
                            .truncationMode(.tail)
                            .layoutPriority(1)

                        metadataLine
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HomeTrackButtons(track: track, onPlay: onTap)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isCurrentTrack ? AppTheme.accent.opacity(0.07) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            isCurrentTrack ? AppTheme.accent.opacity(0.38) : Color.clear,
                            lineWidth: 1.5
                        )
                )
        )
        .padding(.horizontal, -10)
    }

    private var isCurrentlyPlaying: Bool {
        isCurrentTrack && isPlaying
    }

    private var metadataLine: some View {
        HStack(spacing: 4) {
            playbackStatusBadge
            TrackEngagementBadges(track: track)

            if let duration = track.formattedDuration {
                Text(duration)
                    .font(.caption)
                    .foregroundStyle(AppTheme.tertiaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if let views = track.formattedViewCount {
                Text("· \(views)")
                    .font(.caption)
                    .foregroundStyle(AppTheme.tertiaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineLimit(1)
    }

    @ViewBuilder
    private var playbackStatusBadge: some View {
        if isCurrentlyPlaying {
            statusBadge(systemImage: "speaker.wave.2.fill", text: "Playing", color: AppTheme.accent)
        } else if isCurrentTrack {
            statusBadge(systemImage: "speaker.fill", text: "Paused", color: AppTheme.accent.opacity(0.7))
        }
    }

    private func statusBadge(systemImage: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.semibold))
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - HomeTrackButtons

private struct HomeTrackButtons: View {
    @EnvironmentObject private var appState: AppState
    let track: Track
    let onPlay: () -> Void
    var buttonSize: CGFloat = 36

    var body: some View {
        HStack(spacing: 8) {
            DownloadButton(track: track, size: buttonSize)

            Button(action: handlePlaybackButtonTap) {
                Image(systemName: isCurrentTrack && appState.isPlaying ? "pause.fill" : "play.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: buttonSize, height: buttonSize)
                    .background(Circle().fill(AppTheme.accent))
            }
            .buttonStyle(.plain)
        }
    }

    private var isCurrentTrack: Bool {
        appState.nowPlaying?.playbackKey == track.playbackKey
    }

    private func handlePlaybackButtonTap() {
        if isCurrentTrack {
            appState.togglePlayback()
        } else {
            onPlay()
        }
    }
}

// MARK: - HomeAccountSheet

private struct HomeAccountSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            if let user = appState.user {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color(red: 0.85, green: 0.22, blue: 0.22))
                            .frame(width: 52, height: 52)
                        Text(initials(from: user.name))
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(user.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(user.email)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)

                Divider().padding(.horizontal, 20)

                HStack(spacing: 12) {
                    Button {
                        dismiss()
                        Task { await appState.switchAccount() }
                    } label: {
                        Label("Switch Account", systemImage: "arrow.left.arrow.right")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.accent))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    Button {
                        dismiss()
                        Task { await appState.signOut() }
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemFill)))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
        }
        .padding(.bottom, 8)
    }

    private func initials(from name: String) -> String {
        let parts = name.components(separatedBy: " ").filter { !$0.isEmpty }
        return parts.prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}

// MARK: - Shimmer

private struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, AppTheme.divider, .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 2)
                    .offset(x: geo.size.width * (phase - 1))
                }
                .allowsHitTesting(false)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 2
                }
            }
            .onDisappear {
                phase = 0
            }
    }
}

private extension View {
    func shimmering() -> some View { modifier(ShimmerModifier()) }
}
