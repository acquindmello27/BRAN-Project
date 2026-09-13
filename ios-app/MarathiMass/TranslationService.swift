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
    @Published private(set) var debugInfo: String = ""     // small diagnostic line in the UI

    private let settings = AppSettings.shared
    private let player = AudioPlayerQueue()
    private var recognizer: SPXTranslationRecognizer?
    private var mic: MicrophoneCapture?
    private var credentials: Credentials?
    private var synthChunks = Data()
    private var synthEvents = 0
    private var synthBytes = 0
    private var synthesizer: SPXSpeechSynthesizer?
    private let ttsQueue = DispatchQueue(label: "marathi.tts", qos: .userInitiated)
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
            errorMessage = Self.shortMessage(error)
        }
    }

    /// SDK errors carry a multi-page call stack; keep the first line only.
    private static func shortMessage(_ error: Error) -> String {
        let text = error.localizedDescription
        if let r = text.range(of: "[CALL STACK") { return text[..<r.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines) }
        return text
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
        if settings.engine == "builtin" {
            config.voiceName = settings.voice   // Azure speaks the Marathi in the same stream
        }
        // Finalize (and speak) a phrase after 0.7 s of silence instead of the default ~1 s.
        config.setPropertyTo("700", by: SPXPropertyId.speechSegmentationSilenceTimeoutMs)
        // Don't give up during long silences (hymns, procession, quiet prayer).
        config.setPropertyTo("60000", by: SPXPropertyId.speechServiceConnectionInitialSilenceTimeoutMs)
        return config
    }

    private func startRecognizer() throws {
        let config = try makeConfig()
        // We capture the mic ourselves (works in the Simulator too) and push
        // PCM into the SDK; see MicrophoneCapture.
        let capture = try MicrophoneCapture()
        let audio = try capture.audioConfiguration()
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
            print("Audio: synthesis event, \(chunk?.count ?? 0) bytes, reason \(evt.result.reason.rawValue), done=\(done)")
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

        if settings.engine != "builtin" {
            try makeSynthesizer()
        }

        // Publish before starting so early events pass the identity check.
        recognizer = rec
        mic = capture
        synthEvents = 0; synthBytes = 0
        updateDebug()
        do {
            try capture.start()
            try rec.startContinuousRecognition()
        } catch {
            capture.stop()
            mic = nil
            recognizer = nil
            throw error
        }
    }

    /// Separate text-to-speech engine: a synthesizer with no audio output of its
    /// own (nil audio configuration) so it hands us the WAV bytes and our queue
    /// plays them in order.
    private func makeSynthesizer() throws {
        guard let creds = credentials else { throw CredentialError.notConfigured }
        let scfg: SPXSpeechConfiguration
        switch creds {
        case .key(let key, let region):
            scfg = try SPXSpeechConfiguration(subscription: key, region: region)
        case .token(let token, let region, _):
            scfg = try SPXSpeechConfiguration(authorizationToken: token, region: region)
        }
        scfg.speechSynthesisVoiceName = settings.voice
        synthesizer = try SPXSpeechSynthesizer(speechConfiguration: scfg, audioConfiguration: nil)
    }

    private func speakWithTts(_ text: String) {
        guard let synth = synthesizer else { return }
        ttsQueue.async { [weak self] in
            do {
                let result = try synth.speakText(text)
                let data = result.audioData ?? Data()
                Task { @MainActor in
                    guard let self, self.state == .listening else { return }
                    self.synthEvents += 1
                    self.synthBytes += data.count
                    if result.reason == .synthesizingAudioCompleted, !data.isEmpty {
                        self.player.enqueue(wav: data)
                    } else {
                        print("TTS: reason \(result.reason.rawValue), \(data.count) bytes")
                    }
                    self.updateDebug()
                }
            } catch {
                print("TTS error: \(error)")
            }
        }
    }

    private func updateDebug() {
        let engine = settings.engine == "builtin" ? "built-in voice" : "separate TTS"
        var s = "\(engine) · audio events \(synthEvents) (\(synthBytes / 1024) KB) · played \(player.playedCount) · out: \(player.currentRoute)"
        if let e = player.lastError { s += " · \(e)" }
        debugInfo = s
    }

    func playTestTone() {
        player.playTestTone()
        updateDebug()
    }

    private func teardown() async {
        refreshTask?.cancel(); refreshTask = nil
        UIApplication.shared.isIdleTimerDisabled = false
        player.stop()
        synthChunks.removeAll()
        mic?.stop(); mic = nil
        synthesizer = nil
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
        if settings.engine != "builtin" { speakWithTts(trimmed) }
    }

    private func handleAudio(chunk: Data?, done: Bool) {
        if let c = chunk, !c.isEmpty { synthChunks.append(c); synthBytes += c.count }
        synthEvents += 1
        if done, !synthChunks.isEmpty {
            let wav = synthChunks
            synthChunks = Data()
            if state == .listening { player.enqueue(wav: wav) }
        }
        updateDebug()
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
        mic?.stop(); mic = nil
        synthesizer = nil
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
            await handleDrop(Self.shortMessage(error))
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
