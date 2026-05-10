import AVKit
import SwiftUI

struct PlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    let track: Track
    @ObservedObject var playbackService: PlaybackService

    @State private var scrubPosition: Double = 0
    @State private var isScrubbing = false
    @State private var scrubSafetyTask: Task<Void, Never>?
    @State private var showSleepTimerSheet = false
    @State private var showUpNextSheet = false
    @ObservedObject private var downloadService = DownloadService.shared

    private static let speedSteps: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    /// Tracks how far the user has dragged downward for swipe-to-dismiss.
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            playerBackground.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    // Drag handle — swipe down here to dismiss
                    dragHandle

                    header
                    artwork
                    titleArea
                    progressCard
                    transportCard
                    secondaryControls
                    utilityCard
                    relatedSongsSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .padding(.bottom, 40)
            }
        }
        .offset(y: max(0, dragOffset))
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.7), value: dragOffset)
        .onAppear { syncScrubber() }
        .onChange(of: track.id) { _, _ in syncScrubber() }
        .onChange(of: playbackService.currentTime) { _, newTime in
            guard !isScrubbing else { return }
            // Avoid redundant body re-renders when scrubPosition is already in sync.
            if abs(scrubPosition - newTime) > 0.25 { syncScrubber() }
        }
        .onChange(of: playbackService.duration) { _, _ in
            guard !isScrubbing else { return }
            syncScrubber()
        }
        .sheet(isPresented: $showSleepTimerSheet) {
            SleepTimerSheet()
                .environmentObject(appState)
                .presentationDetents([.height(360)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showUpNextSheet) {
            UpNextSheet(playbackService: playbackService)
                .environmentObject(appState)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // Drag-handle — full-width transparent hit area with a visible pill.
    // The dismiss gesture lives here only, so it never conflicts with the Slider.
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
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        let dy = value.translation.height
                        guard dy > 0 else { return }
                        dragOffset = dy
                    }
                    .onEnded { value in
                        let dy       = value.translation.height
                        let velocity = value.predictedEndTranslation.height
                        if dy > 36 || velocity > 200 {
                            withAnimation(.easeIn(duration: 0.18)) { dragOffset = 900 }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                                appState.dismissPlayer()
                                dismiss()
                            }
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
    }

    // MARK: Header

    private var header: some View {
        let sideControlsWidth: CGFloat = 136

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
            .frame(width: sideControlsWidth, alignment: .leading)

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
                    Circle()
                        .fill(AppTheme.controlFill)
                        .frame(width: 40, height: 40)
                    AirPlayPickerView()
                        .frame(width: 40, height: 40)
                }

                if let shareURL = track.musicTubeShareURL {
                    ShareLink(item: shareURL) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(AppTheme.primaryText)
                            .frame(width: 40, height: 40)
                            .background(AppTheme.controlFill)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(AppTheme.tertiaryText)
                        .frame(width: 40, height: 40)
                        .background(AppTheme.controlFill)
                        .clipShape(Circle())
                }

                Button {
                    if downloadService.isDownloaded(track) {
                        // Already downloaded — no-op or show confirmation
                    } else {
                        appState.downloadTrack(track)
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(AppTheme.controlFill)
                            .frame(width: 40, height: 40)

                        if downloadService.isDownloading(track) {
                            let key = track.youtubeVideoID ?? track.id
                            let progress = downloadService.activeDownloads[key]?.progress ?? 0
                            CircularProgress(progress: progress)
                                .frame(width: 22, height: 22)
                        } else if downloadService.isDownloaded(track) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.headline)
                                .foregroundStyle(Color.cyan)
                        } else {
                            Image(systemName: "arrow.down.circle")
                                .font(.headline)
                                .foregroundStyle(AppTheme.primaryText)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(downloadService.isDownloading(track) || downloadService.isDownloaded(track))
            }
            .frame(width: sideControlsWidth, alignment: .trailing)
        }
    }

    // MARK: Artwork

    private var artwork: some View {
        AsyncArtworkView(
            url: track.artworkURL,
            cornerRadius: 30,
            maxPixelSize: ArtworkPixelSize.nowPlaying
        )
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 320)
            .shadow(color: .black.opacity(0.45), radius: 30, y: 18)
            .overlay {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(AppTheme.playerGlassStroke, lineWidth: 1)
            }
            .scaleEffect(playbackService.isPlaying ? 1.0 : 0.95)
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: playbackService.isPlaying)
    }

    // MARK: Title

    private var titleArea: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(track.title)
                    .font(.title2.bold())
                    .foregroundStyle(AppTheme.primaryText)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(track.artist)
                    .font(.body)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                TrackActionsButton(track: track, size: 38)

                Button {
                    appState.toggleLike(for: track)
                } label: {
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

    // MARK: Progress Card

    private var progressCard: some View {
        VStack(spacing: 12) {
            BufferedScrubber(
                value: $scrubPosition,
                duration: max(playbackService.duration, 1),
                bufferedProgress: bufferedProgress,
                playedProgress: playedProgress,
                showsThumb: isScrubbing,
                isEnabled: playbackService.duration > 0,
                onEditingChanged: handleScrubbingChanged
            )

            HStack {
                Text(formatted(displayedPlaybackPosition))
                    .foregroundStyle(AppTheme.secondaryText)
                Spacer()
                if playbackService.isResolvingStream {
                    HStack(spacing: 6) {
                        ProgressView().tint(AppTheme.primaryText).scaleEffect(0.7)
                        Text("Loading audio…")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                } else if playbackService.isBufferingPlayback {
                    HStack(spacing: 6) {
                        ProgressView().tint(AppTheme.primaryText).scaleEffect(0.7)
                        Text("Buffering…")
                            .font(.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }
                Spacer()
                Text(formatted(playbackService.duration))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .font(.caption.monospacedDigit())
        }
        .padding(20)
        .background(glassCard(cornerRadius: 26))
    }

    // MARK: Transport Card

    private var transportCard: some View {
        HStack(spacing: 24) {
            Button { appState.playPreviousTrack() } label: {
                Image(systemName: "backward.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(playbackService.hasPreviousTrack ? AppTheme.primaryText : AppTheme.tertiaryText)
                    .frame(width: 52, height: 52)
                    .background(AppTheme.controlFill)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!playbackService.hasPreviousTrack)

            // Play / Pause
            Button { appState.togglePlayback() } label: {
                ZStack {
                    Circle()
                        .fill(AppTheme.inverseFill)
                        .frame(width: 84, height: 84)
                    if playbackService.isResolvingStream {
                        ProgressView().tint(AppTheme.inverseText)
                    } else {
                        Image(systemName: playbackService.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(AppTheme.inverseText)
                            .offset(x: playbackService.isPlaying ? 0 : 2)
                    }
                }
            }
            .buttonStyle(.plain)

            Button { appState.playNextTrack() } label: {
                Image(systemName: "forward.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(playbackService.hasNextTrack ? AppTheme.primaryText : AppTheme.tertiaryText)
                    .frame(width: 52, height: 52)
                    .background(AppTheme.controlFill)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!playbackService.hasNextTrack)
        }
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .background(glassCard(cornerRadius: 30))
    }

    // MARK: Secondary Controls (Shuffle / Repeat / Speed / Up Next / Sleep Timer)

    private var secondaryControls: some View {
        HStack(spacing: 0) {
            Spacer()

            // Shuffle
            Button { appState.toggleShuffle() } label: {
                secondaryControlLabel(
                    icon: "shuffle",
                    isActive: playbackService.shuffleMode,
                    activeColor: AppTheme.accent
                )
            }
            .buttonStyle(.plain)

            Spacer()

            // Repeat
            Button { appState.cycleRepeatMode() } label: {
                secondaryControlLabel(
                    icon: repeatIcon,
                    isActive: playbackService.repeatMode != .off,
                    activeColor: AppTheme.accent
                )
            }
            .buttonStyle(.plain)

            Spacer()

            // Speed
            Button { cycleSpeed() } label: {
                VStack(spacing: 4) {
                    Text(speedLabel)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(playbackService.playbackRate == 1.0 ? AppTheme.secondaryText : AppTheme.accent)
                        .frame(minWidth: 36)
                    if playbackService.playbackRate != 1.0 {
                        Circle()
                            .fill(AppTheme.accent)
                            .frame(width: 4, height: 4)
                    } else {
                        Color.clear.frame(width: 4, height: 4)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // Up Next
            Button { showUpNextSheet = true } label: {
                secondaryControlLabel(
                    icon: "list.bullet",
                    isActive: false,
                    activeColor: AppTheme.accent
                )
            }
            .buttonStyle(.plain)

            Spacer()

            // Sleep Timer
            Button { showSleepTimerSheet = true } label: {
                secondaryControlLabel(
                    icon: "moon.zzz",
                    isActive: appState.sleepTimerEndDate != nil,
                    activeColor: Color.cyan
                )
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(glassCard(cornerRadius: 22))
    }

    private func secondaryControlLabel(icon: String, isActive: Bool, activeColor: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isActive ? activeColor : AppTheme.secondaryText)
            if isActive {
                Circle()
                    .fill(activeColor)
                    .frame(width: 4, height: 4)
            } else {
                Color.clear.frame(width: 4, height: 4)
            }
        }
    }

    private var speedLabel: String {
        let rate = playbackService.playbackRate
        if rate == 1.0 { return "1×" }
        let formatted = String(format: rate.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f×" : "%.2g×", rate)
        return formatted
    }

    private func cycleSpeed() {
        let steps = Self.speedSteps
        let current = playbackService.playbackRate
        let next = steps.first(where: { $0 > current }) ?? steps[0]
        appState.setPlaybackRate(next)
    }

    private var repeatIcon: String {
        switch playbackService.repeatMode {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    // MARK: Utility Card

    private var utilityCard: some View {
        VStack(spacing: 0) {
            if downloadService.isDownloaded(track) {
                infoRow(
                    icon: "arrow.down.circle.fill",
                    iconColor: .cyan,
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

    private var relatedSongsSection: some View {
        let displayedTracks = Array(appState.relatedTracks.prefix(8))

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Related Songs")
                    .font(.title3.bold())
                    .foregroundStyle(AppTheme.primaryText)

                Spacer()

                if appState.isLoadingRelatedTracks {
                    ProgressView()
                        .tint(AppTheme.primaryText)
                        .scaleEffect(0.75)
                }
            }

            if displayedTracks.isEmpty {
                Text(appState.isLoadingRelatedTracks ? "Loading related songs..." : "Play more songs and MusicTube will keep improving the matches here.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(glassCard(cornerRadius: 22))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(displayedTracks.enumerated()), id: \.element.id) { index, relatedTrack in
                        RecommendedRow(track: relatedTrack) {
                            appState.play(track: relatedTrack, queue: appState.relatedTracks)
                        }
                        .padding(.horizontal, 16)

                        if index < displayedTracks.count - 1 {
                            Divider()
                                .overlay(AppTheme.divider)
                                .padding(.leading, 92)
                        }
                    }
                }
                .background(glassCard(cornerRadius: 22))
            }
        }
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

    // MARK: Background

    private var playerBackground: some View {
        ZStack {
            AppTheme.playerBackground
            Circle()
                .fill(Color.pink.opacity(0.18))
                .frame(width: 320, height: 320)
                .blur(radius: 120)
                .offset(x: 140, y: -210)
            Circle()
                .fill(Color.blue.opacity(0.14))
                .frame(width: 280, height: 280)
                .blur(radius: 110)
                .offset(x: -150, y: 260)
        }
    }

    // MARK: Helpers

    private var displayedPlaybackPosition: TimeInterval {
        // scrubPosition is always in sync with playbackService.currentTime when not scrubbing
        // (kept up to date by onChange → syncScrubber), so it's safe to use here always.
        scrubPosition
    }

    private var playedProgress: CGFloat {
        guard playbackService.duration > 0 else { return 0 }
        return CGFloat(min(max(displayedPlaybackPosition / playbackService.duration, 0), 1))
    }

    private var bufferedProgress: CGFloat {
        guard playbackService.duration > 0 else { return 0 }
        return CGFloat(min(max(playbackService.bufferedTime / playbackService.duration, 0), 1))
    }

    private func handleScrubbingChanged(_ editing: Bool) {
        scrubSafetyTask?.cancel()
        isScrubbing = editing

        if !editing {
            appState.seek(to: scrubPosition)
        } else {
            // Safety net: if onEditingChanged(false) never fires (known SwiftUI Slider bug),
            // force-reset isScrubbing after 5s so the bar doesn't stay frozen indefinitely.
            scrubSafetyTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, isScrubbing else { return }
                isScrubbing = false
                appState.seek(to: scrubPosition)
            }
        }
    }

    private func syncScrubber() {
        let current = min(playbackService.currentTime, playbackService.duration)
        scrubPosition = max(0, current)
    }

    private func formatted(_ interval: TimeInterval) -> String {
        Track.formatDuration(interval) ?? "0:00"
    }

    private func glassCard(cornerRadius: CGFloat) -> some View {
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

// MARK: - AirPlayPickerView

private struct AirPlayPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = UIColor(AppTheme.accent)
        view.prioritizesVideoDevices = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - CircularProgress

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
                Capsule()
                    .fill(AppTheme.progressTrack)
                    .frame(height: 6)

                Capsule()
                    .fill(AppTheme.progressBuffered)
                    .frame(width: width * bufferedProgress, height: 6)

                Capsule()
                    .fill(AppTheme.progressPlayed)
                    .frame(width: width * playedProgress, height: 6)

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
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        if isDragging == false {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        value = value(for: gesture.location.x, width: width)
                    }
                    .onEnded { gesture in
                        guard isEnabled else { return }
                        value = value(for: gesture.location.x, width: width)
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

    private func value(for positionX: CGFloat, width: CGFloat) -> Double {
        guard duration > 0 else { return 0 }
        let progress = min(max(positionX / width, 0), 1)
        return Double(progress) * duration
    }

    private func thumbOffset(for width: CGFloat) -> CGFloat {
        width * playedProgress
    }
}

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

// MARK: - UpNextSheet

private struct UpNextSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var playbackService: PlaybackService

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if let nowPlaying = playbackService.nowPlaying {
                        nowPlayingRow(nowPlaying)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 8)

                        Divider()
                            .overlay(AppTheme.divider)
                            .padding(.leading, 20)
                            .padding(.bottom, 8)
                    }

                    let upNext = upNextTracks
                    if upNext.isEmpty {
                        Text("No upcoming tracks.")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.secondaryText)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                    } else {
                        ForEach(Array(upNext.enumerated()), id: \.element.id) { index, track in
                            queueRow(track: track, index: index)
                                .padding(.horizontal, 20)

                            if index < upNext.count - 1 {
                                Divider()
                                    .overlay(AppTheme.divider)
                                    .padding(.leading, 84)
                            }
                        }
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(AppTheme.accent)
                }
            }
            .background(AppTheme.screenBackground.ignoresSafeArea())
        }
    }

    private var upNextTracks: [Track] {
        guard let idx = playbackService.currentQueueIndex else { return [] }
        let queue = playbackService.currentQueue
        guard idx + 1 < queue.count else { return [] }
        return Array(queue[(idx + 1)...])
    }

    private func nowPlayingRow(_ track: Track) -> some View {
        HStack(spacing: 12) {
            AsyncArtworkView(url: track.artworkURL, cornerRadius: 10)
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
                Text(track.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "speaker.wave.2.fill")
                .font(.subheadline)
                .foregroundStyle(AppTheme.accent)
        }
        .padding(.vertical, 8)
    }

    private func queueRow(track: Track, index: Int) -> some View {
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
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                appState.play(track: track, queue: playbackService.currentQueue)
                dismiss()
            } label: {
                Image(systemName: "play.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(AppTheme.accent))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }
}
