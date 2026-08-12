//
//  SoundCues.swift
//  Ace
//
//  UI sound cues (§8).
//
//  Two rules, both from the brief's "packed but calm" requirement:
//
//    1. Sounds are *synthesised here*, not shipped as files. Each cue is a short
//       sine tone with a soft envelope, generated once at launch and cached.
//       That keeps them perfectly consistent with each other, keeps the app
//       small, and means there is no royalty question about any asset.
//    2. Cues are quiet and short (<200ms). They confirm, they never announce.
//       Anything that would compete with Ace's voice or the focus music is not
//       a UI sound.
//

import Foundation
import AVFoundation

/// The sound vocabulary. Mirrors `Haptic` deliberately — a correct answer looks,
/// feels and sounds like one coherent event.
enum SoundCue: String, CaseIterable {
    case tap
    case correct
    case incorrect
    case complete
    case levelUp
    case nudge

    /// (frequency in Hz, duration in seconds, peak gain) for each partial.
    /// Multiple entries play in sequence — that's how `levelUp` gets its rise.
    fileprivate var tones: [(frequency: Double, duration: Double, gain: Float)] {
        switch self {
        case .tap:
            return [(1_320, 0.035, 0.10)]
        case .correct:
            // A clean rising major third.
            return [(880, 0.055, 0.16), (1_108.73, 0.085, 0.16)]
        case .incorrect:
            // A gentle falling second — soft, never a buzzer.
            return [(440, 0.070, 0.12), (392, 0.095, 0.10)]
        case .complete:
            return [(659.25, 0.070, 0.16), (830.61, 0.070, 0.16), (987.77, 0.130, 0.15)]
        case .levelUp:
            // Major arpeggio. The one cue allowed to be a little triumphant.
            return [(523.25, 0.065, 0.17), (659.25, 0.065, 0.17),
                    (783.99, 0.065, 0.17), (1_046.50, 0.180, 0.16)]
        case .nudge:
            // Two soft, low taps. Reads as "hey" rather than "alert".
            return [(587.33, 0.055, 0.09), (587.33, 0.055, 0.07)]
        }
    }
}

/// Plays the cues. One shared engine, buffers built lazily and cached.
@MainActor
final class SoundCuePlayer {
    static let shared = SoundCuePlayer()

    private static let storageKey = "ace.sounds.enabled"
    private let engine = AVAudioEngine()
    private let mixer = AVAudioMixerNode()
    private var players: [SoundCue: AVAudioPlayerNode] = [:]
    private var buffers: [SoundCue: AVAudioPCMBuffer] = [:]
    private var isEngineRunning = false

    /// Student-controlled. Also flipped off by Do Not Disturb in Part 4.
    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.storageKey) }
    }

    /// Master gain, lowered while Ace is speaking so cues never fight the voice.
    var gain: Float = 1.0 {
        didSet { mixer.outputVolume = max(0, min(gain, 1)) }
    }

    private init() {
        if UserDefaults.standard.object(forKey: Self.storageKey) == nil {
            isEnabled = true
        } else {
            isEnabled = UserDefaults.standard.bool(forKey: Self.storageKey)
        }
    }

    /// Build the engine and pre-render every buffer. Called once on launch so
    /// the first tap isn't silent while the engine spins up.
    func prepare() {
        guard !isEngineRunning else { return }

        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
        guard let format else { return }

        engine.attach(mixer)
        engine.connect(mixer, to: engine.mainMixerNode, format: format)
        mixer.outputVolume = gain

        for cue in SoundCue.allCases {
            guard let buffer = Self.render(cue, format: format) else { continue }
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: mixer, format: format)
            players[cue] = player
            buffers[cue] = buffer
        }

        do {
            engine.prepare()
            try engine.start()
            isEngineRunning = true
            for player in players.values { player.play() }
        } catch {
            // A device that can't start an audio engine (rare, usually another
            // app holding it exclusively) simply gets a silent UI. Never fatal.
            isEngineRunning = false
        }
    }

    /// Play a cue. No-op when disabled or if the engine failed to start.
    func play(_ cue: SoundCue) {
        guard isEnabled, isEngineRunning,
              let player = players[cue], let buffer = buffers[cue] else { return }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
    }

    /// Stop everything and release the engine — used when handing the audio
    /// session over to the realtime voice transport.
    func shutdown() {
        guard isEngineRunning else { return }
        for player in players.values { player.stop() }
        engine.stop()
        isEngineRunning = false
    }

    // MARK: - Synthesis

    /// Render a cue's tones into a single PCM buffer.
    ///
    /// Each tone gets a short attack and a longer exponential release. Without
    /// the envelope you hear a click at the buffer edges, which is the single
    /// most common reason synthesised UI sounds feel cheap.
    private static func render(_ cue: SoundCue, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        let totalDuration = cue.tones.reduce(0) { $0 + $1.duration }
        let frameCount = AVAudioFrameCount(totalDuration * sampleRate)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0]
        else { return nil }

        buffer.frameLength = frameCount

        var writeIndex = 0
        for tone in cue.tones {
            let toneFrames = Int(tone.duration * sampleRate)
            let attackFrames = max(1, Int(0.004 * sampleRate))   // 4ms attack

            for i in 0..<toneFrames {
                guard writeIndex < Int(frameCount) else { break }

                let t = Double(i) / sampleRate
                // Fundamental plus a quiet octave — one sine alone sounds thin.
                let fundamental = sin(2 * .pi * tone.frequency * t)
                let octave = sin(2 * .pi * tone.frequency * 2 * t) * 0.18
                let sample = (fundamental + octave) / 1.18

                // Envelope: linear attack, exponential decay.
                let attack = min(1.0, Double(i) / Double(attackFrames))
                let progress = Double(i) / Double(toneFrames)
                let decay = exp(-4.2 * progress)
                let envelope = attack * decay

                channel[writeIndex] = Float(sample * envelope) * tone.gain
                writeIndex += 1
            }
        }

        // Zero any remaining frames from rounding.
        while writeIndex < Int(frameCount) {
            channel[writeIndex] = 0
            writeIndex += 1
        }

        return buffer
    }
}

// MARK: - Convenience

/// Fire the haptic and the sound for one event together. Feature code should
/// almost always use this rather than either layer directly — it's what keeps
/// touch and audio in sync.
@MainActor
enum Feedback {
    static func tap() { Haptic.tap.play(); SoundCuePlayer.shared.play(.tap) }
    static func press() { Haptic.press.play(); SoundCuePlayer.shared.play(.tap) }
    static func selection() { Haptic.selection.play() }
    static func correct() { Haptic.correct.play(); SoundCuePlayer.shared.play(.correct) }
    static func incorrect() { Haptic.incorrect.play(); SoundCuePlayer.shared.play(.incorrect) }
    static func complete() { Haptic.success.play(); SoundCuePlayer.shared.play(.complete) }
    static func levelUp() { Haptic.levelUp.play(); SoundCuePlayer.shared.play(.levelUp) }
    static func nudge() { Haptic.nudge.play(); SoundCuePlayer.shared.play(.nudge) }
    static func warning() { Haptic.warning.play() }

    /// Silence everything non-essential — Do Not Disturb, and any moment the
    /// crisis net is engaged. Celebration noise is never appropriate there.
    static func setMuted(_ muted: Bool) {
        SoundCuePlayer.shared.isEnabled = !muted
        HapticSettings.shared.isEnabled = !muted
    }
}
