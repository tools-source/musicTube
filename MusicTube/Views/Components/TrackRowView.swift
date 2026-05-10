import SwiftUI

struct DownloadButton: View {
    @Environment(\.colorScheme) private var colorScheme
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
            appState.downloadTrack(track, source: source, sourceTrackIndex: sourceTrackIndex)
        } label: {
            ZStack {
                Circle().fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08))

                if downloading {
                    Circle()
                        .stroke(AppTheme.progressTrack, lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.cyan, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.3), value: progress)
                    Image(systemName: "arrow.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.secondary)
                } else if downloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.cyan)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                }
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .disabled(downloading || downloaded)
    }
}

struct TrackActionsButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appState: AppState
    let track: Track
    var size: CGFloat = 36

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

            if let shareURL = track.musicTubeShareURL {
                ShareLink(item: shareURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.primary)
                .frame(width: size, height: size)
                .background(Circle().fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}

struct TrackRowView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    let track: Track
    var showsNowPlayingIndicator: Bool = false
    var showsDownloadButton: Bool = false
    var downloadSource: DownloadSource? = nil
    var downloadSourceTrackIndex: Int? = nil
    var prefetchPlaybackOnAppear: Bool = true
    let onTap: () -> Void

    @ObservedObject private var downloadService = DownloadService.shared

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    AsyncArtworkView(url: track.artworkURL, cornerRadius: 10)
                        .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isCurrentTrack ? Color(red: 1, green: 0.24, blue: 0.43) : Color.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        HStack(spacing: 4) {
                            if isCurrentlyPlaying {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color(red: 1, green: 0.24, blue: 0.43))

                                Text("Playing")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color(red: 1, green: 0.24, blue: 0.43))
                            } else if isCurrentTrack {
                                Image(systemName: "speaker.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color(red: 1, green: 0.24, blue: 0.43).opacity(0.7))

                                Text("Paused")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color(red: 1, green: 0.24, blue: 0.43).opacity(0.7))
                            }

                            if appState.isTrackSaved(track) {
                                Image(systemName: "bookmark.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.secondary)
                            }

                            if downloadService.isDownloaded(track) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.cyan.opacity(0.8))
                            }

                            Text(track.artist)
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                                .lineLimit(1)

                            if let duration = track.formattedDuration {
                                Text("· \(duration)")
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                                    .fixedSize()
                            }

                            if let views = track.formattedViewCount {
                                Text("· \(views)")
                                    .font(.caption)
                                    .foregroundStyle(Color.secondary)
                                    .fixedSize()
                            }
                        }
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
                    sourceTrackIndex: downloadSourceTrackIndex,
                    size: 36
                )
            }

            TrackActionsButton(track: track, size: 36)

            Button(action: handlePlaybackButtonTap) {
                Image(systemName: isCurrentlyPlaying ? "pause.fill" : "play.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(isCurrentTrack
                                  ? Color(red: 1, green: 0.24, blue: 0.43)
                                  : Color(red: 1, green: 0.24, blue: 0.43))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isCurrentTrack
                      ? Color(red: 1, green: 0.24, blue: 0.43).opacity(0.07)
                      : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            isCurrentTrack
                                ? Color(red: 1, green: 0.24, blue: 0.43).opacity(0.38)
                                : Color.clear,
                            lineWidth: 1.5
                        )
                )
        )
        .padding(.horizontal, -10)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isCurrentTrack)
        .task(id: track.playbackKey) {
            guard prefetchPlaybackOnAppear else { return }
            appState.prefetchPlayback(for: [track])
        }
    }

    private var isCurrentTrack: Bool {
        appState.nowPlaying?.playbackKey == track.playbackKey
    }

    private var isCurrentlyPlaying: Bool {
        showsNowPlayingIndicator && isCurrentTrack && appState.isPlaying
    }

    private func handlePlaybackButtonTap() {
        if showsNowPlayingIndicator && isCurrentTrack {
            appState.togglePlayback()
        } else {
            onTap()
        }
    }
}
