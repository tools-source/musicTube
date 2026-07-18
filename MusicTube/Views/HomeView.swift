import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject var viewModel: HomeViewModel

    private var snapshot: HomeSnapshot { viewModel.snapshot }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: AppLayout.sectionSpacing) {
                    header
                    statusMessage
                    continueListeningSection
                    madeForYouSection
                    recentlyPlayedSection
                    mixesSection
                    contextualSection
                }
                .padding(.horizontal, AppLayout.horizontalMargin)
                .padding(.top, AppSpacing.small)
                .padding(.bottom, snapshot.nowPlayingKey == nil ? 108 : 178)
            }
            .navigationBarHidden(true)
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(
                    playlist: playlist,
                    viewModel: coordinator.playlistViewModel(for: playlist)
                )
            }
            .refreshable {
                await viewModel.refresh()
            }
            .task {
                await viewModel.appear()
            }
            .premiumScreenBackground()
        }
    }

    private var header: some View {
        HStack(spacing: AppSpacing.medium) {
            VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                Text(snapshot.displayName.map { "For \($0)" } ?? "Home")
                    .font(.largeTitle.bold())
                    .foregroundStyle(AppTheme.primaryText)

                Text("Pick up where you left off")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Spacer(minLength: AppSpacing.small)

            NavigationLink {
                SettingsView(viewModel: coordinator.settings)
            } label: {
                Image(systemName: "person.crop.circle")
                    .font(.title2)
                    .foregroundStyle(AppTheme.primaryText)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(AppTheme.controlFill))
            }
            .accessibilityLabel("Account and settings")
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        if let message = snapshot.statusMessage, message.isEmpty == false {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)
                .padding(AppSpacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .appSurface()
        }
    }

    @ViewBuilder
    private var continueListeningSection: some View {
        if snapshot.continueListening.isEmpty == false {
            HomeSection(title: "Continue Listening") {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: AppSpacing.medium) {
                        ForEach(snapshot.continueListening) { track in
                            HomeArtworkCard(
                                track: track,
                                isCurrent: snapshot.nowPlayingKey == track.playbackKey,
                                isPlaying: snapshot.isPlaying
                            ) {
                                viewModel.playContinueListening(track)
                            }
                        }
                    }
                }
                .contentMargins(.horizontal, 1)
            }
        }
    }

    private var madeForYouSection: some View {
        HomeSection(title: "Made for You", subtitle: snapshot.recommendationBlurb) {
            if snapshot.madeForYou.isEmpty {
                if snapshot.hasLoaded == false || snapshot.isLoading {
                    HomeLoadingRows()
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(snapshot.madeForYou) { item in
                        TrackSwipeActionsView(
                            onMore: { viewModel.recommendMoreLike(item.track) },
                            onLess: { viewModel.recommendLessLike(item.track) }
                        ) {
                            RecommendedRow(
                                track: item.track,
                                isCurrentTrack: snapshot.nowPlayingKey == item.track.playbackKey,
                                isPlaying: snapshot.isPlaying,
                                onTap: {
                                    viewModel.play(
                                        item.track,
                                        queue: snapshot.madeForYou.map(\.track)
                                    )
                                },
                                onPlayPause: viewModel.togglePlayback
                            )
                        }
                        .onAppear {
                            viewModel.recommendationAppeared(item)
                        }

                        if item.id != snapshot.madeForYou.last?.id {
                            Divider()
                                .overlay(AppTheme.divider)
                                .padding(.leading, 64)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recentlyPlayedSection: some View {
        if snapshot.recentlyPlayed.isEmpty == false {
            HomeSection(title: "Recently Played") {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: AppSpacing.medium) {
                        ForEach(snapshot.recentlyPlayed) { track in
                            HomeArtworkCard(
                                track: track,
                                isCurrent: snapshot.nowPlayingKey == track.playbackKey,
                                isPlaying: snapshot.isPlaying
                            ) {
                                viewModel.play(track, queue: snapshot.recentlyPlayed)
                            }
                        }
                    }
                }
                .contentMargins(.horizontal, 1)
            }
        }
    }

    @ViewBuilder
    private var mixesSection: some View {
        if snapshot.mixes.isEmpty == false {
            HomeSection(title: "Your Mixes") {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: AppSpacing.medium) {
                        ForEach(snapshot.mixes) { playlist in
                            NavigationLink(value: playlist) {
                                HomeMixCard(playlist: playlist)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .contentMargins(.horizontal, 1)
            }
        }
    }

    @ViewBuilder
    private var contextualSection: some View {
        if snapshot.contextualTracks.isEmpty == false {
            HomeSection(title: "More Like This") {
                LazyVStack(spacing: 0) {
                    ForEach(snapshot.contextualTracks) { track in
                        RecommendedRow(
                            track: track,
                            isCurrentTrack: snapshot.nowPlayingKey == track.playbackKey,
                            isPlaying: snapshot.isPlaying,
                            onTap: {
                                viewModel.play(track, queue: snapshot.contextualTracks)
                            },
                            onPlayPause: viewModel.togglePlayback
                        )

                        if track.playbackKey != snapshot.contextualTracks.last?.playbackKey {
                            Divider()
                                .overlay(AppTheme.divider)
                                .padding(.leading, 64)
                        }
                    }
                }
            }
        }
    }
}

private struct HomeSection<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(AppTheme.primaryText)

            if let subtitle, subtitle.isEmpty == false {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.secondaryText)
            }

            content
        }
    }
}

private struct HomeArtworkCard: View {
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                AsyncArtworkView(
                    url: track.artworkURL,
                    cornerRadius: AppCornerRadius.medium,
                    maxPixelSize: ArtworkTargetSize.card
                )
                .frame(width: 148, height: 148)
                .overlay(alignment: .bottomTrailing) {
                    if isCurrent {
                        Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(7)
                            .background(Circle().fill(AppTheme.accent))
                            .padding(7)
                    }
                }

                Text(track.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isCurrent ? AppTheme.accent : AppTheme.primaryText)
                    .lineLimit(1)

                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
            }
            .frame(width: 148, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

private struct HomeMixCard: View {
    let playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            AsyncArtworkView(
                url: playlist.artworkURL,
                cornerRadius: AppCornerRadius.medium,
                maxPixelSize: ArtworkTargetSize.card
            )
            .frame(width: 148, height: 148)

            Text(playlist.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.primaryText)
                .lineLimit(1)

            Text(playlist.itemCount == 1 ? "1 track" : "\(playlist.itemCount) tracks")
                .font(.caption)
                .foregroundStyle(AppTheme.secondaryText)
        }
        .frame(width: 148, alignment: .leading)
    }
}

private struct HomeLoadingRows: View {
    var body: some View {
        VStack(spacing: AppSpacing.small) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                    .fill(AppTheme.cardFill)
                    .frame(height: 68)
                    .redacted(reason: .placeholder)
            }
        }
        .accessibilityLabel("Loading recommendations")
    }
}
