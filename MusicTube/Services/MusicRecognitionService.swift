import AVFoundation
import Foundation
import ShazamKit
import UserNotifications

enum MusicRecognitionError: LocalizedError {
    case permissionDenied
    case matchFailed
    case audioEngineFailed
    case interrupted
    
    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Microphone access is required to recognize music."
        case .matchFailed: return "MusicTube could not recognize the song. Please try again."
        case .audioEngineFailed: return "Failed to start the audio engine."
        case .interrupted: return "Recognition was interrupted by another app taking control of the audio."
        }
    }
}

final class MusicRecognitionService: NSObject, SHSessionDelegate, SecondaryAudioSource {
    /// Called by `RemoteCommandManager` just before primary playback starts so
    /// the recognition engine releases its `.playAndRecord` audio session and
    /// stops consuming remote-command events. A no-op when not listening.
    func pauseForPrimaryPlayback() {
        stopRecognition()
    }

    private var session: SHSession?
    private var audioEngine: AVAudioEngine?
    private var didInstallInputTap = false
    private var continuation: CheckedContinuation<String, Error>?
    private var isListening = false
    private var timeoutTask: Task<Void, Never>?
    
    override init() {
        super.init()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self = self, self.isListening else { return }
            guard let info = notification.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue),
                  type == .began else { return }
            
            self.finishRecognition(with: .failure(MusicRecognitionError.interrupted))
        }
    }
    
    func recognizeSong() async throws -> String {
        stopRecognition()
        
        guard await requestMicrophonePermission() else {
            throw MusicRecognitionError.permissionDenied
        }
        
        // Switch session to allow recording while letting other apps (like Instagram) play audio out loud
        // VERY IMPORTANT: Use mode .measurement to disable Echo Cancellation (AEC).
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
            try audioSession.setActive(true)
        } catch {
            throw MusicRecognitionError.audioEngineFailed
        }
        
        isListening = true
        
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000) // 15-second timeout
            guard !Task.isCancelled else { return }
            self?.finishRecognition(with: .failure(MusicRecognitionError.matchFailed))
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            
            let session = SHSession()
            session.delegate = self
            self.session = session
            
            // Use a fresh engine each time because switching audio categories invalidates the old engine's I/O nodes
            let engine = AVAudioEngine()
            self.audioEngine = engine
            
            let inputNode = engine.inputNode
            let inputFormat = inputNode.inputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                self.finishRecognition(with: .failure(MusicRecognitionError.audioEngineFailed))
                return
            }

            // ShazamKit accepts the microphone's native PCM format. Installing the
            // tap directly on the input node avoids building an output graph, which
            // can fail on device when the active route cannot render the forced
            // 48 kHz mono mixer format.
            inputNode.installTap(onBus: 0, bufferSize: 8192, format: inputFormat) { buffer, time in
                session.matchStreamingBuffer(buffer, at: time)
            }
            self.didInstallInputTap = true
            
            engine.prepare()
            do {
                try engine.start()
            } catch {
                self.finishRecognition(with: .failure(MusicRecognitionError.audioEngineFailed))
            }
        }
    }
    
    func stopRecognition() {
        finishRecognition(with: .failure(CancellationError()))
    }
    
    // MARK: - SHSessionDelegate
    
    func session(_ session: SHSession, didFind match: SHMatch) {
        guard let mediaItem = match.mediaItems.first else {
            finishRecognition(with: .failure(MusicRecognitionError.matchFailed))
            return
        }
        let title = mediaItem.title ?? ""
        let artist = mediaItem.artist ?? ""
        let query = [title, artist].filter { !$0.isEmpty }.joined(separator: " ")

        guard query.isEmpty == false else {
            finishRecognition(with: .failure(MusicRecognitionError.matchFailed))
            return
        }

        finishRecognition(with: .success(query))
    }
    
    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        // ShazamKit calls this repeatedly while listening when a specific small audio chunk doesn't match.
        // We MUST NOT cancel the entire recognition process here.
        // Let the 15-second timeout task handle true failures if no match is ever found.
    }
    
    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func tearDownRecognition() {
        if isListening {
            if didInstallInputTap {
                audioEngine?.inputNode.removeTap(onBus: 0)
                didInstallInputTap = false
            }
            audioEngine?.stop()
            audioEngine = nil
            isListening = false
            
            // Restore audio session to pure playback so your music sounds high-quality again
            do {
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
                try audioSession.setActive(true)
            } catch {
                // Ignore safe teardown errors
            }
        }
        session = nil
    }

    private func finishRecognition(with result: Result<String, Error>) {
        let pendingContinuation = continuation
        continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        tearDownRecognition()

        switch result {
        case .success(let query):
            sendNotification(title: "Song Recognized!", body: "Found: \(query). Tap to play.")
            pendingContinuation?.resume(returning: query)
        case .failure(let error):
            if !(error is CancellationError) {
                sendNotification(title: "Recognition Failed", body: error.localizedDescription)
            }
            pendingContinuation?.resume(throwing: error)
        }
    }

    private func sendNotification(title: String, body: String) {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard settings.authorizationStatus == .authorized else { return }
            
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}
