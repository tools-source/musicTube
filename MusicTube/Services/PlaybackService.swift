import AVFoundation
import Foundation
import MediaPlayer
import UIKit

struct PlaybackState: Equatable {
    var nowPlaying: Track?
    var isPlaying = false
    var isResolvingStream = false
    var playbackErrorMessage: String?
    var hasNextTrack = false
    var hasPreviousTrack = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var bufferedTime: TimeInterval = 0
    var isBufferingPlayback = false

    static let idle = PlaybackState()
}

@MainActor
final class PlaybackService: NSObject, ObservableObject, PlaybackControlling {
    private let logger: any AppLogging

    private enum BufferingPolicy {
        static let startupForwardBufferDuration = AppConfig.Playback.startupForwardBufferDuration
        static let steadyStateForwardBufferDuration = AppConfig.Playback.steadyStateForwardBufferDuration
        static let startupWaitTimeoutNanoseconds = AppConfig.Playback.startupWaitTimeoutNanoseconds
    }

    private struct StreamResolutionResult {
        let urls: [URL]
        let approximateDuration: TimeInterval?
    }

    enum RepeatMode: String, CaseIterable {
        case off, one, all
    }

    @Published private(set) var state: PlaybackState = .idle
    private(set) var nowPlaying: Track?
    private(set) var isPlaying = false
    private(set) var isResolvingStream = false
    private(set) var playbackErrorMessage: String?
    private(set) var hasNextTrack = false
    private(set) var hasPreviousTrack = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var bufferedTime: TimeInterval = 0
    private(set) var isBufferingPlayback = false
    @Published var shuffleMode: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var playbackRate: Float = 1.0
    @Published private(set) var currentQueue: [Track] = []
    @Published private(set) var currentQueueIndex: Int?

    private var originalQueue: [Track] = []

    private var player: AVPlayer?
    private var activeStreamURL: URL?
    private var playbackObservation: NSKeyValueObservation?
    private var playerItemStatusObservation: NSKeyValueObservation?
    private var playerItemDurationObservation: NSKeyValueObservation?
    private var playerItemBufferedTimeObservation: NSKeyValueObservation?
    private var playbackStartupTask: Task<Void, Never>?
    private var resolveTask: Task<Void, Never>?
    private var artworkLoadTask: Task<Void, Never>?
    private var timeObserverToken: Any?
    private var playbackEndWatchdogTask: Task<Void, Never>?
    private var lastObservedTime: TimeInterval = 0
    private var pendingSeekTime: TimeInterval? = nil
    private var userInitiatedPause = false
    private var playbackQueue: [Track] = []
    private var playbackQueueIndex: Int?
    private var itemDidEndObserver: NSObjectProtocol?
    private var itemFailedObserver: NSObjectProtocol?
    private var stalledObserver: NSObjectProtocol?
    private var stallRecoveryTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var streamCandidateCache: [String: [URL]] = [:]
    private var authoritativeDurationCache: [String: TimeInterval] = [:]
    private var prefetchTasks: [String: Task<[URL], Never>] = [:]
    private var isAppInBackground = false
    private var lastNowPlayingElapsedUpdate = Date.distantPast
    /// Tracks the timestamp of the last resolution failure per videoID, used to
    /// avoid hammering YouTube for tracks that are genuinely unavailable.
    private var streamResolutionFailureTimestamps: [String: Date] = [:]
    private let remoteCommandManager = RemoteCommandManager()
    /// Tracks whether `AVAudioSession.setActive(true)` has been called. Deferring
    /// activation until first play avoids ducking other apps' audio at launch
    /// and skips the activation handshake during cold start.
    private var audioSessionActivated = false
    /// True between the moment the user requests playback and the moment
    /// AVPlayer actually reports `.playing`. The manager reads this so the
    /// system sees `playbackRate = 1.0` / `playbackState = .playing` during
    /// stream resolution — without it, the Now Playing app registration is
    /// deferred until audio starts, and skip/seek buttons render grayed
    /// because iOS doesn't yet consider us the active media source.
    private var isStartingPlayback = false
    private let artworkCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 50
        return cache
    }()
    // Stores JPEG-round-tripped images ready for AirPlay transmission, keyed by artwork URL.
    private let transmittableArtworkCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 20
        return cache
    }()
    private let foregroundNowPlayingElapsedUpdateInterval: TimeInterval = 1
    private let backgroundNowPlayingElapsedUpdateInterval: TimeInterval = 30

    init(logger: any AppLogging = DefaultAppLogger(category: "PlaybackService")) {
        self.logger = logger
        super.init()
        configureAudioSession()
        // Pre-warm AVPlayer once so every subsequent track avoids the full pipeline-creation cost.
        let player = AVPlayer()
        player.automaticallyWaitsToMinimizeStalling = false
        player.allowsExternalPlayback = false
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        player.preventsDisplaySleepDuringVideoPlayback = false
        self.player = player
        remoteCommandManager.attachPlayer(player)
        installRemoteCommandHandlers()
        observeAudioSessionInterruptions()
        observeAppLifecycle()
        installTimeObserver(on: player)
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Lets other audio sources (e.g. `MusicRecognitionService`) opt in to being
    /// silenced before primary playback resumes. Without this, two concurrent
    /// audio sources can both be subscribed to remote commands, leaving the
    /// Lock-Screen pause button routed to the wrong one.
    func registerSecondaryAudioSource(_ source: SecondaryAudioSource) {
        remoteCommandManager.registerSecondaryPlayer(source)
    }

    func unregisterSecondaryAudioSource(_ source: SecondaryAudioSource) {
        remoteCommandManager.unregisterSecondaryPlayer(source)
    }

    /// Plays a single track, preserving the current queue when possible.
    func play(track: Track) {
        play(track: track, queue: nil)
    }

    /// Plays a track and replaces the active queue with the provided ordering.
    func play(track: Track, queue: [Track]?) {
        userInitiatedPause = false

        if track.streamURL == nil {
            // Cancel any in-flight low-priority background prefetch for this track so
            // user-initiated playback immediately starts a fresh high-priority resolution.
            let key = cacheKey(for: track)
            if let existingTask = prefetchTasks[key] {
                existingTask.cancel()
                prefetchTasks.removeValue(forKey: key)
            }

            // Use full remote fallback so the first play-initiated resolution never
            // wastes time on a local-only attempt that might fail and then retries.
            _ = enqueueStreamResolutionTaskIfNeeded(for: track, priority: .high, useRemoteFallback: true)
        }

        configureQueue(for: track, queue: queue)

        if let currentTrack = nowPlaying, matches(currentTrack, track), player?.currentItem != nil {
            resume()
            return
        }

        startPlayback(for: track)
    }

    func playNextTrack() {
        userInitiatedPause = false

        guard playbackQueue.isEmpty == false else { return }

        if let playbackQueueIndex, playbackQueueIndex + 1 < playbackQueue.count {
            let nextIndex = playbackQueueIndex + 1
            self.playbackQueueIndex = nextIndex
            updateQueueState()
            startPlayback(for: playbackQueue[nextIndex])
            return
        }

        guard repeatMode == .all else { return }
        playbackQueueIndex = 0
        updateQueueState()
        startPlayback(for: playbackQueue[0])
    }

    func playPreviousTrack() {
        userInitiatedPause = false

        if let player, player.currentTime().seconds > 5 {
            // If the stream URL expired, restart rather than seeking on a dead item.
            if let url = activeStreamURL, Self.isStreamURLExpired(url), let track = nowPlaying {
                streamCandidateCache.removeValue(forKey: cacheKey(for: track))
                startPlayback(for: track)
                return
            }
            player.seek(to: .zero)
            if isPlaying == false {
                player.play()
                player.rate = playbackRate
                setIsPlaying(true)
                updatePlaybackState()
            }
            return
        }

        guard let playbackQueueIndex else { return }

        if playbackQueueIndex > 0 {
            let previousIndex = playbackQueueIndex - 1
            self.playbackQueueIndex = previousIndex
            updateQueueState()
            startPlayback(for: playbackQueue[previousIndex])
            return
        }

        if repeatMode == .all, let lastIndex = playbackQueue.indices.last {
            self.playbackQueueIndex = lastIndex
            updateQueueState()
            startPlayback(for: playbackQueue[lastIndex])
            return
        }

        player?.seek(to: .zero)
        updatePlaybackState()
    }

    func toggleShuffle() {
        shuffleMode.toggle()
        guard playbackQueue.isEmpty == false else {
            updateCommandAvailability()
            return
        }

        if shuffleMode {
            // Save original, shuffle remaining (keep current track at index)
            originalQueue = playbackQueue
            if let currentIndex = playbackQueueIndex {
                let current = playbackQueue[currentIndex]
                var rest = playbackQueue
                rest.remove(at: currentIndex)
                rest.shuffle()
                playbackQueue = [current] + rest
                playbackQueueIndex = 0
            } else {
                playbackQueue.shuffle()
            }
        } else {
            // Restore original order, keep position on current track
            if originalQueue.isEmpty == false {
                let current = nowPlaying
                playbackQueue = originalQueue
                if let current, let idx = playbackQueue.firstIndex(where: { matches($0, current) }) {
                    playbackQueueIndex = idx
                }
                originalQueue = []
            }
        }
        updateQueueState()
        if let current = nowPlaying {
            prewarmQueue(around: current)
        }
        updateCommandAvailability()
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        updateCommandAvailability()
    }

    /// Eagerly warms the stream cache for a list of tracks (call when tracks first appear on screen).
    func prefetchStreams(for tracks: [Track]) {
        guard isAppInBackground == false else { return }

        let candidates = tracks
            .filter { $0.youtubeVideoID != nil && $0.streamURL == nil }
            .prefix(10)

        // Stagger background prefetch to avoid firing dozens of InnerTube requests
        // simultaneously. The first 3 tracks get immediate resolution; subsequent
        // tracks are spaced 350ms apart to stay well under YouTube's rate limit.
        for (index, track) in candidates.enumerated() {
            let immediateWindow = 3
            if index < immediateWindow {
                _ = enqueueStreamResolutionTaskIfNeeded(for: track, priority: .userInitiated)
            } else {
                let delayNS = UInt64(index - immediateWindow + 1) * 350_000_000
                Task(priority: .background) { [weak self, track] in
                    try? await Task.sleep(nanoseconds: delayNS)
                    guard Task.isCancelled == false else { return }
                    _ = self?.enqueueStreamResolutionTaskIfNeeded(for: track, priority: .background)
                }
            }
        }
    }

    /// Resolves the best audio stream URL for a track (used by DownloadService).
    func resolveStreamURL(for track: Track) async throws -> URL? {
        let candidates = try await resolveAndCacheStreamCandidates(for: track)
        return candidates.first
    }

    /// Stops playback and clears queue, observers, and now-playing metadata.
    func stop() {
        resolveTask?.cancel()
        resolveTask = nil
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
        isResolvingStream = false
        playbackErrorMessage = nil
        tearDownPlayer()
        nowPlaying = nil
        setIsPlaying(false)
        setCurrentTime(0, threshold: 0)
        setDuration(0, threshold: 0)
        setBufferedTime(0, threshold: 0)
        setIsBufferingPlayback(false)
        playbackQueue = []
        playbackQueueIndex = nil
        stallRecoveryTask?.cancel()
        stallRecoveryTask = nil
        playbackEndWatchdogTask?.cancel()
        playbackEndWatchdogTask = nil
        userInitiatedPause = false
        isStartingPlayback = false
        prefetchTasks.values.forEach { $0.cancel() }
        prefetchTasks = [:]
        remoteCommandManager.clearNowPlaying()
        deactivateAudioSession()
        updateQueueState()
    }

    private func startPlayback(for track: Track) {
        resolveTask?.cancel()
        resolveTask = nil
        playbackStartupTask?.cancel()
        playbackStartupTask = nil
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
        playbackErrorMessage = nil
        userInitiatedPause = false
        // Mark intent to play *before* updating Now Playing info so the system
        // sees us as the active media source from the very first system tick
        // after the user taps a track — not 1–3 s later when stream resolution
        // completes. This is what eliminates the "buttons are grayed until
        // pause-play-pause" symptom.
        isStartingPlayback = true
        nowPlaying = track
        setCurrentTime(0, threshold: 0)
        if let authoritativeDuration = authoritativeDuration(for: track) {
            setDuration(authoritativeDuration, threshold: 0)
        } else {
            setDuration(0, threshold: 0)
        }
        setBufferedTime(0, threshold: 0)
        setIsBufferingPlayback(false)
        // Activate the audio session up-front (before stream extraction) so
        // iOS designates this app as the now-playing source immediately.
        // Without an active session, the system may route remote-command
        // events to a previously-playing app or render the controls inert.
        activateAudioSessionIfNeeded()
        remoteCommandManager.becomeActiveIfPossible()
        updateNowPlayingInfo(for: track)
        // Refresh `next/previous/seek` enable state right after Now Playing
        // info is set so the lock-screen layout doesn't render gray buttons
        // for the first paint.
        updateQueueState()
        prewarmQueue(around: track)
        tearDownPlayer()

        if let streamURL = track.streamURL {
            startPlayback(fromCandidates: [streamURL], for: track)
        } else if let cachedCandidates = cachedStreamCandidates(for: track), cachedCandidates.isEmpty == false {
            startPlayback(fromCandidates: cachedCandidates, for: track)
        } else if track.youtubeVideoID != nil {
            isResolvingStream = true
            updatePlaybackState()

            resolveTask = Task { [weak self, track] in
                guard let self else { return }

                do {
                    let resolvedURLs = try await self.resolveAndCacheStreamCandidates(
                        for: track,
                        reuseExistingPrefetch: false
                    )

                    guard Task.isCancelled == false else { return }
                    guard self.nowPlaying?.id == track.id else { return }

                    self.startPlayback(fromCandidates: resolvedURLs, for: track)
                } catch is CancellationError {
                    guard self.nowPlaying?.id == track.id else { return }
                    self.isResolvingStream = false
                    self.updatePlaybackState()
                } catch {
                    guard self.nowPlaying?.id == track.id else { return }
                    self.recordResolutionFailure(for: track)
                    self.isResolvingStream = false
                    self.setIsPlaying(false)
                    self.playbackErrorMessage = "MusicTube couldn't extract audio for this YouTube item right now."
                    self.updatePlaybackState()
                }
            }
        } else {
            isResolvingStream = false
            setIsPlaying(false)
            updatePlaybackState()
        }
    }

    /// Resumes playback or re-resolves the current track if the player has been torn down.
    func resume() {
        playbackErrorMessage = nil

        if isResolvingStream {
            return
        }

        userInitiatedPause = false

        if let player {
            // If the active stream URL has expired, recover with a fresh URL before resuming.
            if let url = activeStreamURL, Self.isStreamURLExpired(url), let track = nowPlaying {
                streamCandidateCache.removeValue(forKey: cacheKey(for: track))
                recoverPlayback(for: track, resumingAt: currentTime)
                return
            }
            activateAudioSessionIfNeeded()
            remoteCommandManager.becomeActiveIfPossible()
            player.play()
            player.rate = playbackRate
            setIsPlaying(true)
            updatePlaybackState()
            return
        }

        if let track = nowPlaying {
            play(track: track, queue: playbackQueue.isEmpty ? nil : playbackQueue)
        }
    }

    /// Pauses active playback and cancels in-flight startup and recovery work.
    func pause() {
        resolveTask?.cancel()
        resolveTask = nil
        playbackStartupTask?.cancel()
        playbackStartupTask = nil
        stallRecoveryTask?.cancel()
        stallRecoveryTask = nil
        cancelAllPrefetchTasks()
        isResolvingStream = false
        userInitiatedPause = true
        // Clear the optimistic load flag — pausing during stream resolution
        // must take effect immediately on the lock-screen icon, not wait for
        // the resolver to finish.
        isStartingPlayback = false
        player?.pause()
        setIsPlaying(false)
        updatePlaybackState()
    }

    /// Seeks to the requested playback time, clamped to the current duration.
    func seek(to time: TimeInterval) {
        guard let player else { return }

        // If the stream URL has expired, re-resolve and resume from the seek target.
        if let url = activeStreamURL, Self.isStreamURLExpired(url), let track = nowPlaying {
            streamCandidateCache.removeValue(forKey: cacheKey(for: track))
            pendingSeekTime = time
            setCurrentTime(time, threshold: 0)
            lastObservedTime = time
            updatePlaybackState()
            isResolvingStream = true
            resolveTask?.cancel()
            resolveTask = Task { [weak self, track, time] in
                guard let self else { return }
                do {
                    let freshURLs = try await self.resolveAndCacheStreamCandidates(
                        for: track,
                        reuseExistingPrefetch: false
                    )
                    guard !Task.isCancelled, self.nowPlaying?.id == track.id else { return }
                    self.startPlayback(fromCandidates: freshURLs, for: track, resumeTime: time)
                } catch {
                    guard self.nowPlaying?.id == track.id else { return }
                    self.isResolvingStream = false
                    self.pendingSeekTime = nil
                    self.playbackErrorMessage = "Stream interrupted. Tap play to retry."
                    self.updatePlaybackState()
                }
            }
            return
        }

        let boundedDuration = duration.isFinite && duration > 0 ? duration : time
        let clampedTime = max(0, min(time, boundedDuration))
        let targetTime = CMTime(seconds: clampedTime, preferredTimescale: 600)

        // Update UI immediately so the bar shows the new position right away.
        pendingSeekTime = clampedTime
        setCurrentTime(clampedTime, threshold: 0)
        lastObservedTime = clampedTime
        updatePlaybackState()

        // 0.5s tolerance = instant keyframe seek for audio; zero tolerance can take 3–10s
        // on DASH streams, which froze the bar while audio played from the new position.
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pendingSeekTime = nil
            }
        }
    }

    private func configureAudioSession() {
        // Configure category only — `setActive(true)` is deferred to
        // `activateAudioSessionIfNeeded()` so we don't duck other apps' audio
        // at launch when the user hasn't yet asked us to play anything. This
        // also moves the activation handshake off the cold-start critical path.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback,
                mode: .default,
                policy: .longFormAudio,
                options: []
            )
        } catch {
            do {
                try session.setCategory(.playback, mode: .default, options: [.allowAirPlay])
            } catch {
                logger.error("Failed to configure audio session", error: error)
            }
        }
    }

    private func installRemoteCommandHandlers() {
        let bindings = RemoteCommandManager.Bindings(
            isPlaying: { [weak self] in
                guard let self else { return false }
                // Treat "still loading the stream the user just asked for" as
                // playing for the purposes of `MPNowPlayingInfo`. Otherwise
                // the system shows playbackRate=0 / playbackState=.paused
                // during the 1–3 s YouTube extraction, refuses to designate
                // us as the active media source, and the entire command set
                // renders grayed-out until something else triggers a refresh.
                return self.isPlaying || self.isStartingPlayback
            },
            currentRate: { [weak self] in self?.playbackRate ?? 1.0 },
            currentTime: { [weak self] in self?.currentTime ?? 0 },
            duration: { [weak self] in self?.duration ?? 0 },
            queueIndex: { [weak self] in self?.playbackQueueIndex },
            queueCount: { [weak self] in self?.playbackQueue.count ?? 0 },
            hasNextTrack: { [weak self] in self?.hasNextTrack ?? false },
            hasPreviousTrack: { [weak self] in self?.hasPreviousTrack ?? false },
            canSeek: { [weak self] in (self?.duration ?? 0) > 0 },
            isPlayingImmediately: { [weak player] in
                guard let player else { return false }
                return player.rate != 0 || player.timeControlStatus == .playing
            },
            pauseImmediately: { [weak player] in
                player?.pause()
            },
            currentTimeImmediately: { [weak player] in
                guard let seconds = player?.currentTime().seconds, seconds.isFinite else { return 0 }
                return max(0, seconds)
            },
            play: { [weak self] in self?.resume() },
            pause: { [weak self] in self?.pause() },
            toggle: { [weak self] in self?.togglePlayback() },
            next: { [weak self] in self?.playNextTrack() },
            previous: { [weak self] in self?.playPreviousTrack() },
            seek: { [weak self] time in self?.seek(to: time) },
            changeRepeatType: { [weak self] type in self?.applyRepeatType(type) },
            changeShuffleType: { [weak self] type in self?.applyShuffleType(type) }
        )
        remoteCommandManager.install(bindings)
        remoteCommandManager.applyCommandAvailability()
    }

    private func updateNowPlayingInfo(for track: Track) {
        var artwork: MPMediaItemArtwork?
        // Include cached processed artwork immediately so Apple TV gets it on first transmission.
        if let artworkURL = track.artworkURL,
           let cached = transmittableArtworkCache.object(forKey: artworkURL as NSURL) {
            let side = CGFloat(ArtworkPixelSize.nowPlaying)
            let size = CGSize(width: side, height: side)
            artwork = MPMediaItemArtwork(boundsSize: size) { _ in cached }
        }

        remoteCommandManager.updateNowPlayingInfo(
            title: track.title,
            artist: track.artist,
            artwork: artwork
        )
        loadArtworkForNowPlaying(track)
    }

    private func updatePlaybackState() {
        remoteCommandManager.syncPlaybackState()
        refreshStateSnapshot()
        updateCommandAvailability()
        updateQueueState()
    }

    /// Lightweight variant used by the periodic time observer — only updates elapsed
    /// time in NowPlayingInfo and refreshes the state snapshot. Avoids the overhead
    /// of updateCommandAvailability() and updateQueueState() on every 0.5 s tick.
    private func updateElapsedPlaybackInfo() {
        guard shouldUpdateNowPlayingElapsedInfo() else { return }
        remoteCommandManager.updateElapsedTime()
    }

    private func tearDownPlayer() {
        playbackStartupTask?.cancel()
        playbackStartupTask = nil
        stallRecoveryTask?.cancel()
        stallRecoveryTask = nil
        playbackEndWatchdogTask?.cancel()
        playbackEndWatchdogTask = nil
        pendingSeekTime = nil
        playerItemStatusObservation = nil
        playerItemDurationObservation = nil
        playerItemBufferedTimeObservation = nil
        playbackObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        activeStreamURL = nil
        setBufferedTime(0, threshold: 0)
        setIsBufferingPlayback(false)
        removeItemDidEndObserver()
        removeItemFailedObserver()
        removeStalledObserver()
    }

    private func startPlayback(
        fromCandidates candidateURLs: [URL],
        for track: Track,
        candidateIndex: Int = 0,
        resumeTime: TimeInterval = 0,
        allowRemoteRecovery: Bool = true
    ) {
        let uniqueCandidates = Self.deduplicatedURLs(candidateURLs)

        guard candidateIndex < uniqueCandidates.count else {
            if allowRemoteRecovery, track.youtubeVideoID != nil {
                streamCandidateCache.removeValue(forKey: cacheKey(for: track))
                resolveTask?.cancel()
                isResolvingStream = true
                setIsBufferingPlayback(true)
                updatePlaybackState()

                resolveTask = Task { [weak self] in
                    guard let self else { return }

                    do {
                        let remoteCandidates = try await self.resolveRemoteStreamCandidates(for: track)
                        guard Task.isCancelled == false else { return }
                        guard self.nowPlaying?.id == track.id else { return }

                        self.startPlayback(
                            fromCandidates: remoteCandidates,
                            for: track,
                            resumeTime: resumeTime,
                            allowRemoteRecovery: false
                        )
                    } catch {
                        guard self.nowPlaying?.id == track.id else { return }
                        self.recordResolutionFailure(for: track)
                        self.tearDownPlayer()
                        self.isResolvingStream = false
                        self.setIsBufferingPlayback(false)
                        self.setIsPlaying(false)
                        self.playbackErrorMessage = "MusicTube couldn't start audio for this YouTube item right now."
                        self.updatePlaybackState()
                    }
                }
                return
            }

            recordResolutionFailure(for: track)
            tearDownPlayer()
            isResolvingStream = false
            setIsBufferingPlayback(false)
            setIsPlaying(false)
            playbackErrorMessage = "MusicTube couldn't start audio for this YouTube item right now."
            updatePlaybackState()
            return
        }

        let url = uniqueCandidates[candidateIndex]
        tearDownPlayer()
        isResolvingStream = false
        activeStreamURL = url
        if let authoritativeDuration = authoritativeDuration(for: track) {
            setDuration(authoritativeDuration, threshold: 0)
        }

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = BufferingPolicy.startupForwardBufferDuration
        playerItem.preferredPeakBitRate = 256_000
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        self.player?.replaceCurrentItem(with: playerItem)
        registerItemDidEndObserver(for: playerItem)
        registerItemFailedObserver(for: playerItem, track: track)
        registerStalledObserver(for: playerItem, track: track)
        observeDuration(for: playerItem, track: track)
        observeBufferedTime(for: playerItem, track: track)
        activateAudioSessionIfNeeded()

        playerItemStatusObservation = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.nowPlaying?.id == track.id else { return }

                switch item.status {
                case .failed:
                    self.startPlayback(
                        fromCandidates: uniqueCandidates,
                        for: track,
                        candidateIndex: candidateIndex + 1,
                        resumeTime: resumeTime
                    )
                case .readyToPlay:
                    self.playbackStartupTask?.cancel()
                    self.playbackStartupTask = nil
                    if let duration = self.preferredDuration(for: track, reportedDuration: self.seconds(from: item.duration)) {
                        self.setDuration(duration)
                    }
                    // Resume from position after stream recovery.
                    // Use 0.5 s tolerance — zero tolerance can stall for several seconds on DASH streams.
                    if resumeTime > 1 {
                        let target = CMTime(seconds: resumeTime, preferredTimescale: 600)
                        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
                        self.player?.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance)
                        self.setCurrentTime(resumeTime, threshold: 0)
                    }
                    // Never override a user-initiated pause — the user tapped pause before
                    // the item finished loading; honour that intent and stay paused.
                    guard !self.userInitiatedPause else {
                        self.updatePlaybackState()
                        return
                    }
                    self.player?.play()
                    self.player?.rate = self.playbackRate
                    self.updatePlaybackState()
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }

        playbackObservation = self.player?.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                self.setIsPlaying(self.shouldPresentAsPlaying(player))
                self.setIsBufferingPlayback(
                    player.timeControlStatus == .waitingToPlayAtSpecifiedRate && self.isResolvingStream == false
                )
                switch player.timeControlStatus {
                case .playing:
                    // Stream is healthy — commit to steady-state buffering and dismiss the watchdog.
                    player.automaticallyWaitsToMinimizeStalling = false
                    player.currentItem?.preferredForwardBufferDuration = BufferingPolicy.steadyStateForwardBufferDuration
                    self.playbackStartupTask?.cancel()
                    self.playbackStartupTask = nil
                case .waitingToPlayAtSpecifiedRate:
                    // Player is actively buffering — stream is in progress, dismiss the watchdog.
                    self.playbackStartupTask?.cancel()
                    self.playbackStartupTask = nil
                default:
                    break
                }
                self.updatePlaybackState()
            }
        }

        updateNowPlayingInfo(for: track)
        setIsBufferingPlayback(true)
        updatePlaybackState()

        playbackStartupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: BufferingPolicy.startupWaitTimeoutNanoseconds)
            guard let self else { return }
            guard let player = self.player else { return }
            guard Task.isCancelled == false else { return }
            guard self.nowPlaying?.id == track.id else { return }

            // Both .playing and .waitingToPlayAtSpecifiedRate mean the stream is healthy.
            // Only act when the player is .paused (truly stalled with nothing in flight).
            if player.timeControlStatus != .paused {
                return
            }

            if player.currentItem?.status != .readyToPlay {
                self.startPlayback(
                    fromCandidates: uniqueCandidates,
                    for: track,
                    candidateIndex: candidateIndex + 1,
                    resumeTime: resumeTime
                )
                return
            }

            player.automaticallyWaitsToMinimizeStalling = false
            player.play()
            player.rate = self.playbackRate
        }

        updatePlaybackState()
    }

    private func configureQueue(for track: Track, queue: [Track]?) {
        var normalizedQueue = normalizeQueue(queue ?? [track], selectedTrack: track)
        originalQueue = normalizedQueue

        if shuffleMode {
            if let idx = normalizedQueue.firstIndex(where: { matches($0, track) }) {
                normalizedQueue.remove(at: idx)
                normalizedQueue.shuffle()
                normalizedQueue.insert(track, at: 0)
            } else {
                normalizedQueue.shuffle()
            }
        }

        playbackQueue = normalizedQueue
        playbackQueueIndex = normalizedQueue.firstIndex(where: { matches($0, track) }) ?? 0
        updateQueueState()
        prewarmQueue(around: track)
    }

    private func normalizeQueue(_ queue: [Track], selectedTrack: Track) -> [Track] {
        let dedupedQueue = deduplicatedTracks(queue)

        if dedupedQueue.contains(where: { matches($0, selectedTrack) }) {
            return dedupedQueue
        }

        return [selectedTrack] + dedupedQueue
    }

    private func deduplicatedTracks(_ tracks: [Track]) -> [Track] {
        var seenTrackIDs: Set<String> = []
        return tracks.filter { track in
            let identifier = track.youtubeVideoID ?? track.id
            return seenTrackIDs.insert(identifier).inserted
        }
    }

    private func matches(_ lhs: Track, _ rhs: Track) -> Bool {
        let lhsIdentifier = lhs.youtubeVideoID ?? lhs.id
        let rhsIdentifier = rhs.youtubeVideoID ?? rhs.id
        return lhsIdentifier == rhsIdentifier
    }

    private func updateQueueState() {
        let nextTrackAvailable = canAdvanceToNextTrack
        let previousTrackAvailable = canReturnToPreviousTrack

        if hasNextTrack != nextTrackAvailable { hasNextTrack = nextTrackAvailable }
        if hasPreviousTrack != previousTrackAvailable { hasPreviousTrack = previousTrackAvailable }
        if currentQueue != playbackQueue { currentQueue = playbackQueue }
        if currentQueueIndex != playbackQueueIndex { currentQueueIndex = playbackQueueIndex }

        refreshStateSnapshot()
        updateCommandAvailability()
    }

    private var canAdvanceToNextTrack: Bool {
        guard playbackQueue.isEmpty == false else { return false }
        guard let playbackQueueIndex else { return playbackQueue.count > 1 }
        return playbackQueueIndex < playbackQueue.count - 1 || (repeatMode == .all && playbackQueue.count > 1)
    }

    private var canReturnToPreviousTrack: Bool {
        // Always available when a track is loaded. The handler decides between
        // "seek to start" (currentTime > 5 s) and "skip to previous queue item"
        // (currentTime ≤ 5 s). Gating the button on the 5-second threshold made
        // it render as grayed for the first five seconds of every song; users
        // couldn't tell whether the control was broken or just disabled until
        // they manually pause/play/paused to force a refresh.
        return nowPlaying != nil
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            player?.rate = rate
        }
    }

    private func registerItemDidEndObserver(for item: AVPlayerItem?) {
        removeItemDidEndObserver()

        guard let item else { return }

        itemDidEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePlaybackEnd()
            }
        }
    }

    private func handlePlaybackEnd() {
        playbackEndWatchdogTask?.cancel()
        playbackEndWatchdogTask = nil
        userInitiatedPause = false

        switch repeatMode {
        case .one:
            // If the stream URL expired mid-song, do a full restart rather than seeking on a dead item.
            if let url = activeStreamURL, Self.isStreamURLExpired(url), let track = nowPlaying {
                streamCandidateCache.removeValue(forKey: cacheKey(for: track))
                startPlayback(for: track)
                return
            }
            player?.seek(to: .zero)
            player?.play()
            setIsPlaying(true)
            setCurrentTime(0, threshold: 0)
            updatePlaybackState()
        case .all:
            if hasNextTrack {
                playNextTrack()
            } else if playbackQueue.isEmpty == false {
                playbackQueueIndex = 0
                updateQueueState()
                startPlayback(for: playbackQueue[0])
            }
        case .off:
            if hasNextTrack {
                playNextTrack()
            } else {
                setIsPlaying(false)
                updatePlaybackState()
            }
        }
    }

    private func removeItemDidEndObserver() {
        if let itemDidEndObserver {
            NotificationCenter.default.removeObserver(itemDidEndObserver)
            self.itemDidEndObserver = nil
        }
    }

    // MARK: - Stream Failure Recovery

    /// Fires when the stream errors mid-playback (e.g. expired YouTube URL).
    /// Clears the cached URL and re-resolves a fresh one, resuming from currentTime.
    private func registerItemFailedObserver(for item: AVPlayerItem, track: Track) {
        itemFailedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.nowPlaying?.id == track.id else { return }
                let resumeAt = self.currentTime
                // Evict the stale (likely expired) URL from cache before re-resolving
                self.streamCandidateCache.removeValue(forKey: self.cacheKey(for: track))
                self.recoverPlayback(for: track, resumingAt: resumeAt)
            }
        }
    }

    private func removeItemFailedObserver() {
        if let itemFailedObserver {
            NotificationCenter.default.removeObserver(itemFailedObserver)
            self.itemFailedObserver = nil
        }
    }

    /// Fires when AVPlayer stalls mid-song due to buffer underrun.
    /// Gives AVPlayer 30 s to self-recover; if still stalled, re-resolves the stream.
    private func registerStalledObserver(for item: AVPlayerItem, track: Track) {
        stalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.nowPlaying?.id == track.id else { return }
                self.scheduleStallRecovery(for: track)
            }
        }
    }

    private func removeStalledObserver() {
        if let stalledObserver {
            NotificationCenter.default.removeObserver(stalledObserver)
            self.stalledObserver = nil
        }
    }

    private func scheduleStallRecovery(for track: Track) {
        stallRecoveryTask?.cancel()
        stallRecoveryTask = Task { [weak self, track] in
            // Give AVPlayer 12 s to self-recover before forcing a stream re-resolution.
            // 30 s was too long: expired stream URLs cause a 30-second hang on seek/resume.
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self, Task.isCancelled == false else { return }
            guard self.nowPlaying?.id == track.id else { return }
            // Still stalled — force a fresh stream resolution
            guard self.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
            let resumeAt = self.currentTime
            self.streamCandidateCache.removeValue(forKey: self.cacheKey(for: track))
            self.recoverPlayback(for: track, resumingAt: resumeAt)
        }
    }

    /// Re-resolves a fresh stream URL and resumes playback from `time`.
    private func recoverPlayback(for track: Track, resumingAt time: TimeInterval) {
        guard nowPlaying?.id == track.id else { return }
        // Don't attempt recovery while the user has deliberately paused — the stream
        // will be re-resolved when the user taps play.
        guard !userInitiatedPause else { return }
        isResolvingStream = true
        resolveTask?.cancel()
        resolveTask = Task { [weak self, track, time] in
            guard let self else { return }
            do {
                let freshURLs = try await self.resolveAndCacheStreamCandidates(
                    for: track,
                    reuseExistingPrefetch: false
                )
                guard Task.isCancelled == false, self.nowPlaying?.id == track.id else { return }
                self.startPlayback(fromCandidates: freshURLs, for: track, resumeTime: time)
            } catch {
                guard self.nowPlaying?.id == track.id else { return }
                self.isResolvingStream = false
                self.setIsPlaying(false)
                self.playbackErrorMessage = "Stream interrupted. Tap play to retry."
                self.updatePlaybackState()
            }
        }
    }

    private func installTimeObserver(on player: AVPlayer) {
        removeTimeObserver()
        lastObservedTime = 0

        let interval = CMTime(seconds: 1.0, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak player] time in
            // Already on the main queue — assumeIsolated avoids the async hop that
            // Task { @MainActor } would introduce, which under background QoS (no
            // debugger) stalls the scheduler and causes visible UI lag.
            MainActor.assumeIsolated { [weak self, weak player] in
                guard let self, let player else { return }
                guard self.player === player else { return }

                let updatedTime = CMTimeGetSeconds(time)
                if updatedTime.isFinite {
                    if let target = self.pendingSeekTime, updatedTime < target - 1.0 {
                        // Still mid-seek — keep the already-set pending position on screen.
                    } else {
                        self.setCurrentTime(max(0, updatedTime))
                        self.checkForDASHPlaybackEnd(currentTime: updatedTime, player: player)
                        self.lastObservedTime = updatedTime
                    }
                }

                if let item = player.currentItem {
                    self.setBufferedTime(self.bufferedTime(for: item))
                }

                if self.duration == 0,
                   let track = self.nowPlaying,
                   let itemDuration = self.preferredDuration(
                        for: track,
                        reportedDuration: self.seconds(from: player.currentItem?.duration)
                   ) {
                    self.setDuration(itemDuration)
                }

                self.updateElapsedPlaybackInfo()
            }
        }
    }

    /// Watchdog for YouTube DASH audio-only streams whose reported duration is shorter than
    /// actual playback — `AVPlayerItemDidPlayToEndTime` never fires in that case.
    /// Detects end-of-stream by checking the playhead has stopped advancing near duration.
    private func checkForDASHPlaybackEnd(currentTime: TimeInterval, player: AVPlayer) {
        guard duration > 0, nowPlaying != nil, userInitiatedPause == false else { return }
        // Only arm the watchdog within the last 5 seconds of reported duration
        guard currentTime >= duration - 5 else {
            playbackEndWatchdogTask?.cancel()
            playbackEndWatchdogTask = nil
            return
        }
        guard playbackEndWatchdogTask == nil else { return }

        playbackEndWatchdogTask = Task { [weak self, weak player] in
            // Wait 3 s (3 time-observer ticks) before concluding the stream truly ended.
            // 1.5 s was too short: a brief buffer stall near the end falsely triggered
            // end-of-track, silently skipping to the next song while audio was still playing.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard let player else { return }

            let newTime = CMTimeGetSeconds(player.currentTime())
            // Require at least 0.5 s of advancement to consider the stream still alive.
            let timeAdvanced = abs(newTime - self.lastObservedTime) > 0.5
            let playerStillThinkingItsPlaying = player.timeControlStatus == .playing || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            let playerSilentlyStoppedNearTheEnd = player.timeControlStatus == .paused && newTime >= self.duration - 0.75

            if !timeAdvanced, (playerStillThinkingItsPlaying || playerSilentlyStoppedNearTheEnd) {
                await MainActor.run { [weak self] in
                    self?.handlePlaybackEnd()
                }
            }
            await MainActor.run { [weak self] in
                self?.playbackEndWatchdogTask = nil
            }
        }
    }

    private func removeTimeObserver() {
        if let timeObserverToken, let player {
            player.removeTimeObserver(timeObserverToken)
            self.timeObserverToken = nil
        }
    }

    private func observeDuration(for item: AVPlayerItem, track: Track) {
        playerItemDurationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.nowPlaying?.id == track.id else { return }
                if let duration = self.preferredDuration(for: track, reportedDuration: self.seconds(from: item.duration)) {
                    self.setDuration(duration)
                }
                self.updatePlaybackState()
            }
        }

        // Some YouTube DASH audio streams report an inflated duration through AVPlayer.
        // Prefer YouTube's own duration metadata when we have it, otherwise fall back to
        // the asset container duration if it looks more trustworthy than the player item.
        Task { [weak self, weak item, track] in
            guard let asset = item?.asset as? AVURLAsset else { return }
            guard let assetDuration = try? await asset.load(.duration) else { return }
            let loadedDuration = CMTimeGetSeconds(assetDuration)
            guard loadedDuration.isFinite, loadedDuration > 1 else { return }
            await MainActor.run { [weak self] in
                guard let self, self.nowPlaying?.id == track.id else { return }
                let candidate = self.preferredDuration(for: track, reportedDuration: loadedDuration) ?? loadedDuration
                if self.duration == 0 || self.duration > candidate * 1.4 {
                    self.setDuration(candidate, threshold: 0)
                    self.updatePlaybackState()
                }
            }
        }
    }

    private func observeBufferedTime(for item: AVPlayerItem, track: Track) {
        playerItemBufferedTimeObservation = item.observe(\.loadedTimeRanges, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.nowPlaying?.id == track.id else { return }
                guard self.isAppInBackground == false else { return }
                self.setBufferedTime(self.bufferedTime(for: item))
            }
        }
    }

    private func setIsPlaying(_ newValue: Bool) {
        // Once we have real playback state from AVPlayer (in either direction),
        // the optimistic loading flag is no longer needed and must be cleared
        // so future updates accurately reflect the player.
        if isStartingPlayback {
            isStartingPlayback = false
        }
        guard isPlaying != newValue else { return }
        isPlaying = newValue
        refreshStateSnapshot()
    }

    private func setCurrentTime(_ newValue: TimeInterval, threshold: TimeInterval = 0.05) {
        let clampedValue = duration > 0 ? max(0, min(newValue, duration)) : max(0, newValue)
        guard abs(currentTime - clampedValue) > threshold else { return }
        currentTime = clampedValue
        if isAppInBackground == false {
            refreshStateSnapshot()
        }
    }

    private func setDuration(_ newValue: TimeInterval, threshold: TimeInterval = 0.05) {
        let normalizedValue = max(0, newValue)
        let previousDuration = duration
        guard abs(previousDuration - normalizedValue) > threshold else { return }
        duration = normalizedValue
        refreshStateSnapshot()
        // `changePlaybackPositionCommand.isEnabled` is gated on `duration > 0`.
        // Without this refresh the scrubber stays disabled until the next
        // `updatePlaybackState()` (typically only fired by a user tap), which
        // is what manifested as a "grayed-out seek bar that wakes up only
        // after pause/play/pause."
        let crossedZeroBoundary = (previousDuration == 0) != (normalizedValue == 0)
        if crossedZeroBoundary {
            remoteCommandManager.applyCommandAvailability()
        }
    }

    private func setBufferedTime(_ newValue: TimeInterval, threshold: TimeInterval = 0.1) {
        let upperBound = duration > 0 ? duration : .greatestFiniteMagnitude
        let normalizedValue = max(currentTime, min(max(0, newValue), upperBound))
        guard abs(bufferedTime - normalizedValue) > threshold else { return }
        bufferedTime = normalizedValue
        if isAppInBackground == false {
            refreshStateSnapshot()
        }
    }

    private func setIsBufferingPlayback(_ newValue: Bool) {
        guard isBufferingPlayback != newValue else { return }
        isBufferingPlayback = newValue
        refreshStateSnapshot()
    }

    private func refreshStateSnapshot() {
        let snapshot = PlaybackState(
            nowPlaying: nowPlaying,
            isPlaying: isPlaying,
            isResolvingStream: isResolvingStream,
            playbackErrorMessage: playbackErrorMessage,
            hasNextTrack: hasNextTrack,
            hasPreviousTrack: hasPreviousTrack,
            currentTime: currentTime,
            duration: duration,
            bufferedTime: bufferedTime,
            isBufferingPlayback: isBufferingPlayback
        )

        guard state != snapshot else { return }
        state = snapshot
    }

    private func shouldUpdateNowPlayingElapsedInfo() -> Bool {
        let now = Date()
        let interval = isAppInBackground
            ? backgroundNowPlayingElapsedUpdateInterval
            : foregroundNowPlayingElapsedUpdateInterval
        guard now.timeIntervalSince(lastNowPlayingElapsedUpdate) >= interval else { return false }
        lastNowPlayingElapsedUpdate = now
        return true
    }

    private func shouldPresentAsPlaying(_ player: AVPlayer) -> Bool {
        switch player.timeControlStatus {
        case .paused:
            return false
        case .playing, .waitingToPlayAtSpecifiedRate:
            return true
        @unknown default:
            return player.rate != 0
        }
    }

    private func loadArtworkForNowPlaying(_ track: Track) {
        artworkLoadTask?.cancel()
        artworkLoadTask = nil

        guard let artworkURL = track.artworkURL else {
            remoteCommandManager.removeArtwork()
            return
        }

        // Already processed and cached — apply immediately.
        if let transmittable = transmittableArtworkCache.object(forKey: artworkURL as NSURL) {
            applyTransmittableArtwork(transmittable)
            return
        }

        artworkLoadTask = Task { [weak self, artworkURL, track] in
            guard let self else { return }

            // Try memory caches before hitting the network.
            let sourceImage: UIImage?
            if let cached = self.artworkCache.object(forKey: artworkURL as NSURL) {
                sourceImage = cached
            } else if let cached = ImageCache.shared.image(for: artworkURL, maxPixelSize: ArtworkPixelSize.nowPlaying) {
                self.artworkCache.setObject(cached, forKey: artworkURL as NSURL)
                sourceImage = cached
            } else {
                sourceImage = await ArtworkRepository.shared.image(
                    for: artworkURL,
                    maxPixelSize: ArtworkPixelSize.nowPlaying
                )
            }

            guard let image = sourceImage, !Task.isCancelled else { return }
            self.artworkCache.setObject(image, forKey: artworkURL as NSURL)

            // Process the image off the main thread so AirPlay/Lock Screen artwork is fully decoded.
            let transmittable = await Task.detached(priority: .utility) {
                Self.makeTransmittableArtwork(from: image)
            }.value

            guard !Task.isCancelled, self.nowPlaying?.id == track.id else { return }

            self.transmittableArtworkCache.setObject(transmittable, forKey: artworkURL as NSURL)
            self.applyTransmittableArtwork(transmittable)
        }
    }

    // Runs on a background thread — no actor state accessed.
    // Uses CGContext to produce a raw pixel-buffer UIImage (no lazy decoding) so AirPlay 2
    // can serialize it directly without needing to call back into a Swift closure.
    private nonisolated static func makeTransmittableArtwork(from image: UIImage) -> UIImage {
        let side = ArtworkPixelSize.nowPlaying
        let sideCG = CGFloat(side)
        guard let cgSource = image.cgImage else { return image }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
                       | CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return image }

        // Center-crop 16:9 source into a 1:1 square.
        let srcW = CGFloat(cgSource.width)
        let srcH = CGFloat(cgSource.height)
        let srcRatio = srcW / srcH
        let drawRect: CGRect
        if srcRatio > 1 {
            let w = sideCG * srcRatio
            drawRect = CGRect(x: -(w - sideCG) / 2, y: 0, width: w, height: sideCG)
        } else {
            let h = sideCG / srcRatio
            drawRect = CGRect(x: 0, y: -(h - sideCG) / 2, width: sideCG, height: h)
        }
        ctx.draw(cgSource, in: drawRect)

        guard let result = ctx.makeImage() else { return image }
        return UIImage(cgImage: result)
    }

    private func applyTransmittableArtwork(_ transmittable: UIImage) {
        let side = CGFloat(ArtworkPixelSize.nowPlaying)
        let size = CGSize(width: side, height: side)
        let artwork = MPMediaItemArtwork(boundsSize: size) { _ in transmittable }
        remoteCommandManager.setArtwork(artwork)
    }

    private func observeAudioSessionInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleAudioSessionInterruption(notification)
            }
        }
    }

    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        let backgroundObserver = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAppDidEnterBackground()
            }
        }

        let foregroundObserver = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isAppInBackground = false
            }
        }

        lifecycleObservers = [backgroundObserver, foregroundObserver]
    }

    private func handleAppDidEnterBackground() {
        isAppInBackground = true
        // Keep the active AVPlayer untouched, but stop speculative network work.
        // Detached from Xcode, iOS aggressively throttles background networking;
        // awaiting one of these prefetches is what made lock-screen skip/pause
        // feel like it was stuck for several seconds.
        cancelAllPrefetchTasks()
        artworkLoadTask?.cancel()
        artworkLoadTask = nil
    }

    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let interruptionType = AVAudioSession.InterruptionType(rawValue: typeValue)
        else {
            return
        }

        switch interruptionType {
        case .began:
            // iOS implicitly deactivates the session on interruption — reset the
            // flag so activateAudioSessionIfNeeded() runs setActive(true) again
            // when playback resumes, re-establishing us as the Now Playing source.
            audioSessionActivated = false
            pause()
        case .ended:
            guard
                let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt
            else {
                return
            }

            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                resume()
            }
        @unknown default:
            break
        }
    }

    private func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    private func activateAudioSessionIfNeeded() {
        // Skip the activation handshake when the session is already active —
        // calling `setActive(true)` repeatedly is cheap-ish but not free, and
        // doing it on every play/seek event under main-thread pressure (long
        // background sessions without the debugger) adds perceptible latency.
        guard !audioSessionActivated else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            audioSessionActivated = true
        } catch {
            logger.error("Failed to reactivate audio session", error: error)
        }
    }

    private func deactivateAudioSession() {
        guard audioSessionActivated else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            audioSessionActivated = false
        } catch {
            logger.error("Failed to deactivate audio session", error: error)
        }
    }

    private func updateCommandAvailability() {
        remoteCommandManager.applyCommandAvailability()
        remoteCommandManager.setShuffleType(shuffleMode ? .items : .off)
        remoteCommandManager.setRepeatType(currentRemoteRepeatType)
    }

    private func cachedStreamCandidates(for track: Track) -> [URL]? {
        streamCandidateCache[cacheKey(for: track)]
    }

    private func cacheKey(for track: Track) -> String {
        track.youtubeVideoID ?? track.id
    }

    private func authoritativeDuration(for track: Track) -> TimeInterval? {
        let cachedDuration = authoritativeDurationCache[cacheKey(for: track)]
        let trackDuration = track.duration

        for candidate in [cachedDuration, trackDuration] {
            if let candidate, candidate.isFinite, candidate > 0 {
                return candidate
            }
        }

        return nil
    }

    private func preferredDuration(for track: Track, reportedDuration: TimeInterval?) -> TimeInterval? {
        if let authoritativeDuration = authoritativeDuration(for: track) {
            return authoritativeDuration
        }

        return reportedDuration
    }

    private func bufferedTime(for item: AVPlayerItem) -> TimeInterval {
        let loadedRanges = item.loadedTimeRanges.compactMap(\.timeRangeValue)
        let loadedEndTimes = loadedRanges.compactMap { range -> TimeInterval? in
            let start = CMTimeGetSeconds(range.start)
            let length = CMTimeGetSeconds(range.duration)
            guard start.isFinite, length.isFinite else { return nil }
            return start + length
        }

        return loadedEndTimes.max() ?? currentTime
    }

    private func resolveAndCacheStreamCandidates(
        for track: Track,
        allowRemoteFallback: Bool = true,
        reuseExistingPrefetch: Bool = true
    ) async throws -> [URL] {
        let key = cacheKey(for: track)
        if let cached = cachedStreamCandidates(for: track), cached.isEmpty == false {
            // Filter out any URLs whose YouTube `expire` timestamp is within 5 minutes
            let stillValid = cached.filter { !Self.isStreamURLExpired($0) }
            if stillValid.isEmpty == false {
                return stillValid
            }
            // All cached URLs are expired — evict and re-resolve
            streamCandidateCache.removeValue(forKey: key)
        }

        if reuseExistingPrefetch == false {
            cancelPrefetch(for: track)
        } else if let prefetchTask = prefetchTasks[key] ?? enqueueStreamResolutionTaskIfNeeded(for: track, priority: .userInitiated) {
            let prefetchedCandidates = await prefetchTask.value
            let stillValidPrefetch = prefetchedCandidates.filter { !Self.isStreamURLExpired($0) }
            if stillValidPrefetch.isEmpty == false {
                streamCandidateCache[key] = stillValidPrefetch
                return stillValidPrefetch
            }
        }

        if allowRemoteFallback {
            return try await resolveFreshStreamCandidates(for: track)
        } else {
            return try await resolveLocalStreamCandidates(for: track)
        }
    }

    private func resolveFreshStreamCandidates(for track: Track) async throws -> [URL] {
        let result = try await Self.extractPlayableStreamCandidates(for: track, methods: [.local, .remote])
        let deduplicated = Self.deduplicatedURLs(result.urls)
        if deduplicated.isEmpty == false {
            streamCandidateCache[cacheKey(for: track)] = deduplicated
            if let approximateDuration = result.approximateDuration {
                authoritativeDurationCache[cacheKey(for: track)] = approximateDuration
            }
            trimStreamCacheIfNeeded()
        }
        return deduplicated
    }

    private func resolveLocalStreamCandidates(for track: Track) async throws -> [URL] {
        let result = try await Self.extractPlayableStreamCandidates(for: track, methods: [.local])
        let deduplicated = Self.deduplicatedURLs(result.urls)
        if deduplicated.isEmpty == false {
            streamCandidateCache[cacheKey(for: track)] = deduplicated
            if let approximateDuration = result.approximateDuration {
                authoritativeDurationCache[cacheKey(for: track)] = approximateDuration
            }
            trimStreamCacheIfNeeded()
        }
        return deduplicated
    }

    private func resolveRemoteStreamCandidates(for track: Track) async throws -> [URL] {
        let result = try await Self.extractPlayableStreamCandidates(for: track, methods: [.remote])
        let deduplicated = Self.deduplicatedURLs(result.urls)
        if deduplicated.isEmpty == false {
            streamCandidateCache[cacheKey(for: track)] = deduplicated
            if let approximateDuration = result.approximateDuration {
                authoritativeDurationCache[cacheKey(for: track)] = approximateDuration
            }
            trimStreamCacheIfNeeded()
        }
        return deduplicated
    }

    /// Evicts oldest entries when any unbounded cache exceeds 200 items.
    private func trimStreamCacheIfNeeded() {
        let maxEntries = 200
        let targetEntries = 100
        if streamCandidateCache.count > maxEntries {
            streamCandidateCache.keys
                .prefix(streamCandidateCache.count - targetEntries)
                .forEach { streamCandidateCache.removeValue(forKey: $0) }
        }
        if authoritativeDurationCache.count > maxEntries {
            authoritativeDurationCache.keys
                .prefix(authoritativeDurationCache.count - targetEntries)
                .forEach { authoritativeDurationCache.removeValue(forKey: $0) }
        }
        if streamResolutionFailureTimestamps.count > maxEntries {
            streamResolutionFailureTimestamps.keys
                .prefix(streamResolutionFailureTimestamps.count - targetEntries)
                .forEach { streamResolutionFailureTimestamps.removeValue(forKey: $0) }
        }
    }

    /// Returns true when a YouTube stream URL's `expire` param is within 5 minutes of now.
    private nonisolated static func isStreamURLExpired(_ url: URL) -> Bool {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let expireItem = components.queryItems?.first(where: { $0.name == "expire" }),
            let expireString = expireItem.value,
            let expireTimestamp = TimeInterval(expireString)
        else {
            return false   // no expiry info — assume still valid
        }
        // Treat as expired if fewer than 5 minutes remain
        return Date().timeIntervalSince1970 > expireTimestamp - 300
    }

    @discardableResult
    /// Returns true if the track failed resolution recently and should be skipped
    /// during background prefetch to avoid hammering YouTube for unavailable content.
    /// Play-initiated (user tap) calls bypass this so the user always gets a fresh attempt.
    private func recentlyFailed(_ track: Track, withinSeconds window: TimeInterval = 60) -> Bool {
        guard let videoID = track.youtubeVideoID,
              let failedAt = streamResolutionFailureTimestamps[videoID] else { return false }
        return Date().timeIntervalSince(failedAt) < window
    }

    private func recordResolutionFailure(for track: Track) {
        guard let videoID = track.youtubeVideoID else { return }
        streamResolutionFailureTimestamps[videoID] = Date()
        trimStreamCacheIfNeeded()
    }

    private func cancelPrefetch(for track: Track) {
        let key = cacheKey(for: track)
        prefetchTasks[key]?.cancel()
        prefetchTasks.removeValue(forKey: key)
    }

    private func cancelAllPrefetchTasks() {
        prefetchTasks.values.forEach { $0.cancel() }
        prefetchTasks.removeAll()
    }

    private func enqueueStreamResolutionTaskIfNeeded(
        for track: Track,
        priority: TaskPriority,
        useRemoteFallback: Bool = false
    ) -> Task<[URL], Never>? {
        let key = cacheKey(for: track)

        if let cached = streamCandidateCache[key], cached.contains(where: { !Self.isStreamURLExpired($0) }) {
            return nil
        }

        // Skip background prefetch for tracks that recently failed — avoids burning
        // quota on genuinely unavailable content. Play-initiated calls (useRemoteFallback)
        // always get a fresh attempt regardless so the user can retry manually.
        if !useRemoteFallback, recentlyFailed(track) {
            return nil
        }

        if let existingTask = prefetchTasks[key] {
            return existingTask
        }

        guard track.youtubeVideoID != nil || track.streamURL != nil else { return nil }

        let task: Task<[URL], Never> = Task(priority: priority) { [weak self, track] in
            guard let self else { return [] }
            defer { Task { @MainActor in self.prefetchTasks.removeValue(forKey: key) } }

            // For play-initiated (high priority) resolution use both local and remote so
            // we never waste a round-trip on a local-only attempt that then retries remotely.
            let candidates: [URL]
            if useRemoteFallback {
                candidates = (try? await self.resolveFreshStreamCandidates(for: track)) ?? []
            } else {
                candidates = (try? await self.resolveLocalStreamCandidates(for: track)) ?? []
            }
            return candidates.filter { !Self.isStreamURLExpired($0) }
        }

        prefetchTasks[key] = task
        return task
    }

    private func prewarmQueue(around track: Track) {
        guard isAppInBackground == false else { return }
        guard playbackQueue.isEmpty == false else { return }
        guard let currentIndex = playbackQueue.firstIndex(where: { matches($0, track) }) else { return }

        let nextTrackLimit = shuffleMode ? 8 : 3
        let previousTrackLimit = shuffleMode ? 0 : 1
        let nextTracks = playbackQueue
            .dropFirst(currentIndex + 1)
            .prefix(nextTrackLimit)

        let previousTracks = playbackQueue
            .prefix(currentIndex)
            .suffix(previousTrackLimit)

        let targetTracks = [track] + Array(nextTracks) + Array(previousTracks)

        for (index, pendingTrack) in targetTracks.enumerated() {
            let priority: TaskPriority
            priority = index < (shuffleMode ? 4 : 2) ? .utility : .background

            // The next 2 tracks are very likely to be played imminently — resolve with
            // remote fallback so they're ready the instant the user skips forward.
            let shouldUseRemoteFallback = index < 2
            _ = enqueueStreamResolutionTaskIfNeeded(
                for: pendingTrack,
                priority: priority,
                useRemoteFallback: shouldUseRemoteFallback
            )
        }
    }

    private nonisolated static func extractPlayableStreamCandidates(
        for track: Track,
        methods: [YouTube.ExtractionMethod]
    ) async throws -> StreamResolutionResult {
        if let directURL = track.streamURL {
            return StreamResolutionResult(urls: [directURL], approximateDuration: track.duration)
        }

        guard let videoID = track.youtubeVideoID else {
            throw PlaybackError.missingSource
        }

        let youtube = YouTube(videoID: videoID, methods: methods)
        let streams: [Stream]
        do {
            streams = try await youtube.streams
        } catch {
            let liveCandidates = (try? await extractLivestreamCandidates(from: youtube)) ?? []
            if liveCandidates.isEmpty == false {
                return StreamResolutionResult(urls: liveCandidates, approximateDuration: track.duration)
            }
            throw error
        }

        let preferredStreams = preferredPlaybackStreams(from: streams)
        let candidateURLs = deduplicatedURLs(preferredStreams.map(\.url))
        let approximateDuration = preferredStreams
            .compactMap(\.approximateDuration)
            .first(where: { $0.isFinite && $0 > 0 })
            ?? streams.compactMap(\.approximateDuration).first(where: { $0.isFinite && $0 > 0 })
            ?? track.duration

        if candidateURLs.isEmpty == false {
            return StreamResolutionResult(urls: candidateURLs, approximateDuration: approximateDuration)
        }

        let liveCandidates = try await extractLivestreamCandidates(from: youtube)
        if liveCandidates.isEmpty == false {
            return StreamResolutionResult(urls: liveCandidates, approximateDuration: approximateDuration)
        }

        throw PlaybackError.noPlayableStream
    }

    private nonisolated static func extractLivestreamCandidates(from youtube: YouTube) async throws -> [URL] {
        let livestreams = try await youtube.livestreams
        return deduplicatedURLs(livestreams.map(\.url))
    }

    private var currentRemoteRepeatType: MPRepeatType {
        switch repeatMode {
        case .off:
            return .off
        case .one:
            return .one
        case .all:
            return .all
        }
    }

    private func applyRepeatType(_ repeatType: MPRepeatType) {
        switch repeatType {
        case .off:
            repeatMode = .off
        case .one:
            repeatMode = .one
        case .all:
            repeatMode = .all
        default:
            break
        }

        updateCommandAvailability()
    }

    private func applyShuffleType(_ shuffleType: MPShuffleType) {
        let shouldShuffle = shuffleType != .off
        guard shuffleMode != shouldShuffle else {
            updateCommandAvailability()
            return
        }

        toggleShuffle()
    }

    private nonisolated static func preferredPlaybackStreams(from streams: [Stream]) -> [Stream] {
        streams
            .filter { $0.includesAudioTrack && $0.isNativelyPlayable }
            .sorted { lhs, rhs in
                let lhsScore = playbackPreferenceScore(for: lhs)
                let rhsScore = playbackPreferenceScore(for: rhs)

                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }

                return (lhs.itag.audioBitrate ?? 0) > (rhs.itag.audioBitrate ?? 0)
            }
    }

    private nonisolated static func playbackPreferenceScore(for stream: Stream) -> Int {
        var score = 0

        if stream.includesAudioTrack && stream.includesVideoTrack == false {
            score += 50
        }

        if stream.fileExtension == .m4a {
            score += 40
        } else if stream.fileExtension == .mp4 {
            score += 30
        }

        if stream.audioCodec == .mp4a {
            score += 35
        }

        if let audioBitrate = stream.itag.audioBitrate {
            switch audioBitrate {
            case 96...192:
                score += 18
            case 193...256:
                score += 8
            case let bitrate where bitrate > 256:
                score -= 8
            default:
                break
            }
        }

        if stream.videoCodec == .avc1 {
            score += 10
        }

        if stream.audioCodec == .ec3 || stream.audioCodec == .ac3 {
            score -= 20
        }

        if stream.fileExtension == .m3u8 || stream.itag.isHLS {
            score -= 10
        }

        return score
    }

    private nonisolated static func deduplicatedURLs(_ urls: [URL]) -> [URL] {
        var seenURLs: Set<String> = []
        return urls.filter { url in
            seenURLs.insert(url.absoluteString).inserted
        }
    }

    private func seconds(from time: CMTime?) -> TimeInterval? {
        guard let time else { return nil }
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }
}

private enum PlaybackError: LocalizedError {
    case missingSource
    case noPlayableStream

    var errorDescription: String? {
        switch self {
        case .missingSource:
            return "No playback source was available for this item."
        case .noPlayableStream:
            return "MusicTube couldn't find a playable audio stream for this YouTube item."
        }
    }
}
