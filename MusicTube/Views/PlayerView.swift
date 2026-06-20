import AVKit
import SwiftUI

// MARK: - Player Tab

private enum PlayerTab: String, CaseIterable {
    case queue   = "Queue"
    case related = "Related"
    case lyrics  = "Lyrics"
}

// MARK: - PlayerView

struct PlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: AppState

    let track: Track
    let playbackService: PlaybackService

    @State private var showSleepTimerSheet = false
    @State private var sharePayload: TrackSharePayload?
    @State private var isPreparingShare = false
    @State private var isShowingHeartBurst = false
    @State private var heartBurstID = 0
    @State private var selectedTab: PlayerTab = .related
    @Namespace private var tabNamespace

    @ObservedObject private var downloadService = DownloadService.shared
    @State private var dragOffset: CGFloat = 0
    @State private var scrollOffsetY: CGFloat = 0
    @State private var minimizeDragStartTranslation: CGFloat?

    var body: some View {
        ZStack {
            // Backdrop revealed by the rounded top corners and during the
            // swipe-to-minimize shrink. Matches the player tone so the safe-area
            // edges stay light instead of showing a black bar.
            AppTheme.playerBackground.ignoresSafeArea()

            playerCard
                .offset(y: max(0, dragOffset))
                .scaleEffect(1 - dismissProgress * 0.045)
                .opacity(1 - dismissProgress * 0.10)
                .clipShape(TopRoundedRectangle(radius: 38 + dismissProgress * 10))
                .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.82), value: dragOffset)
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { likeWithHeartBurst() }
        )
        .simultaneousGesture(playerMinimizeGesture)
        .sheet(isPresented: $showSleepTimerSheet) {
            SleepTimerSheet()
                .environmentObject(appState)
                .presentationDetents([.height(360)])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $sharePayload) { payload in
            TrackShareSheet(activityItems: [TrackShareItemSource(payload: payload)])
        }
    }

    private var playerCard: some View {
        ZStack {
            playerBackground.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PlayerScrollOffsetPreferenceKey.self,
                        value: proxy.frame(in: .named(PlayerScrollCoordinateSpace.name)).minY
                    )
                }
                .frame(height: 0)

                VStack(spacing: 20) {
                    dragHandle
                    header
                    artwork
                    titleArea
                    progressCard
                    transportCard
                    secondaryControls
                    playerTabBar
                    playerTabContent
                    utilityCard
                    if let url = track.youtubeWatchURL {
                        youtubeLink(url: url)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .padding(.bottom, 48)
            }
            .coordinateSpace(name: PlayerScrollCoordinateSpace.name)
            .onPreferenceChange(PlayerScrollOffsetPreferenceKey.self) { value in
                guard abs(scrollOffsetY - value) > 2 else { return }
                scrollOffsetY = value
            }

            if isShowingHeartBurst {
                HeartBurstView()
                    .id(heartBurstID)
                    .transition(.scale(scale: 0.35).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Heart Burst

    private func likeWithHeartBurst() {
        appState.likeTrackIfNeeded(track)
        heartBurstID += 1
        withAnimation(.spring(response: 0.24, dampingFraction: 0.62)) {
            isShowingHeartBurst = true
        }
        let id = heartBurstID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard heartBurstID == id else { return }
            withAnimation(.easeOut(duration: 0.22)) { isShowingHeartBurst = false }
        }
    }

    // MARK: Drag Handle

    private var dragHandle: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(AppTheme.playerHandle)
                    .frame(width: 40, height: 5)
                    .padding(.top, 10)
            }
            .contentShape(Rectangle())
            .gesture(playerMinimizeGesture)
    }

    private var dismissProgress: CGFloat {
        min(max(dragOffset / 420, 0), 1)
    }

    private var isScrolledToTop: Bool {
        scrollOffsetY > -8
    }

    private var playerMinimizeGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .local)
            .onChanged { value in
                if minimizeDragStartTranslation == nil {
                    guard canStartMinimizeDrag(value) else { return }
                    minimizeDragStartTranslation = value.translation.height
                }
                let effectiveTranslation = value.translation.height - (minimizeDragStartTranslation ?? 0)
                guard effectiveTranslation > 0 else {
                    dragOffset = 0
                    return
                }
                dragOffset = min(effectiveTranslation, 520)
            }
            .onEnded { value in
                guard let startTranslation = minimizeDragStartTranslation else { return }
                minimizeDragStartTranslation = nil

                let distance = value.translation.height - startTranslation
                let projectedDistance = value.predictedEndTranslation.height - startTranslation
                let startedOnHandle = value.startLocation.y < 88
                let shouldDismiss = startedOnHandle
                    ? (distance > 46 || projectedDistance > 210)
                    : (distance > 96 || projectedDistance > 280)
                if shouldDismiss {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.92)) {
                        dragOffset = 900
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                        appState.dismissPlayer()
                        dismiss()
                    }
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private func canStartMinimizeDrag(_ value: DragGesture.Value) -> Bool {
        // Only allow swipe-to-minimize when the content is at the top. Once the
        // user has scrolled down, a downward drag scrolls the content instead.
        guard isScrolledToTop else { return false }
        return value.startLocation.y < 520
    }

    // MARK: Header

    private var header: some View {
        let sideWidth: CGFloat = 136
        return HStack(spacing: 12) {
            Button {
                appState.dismissPlayer()
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(width: 40, height: 40)
                    .background(AppTheme.controlFill)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .frame(width: sideWidth, alignment: .leading)

            VStack(spacing: 2) {
                Text("Now Playing")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .textCase(.uppercase)
                Text("MusicTube")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)

            HStack {
                ZStack {
                    Circle().fill(AppTheme.controlFill).frame(width: 40, height: 40)
                    AirPlayPickerView().frame(width: 40, height: 40)
                }

                Button { prepareShareSheet() } label: {
                    ZStack {
                        Image(systemName: "square.and.arrow.up")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(track.musicTubeShareURL == nil ? AppTheme.tertiaryText : AppTheme.primaryText)
                            .opacity(isPreparingShare ? 0 : 1)
                        if isPreparingShare {
                            ProgressView().tint(AppTheme.primaryText).controlSize(.small)
                        }
                    }
                    .frame(width: 40, height: 40)
                    .background(AppTheme.controlFill)
                    .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(track.musicTubeShareURL == nil || isPreparingShare)

                Button {
                    if downloadService.isDownloading(track) {
                        downloadService.cancelDownload(for: track)
                    } else if !downloadService.isDownloaded(track) {
                        appState.downloadTrack(track)
                    }
                } label: {
                    ZStack {
                        Circle().fill(AppTheme.controlFill).frame(width: 40, height: 40)
                        if downloadService.isDownloading(track) {
                            let key = track.youtubeVideoID ?? track.id
                            let progress = downloadService.activeDownloads[key]?.progress ?? 0
                            CircularProgress(progress: progress).frame(width: 22, height: 22)
                            Image(systemName: "stop.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(AppTheme.secondaryText)
                        } else if downloadService.isDownloaded(track) {
                            Image(systemName: "arrow.down.circle")
                                .font(.headline)
                                .foregroundStyle(AppTheme.secondaryText)
                        } else {
                            Image(systemName: "arrow.down.circle")
                                .font(.headline)
                                .foregroundStyle(AppTheme.primaryText)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(downloadService.isDownloaded(track))
                .accessibilityLabel(
                    downloadService.isDownloading(track) ? "Stop Download" :
                    downloadService.isDownloaded(track) ? "Downloaded" : "Download"
                )
            }
            .frame(width: sideWidth, alignment: .trailing)
        }
    }

    // MARK: Artwork

    private var artwork: some View {
        NowPlayingArtworkView(artworkURL: track.artworkURL, playbackService: playbackService)
    }

    // MARK: Title

    private var titleArea: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.title2.bold())
                    .foregroundStyle(AppTheme.primaryText)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !track.artist.isEmpty {
                    Text(track.artist)
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                TrackActionsButton(track: track, size: 38)
                Button { appState.toggleLike(for: track) } label: {
                    Image(systemName: appState.isTrackLiked(track) ? "heart.fill" : "heart")
                        .font(.title2)
                        .foregroundStyle(appState.isTrackLiked(track) ? AppTheme.accent : AppTheme.secondaryText)
                        .animation(.spring(response: 0.3), value: appState.isTrackLiked(track))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
    }

    private func prepareShareSheet() {
        guard track.musicTubeShareURL != nil, !isPreparingShare else { return }
        isPreparingShare = true
        Task {
            let payload = await makeTrackSharePayload(for: track)
            await MainActor.run {
                sharePayload = payload
                isPreparingShare = false
            }
        }
    }

    // MARK: Playback Cards

    private var progressCard: some View {
        PlaybackProgressCard(playbackService: playbackService, trackID: track.id)
            .environmentObject(appState)
    }

    private var transportCard: some View {
        PlaybackTransportCard(playbackService: playbackService)
            .environmentObject(appState)
    }

    private var secondaryControls: some View {
        PlaybackSecondaryControls(
            playbackService: playbackService,
            showSleepTimerSheet: $showSleepTimerSheet,
            onUpNextTap: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    selectedTab = .queue
                }
            }
        )
        .environmentObject(appState)
    }

    // MARK: Tab Bar

    private var playerTabBar: some View {
        HStack(spacing: 0) {
            ForEach(PlayerTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 6) {
                        Text(tab.rawValue)
                            .font(.subheadline.weight(selectedTab == tab ? .semibold : .regular))
                            .foregroundStyle(selectedTab == tab ? AppTheme.primaryText : AppTheme.secondaryText)
                        ZStack {
                            Capsule().fill(Color.clear).frame(height: 2)
                            if selectedTab == tab {
                                Capsule()
                                    .fill(AppTheme.accent)
                                    .frame(height: 2)
                                    .matchedGeometryEffect(id: "tabLine", in: tabNamespace)
                            }
                        }
                        .frame(height: 2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
        .background(PlayerGlassCardBackground(cornerRadius: 18))
    }

    // MARK: Tab Content

    @ViewBuilder
    private var playerTabContent: some View {
        switch selectedTab {
        case .queue:
            QueueTabContent(playbackService: playbackService)
                .environmentObject(appState)
                .transition(.opacity)
        case .related:
            RelatedTabContent()
                .environmentObject(appState)
                .transition(.opacity)
        case .lyrics:
            LyricsTabContent()
                .transition(.opacity)
        }
    }

    // MARK: Utility Card

    private var utilityCard: some View {
        VStack(spacing: 0) {
            if downloadService.isDownloaded(track) {
                infoRow(
                    icon: "checkmark.circle.fill",
                    iconColor: .green,
                    title: "Saved for offline",
                    subtitle: "This track plays without an internet connection."
                )
                Divider().overlay(AppTheme.divider).padding(.leading, 48)
            }
            infoRow(
                icon: "waveform",
                iconColor: Color(red: 1, green: 0.23, blue: 0.42),
                title: "Background playback",
                subtitle: "Plays on the lock screen, home screen, and CarPlay."
            )
        }
        .padding(.vertical, 6)
        .background(glassCard(cornerRadius: 24))
    }

    private func infoRow(icon: String, iconColor: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func youtubeLink(url: URL) -> some View {
        Link(destination: url) {
            Label("Open in YouTube", systemImage: "arrow.up.right.square")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
    }

    // MARK: Background (Dynamic Blurred Artwork)

    private var playerBackground: some View {
        ZStack {
            // Adaptive base: near-black in dark mode, soft lavender-white in light mode.
            AppTheme.playerBackground

            // Blurred artwork tint — more subdued in light mode to keep text legible.
            AsyncArtworkView(
                url: track.artworkURL,
                cornerRadius: 0,
                maxPixelSize: ArtworkPixelSize.nowPlaying
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .blur(radius: 72)
            .opacity(colorScheme == .dark ? 0.55 : 0.22)
            .clipped()
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.7), value: track.id)

            // Gradient overlay — dark mode keeps the premium black vignette;
            // light mode uses a white vignette so the background stays bright.
            LinearGradient(
                stops: colorScheme == .dark ? [
                    .init(color: Color.black.opacity(0.00), location: 0.0),
                    .init(color: Color.black.opacity(0.45), location: 0.42),
                    .init(color: Color.black.opacity(0.82), location: 1.0),
                ] : [
                    .init(color: Color.white.opacity(0.00), location: 0.0),
                    .init(color: Color.white.opacity(0.40), location: 0.42),
                    .init(color: Color.white.opacity(0.70), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private func glassCard(cornerRadius: CGFloat) -> some View {
        PlayerGlassCardBackground(cornerRadius: cornerRadius)
    }
}

// MARK: - HeartBurstView

private struct HeartBurstView: View {
    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 112, weight: .bold))
            .foregroundStyle(AppTheme.accent)
            .shadow(color: AppTheme.accent.opacity(0.35), radius: 24, y: 8)
    }
}

// MARK: - PlayerGlassCardBackground

private struct PlayerGlassCardBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(AppTheme.playerGlassOverlay)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(AppTheme.playerGlassStroke, lineWidth: 1)
            }
    }
}

// MARK: - TopRoundedRectangle

/// Rounds only the top-leading and top-trailing corners. Pure SwiftUI `Path`
/// (no UIKit) so it needs no extra import, and animates via `radius`.
private struct TopRoundedRectangle: Shape {
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = max(0, min(radius, min(rect.width, rect.height) / 2))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.minY + r),
            radius: r,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.minY + r),
            radius: r,
            startAngle: .degrees(270),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Player Scroll Tracking

private enum PlayerScrollCoordinateSpace {
    static let name = "MusicTubePlayerScroll"
}

private struct PlayerScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - NowPlayingArtworkView

private struct NowPlayingArtworkView: View {
    let artworkURL: URL?
    @ObservedObject var playbackService: PlaybackService
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        AsyncArtworkView(
            url: artworkURL,
            cornerRadius: 26,
            maxPixelSize: ArtworkPixelSize.nowPlaying,
            contentMode: .fit
        )
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.15), radius: 36, y: 20)
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(AppTheme.playerGlassStroke, lineWidth: 1)
        }
        .scaleEffect(playbackService.state.isPlaying ? 1.0 : 0.94)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: playbackService.state.isPlaying)
    }
}

// MARK: - PlaybackProgressCard

private struct PlaybackProgressCard: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var playbackService: PlaybackService
    let trackID: String

    @State private var scrubPosition: Double = 0
    @State private var isScrubbing = false
    @State private var scrubSafetyTask: Task<Void, Never>?

    var body: some View {
        let playbackState = playbackService.state

        VStack(spacing: 12) {
            BufferedScrubber(
                value: $scrubPosition,
                duration: max(playbackState.duration, 1),
                bufferedProgress: bufferedProgress(for: playbackState),
                playedProgress: playedProgress(for: playbackState),
                showsThumb: isScrubbing,
                isEnabled: playbackState.duration > 0,
                onEditingChanged: handleScrubbingChanged
            )

            HStack {
                Text(formatted(displayedPlaybackPosition))
                    .foregroundStyle(AppTheme.secondaryText)
                Spacer()
                if playbackState.isResolvingStream {
                    HStack(spacing: 6) {
                        ProgressView().tint(AppTheme.primaryText).scaleEffect(0.7)
                        Text("Loading audio…")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                } else if playbackState.isBufferingPlayback {
                    HStack(spacing: 6) {
                        ProgressView().tint(AppTheme.primaryText).scaleEffect(0.7)
                        Text("Buffering…")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }
                Spacer()
                Text(formatted(playbackState.duration))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .font(.caption.monospacedDigit())
        }
        .padding(20)
        .background(PlayerGlassCardBackground(cornerRadius: 26))
        .onAppear { syncScrubber(with: playbackState) }
        .onChange(of: trackID) { _, _ in syncScrubber(with: playbackService.state) }
        .onChange(of: playbackState.currentTime) { _, newTime in
            guard !isScrubbing else { return }
            if abs(scrubPosition - newTime) > 0.25 { syncScrubber(with: playbackState) }
        }
        .onChange(of: playbackState.duration) { _, _ in
            guard !isScrubbing else { return }
            syncScrubber(with: playbackState)
        }
    }

    private var displayedPlaybackPosition: TimeInterval { scrubPosition }

    private func playedProgress(for state: PlaybackState) -> CGFloat {
        guard state.duration > 0 else { return 0 }
        return CGFloat(min(max(displayedPlaybackPosition / state.duration, 0), 1))
    }

    private func bufferedProgress(for state: PlaybackState) -> CGFloat {
        guard state.duration > 0 else { return 0 }
        return CGFloat(min(max(state.bufferedTime / state.duration, 0), 1))
    }

    private func handleScrubbingChanged(_ editing: Bool) {
        scrubSafetyTask?.cancel()
        isScrubbing = editing
        if !editing {
            appState.seek(to: scrubPosition)
        } else {
            scrubSafetyTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, isScrubbing else { return }
                isScrubbing = false
                appState.seek(to: scrubPosition)
            }
        }
    }

    private func syncScrubber(with state: PlaybackState) {
        scrubPosition = max(0, min(state.currentTime, state.duration))
    }

    private func formatted(_ interval: TimeInterval) -> String {
        Track.formatDuration(interval) ?? "0:00"
    }
}

// MARK: - PlaybackTransportCard

private struct PlaybackTransportCard: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var playbackService: PlaybackService

    var body: some View {
        let state = playbackService.state

        HStack(spacing: 24) {
            Button { appState.playPreviousTrack() } label: {
                Image(systemName: "backward.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(state.hasPreviousTrack ? AppTheme.primaryText : AppTheme.tertiaryText)
                    .frame(width: 52, height: 52)
                    .background(AppTheme.controlFill)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!state.hasPreviousTrack)

            Button { appState.togglePlayback() } label: {
                ZStack {
                    Circle()
                        .fill(AppTheme.inverseFill)
                        .frame(width: 84, height: 84)
                    if state.isResolvingStream {
                        ProgressView().tint(AppTheme.inverseText)
                    } else {
                        Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(AppTheme.inverseText)
                            .offset(x: state.isPlaying ? 0 : 2)
                    }
                }
            }
            .buttonStyle(.plain)

            Button { appState.playNextTrack() } label: {
                Image(systemName: "forward.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(state.hasNextTrack ? AppTheme.primaryText : AppTheme.tertiaryText)
                    .frame(width: 52, height: 52)
                    .background(AppTheme.controlFill)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!state.hasNextTrack)
        }
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .background(PlayerGlassCardBackground(cornerRadius: 30))
    }
}

// MARK: - PlaybackSecondaryControls

private struct PlaybackSecondaryControls: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var playbackService: PlaybackService
    @Binding var showSleepTimerSheet: Bool
    let onUpNextTap: () -> Void

    private static let speedSteps: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        HStack(spacing: 0) {
            Spacer()

            Button { appState.toggleShuffle() } label: {
                controlLabel(icon: "shuffle",
                             isActive: playbackService.shuffleMode,
                             activeColor: AppTheme.accent)
            }
            .buttonStyle(.plain)

            Spacer()

            Button { appState.cycleRepeatMode() } label: {
                controlLabel(icon: repeatIcon,
                             isActive: playbackService.repeatMode != .off,
                             activeColor: AppTheme.accent)
            }
            .buttonStyle(.plain)

            Spacer()

            Button { cycleSpeed() } label: {
                VStack(spacing: 4) {
                    Text(speedLabel)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(playbackService.playbackRate == 1.0 ? AppTheme.secondaryText : AppTheme.accent)
                        .frame(minWidth: 36)
                    Circle()
                        .fill(playbackService.playbackRate != 1.0 ? AppTheme.accent : Color.clear)
                        .frame(width: 4, height: 4)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button { onUpNextTap() } label: {
                controlLabel(icon: "list.bullet", isActive: false, activeColor: AppTheme.accent)
            }
            .buttonStyle(.plain)

            Spacer()

            Button { showSleepTimerSheet = true } label: {
                controlLabel(icon: "moon.zzz",
                             isActive: appState.sleepTimerEndDate != nil,
                             activeColor: Color.cyan)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(PlayerGlassCardBackground(cornerRadius: 22))
    }

    private func controlLabel(icon: String, isActive: Bool, activeColor: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isActive ? activeColor : AppTheme.secondaryText)
            Circle()
                .fill(isActive ? activeColor : Color.clear)
                .frame(width: 4, height: 4)
        }
    }

    private var speedLabel: String {
        let rate = playbackService.playbackRate
        if rate == 1.0 { return "1×" }
        return String(format: rate.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f×" : "%.2g×", rate)
    }

    private var repeatIcon: String {
        playbackService.repeatMode == .one ? "repeat.1" : "repeat"
    }

    private func cycleSpeed() {
        let current = playbackService.playbackRate
        let next = Self.speedSteps.first(where: { $0 > current }) ?? Self.speedSteps[0]
        appState.setPlaybackRate(next)
    }
}

// MARK: - QueueTabContent

private struct QueueTabContent: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var playbackService: PlaybackService

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let nowPlaying = playbackService.nowPlaying {
                HStack(spacing: 12) {
                    AsyncArtworkView(url: nowPlaying.artworkURL, cornerRadius: 10)
                        .frame(width: 52, height: 52)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(AppTheme.accent.opacity(0.5), lineWidth: 2)
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Now Playing")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.accent)
                            .textCase(.uppercase)
                        Text(nowPlaying.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.primaryText)
                            .lineLimit(1)
                        if !nowPlaying.artist.isEmpty {
                            Text(nowPlaying.artist)
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.accent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Divider().overlay(AppTheme.divider).padding(.leading, 20)
            }

            let upNext = upNextTracks
            if upNext.isEmpty {
                Text("No upcoming tracks in the queue.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let displayed = Array(upNext.prefix(20))
                ForEach(Array(displayed.enumerated()), id: \.element.id) { index, track in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AppTheme.tertiaryText)
                            .frame(width: 20, alignment: .trailing)

                        AsyncArtworkView(url: track.artworkURL, cornerRadius: 8)
                            .frame(width: 44, height: 44)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(AppTheme.primaryText)
                                .lineLimit(1)
                            if !track.artist.isEmpty {
                                Text(track.artist)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.secondaryText)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        Button {
                            appState.play(track: track, queue: playbackService.currentQueue)
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(AppTheme.accent))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                    if index < displayed.count - 1 {
                        Divider().overlay(AppTheme.divider).padding(.leading, 80)
                    }
                }

                if upNext.count > 20 {
                    Text("+\(upNext.count - 20) more tracks")
                        .font(.caption)
                        .foregroundStyle(AppTheme.tertiaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
            }
        }
        .background(PlayerGlassCardBackground(cornerRadius: 22))
    }

    private var upNextTracks: [Track] {
        guard let idx = playbackService.currentQueueIndex else { return [] }
        let queue = playbackService.currentQueue
        guard idx + 1 < queue.count else { return [] }
        return Array(queue[(idx + 1)...])
    }
}

// MARK: - RelatedTabContent

private struct RelatedTabContent: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let tracks = Array(appState.relatedTracks.prefix(8))

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Related Songs")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .textCase(.uppercase)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                Spacer()
                if appState.isLoadingRelatedTracks {
                    ProgressView()
                        .tint(AppTheme.primaryText)
                        .scaleEffect(0.75)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                }
            }

            if tracks.isEmpty {
                Text(
                    appState.isLoadingRelatedTracks
                        ? "Loading related songs…"
                        : "Play more songs and MusicTube will keep improving the matches here."
                )
                .font(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    RecommendedRow(
                        track: track,
                        isCurrentTrack: appState.nowPlaying?.playbackKey == track.playbackKey,
                        isPlaying: appState.isPlaying
                    ) {
                        appState.play(track: track, queue: appState.relatedTracks)
                    }
                    .padding(.horizontal, 16)
                    if index < tracks.count - 1 {
                        Divider().overlay(AppTheme.divider).padding(.leading, 92)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .background(PlayerGlassCardBackground(cornerRadius: 22))
        .task(id: appState.nowPlaying?.playbackKey) {
            appState.refreshRelatedTracksForCurrentTrackIfNeeded()
        }
    }
}

// MARK: - LyricsTabContent

private struct LyricsTabContent: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.bubble")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(AppTheme.tertiaryText)
                .padding(.top, 4)

            Text("Lyrics Not Available")
                .font(.headline)
                .foregroundStyle(AppTheme.secondaryText)

            Text("Lyrics for this track are not currently available.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.tertiaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(PlayerGlassCardBackground(cornerRadius: 22))
    }
}

// MARK: - AirPlayPickerView

private struct AirPlayPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .label  // Adapts: white in dark mode, black in light mode
        view.activeTintColor = UIColor(AppTheme.accent)
        view.prioritizesVideoDevices = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - BufferedScrubber

private struct BufferedScrubber: View {
    @Binding var value: Double

    let duration: Double
    let bufferedProgress: CGFloat
    let playedProgress: CGFloat
    let showsThumb: Bool
    let isEnabled: Bool
    let onEditingChanged: (Bool) -> Void

    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)

            ZStack(alignment: .leading) {
                Capsule().fill(AppTheme.progressTrack).frame(height: 6)
                Capsule().fill(AppTheme.progressBuffered).frame(width: width * bufferedProgress, height: 6)
                Capsule().fill(AppTheme.progressPlayed).frame(width: width * playedProgress, height: 6)

                if showsThumb && isEnabled {
                    Circle()
                        .fill(AppTheme.progressPlayed)
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                        .offset(x: thumbOffset(for: width) - 7)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard isEnabled else { return }
                        if !isDragging { isDragging = true; onEditingChanged(true) }
                        value = clampedValue(for: g.location.x, width: width)
                    }
                    .onEnded { g in
                        guard isEnabled else { return }
                        value = clampedValue(for: g.location.x, width: width)
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue(Track.formatDuration(value) ?? "0:00")
        }
        .frame(height: 22)
    }

    private func clampedValue(for x: CGFloat, width: CGFloat) -> Double {
        guard duration > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1)) * duration
    }

    private func thumbOffset(for width: CGFloat) -> CGFloat {
        width * playedProgress
    }
}

// MARK: - CircularProgress

struct CircularProgress: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(AppTheme.progressTrack, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.cyan, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: progress)
        }
    }
}

// MARK: - SleepTimerSheet

private struct SleepTimerSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private let options = [15, 30, 45, 60, 90]

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Image(systemName: "moon.zzz.fill")
                    .font(.largeTitle)
                    .foregroundStyle(Color.cyan)
                Text("Sleep Timer")
                    .font(.title3.bold())
                    .foregroundStyle(AppTheme.primaryText)
                if let endDate = appState.sleepTimerEndDate {
                    Text("Stops at \(endDate, style: .time)")
                        .font(.subheadline)
                        .foregroundStyle(Color.cyan.opacity(0.8))
                }
            }
            .padding(.top, 8)

            VStack(spacing: 10) {
                ForEach(options, id: \.self) { minutes in
                    Button {
                        appState.setSleepTimer(minutes: minutes)
                        dismiss()
                    } label: {
                        HStack {
                            Text("\(minutes) minutes")
                                .font(.body.weight(.medium))
                                .foregroundStyle(AppTheme.primaryText)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(AppTheme.tertiaryText)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(AppTheme.cardFill)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)

            if appState.sleepTimerEndDate != nil {
                Button("Cancel Timer") {
                    appState.cancelSleepTimer()
                    dismiss()
                }
                .foregroundStyle(Color.red.opacity(0.85))
                .font(.subheadline.weight(.semibold))
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(AppTheme.screenBackground.ignoresSafeArea())
    }
}
