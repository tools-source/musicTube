import SwiftUI

private enum PlayerDestination: String, CaseIterable, Identifiable {
    case queue = "Up next"
    case related = "Related"
    var id: String { rawValue }
}

struct PlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: PlayerViewModel
    @State private var destination: PlayerDestination = .related
    @State private var sharePayload: TrackSharePayload?
    @State private var isPreparingShare = false

    private var snapshot: PlayerSnapshot { viewModel.snapshot }

    var body: some View {
        GeometryReader { proxy in
            let popupSpacing = proxy.size.height < 620 ? AppSpacing.medium : 22
            let artworkMaximum = min(AppArtworkSize.nowPlayingMaximum, max(150, proxy.size.height * 0.36))

            ZStack {
                background
                ScrollView(showsIndicators: false) {
                    VStack(spacing: popupSpacing) {
                        header
                        playerPreview(maxArtworkSize: artworkMaximum, spacing: popupSpacing)
                        transportControls
                        secondaryControls
                        destinationPicker
                        destinationContent
                    }
                    .padding(.horizontal, AppSpacing.large)
                    .padding(.bottom, AppSpacing.xLarge)
                }
            }
        }
        .task {
            viewModel.appear()
        }
        .sheet(item: $sharePayload) { payload in
            TrackShareSheet(activityItems: [TrackShareItemSource(payload: payload)])
        }
    }

    private var background: some View {
        ZStack {
            AppTheme.playerBackground
            if let artworkURL = snapshot.track?.artworkURL {
                AsyncArtworkView(
                    url: artworkURL,
                    cornerRadius: 0,
                    maxPixelSize: ArtworkTargetSize.nowPlaying
                )
                .blur(radius: 70)
                .scaleEffect(1.35)
                .opacity(0.22)
            }
            Rectangle().fill(.ultraThinMaterial).opacity(0.35)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: AppSpacing.medium) {
            Button(action: close) {
                Image(systemName: "chevron.down")
                    .font(.headline.weight(.bold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss player")

            Spacer()

            VStack(spacing: 2) {
                Text("Playing from")
                    .font(.caption2.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(AppTheme.tertiaryText)

                Text("MusicTube")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(1)
            }

            Spacer()

            moreMenu
        }
        .padding(.top, AppSpacing.small)
    }

    private func playerPreview(maxArtworkSize: CGFloat, spacing: CGFloat) -> some View {
        VStack(spacing: spacing) {
            artwork(maxSize: maxArtworkSize)
            titleRow
            PlayerProgressControl(
                viewModel: viewModel.progress,
                onSeek: viewModel.seek
            )
        }
    }

    private func artwork(maxSize: CGFloat) -> some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, maxSize)
            AsyncArtworkView(
                url: snapshot.track?.artworkURL,
                cornerRadius: AppCornerRadius.small,
                maxPixelSize: ArtworkTargetSize.nowPlaying
            )
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity)
            .shadow(color: .black.opacity(0.24), radius: 22, y: 14)
        }
        .frame(height: maxSize)
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: AppSpacing.medium) {
            VStack(alignment: .leading, spacing: 5) {
                Text(snapshot.track?.title ?? "Nothing Playing")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(AppTheme.primaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(snapshot.track?.artist ?? "")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: AppSpacing.small)

            PlayerCircleButton(
                systemImage: snapshot.isLiked ? "heart.fill" : "heart",
                label: snapshot.isLiked ? "Unlike" : "Like",
                isActive: snapshot.isLiked,
                action: viewModel.toggleLike
            )
        }
        .frame(maxWidth: .infinity)
    }

    private var transportControls: some View {
        HStack(spacing: 28) {
            PlayerTransportSideButton(
                systemImage: snapshot.shuffleEnabled ? "shuffle.circle.fill" : "shuffle",
                label: "Shuffle",
                isActive: snapshot.shuffleEnabled,
                action: viewModel.toggleShuffle
            )

            Button(action: viewModel.previous) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .disabled(snapshot.hasPrevious == false)

            Button(action: viewModel.togglePlayback) {
                ZStack {
                    Circle().fill(AppTheme.inverseFill).frame(width: 74, height: 74)
                    if snapshot.isBuffering {
                        ProgressView().tint(AppTheme.inverseText)
                    } else {
                        Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(AppTheme.inverseText)
                            .offset(x: snapshot.isPlaying ? 0 : 2)
                    }
                }
            }

            Button(action: viewModel.next) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .disabled(snapshot.hasNext == false)

            PlayerTransportSideButton(
                systemImage: repeatIcon,
                label: "Repeat",
                isActive: snapshot.repeatMode != .off,
                action: viewModel.cycleRepeat
            )
        }
        .foregroundStyle(AppTheme.primaryText)
    }

    private var secondaryControls: some View {
        HStack(spacing: 14) {
            PlayerIconButton(
                systemImage: "square.and.arrow.up",
                label: "Share",
                isActive: false,
                action: prepareShare
            )

            PlayerIconButton(
                systemImage: downloadIcon,
                label: "Download",
                isActive: snapshot.isDownloaded,
                action: viewModel.download
            )

            PlayerIconButton(
                systemImage: "timer",
                label: snapshot.sleepTimerEndDate == nil ? "Sleep Timer" : "Cancel Sleep Timer",
                isActive: snapshot.sleepTimerEndDate != nil,
                action: {
                    if snapshot.sleepTimerEndDate == nil {
                        viewModel.setSleepTimer(minutes: 30)
                    } else {
                        viewModel.cancelSleepTimer()
                    }
                }
            )
        }
    }

    private var destinationPicker: some View {
        HStack(spacing: AppSpacing.small) {
            ForEach(PlayerDestination.allCases) { item in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        destination = item
                    }
                } label: {
                    Text(item.rawValue)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(destination == item ? AppTheme.inverseText : AppTheme.primaryText)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(destination == item ? AppTheme.inverseFill : AppTheme.controlFill)
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var destinationContent: some View {
        switch destination {
        case .queue:
            PlayerTrackList(
                items: snapshot.queue,
                nowPlayingKey: snapshot.track?.playbackKey,
                isPlaying: snapshot.isPlaying,
                onSelect: viewModel.playQueueItem,
                onTogglePlayback: viewModel.togglePlayback
            )
        case .related:
            if snapshot.related.isEmpty, snapshot.isLoadingRelated {
                ProgressView("Loading related songs…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.large)
            } else if snapshot.related.isEmpty {
                ContentUnavailableView {
                    Label("No Related Songs", systemImage: "music.note.list")
                } description: {
                    Text("Related songs could not be loaded right now.")
                } actions: {
                    Button("Try Again", action: viewModel.retryRelated)
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.accent)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.medium)
            } else {
                PlayerRelatedList(
                    tracks: snapshot.related,
                    nowPlayingKey: snapshot.track?.playbackKey,
                    isPlaying: snapshot.isPlaying,
                    onSelect: viewModel.playRelated,
                    onTogglePlayback: viewModel.togglePlayback
                )
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            Section("Sleep Timer") {
                Button("15 minutes") { viewModel.setSleepTimer(minutes: 15) }
                Button("30 minutes") { viewModel.setSleepTimer(minutes: 30) }
                Button("1 hour") { viewModel.setSleepTimer(minutes: 60) }
                if snapshot.sleepTimerEndDate != nil {
                    Button("Cancel Timer", role: .destructive, action: viewModel.cancelSleepTimer)
                }
            }
            Section("Playback Speed") {
                Button("0.75×") { viewModel.setPlaybackRate(0.75) }
                Button("1×") { viewModel.setPlaybackRate(1) }
                Button("1.25×") { viewModel.setPlaybackRate(1.25) }
                Button("1.5×") { viewModel.setPlaybackRate(1.5) }
            }
            Button("Share", action: prepareShare)
            if let url = snapshot.track?.youtubeWatchURL {
                Link("Open on YouTube", destination: url)
            }
        } label: {
            if isPreparingShare {
                ProgressView().frame(width: 44, height: 44)
            } else {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(AppTheme.controlFill))
            }
        }
        .accessibilityLabel("More player options")
    }

    private var repeatIcon: String {
        switch snapshot.repeatMode {
        case .off: "repeat"
        case .one: "repeat.1"
        case .all: "repeat.circle.fill"
        }
    }

    private var downloadIcon: String {
        if snapshot.isDownloaded { return "checkmark.circle.fill" }
        if snapshot.isDownloading { return "arrow.down.circle.fill" }
        return "arrow.down.circle"
    }

    private func close() {
        viewModel.dismiss()
        dismiss()
    }

    private func prepareShare() {
        guard let track = snapshot.track else { return }
        isPreparingShare = true
        Task {
            sharePayload = await makeTrackSharePayload(for: track)
            isPreparingShare = false
        }
    }
}

private struct PlayerProgressControl: View {
    @ObservedObject var viewModel: PlayerProgressViewModel
    let onSeek: (TimeInterval) -> Void

    @State private var scrubPosition: TimeInterval = 0
    @State private var isScrubbing = false

    private var snapshot: PlayerProgressSnapshot { viewModel.snapshot }

    var body: some View {
        VStack(spacing: AppSpacing.xSmall) {
            Slider(
                value: $scrubPosition,
                in: 0...max(snapshot.duration, 1),
                onEditingChanged: handleScrubbing
            )
            .tint(AppTheme.accent)

            HStack {
                Text(Track.formatDuration(scrubPosition) ?? "0:00")
                Spacer()
                Text("-\(Track.formatDuration(max(0, snapshot.duration - scrubPosition)) ?? "0:00")")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(AppTheme.secondaryText)
        }
        .task {
            scrubPosition = snapshot.currentTime
        }
        .onChange(of: snapshot.currentTime) { _, value in
            if isScrubbing == false { scrubPosition = value }
        }
    }

    private func handleScrubbing(_ editing: Bool) {
        isScrubbing = editing
        if editing == false { onSeek(scrubPosition) }
    }
}

private struct PlayerCircleButton: View {
    let systemImage: String
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(isActive ? AppTheme.accent : AppTheme.primaryText)
                .frame(width: 48, height: 48)
                .background(
                    Circle()
                        .fill(AppTheme.controlFill)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct PlayerTransportSideButton: View {
    let systemImage: String
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(isActive ? AppTheme.accent : AppTheme.primaryText)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct PlayerIconButton: View {
    let systemImage: String
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.bold))

                Text(label)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isActive ? AppTheme.accent : AppTheme.primaryText)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(
                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                    .fill(AppTheme.controlFill)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct PlayerTrackList: View {
    let items: [IndexedTrackPresentation]
    let nowPlayingKey: String?
    let isPlaying: Bool
    let onSelect: (IndexedTrackPresentation) -> Void
    let onTogglePlayback: () -> Void

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(items) { item in
                RecommendedRow(
                    track: item.track,
                    isCurrentTrack: nowPlayingKey == item.track.playbackKey,
                    isPlaying: isPlaying,
                    onTap: { onSelect(item) },
                    onPlayPause: onTogglePlayback
                )
            }
        }
    }
}

private struct PlayerRelatedList: View {
    let tracks: [Track]
    let nowPlayingKey: String?
    let isPlaying: Bool
    let onSelect: (Track) -> Void
    let onTogglePlayback: () -> Void

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(tracks) { track in
                RecommendedRow(
                    track: track,
                    isCurrentTrack: nowPlayingKey == track.playbackKey,
                    isPlaying: isPlaying,
                    onTap: { onSelect(track) },
                    onPlayPause: onTogglePlayback
                )
            }
        }
    }
}
