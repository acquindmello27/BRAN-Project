import Foundation
import AVFoundation
import UIKit
import MicrosoftCognitiveServicesSpeech

/// Drives one live-translation session:
///   microphone -> Azure speech translation (en-US -> mr) -> Marathi text + Marathi audio
///   -> AudioPlayerQueue -> earphones
@MainActor
final class TranslationService: ObservableObject {
    enum State: Equatable { case idle, connecting, listening, reconnecting }

    @Published private(set) var state: State = .idle
    @Published private(set) var lines: [String] = []     // finalized Marathi sentences
    @Published private(set) var partial: String = ""     // in-progress translation
    @Published var errorMessage: String?

    private let settings = AppSettings.shared
    private let player = AudioPlayerQueue()
    private var recognizer: SPXTranslationRecognizer?
    private var credentials: Credentials?
    private var synthChunks = Data()
    private var refreshTask: Task<Void, Never>?
    private var restartAttempts = 0
    private var stopping = false
    private let maxLines = 40

    // MARK: - Public

    func start() async {
        guard state == .idle, !stopping else { return }
        state = .connecting
        errorMessage = nil
        lines.removeAll()
        partial = ""
        do {
            try await ensureMicrophonePermission()
            try player.configureSession()
            credentials = try await Credentials.load(from: settings)
            try startRecognizer()
            state = .listening
            restartAttempts = 0
            UIApplication.shared.isIdleTimerDisabled = true
            scheduleTokenRefresh()
        } catch {
            await teardown()
            state = .idle
            errorMessage = error.localizedDescription
        }
    }

    func stop() async {
        guard state != .idle, !stopping else { return }
        stopping = true
        state = .idle
        await teardown()
        stopping = false
    }

    // MARK: - Session

    private func ensureMicrophonePermission() async throws {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted: return
        case .denied: throw SessionError.micDenied
        case .undetermined:
            let ok = await withCheckedContinuation { cont in
                session.requestRecordPermission { cont.resume(returning: $0) }
            }
            if !ok { throw SessionError.micDenied }
        @unknown default: return
        }
    }

    private func makeConfig() throws -> SPXSpeechTranslationConfiguration {
        guard let creds = credentials else { throw CredentialError.notConfigured }
        let config: SPXSpeechTranslationConfiguration
        switch creds {
        case .key(let key, let region):
            config = try SPXSpeechTranslationConfiguration(subscription: key, region: region)
        case .token(let token, let region, _):
            config = try SPXSpeechTranslationConfiguration(authorizationToken: token, region: region)
        }
        config.speechRecognitionLanguage = "en-US"
        config.addTargetLanguage("mr")
        config.voiceName = settings.voice   // Azure speaks the Marathi in the same stream
        // Finalize (and speak) a phrase after 0.7 s of silence instead of the default ~1 s.
        config.setPropertyTo("700", by: SPXPropertyId.speechSegmentationSilenceTimeoutMs)
        // Don't give up during long silences (hymns, procession, quiet prayer).
        config.setPropertyTo("60000", by: SPXPropertyId.speechServiceConnectionInitialSilenceTimeoutMs)
        return config
    }

    private func startRecognizer() throws {
        let config = try makeConfig()
        let audio = SPXAudioConfiguration()   // default microphone
        let rec = try SPXTranslationRecognizer(speechTranslationConfiguration: config, audioConfiguration: audio)

        // SDK callbacks arrive on background threads; hop to the main actor.
        // Each handler checks `self.recognizer === rec` so events from a
        // recognizer we already discarded (after Stop or a reconnect) are ignored.
        rec.addRecognizingEventHandler { [weak self] _, evt in
            let text = evt.result.translations["mr"] as? String ?? ""
            Task { @MainActor in
                guard let self, self.recognizer === rec else { return }
                self.handlePartial(text)
            }
        }
        rec.addRecognizedEventHandler { [weak self] _, evt in
            guard evt.result.reason == .translatedSpeech else { return }
            let text = evt.result.translations["mr"] as? String ?? ""
            Task { @MainActor in
                guard let self, self.recognizer === rec else { return }
                self.handleFinal(text)
            }
        }
        rec.addSynthesizingEventHandler { [weak self] _, evt in
            // Audio for one utterance arrives in one or more chunks, then a
            // "completed" event with no audio. Accumulate, then play the whole thing.
            let chunk = evt.result.audio
            let done = evt.result.reason == .synthesizingAudioCompleted || (chunk?.isEmpty ?? true)
            Task { @MainActor in
                guard let self, self.recognizer === rec else { return }
                self.handleAudio(chunk: chunk, done: done)
            }
        }
        rec.addCanceledEventHandler { [weak self] _, evt in
            guard evt.reason == .error else { return }
            let details = evt.errorDetails ?? "canceled"
            Task { @MainActor in
                guard let self, self.recognizer === rec else { return }
                await self.handleDrop(details)
            }
        }
        rec.addSessionStoppedEventHandler { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.recognizer === rec else { return }
                await self.handleDrop("session stopped")
            }
        }

        // Publish before starting so early events pass the identity check.
        recognizer = rec
        do {
            try rec.startContinuousRecognition()
        } catch {
            recognizer = nil
            throw error
        }
    }

    private func teardown() async {
        refreshTask?.cancel(); refreshTask = nil
        UIApplication.shared.isIdleTimerDisabled = false
        player.stop()
        synthChunks.removeAll()
        if let rec = recognizer {
            recognizer = nil
            // stopContinuousRecognition blocks; keep the UI responsive.
            await Task.detached { try? rec.stopContinuousRecognition() }.value
        }
    }

    // MARK: - Event handling (main actor)

    private func handlePartial(_ text: String) {
        guard state == .listening, !text.isEmpty else { return }
        partial = text
    }

    private func handleFinal(_ text: String) {
        guard state == .listening else { return }
        partial = ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lines.append(trimmed)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    private func handleAudio(chunk: Data?, done: Bool) {
        if let c = chunk, !c.isEmpty { synthChunks.append(c) }
        if done, !synthChunks.isEmpty {
            let wav = synthChunks
            synthChunks = Data()
            if state == .listening { player.enqueue(wav: wav) }
        }
    }

    /// Network blip or expired token mid-Mass: reconnect quietly, up to 5 times.
    private func handleDrop(_ detail: String) async {
        guard state == .listening || state == .reconnecting else { return }
        restartAttempts += 1
        if restartAttempts > 5 {
            await teardown()
            state = .idle
            errorMessage = "Connection lost. Tap Start again. (\(detail))"
            return
        }
        state = .reconnecting
        if let rec = recognizer {
            recognizer = nil
            await Task.detached { try? rec.stopContinuousRecognition() }.value
        }
        synthChunks.removeAll()
        try? await Task.sleep(nanoseconds: UInt64(restartAttempts) * 1_500_000_000)
        guard state == .reconnecting else { return }
        do {
            credentials = try await Credentials.load(from: settings)
            try startRecognizer()
            state = .listening
        } catch {
            await handleDrop(error.localizedDescription)
        }
    }

    /// Azure tokens expire after 10 minutes; swap in a fresh one before that.
    private func scheduleTokenRefresh() {
        refreshTask?.cancel()
        guard case .token(_, _, let refreshIn)? = credentials else { return } // keys never expire
        let secs = max(60, min(540, refreshIn))
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(secs) * 1_000_000_000)
                guard !Task.isCancelled, let self, self.state == .listening else { return }
                if let fresh = try? await Credentials.load(from: self.settings),
                   case .token(let t, _, _) = fresh {
                    self.credentials = fresh
                    self.recognizer?.authorizationToken = t
                }
            }
        }
    }
}

enum SessionError: LocalizedError {
    case micDenied
    var errorDescription: String? {
        switch self {
        case .micDenied: return "Microphone access is off. Enable it in iPhone Settings > Privacy & Security > Microphone."
        }
    }
}
