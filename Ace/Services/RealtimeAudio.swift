//
//  RealtimeAudio.swift
//  Ace
//
//  Microphone in, Ace's voice out.
//
//  Two objects:
//    • `MicrophoneCapture`  — taps the input, converts to the 24kHz mono PCM16
//      the Realtime API wants, and extracts the level/brightness features that
//      voice matching runs on (§9).
//    • `RealtimeAudioPlayer` — plays the audio the model streams back, and can
//      stop in a single buffer period, which is what makes barge-in fit the
//      150ms budget (§7).
//
//  Neither ever writes audio to disk and neither retains samples beyond the
//  buffer it is currently processing.
//

import Foundation
// `@preconcurrency`: AVFoundation predates strict concurrency, so its types are
// not annotated `Sendable` even where they are safe to hand across a boundary.
// The converter's input block below is invoked synchronously by
// `AVAudioConverter.convert`, on the caller's thread, before that call returns —
// the buffer never actually escapes. Without this the compiler has no way to
// know that and flags every capture.
@preconcurrency import AVFoundation

// MARK: - Microphone

/// Captures and converts microphone audio.
///
/// Deliberately NOT `@MainActor`: the input tap fires on a realtime audio
/// thread, and anything it touches has to be reachable from there. State is
/// guarded by a lock instead.
final class MicrophoneCapture: @unchecked Sendable {

    /// Called with converted PCM16 ready to send upstream.
    var onAudio: (@Sendable (Data) -> Void)?
    /// Called with the analysed features of the same chunk, for voice matching.
    var onFrame: (@Sendable (VoiceFrame) -> Void)?

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var _isRunning = false

    var isRunning: Bool { lock.withLock { _isRunning } }

    /// Below this RMS we call it silence. Deliberately low — the server's VAD
    /// makes the real decision; this is only for the energy features.
    private let speechFloor: Float = 0.012

    init() {}

    /// Ask for microphone permission. Returns whether we got it.
    static func requestPermission() async -> Bool {
        #if os(iOS)
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        #else
        return true
        #endif
    }

    func start() throws {
        guard !isRunning else { return }
        lock.withLock { _isRunning = true }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        // The API wants 24kHz mono PCM16; hardware gives us whatever it gives us.
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: RealtimeAudio.sampleRate,
            channels: AVAudioChannelCount(RealtimeAudio.channels),
            interleaved: true
        ) else {
            throw AIProviderError.audioUnavailable
        }
        lock.withLock {
            targetFormat = target
            converter = AVAudioConverter(from: inputFormat, to: target)
        }

        // ~100ms per tap. Small enough that a barge-in is noticed promptly,
        // large enough not to wake the CPU constantly.
        let bufferSize = AVAudioFrameCount(inputFormat.sampleRate / 10)

        input.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // The tap runs on a realtime audio thread. Feature extraction is
            // cheap arithmetic and safe here; anything heavier would glitch.
            let frame = Self.analyse(buffer: buffer, floor: self.speechFloor)
            self.onFrame?(frame)

            if let data = self.convert(buffer) {
                self.onAudio?(data)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            lock.withLock { _isRunning = false }
            throw error
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock { _isRunning = false }
    }

    // MARK: Conversion

    private func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        let (converter, targetFormat) = lock.withLock { (self.converter, self.targetFormat) }
        guard let converter, let targetFormat else { return nil }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        // `AVAudioConverter` types its input block `@Sendable`, but it calls it
        // synchronously on this thread and is finished with it before `convert`
        // returns. A plain captured `var` is therefore safe here and the
        // compiler has no way to know it — so the guarantee is stated in a type
        // rather than assumed in a comment.
        let input = ConverterInput(buffer: buffer)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            // The converter asks repeatedly; hand it the buffer once, then
            // report that there's no more input for this pass.
            guard let next = input.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return next
        }

        guard error == nil,
              output.frameLength > 0,
              let channelData = output.int16ChannelData else { return nil }

        let byteCount = Int(output.frameLength) * RealtimeAudio.bytesPerFrame
        return Data(bytes: channelData[0], count: byteCount)
    }

    // MARK: Feature extraction

    /// RMS level and zero-crossing rate. Pure arithmetic over the buffer — no
    /// samples are copied or kept.
    private static func analyse(buffer: AVAudioPCMBuffer, floor: Float) -> VoiceFrame {
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate

        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
            return VoiceFrame(level: 0, brightness: 0, duration: duration, isSpeech: false)
        }

        let count = Int(buffer.frameLength)
        var sumSquares: Float = 0
        var crossings = 0
        var previous: Float = channel[0]

        for index in 0..<count {
            let sample = channel[index]
            sumSquares += sample * sample
            if (sample >= 0) != (previous >= 0) { crossings += 1 }
            previous = sample
        }

        let rms = sqrt(sumSquares / Float(count))
        let zeroCrossingRate = Double(crossings) / Double(count)

        return VoiceFrame(
            level: Double(min(rms * 4, 1)),        // scaled into a usable 0...1
            brightness: min(zeroCrossingRate * 8, 1),
            duration: duration,
            isSpeech: rms > floor
        )
    }
}

/// Hands a buffer to `AVAudioConverter` exactly once.
///
/// `@unchecked Sendable` with a lock rather than a bare captured `var`: the
/// converter's callback is typed `@Sendable`, and satisfying that with an
/// unprotected local is the kind of thing that is fine until the day the
/// framework decides to call it from somewhere else.
private final class ConverterInput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?

    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    /// The buffer on the first call, nil on every one after.
    func take() -> AVAudioPCMBuffer? {
        lock.withLock {
            defer { buffer = nil }
            return buffer
        }
    }
}

// MARK: - Playback

/// Plays the audio stream coming back from the model.
///
/// The barge-in requirement drives the whole design. `stopImmediately()` has to
/// silence output within a buffer period, so:
///   • buffers are scheduled small (the queue is never more than ~200ms deep),
///   • stopping calls `AVAudioPlayerNode.stop()`, which drops everything
///     scheduled rather than draining it,
///   • and there is deliberately no fade-out. A 100ms fade would eat most of the
///     150ms budget on its own.
final class RealtimeAudioPlayer: RealtimeAudioSink, @unchecked Sendable {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat?
    private let lock = NSLock()
    private var isPrepared = false
    private var isPlaying = false

    init() {
        // The model sends interleaved PCM16; the engine wants deinterleaved
        // float. `AVAudioFormat(standardFormatWithSampleRate:)` gives us the
        // float format, and conversion happens per buffer.
        format = AVAudioFormat(standardFormatWithSampleRate: RealtimeAudio.sampleRate,
                               channels: AVAudioChannelCount(RealtimeAudio.channels))
    }

    private func prepareIfNeeded() {
        lock.withLock {
            guard !isPrepared, let format else { return }

            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.prepare()
            do {
                try engine.start()
                isPrepared = true
            } catch {
                // No audio engine means no voice. The caller degrades to text; it
                // must never be fatal.
                isPrepared = false
            }
        }
    }

    // MARK: RealtimeAudioSink

    // These are `async` because `RealtimeAudioSink` is, and `NSLock.lock()` is
    // unavailable from an async context — an error outright in the Swift 6
    // language mode. The reason is worth keeping: awaiting while holding a lock
    // blocks a thread from the cooperative pool, and enough of those deadlocks
    // the whole concurrency runtime.
    //
    // `withLock` is the scoped form, which cannot span a suspension point by
    // construction. Every AVFoundation call is made *outside* it too — issuing
    // engine work while holding our own lock is how the audio thread and the
    // caller end up waiting on each other.

    func beginPlayback() async {
        prepareIfNeeded()
        let ready = lock.withLock { () -> Bool in
            guard isPrepared else { return false }
            isPlaying = true
            return true
        }
        guard ready, !player.isPlaying else { return }
        player.play()
    }

    func enqueue(_ pcm: Data) async {
        let ready = lock.withLock { isPrepared && isPlaying }
        guard ready, let format, let buffer = Self.makeBuffer(from: pcm, format: format) else {
            return
        }
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    func finishPlayback() async {
        lock.withLock { isPlaying = false }
    }

    /// Barge-in. No fade, no drain — everything scheduled is discarded.
    func stopImmediately() async {
        let ready = lock.withLock { () -> Bool in
            isPlaying = false
            return isPrepared
        }
        guard ready else { return }
        player.stop()
    }

    func shutdown() {
        player.stop()
        engine.stop()
        lock.withLock {
            isPrepared = false
            isPlaying = false
        }
    }

    // MARK: Conversion

    /// Interleaved PCM16 bytes → a float buffer the engine can play.
    private static func makeBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = data.count / RealtimeAudio.bytesPerFrame
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frameCount)),
              let channel = buffer.floatChannelData?[0] else { return nil }

        buffer.frameLength = AVAudioFrameCount(frameCount)

        data.withUnsafeBytes { raw in
            guard let samples = raw.bindMemory(to: Int16.self).baseAddress else { return }
            for index in 0..<frameCount {
                // Int16 → normalised float.
                channel[index] = Float(Int16(littleEndian: samples[index])) / 32_768.0
            }
        }
        return buffer
    }
}
