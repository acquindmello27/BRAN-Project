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

    /// Configure the shared audio session for "record from mic, play to earphones".
    /// `.allowBluetoothA2DP` keeps AirPods on the high-quality output profile while
    /// the phone's own microphone does the listening.
    func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP])
        try session.setActive(true, options: [])
    }

    func enqueue(wav data: Data) {
        guard let pcm = WAVDecoder.decode(data) else { return }
        lock.lock(); defer { lock.unlock() }
        do {
            try ensureEngine(for: pcm.format)
            let buffer = try convertIfNeeded(pcm)
            player.scheduleBuffer(buffer, completionHandler: nil)
            if !player.isPlaying { player.play() }
        } catch {
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

/// Minimal RIFF/WAVE parser for 8/16-bit integer or 32-bit float PCM.
enum WAVDecoder {
    static func decode(_ data: Data) -> AVAudioPCMBuffer? {
        guard data.count > 44 else { return nil }
        let bytes = [UInt8](data)
        func tag(_ o: Int) -> String { String(bytes: bytes[o..<o + 4], encoding: .ascii) ?? "" }
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard tag(0) == "RIFF", tag(8) == "WAVE" else { return nil }

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
}
