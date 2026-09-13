import AVFoundation

/// Plays synthesized Marathi utterances one after another, in order, with no
/// overlap. Each utterance arrives as a WAV blob (RIFF header + PCM); we parse
/// it ourselves because streamed WAV headers often carry a bogus data length
/// that AVAudioPlayer rejects.
final class AudioPlayerQueue {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var nodeFormat: AVAudioFormat?
    private let lock = NSLock()

    init() {
        // If iOS reconfigures the engine (route change, another engine starting,
        // an interruption), rebuild the graph on the next utterance instead of
        // silently playing into a dead node.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.nodeFormat = nil; self.lock.unlock()
            print("Audio: engine configuration changed, will rebuild")
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            self.lock.lock(); self.nodeFormat = nil; self.lock.unlock()
        }
    }

    /// Diagnostics shown on screen: how many utterances were played and where.
    private(set) var playedCount = 0
    private(set) var lastError: String?
    var currentRoute: String {
        AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portName }.joined(separator: ",")
    }

    /// Plays a short beep through the same path as the Marathi audio, so the
    /// playback chain can be checked without Azure.
    func playTestTone() {
        try? configureSession()
        let rate = 16_000.0, seconds = 0.6
        let frames = Int(rate * seconds)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buf.floatChannelData else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            let env = min(1, Double(min(i, frames - i)) / 800) // soft edges
            out[0][i] = Float(0.4 * env * sin(2 * .pi * 440 * Double(i) / rate))
        }
        schedule(buf)
    }

    /// Configure the shared audio session for "record from mic, play to earphones".
    /// `.allowBluetoothA2DP` keeps AirPods on the high-quality output profile while
    /// the phone's own microphone does the listening.
    func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .defaultToSpeaker: with no earphones connected, play through the loud
        // speaker instead of the tiny earpiece. Earphones/AirPods still win when present.
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .defaultToSpeaker])
        try session.setActive(true, options: [])
    }

    func enqueue(wav data: Data) {
        guard let pcm = WAVDecoder.decode(data) else {
            lastError = "could not decode \(data.count) bytes"
            print("Audio: could not decode \(data.count) bytes (first bytes: \(data.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")))")
            return
        }
        schedule(pcm)
    }

    private func schedule(_ pcm: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        do {
            try ensureEngine(for: pcm.format)
            let buffer = try convertIfNeeded(pcm)
            player.scheduleBuffer(buffer, completionHandler: nil)
            if !player.isPlaying { player.play() }
            playedCount += 1
            lastError = nil
            print("Audio: playing \(pcm.frameLength) frames @ \(Int(pcm.format.sampleRate)) Hz, route: \(currentRoute)")
        } catch {
            lastError = error.localizedDescription
            print("Audio playback error: \(error)")
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        player.stop()
        engine.stop()
        nodeFormat = nil
    }

    // MARK: - internals

    private func ensureEngine(for format: AVAudioFormat) throws {
        if nodeFormat != nil, engine.isRunning { return }
        if engine.attachedNodes.contains(player) { engine.detach(player) }
        engine.attach(player)
        // Fix the node's format to the first utterance's format; later
        // utterances are converted to it if they differ.
        let fmt = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: format.channelCount) ?? format
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        nodeFormat = fmt
        engine.prepare()
        try engine.start()
    }

    private func convertIfNeeded(_ pcm: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let target = nodeFormat, target.sampleRate != pcm.format.sampleRate || target.channelCount != pcm.format.channelCount else {
            return pcm
        }
        guard let converter = AVAudioConverter(from: pcm.format, to: target) else { return pcm }
        let ratio = target.sampleRate / pcm.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return pcm }
        var consumed = false
        var convError: NSError?
        _ = converter.convert(to: out, error: &convError) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return pcm
        }
        if let e = convError { throw e }
        return out
    }
}

/// Minimal RIFF/WAVE parser for 8/16-bit integer or 32-bit float PCM, with a
/// fallback for headerless 16 kHz 16-bit mono PCM (what the translation
/// service sends when it omits the RIFF header).
enum WAVDecoder {
    static func decode(_ data: Data) -> AVAudioPCMBuffer? {
        guard data.count > 44 else { return nil }
        let bytes = [UInt8](data)
        func tag(_ o: Int) -> String { String(bytes: bytes[o..<o + 4], encoding: .ascii) ?? "" }
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard tag(0) == "RIFF", tag(8) == "WAVE" else { return decodeRawPCM16(bytes, sampleRate: 16_000) }

        var off = 12
        var audioFormat = 0, channels = 0, sampleRate = 0, bits = 0
        var dataStart = -1, dataLen = 0
        while off + 8 <= bytes.count {
            let id = tag(off)
            let len = u32(off + 4)
            let body = off + 8
            if id == "fmt " {
                audioFormat = u16(body)
                channels = u16(body + 2)
                sampleRate = u32(body + 4)
                bits = u16(body + 14)
            } else if id == "data" {
                dataStart = body
                // Streaming writers put 0 or 0xFFFFFFFF here; trust the blob length.
                dataLen = (len == 0 || len == 0xFFFF_FFFF) ? bytes.count - body : min(len, bytes.count - body)
                break
            }
            off = body + len + (len & 1)
        }
        guard dataStart > 0, channels > 0, sampleRate > 0, bits > 0 else { return nil }
        let bytesPer = bits / 8
        let frames = dataLen / (bytesPer * channels)
        guard frames > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: AVAudioChannelCount(channels)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)

        bytes.withUnsafeBufferPointer { raw in
            let base = raw.baseAddress! + dataStart
            for i in 0..<frames {
                for ch in 0..<channels {
                    let p = base + (i * channels + ch) * bytesPer
                    let v: Float
                    switch (audioFormat, bits) {
                    case (3, 32):
                        v = UnsafeRawPointer(p).loadUnaligned(as: Float.self)
                    case (_, 16):
                        v = Float(UnsafeRawPointer(p).loadUnaligned(as: Int16.self)) / 32768
                    case (_, 8):
                        v = (Float(p.pointee) - 128) / 128
                    default:
                        v = 0
                    }
                    out[ch][i] = v
                }
            }
        }
        return buffer
    }

    /// Headerless little-endian Int16 mono PCM.
    private static func decodeRawPCM16(_ bytes: [UInt8], sampleRate: Double) -> AVAudioPCMBuffer? {
        let frames = bytes.count / 2
        guard frames > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        bytes.withUnsafeBufferPointer { raw in
            let base = raw.baseAddress!
            for i in 0..<frames {
                out[0][i] = Float(UnsafeRawPointer(base + i * 2).loadUnaligned(as: Int16.self)) / 32768
            }
        }
        return buffer
    }
}
