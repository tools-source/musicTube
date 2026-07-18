import SwiftUI

struct RecommendedRow: View {
    let track: Track
    let isCurrentTrack: Bool
    let isPlaying: Bool
    let onTap: () -> Void
    let onPlayPause: () -> Void

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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HomeTrackButtons(
                track: track,
                isCurrentTrack: isCurrentTrack,
                isPlaying: isPlaying,
                onPlay: onTap,
                onPlayPause: onPlayPause
            )
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .fill(isCurrentTrack ? AppTheme.accent.opacity(0.07) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .strokeBorder(
                            isCurrentTrack ? AppTheme.accent.opacity(0.38) : Color.clear,
                            lineWidth: 1
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
    let track: Track
    let isCurrentTrack: Bool
    let isPlaying: Bool
    let onPlay: () -> Void
    let onPlayPause: () -> Void
    var buttonSize: CGFloat = 36

    var body: some View {
        HStack(spacing: 8) {
            DownloadButton(track: track, size: buttonSize)

            Button(action: handlePlaybackButtonTap) {
                Image(systemName: isCurrentTrack && isPlaying ? "pause.fill" : "play.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: buttonSize, height: buttonSize)
                    .background(Circle().fill(AppTheme.accent))
            }
            .buttonStyle(.plain)
        }
    }

    private func handlePlaybackButtonTap() {
        if isCurrentTrack {
            onPlayPause()
        } else {
            onPlay()
        }
    }
}
