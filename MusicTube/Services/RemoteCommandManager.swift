import AVFoundation
import Foundation
import MediaPlayer

/// Anything that produces audio independently of `PlaybackService` (recognition
/// engine, in-feed previews, etc.) and must be silenced before primary playback
/// begins. Without this, two AVAudioEngines / AVPlayers can both subscribe to
/// `MPRemoteCommandCenter` events; the system then routes lock-screen taps to
/// whichever was last activated, leaving the user staring at a "pause" button
/// that doesn't actually pause the audio they hear.
///
/// The method is intentionally non-isolated: callers run on the main actor,
/// but implementations may live anywhere and dispatch to their own queue as
/// needed.
protocol SecondaryAudioSource: AnyObject {
    func pauseForPrimaryPlayback()
}

/// Owns the `MPRemoteCommandCenter` / `MPNowPlayingInfoCenter` integration for
/// background and external-accessory playback (Lock Screen, Control Center,
/// CarPlay, AirPods, AirPlay).
///
/// Three things make remote commands fragile during long background sessions,
/// and this class addresses each explicitly:
///
///   1. **The system reads `MPNowPlayingInfoPropertyPlaybackRate` to decide
///      which icon to draw.** If we update the rate after dispatching the
///      actual player work, the icon never flips, the user taps again, taps
///      stack up, and eventually iOS demotes the command. The handlers below
///      mutate Now-Playing state *synchronously* inside the callback and let
///      the heavy work run after.
///
///   2. **Command targets can arrive while the main actor is busy.** Pause and
///      track-change commands first touch the active `AVPlayer` through a tiny
///      thread-safe responder, then the full app state catches up on main.
///
///   3. **`playCommand` / `pauseCommand` / `togglePlayPauseCommand` must each
///      have their own target.** AirPods send the explicit commands; the lock
///      screen sends `togglePlayPauseCommand`. Apple's fallback (toggle when
///      explicit ones are missing) is unreliable across accessories. Wiring
///      all three avoids the "pause works on the phone but not on AirPods"
///      bug class.
@MainActor
final class RemoteCommandManager {

    /// Closures the manager invokes when commands fire, plus read-only
    /// providers it uses to keep `MPNowPlayingInfo` consistent with player
    /// state. Owned by `PlaybackService`; the manager holds no player ref.
    struct Bindings {
        var isPlaying: () -> Bool
        var currentRate: () -> Float
        var currentTime: () -> TimeInterval
        var duration: () -> TimeInterval
        var queueIndex: () -> Int?
        var queueCount: () -> Int
        var hasNextTrack: () -> Bool
        var hasPreviousTrack: () -> Bool
        var canSeek: () -> Bool

        var isPlayingImmediately: () -> Bool
        var pauseImmediately: () -> Void
        var currentTimeImmediately: () -> TimeInterval

        var play: () -> Void
        var pause: () -> Void
        var toggle: () -> Void
        var next: () -> Void
        var previous: () -> Void
        var seek: (TimeInterval) -> Void
        var changeRepeatType: (MPRepeatType) -> Void
        var changeShuffleType: (MPShuffleType) -> Void
    }

    private var nowPlayingSession: MPNowPlayingSession?
    private var sessionCommandCenter: MPRemoteCommandCenter?
    private var sessionNowPlayingInfoCenter: MPNowPlayingInfoCenter?
    private var commandCenter: MPRemoteCommandCenter {
        sessionCommandCenter ?? MPRemoteCommandCenter.shared()
    }
    private var nowPlayingInfoCenter: MPNowPlayingInfoCenter {
        sessionNowPlayingInfoCenter ?? MPNowPlayingInfoCenter.default()
    }
    private nonisolated let immediateResponder = ImmediateRemoteCommandResponder()
    private var bindings: Bindings?
    private var isInstalled = false
    private let secondaryPlayers = NSHashTable<AnyObject>.weakObjects()

    // MARK: - Install

    func attachPlayer(_ player: AVPlayer) {
        guard nowPlayingSession?.players.contains(where: { $0 === player }) != true else {
            becomeActiveIfPossible()
            return
        }

        let session = MPNowPlayingSession(players: [player])
        session.automaticallyPublishesNowPlayingInfo = false
        nowPlayingSession = session
        sessionCommandCenter = session.remoteCommandCenter
        sessionNowPlayingInfoCenter = session.nowPlayingInfoCenter
        immediateResponder.updateNowPlayingInfoCenter(session.nowPlayingInfoCenter)
        becomeActiveIfPossible()
    }

    func becomeActiveIfPossible() {
        guard let nowPlayingSession else { return }
        nowPlayingSession.becomeActiveIfPossible { _ in }
    }

    func install(_ bindings: Bindings) {
        self.bindings = bindings
        immediateResponder.update(
            isPlaying: bindings.isPlayingImmediately,
            pause: bindings.pauseImmediately,
            currentTime: bindings.currentTimeImmediately
        )
        guard !isInstalled else { return }
        isInstalled = true
        configureCommands()
    }

    // MARK: - Secondary Audio Sources

    func registerSecondaryPlayer(_ player: SecondaryAudioSource) {
        secondaryPlayers.add(player)
    }

    func unregisterSecondaryPlayer(_ player: SecondaryAudioSource) {
        secondaryPlayers.remove(player)
    }

    func pauseSecondaryPlayers() {
        for case let player as SecondaryAudioSource in secondaryPlayers.allObjects {
            player.pauseForPrimaryPlayback()
        }
    }

    // MARK: - Now Playing Info

    func updateNowPlayingInfo(
        title: String,
        artist: String,
        artwork: MPMediaItemArtwork?
    ) {
        guard let bindings else { return }
        let playing = bindings.isPlaying()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? Double(bindings.currentRate()) : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: bindings.currentTime(),
            MPNowPlayingInfoPropertyPlaybackQueueIndex: bindings.queueIndex() ?? 0,
            MPNowPlayingInfoPropertyPlaybackQueueCount: bindings.queueCount()
        ]
        let duration = bindings.duration()
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        nowPlayingInfoCenter.nowPlayingInfo = info
        nowPlayingInfoCenter.playbackState = playing ? .playing : .paused
        becomeActiveIfPossible()
        applyCommandAvailability()
    }

    func setArtwork(_ artwork: MPMediaItemArtwork) {
        var info = nowPlayingInfoCenter.nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        nowPlayingInfoCenter.nowPlayingInfo = info
    }

    func removeArtwork() {
        var info = nowPlayingInfoCenter.nowPlayingInfo ?? [:]
        info.removeValue(forKey: MPMediaItemPropertyArtwork)
        nowPlayingInfoCenter.nowPlayingInfo = info
    }

    /// Push the player state into `MPNowPlayingInfo`. Use after any change to
    /// playing/paused/rate/duration so the system UI stays in sync.
    func syncPlaybackState() {
        guard let bindings else { return }
        var info = nowPlayingInfoCenter.nowPlayingInfo ?? [:]
        let playing = bindings.isPlaying()
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? Double(bindings.currentRate()) : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = bindings.currentTime()
        info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = bindings.queueIndex() ?? 0
        info[MPNowPlayingInfoPropertyPlaybackQueueCount] = bindings.queueCount()

        let duration = bindings.duration()
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        } else {
            info.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
        }

        nowPlayingInfoCenter.nowPlayingInfo = info
        // Setting `playbackState` *and* `playbackRate` together — Apple's docs
        // say either alone "may" drive the UI but in practice both are needed
        // for CarPlay + Lock Screen to agree.
        nowPlayingInfoCenter.playbackState = playing ? .playing : .paused
        if playing {
            becomeActiveIfPossible()
        }
        applyCommandAvailability()
    }

    /// Lightweight update for the 1-second time observer: only touches elapsed
    /// time / duration so we don't repeatedly rebuild the whole info dict.
    func updateElapsedTime() {
        guard let bindings else { return }
        var info = nowPlayingInfoCenter.nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = bindings.currentTime()
        let duration = bindings.duration()
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        } else {
            info.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
        }
        nowPlayingInfoCenter.nowPlayingInfo = info
    }

    func clearNowPlaying() {
        nowPlayingInfoCenter.nowPlayingInfo = nil
        nowPlayingInfoCenter.playbackState = .stopped
    }

    // MARK: - Command State

    func setRepeatType(_ type: MPRepeatType) {
        commandCenter.changeRepeatModeCommand.currentRepeatType = type
    }

    func setShuffleType(_ type: MPShuffleType) {
        commandCenter.changeShuffleModeCommand.currentShuffleType = type
    }

    func applyCommandAvailability() {
        guard let bindings else { return }
        commandCenter.nextTrackCommand.isEnabled = bindings.hasNextTrack()
        commandCenter.previousTrackCommand.isEnabled = bindings.hasPreviousTrack()
        commandCenter.changePlaybackPositionCommand.isEnabled = bindings.canSeek()
    }

    // MARK: - Command Registration

    private func configureCommands() {
        // Clear any previously registered targets. Without this a hot-reload
        // (PlaybackService recreated by tests, or a re-install path) would
        // stack closures and fire each command twice per tap.
        let allCommands: [MPRemoteCommand] = [
            commandCenter.playCommand,
            commandCenter.pauseCommand,
            commandCenter.togglePlayPauseCommand,
            commandCenter.nextTrackCommand,
            commandCenter.previousTrackCommand,
            commandCenter.changePlaybackPositionCommand,
            commandCenter.changeRepeatModeCommand,
            commandCenter.changeShuffleModeCommand,
            commandCenter.skipForwardCommand,
            commandCenter.skipBackwardCommand,
            commandCenter.seekForwardCommand,
            commandCenter.seekBackwardCommand,
            commandCenter.bookmarkCommand,
            commandCenter.likeCommand,
            commandCenter.dislikeCommand,
            commandCenter.ratingCommand
        ]
        for command in allCommands {
            command.removeTarget(nil)
            // Leaving a command enabled with no target makes iOS render an
            // unresponsive button. Disable anything we don't implement; the
            // ones we do implement are re-enabled below.
            command.isEnabled = false
        }

        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.changeRepeatModeCommand.isEnabled = true
        commandCenter.changeShuffleModeCommand.isEnabled = true

        let immediateResponder = immediateResponder

        commandCenter.playCommand.addTarget { [weak self] _ in
            RemoteCommandManager.performOnMain { self?.handlePlay() ?? .commandFailed }
        }
        commandCenter.pauseCommand.addTarget { [weak self, immediateResponder] _ in
            immediateResponder.pause()
            return RemoteCommandManager.performOnMainAsync {
                self?.handlePause() ?? .commandFailed
            }
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self, immediateResponder] _ in
            guard let self else { return .commandFailed }
            if immediateResponder.isLikelyPlaying {
                immediateResponder.pause()
                return RemoteCommandManager.performOnMainAsync {
                    self.handleToggle()
                }
            }
            return RemoteCommandManager.performOnMain {
                self.handleToggle()
            }
        }
        commandCenter.nextTrackCommand.addTarget { [weak self, immediateResponder] _ in
            immediateResponder.pauseForTrackChange()
            return RemoteCommandManager.performOnMainAsync {
                self?.handleNext() ?? .commandFailed
            }
        }
        commandCenter.previousTrackCommand.addTarget { [weak self, immediateResponder] _ in
            immediateResponder.pauseForTrackChange()
            return RemoteCommandManager.performOnMainAsync {
                self?.handlePrevious() ?? .commandFailed
            }
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            return RemoteCommandManager.performOnMain {
                self?.handleSeek(to: event.positionTime) ?? .commandFailed
            }
        }
        commandCenter.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else {
                return .commandFailed
            }
            return RemoteCommandManager.performOnMain {
                self?.handleRepeat(event.repeatType) ?? .commandFailed
            }
        }
        commandCenter.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else {
                return .commandFailed
            }
            return RemoteCommandManager.performOnMain {
                self?.handleShuffle(event.shuffleType) ?? .commandFailed
            }
        }
    }

    /// Uses the current thread when iOS delivers the command on main, and a
    /// synchronous fallback for commands that must read main-actor state before
    /// deciding what to do.
    private static func performOnMain<T>(_ work: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { work() }
        }
        // Extremely defensive fallback — if iOS ever changes the delivery
        // thread, sync over to main so we don't crash in production.
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { work() }
        }
    }

    /// Remote command callbacks can arrive while the main actor is busy with
    /// stream extraction bookkeeping, CarPlay updates, or local-library state
    /// churn. For commands where the immediate audio side effect already
    /// happened, return success right away and let the app model catch up on
    /// the next main-queue turn instead of making the system button wait.
    private static func performOnMainAsync(
        _ work: @escaping @MainActor () -> MPRemoteCommandHandlerStatus
    ) -> MPRemoteCommandHandlerStatus {
        DispatchQueue.main.async {
            _ = MainActor.assumeIsolated { work() }
        }
        return .success
    }

    // MARK: - Command Handlers

    private func handlePlay() -> MPRemoteCommandHandlerStatus {
        guard let bindings else { return .commandFailed }
        // Step 1: silence anything else that could be subscribed to remote
        // commands so the system routes subsequent events to us.
        pauseSecondaryPlayers()
        // Step 2: flip the system UI immediately. This is what makes Control
        // Center show the "pause" icon as soon as the user taps "play"; if we
        // wait for the deferred work the user perceives the tap as a no-op.
        applyOptimisticRate(1.0)
        // Step 3: kick off the real work (stream resolution, AVPlayer.play).
        bindings.play()
        return .success
    }

    private func handlePause() -> MPRemoteCommandHandlerStatus {
        guard let bindings else { return .commandFailed }
        applyOptimisticRate(0.0)
        bindings.pause()
        return .success
    }

    private func handleToggle() -> MPRemoteCommandHandlerStatus {
        guard let bindings else { return .commandFailed }
        let willPlay = !bindings.isPlaying()
        if willPlay { pauseSecondaryPlayers() }
        applyOptimisticRate(willPlay ? 1.0 : 0.0)
        bindings.toggle()
        return .success
    }

    private func handleNext() -> MPRemoteCommandHandlerStatus {
        guard let bindings else { return .commandFailed }
        bindings.next()
        return .success
    }

    private func handlePrevious() -> MPRemoteCommandHandlerStatus {
        guard let bindings else { return .commandFailed }
        bindings.previous()
        return .success
    }

    private func handleSeek(to time: TimeInterval) -> MPRemoteCommandHandlerStatus {
        guard let bindings else { return .commandFailed }
        bindings.seek(time)
        return .success
    }

    private func handleRepeat(_ type: MPRepeatType) -> MPRemoteCommandHandlerStatus {
        guard let bindings else { return .commandFailed }
        bindings.changeRepeatType(type)
        return .success
    }

    private func handleShuffle(_ type: MPShuffleType) -> MPRemoteCommandHandlerStatus {
        guard let bindings else { return .commandFailed }
        bindings.changeShuffleType(type)
        return .success
    }

    /// Synchronously flips `MPNowPlayingInfo.playbackRate` and `playbackState`
    /// inside the command callback so the system UI updates on the same tick
    /// as the user's tap, before the (potentially slow) player work begins.
    private func applyOptimisticRate(_ rate: Double) {
        var info = nowPlayingInfoCenter.nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        if let bindings {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = bindings.currentTime()
        }
        nowPlayingInfoCenter.nowPlayingInfo = info
        nowPlayingInfoCenter.playbackState = rate > 0 ? .playing : .paused
    }
}

private final class ImmediateRemoteCommandResponder: @unchecked Sendable {
    private let lock = NSLock()
    private var isPlayingProvider: (() -> Bool)?
    private var pauseHandler: (() -> Void)?
    private var currentTimeProvider: (() -> TimeInterval)?
    private var nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()

    var isLikelyPlaying: Bool {
        lockedSnapshot().isPlaying?() ?? (nowPlayingInfoCenter.playbackState == .playing)
    }

    func update(
        isPlaying: @escaping () -> Bool,
        pause: @escaping () -> Void,
        currentTime: @escaping () -> TimeInterval
    ) {
        lock.lock()
        isPlayingProvider = isPlaying
        pauseHandler = pause
        currentTimeProvider = currentTime
        lock.unlock()
    }

    func updateNowPlayingInfoCenter(_ center: MPNowPlayingInfoCenter) {
        lock.lock()
        nowPlayingInfoCenter = center
        lock.unlock()
    }

    func pause() {
        let snapshot = lockedSnapshot()
        snapshot.pause?()
        applyOptimisticRate(0.0, currentTime: snapshot.currentTime?())
    }

    func pauseForTrackChange() {
        let snapshot = lockedSnapshot()
        snapshot.pause?()
    }

    private func lockedSnapshot() -> (
        isPlaying: (() -> Bool)?,
        pause: (() -> Void)?,
        currentTime: (() -> TimeInterval)?
    ) {
        lock.lock()
        let snapshot = (isPlayingProvider, pauseHandler, currentTimeProvider)
        lock.unlock()
        return snapshot
    }

    private func applyOptimisticRate(_ rate: Double, currentTime: TimeInterval?) {
        var info = nowPlayingInfoCenter.nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        if let currentTime, currentTime.isFinite {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        }
        nowPlayingInfoCenter.nowPlayingInfo = info
        nowPlayingInfoCenter.playbackState = rate > 0 ? .playing : .paused
    }
}
