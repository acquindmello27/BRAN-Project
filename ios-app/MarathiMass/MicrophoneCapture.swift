import AVFoundation
import MicrosoftCognitiveServicesSpeech

/// Captures the microphone with AVAudioEngine and pushes 16 kHz / 16-bit mono
/// PCM into the Speech SDK through a push stream.
///
/// Why not the SDK's own microphone input? It fails on the iOS Simulator with
/// SPXERR_MIC_ERROR and reconfigures the shared audio session on a real device,
/// which fights our playback setup. Owning the capture avoids both.
final class MicrophoneCapture {
    enum MicError: LocalizedError {
        case noInput
        var errorDescription: String? { "No microphone input is available on this device." }
    }

    let stream: SPXPushAudioInputStream
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    init() throws {
        // Typed as optionals on purpose: the SDK's Objective-C initializers are
        // nullable, and this compiles either way.
        let fmt: SPXAudioStreamFormat? = SPXAudioStreamFormat(usingPCMWithSampleRate: 16_000, bitsPerSample: 16, channels: 1)
        guard let fmt else { throw MicError.noInput }
        let s: SPXPushAudioInputStream? = SPXPushAudioInputStream(audioFormat: fmt)
        guard let s else { throw MicError.noInput }
        stream = s
    }

    /// The SDK reads from this configuration.
    func audioConfiguration() throws -> SPXAudioConfiguration {
        let cfg: SPXAudioConfiguration? = SPXAudioConfiguration(streamInput: stream)
        guard let cfg else { throw MicError.noInput }
        return cfg
    }

    func start() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw MicError.noInput }
        converter = AVAudioConverter(from: inFormat, to: targetFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.push(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        stream.close()
    }

    private func push(_ buffer: AVAudioPCMBuffer) {
        guard let converter, buffer.frameLength > 0 else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var convError: NSError?
        _ = converter.convert(to: out, error: &convError) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard convError == nil, out.frameLength > 0, let channels = out.int16ChannelData else { return }
        let byteCount = Int(out.frameLength) * MemoryLayout<Int16>.size
        stream.write(Data(bytes: channels[0], count: byteCount))
    }
}
