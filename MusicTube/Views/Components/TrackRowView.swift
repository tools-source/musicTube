import LinkPresentation
import SwiftUI
import UIKit

struct SourceDownloadButton: View {
    @ObservedObject private var downloadService = DownloadService.shared

    let source: DownloadSource
    var tracks: [Track] = []
    let totalCount: Int
    var size: CGFloat = 36
    var foregroundColor: Color = AppTheme.primaryText
    var backgroundColor: Color = AppTheme.controlFillStrong
    let action: () -> Void

    var body: some View {
        Button {
            if isBusy {
                downloadService.cancelDownloads(for: source)
            } else {
                action()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(backgroundColor)

                if showsProgressBorder {
                    Circle()
                        .stroke(AppTheme.progressTrack, lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            AppTheme.accent,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.25), value: progress)
                }

                icon
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isComplete)
        .accessibilityIdentifier("download-all-\(source.id)")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(isBusy ? "Stops the remaining downloads" : "Downloads every available song")
    }

    @ViewBuilder
    private var icon: some View {
        if isBusy {
            Image(systemName: "stop.fill")
                .font(.system(size: size * 0.30, weight: .bold))
                .foregroundStyle(foregroundColor)
        } else if isComplete {
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(foregroundColor)
        } else {
            Image(systemName: downloadedCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.system(size: size * 0.54, weight: .semibold))
                .foregroundStyle(foregroundColor)
        }
    }

    private var downloadedCount: Int {
        tracks.isEmpty
            ? downloadService.downloadCount(for: source)
            : downloadService.downloadCount(for: source, matching: tracks)
    }

    private var pendingCount: Int {
        downloadService.pendingRequestCount(for: source)
    }

    private var progress: Double {
        if tracks.isEmpty {
            return downloadService.aggregateProgress(for: source, totalCount: totalCount)
        }
        return downloadService.aggregateProgress(
            for: source,
            totalCount: totalCount,
            matching: tracks
        )
    }

    private var isBusy: Bool {
        downloadService.isDownloading(source: source)
    }

    private var isComplete: Bool {
        totalCount > 0 && downloadedCount >= totalCount && isBusy == false
    }

    private var showsProgressBorder: Bool {
        isBusy || downloadedCount > 0
    }

    private var accessibilityLabel: String {
        if isBusy { return "Stop downloading \(source.title)" }
        if isComplete { return "\(source.title) downloaded" }
        return "Download all from \(source.title)"
    }

    private var accessibilityValue: String {
        guard totalCount > 0 else { return "" }
        if pendingCount > 0 {
            return "\(downloadedCount) of \(totalCount) downloaded, \(pendingCount) waiting"
        }
        return "\(downloadedCount) of \(totalCount) downloaded"
    }
}

struct DownloadButton: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var downloadService = DownloadService.shared

    let track: Track
    var source: DownloadSource? = nil
    var sourceTrackIndex: Int? = nil
    var size: CGFloat = 36

    var body: some View {
        let downloading = downloadService.isDownloading(track)
        let downloaded = downloadService.isDownloaded(track)
        let progress = downloadService.downloadProgress(for: track)

        Button {
            if downloading {
                downloadService.cancelDownload(for: track)
            } else if downloaded == false {
                appState.downloadTrack(track, source: source, sourceTrackIndex: sourceTrackIndex)
            }
        } label: {
            ZStack {
                Circle().fill(AppTheme.controlFillStrong)

                if downloading {
                    Circle()
                        .stroke(AppTheme.progressTrack, lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.3), value: progress)
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.secondary)
                } else if downloaded {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(AppTheme.secondaryText)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                }
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .disabled(downloaded)
        .accessibilityLabel(downloading ? "Stop Download" : downloaded ? "Downloaded" : "Download")
        .accessibilityValue(downloading ? progress.formatted(.percent.precision(.fractionLength(0))) : "")
    }
}

struct TrackActionsButton: View {
    @EnvironmentObject private var appState: AppState
    let track: Track
    var size: CGFloat = 36
    @State private var sharePayload: TrackSharePayload?
    @State private var isPreparingShare = false

    var body: some View {
        Menu {
            Button {
                appState.toggleTrackSaved(track)
            } label: {
                Label(
                    appState.isTrackSaved(track) ? "Remove From Library" : "Save To Library",
                    systemImage: appState.isTrackSaved(track) ? "bookmark.slash" : "bookmark"
                )
            }

            Button {
                appState.presentPlaylistPicker(for: track)
            } label: {
                Label("Add To Playlist", systemImage: "text.badge.plus")
            }

            Button {
                appState.toggleLike(for: track)
            } label: {
                Label(
                    appState.isTrackLiked(track) ? "Unlike" : "Like",
                    systemImage: appState.isTrackLiked(track) ? "heart.slash" : "heart"
                )
            }

            if track.musicTubeShareURL != nil {
                Button {
                    prepareShareSheet()
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(isPreparingShare)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.primary)
                .frame(width: size, height: size)
                .background(Circle().fill(AppTheme.controlFillStrong))
        }
        .buttonStyle(.plain)
        .sheet(item: $sharePayload) { payload in
            TrackShareSheet(activityItems: [TrackShareItemSource(payload: payload)])
        }
    }

    private func prepareShareSheet() {
        guard isPreparingShare == false else { return }

        isPreparingShare = true
        Task {
            let payload = await makeTrackSharePayload(for: track)
            await MainActor.run {
                sharePayload = payload
                isPreparingShare = false
            }
        }
    }
}

struct TrackEngagementBadges: View {
    @EnvironmentObject private var appState: AppState
    let track: Track

    var body: some View {
        HStack(spacing: 4) {
            if appState.isTrackLiked(track) {
                Image(systemName: "heart.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.accent.opacity(0.9))
                    .fixedSize()
                    .accessibilityLabel("Liked")
            }

            if appState.isTrackSubstantiallyListened(track) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.green.opacity(0.78))
                    .fixedSize()
                    .accessibilityLabel("Listened")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct TrackRowView: View {
    @EnvironmentObject private var appState: AppState

    let track: Track
    var showsDownloadButton: Bool = false
    var downloadSource: DownloadSource? = nil
    var downloadSourceTrackIndex: Int? = nil
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    AsyncArtworkView(url: track.artworkURL, cornerRadius: AppCornerRadius.artwork)
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

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsDownloadButton {
                DownloadButton(
                    track: track,
                    source: downloadSource,
                    sourceTrackIndex: downloadSourceTrackIndex
                )
            }

            Button(action: handlePlaybackButtonTap) {
                Image(systemName: isCurrentlyPlaying ? "pause.fill" : "play.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(AppTheme.accent)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .fill(isCurrentTrack
                      ? AppTheme.accent.opacity(0.07)
                      : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .strokeBorder(
                            isCurrentTrack
                                ? AppTheme.accent.opacity(0.38)
                                : Color.clear,
                            lineWidth: 1
                        )
                )
        )
        .padding(.horizontal, -10)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isCurrentTrack)
    }

    private var isCurrentTrack: Bool {
        appState.nowPlaying?.playbackKey == track.playbackKey
    }

    private var isCurrentlyPlaying: Bool {
        isCurrentTrack && appState.isPlaying
    }

    private var metadataLine: some View {
        HStack(spacing: 4) {
            playbackStatusBadge
            TrackEngagementBadges(track: track)

            if appState.isTrackSaved(track) {
                Image(systemName: "bookmark.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .fixedSize()
            }

            if let duration = track.formattedDuration {
                Text(duration)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if let views = track.formattedViewCount {
                Text("· \(views)")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
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
            statusBadge(
                systemImage: "speaker.wave.2.fill",
                text: "Playing",
                color: AppTheme.accent
            )
        } else if isCurrentTrack {
            statusBadge(
                systemImage: "speaker.fill",
                text: "Paused",
                color: AppTheme.accent.opacity(0.7)
            )
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

    private func handlePlaybackButtonTap() {
        if isCurrentTrack {
            appState.togglePlayback()
        } else {
            onTap()
        }
    }
}

struct TrackSharePayload: Identifiable {
    let id: String
    let title: String
    let artist: String
    let universalLink: URL
    let deepLink: URL?
    let artwork: UIImage?

    var previewTitle: String {
        "\(title) - \(artist)"
    }
}

func makeTrackSharePayload(for track: Track) async -> TrackSharePayload? {
    guard let universalLink = track.musicTubeShareURL else { return nil }

    let artwork: UIImage?
    if let artworkURL = track.artworkURL {
        artwork = await ArtworkRepository.shared.image(for: artworkURL, maxPixelSize: ArtworkPixelSize.list)
    } else {
        artwork = nil
    }

    return TrackSharePayload(
        id: track.playbackKey,
        title: track.title,
        artist: track.artist,
        universalLink: universalLink,
        deepLink: track.musicTubeDeepLinkURL,
        artwork: artwork
    )
}

final class TrackShareItemSource: NSObject, UIActivityItemSource {
    private let payload: TrackSharePayload

    init(payload: TrackSharePayload) {
        self.payload = payload
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        payload.universalLink
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        return payload.universalLink
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        payload.previewTitle
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.originalURL = payload.universalLink
        metadata.url = payload.universalLink
        metadata.title = payload.previewTitle

        if let artwork = payload.artwork {
            metadata.imageProvider = NSItemProvider(object: artwork)
            metadata.iconProvider = NSItemProvider(object: artwork)
        }

        return metadata
    }
}

struct TrackShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
