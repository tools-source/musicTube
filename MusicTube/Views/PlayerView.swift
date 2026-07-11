import SwiftUI

private enum PlayerDestination: String, CaseIterable, Identifiable {
    case queue = "Queue"
    case related = "Related"
    var id: String { rawValue }
}

struct PlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: PlayerViewModel
    @State private var destination: PlayerDestination = .related
    @State private var scrubPosition: TimeInterval = 0
    @State private var isScrubbing = false
    @State private var sharePayload: TrackSharePayload?
    @State private var isPreparingShare = false

    private var snapshot: PlayerSnapshot { viewModel.snapshot }

    var body: some View {
        ZStack {
            background
            ScrollView(showsIndicators: false) {
                VStack(spacing: AppSpacing.large) {
                    header
                    artwork
                    metadata
                    progress
                    transportControls
                    secondaryControls
                    destinationPicker
                    destinationContent
                }
                .padding(.horizontal, AppSpacing.large)
                .padding(.bottom, AppSpacing.xLarge)
            }
        }
        .task {
            scrubPosition = snapshot.currentTime
            viewModel.appear()
        }
        .onChange(of: snapshot.currentTime) { _, value in
            if isScrubbing == false { scrubPosition = value }
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
        HStack {
            Button(action: close) {
                Image(systemName: "chevron.down")
                    .font(.headline.weight(.bold))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(AppTheme.controlFill))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss player")

            Spacer()
            Capsule()
                .fill(AppTheme.playerHandle)
                .frame(width: 40, height: 5)
            Spacer()

            moreMenu
        }
        .padding(.top, AppSpacing.small)
    }

    private var artwork: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, AppArtworkSize.nowPlayingMaximum)
            AsyncArtworkView(
                url: snapshot.track?.artworkURL,
                cornerRadius: AppCornerRadius.large,
                maxPixelSize: ArtworkTargetSize.nowPlaying
            )
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity)
            .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var metadata: some View {
        VStack(spacing: AppSpacing.xSmall) {
            Text(snapshot.track?.title ?? "Nothing Playing")
                .font(.title2.bold())
                .foregroundStyle(AppTheme.primaryText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(snapshot.track?.artist ?? "")
                .font(.headline)
                .foregroundStyle(AppTheme.secondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var progress: some View {
        VStack(spacing: AppSpacing.xSmall) {
            Slider(
                value: $scrubPosition,
                in: 0...max(snapshot.duration, 1),
                onEditingChanged: handleScrubbing
            )
            .tint(AppTheme.primaryText)

            HStack {
                Text(Track.formatDuration(scrubPosition) ?? "0:00")
                Spacer()
                if snapshot.isBuffering { ProgressView().controlSize(.small) }
                Spacer()
                Text("-\(Track.formatDuration(max(0, snapshot.duration - scrubPosition)) ?? "0:00")")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(AppTheme.secondaryText)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 42) {
            Button(action: viewModel.previous) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 28, weight: .semibold))
            }
            .disabled(snapshot.hasPrevious == false)

            Button(action: viewModel.togglePlayback) {
                ZStack {
                    Circle().fill(AppTheme.inverseFill).frame(width: 76, height: 76)
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
                    .font(.system(size: 28, weight: .semibold))
            }
            .disabled(snapshot.hasNext == false)
        }
        .foregroundStyle(AppTheme.primaryText)
    }

    private var secondaryControls: some View {
        HStack {
            PlayerIconButton(
                systemImage: snapshot.shuffleEnabled ? "shuffle.circle.fill" : "shuffle",
                label: "Shuffle",
                isActive: snapshot.shuffleEnabled,
                action: viewModel.toggleShuffle
            )
            Spacer()
            PlayerIconButton(
                systemImage: snapshot.isLiked ? "heart.fill" : "heart",
                label: snapshot.isLiked ? "Unlike" : "Like",
                isActive: snapshot.isLiked,
                action: viewModel.toggleLike
            )
            Spacer()
            PlayerIconButton(
                systemImage: repeatIcon,
                label: "Repeat",
                isActive: snapshot.repeatMode != .off,
                action: viewModel.cycleRepeat
            )
            Spacer()
            PlayerIconButton(
                systemImage: downloadIcon,
                label: "Download",
                isActive: snapshot.isDownloaded,
                action: viewModel.download
            )
        }
    }

    private var destinationPicker: some View {
        Picker("Player destination", selection: $destination) {
            ForEach(PlayerDestination.allCases) { item in
                Text(item.rawValue).tag(item)
            }
        }
        .pickerStyle(.segmented)
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

    private func handleScrubbing(_ editing: Bool) {
        isScrubbing = editing
        if editing == false { viewModel.seek(to: scrubPosition) }
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

private struct PlayerIconButton: View {
    let systemImage: String
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(isActive ? AppTheme.accent : AppTheme.primaryText)
                .frame(width: 44, height: 44)
        }
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
