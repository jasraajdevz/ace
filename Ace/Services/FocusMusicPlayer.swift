//
//  FocusMusicPlayer.swift
//  Ace
//
//  Focus music, synthesised on the device.
//
//  Nothing is shipped as an audio file. `AmbientScore` decides which notes to
//  play and when; this renders them into buffers and schedules them a window at
//  a time, so the music genuinely never repeats. Three consequences, all good:
//
//    • No licensing question at all — there is no recording to license.
//    • No megabytes in the app bundle.
//    • No loop seam. Looped study music becomes grating precisely because you
//      start hearing the loop; generated music can't do that.
//
//  It ducks under Ace's voice, and it keeps playing through quizzes and
//  flashcards — stopping it at every screen change would be worse than not
//  having it (§Part 4).
//

import Foundation
import AVFoundation

/// Plays generated ambience.
@MainActor
@Observable
final class FocusMusicPlayer {

    private(set) var scene: FocusScene = .off
    private(set) var isPlaying = false

    /// The mix. Setting `userVolume` or `isDucking` applies immediately.
    var mix = MusicMix() {
        didSet { applyMix(animated: true) }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let mixer = AVAudioMixerNode()
    private var format: AVAudioFormat?
    private var scheduler: Task<Void, Never>?
    private var seed: UInt64 = 0x5EED_1234

    /// Each render covers this many seconds. Long enough that scheduling is
    /// cheap, short enough that changing scene takes effect promptly.
    private static let windowSeconds: TimeInterval = 8
    private static let sampleRate: Double = 22_050   // plenty for pads; half the work

    private static let volumeKey = "ace.music.volume"
    private static let sceneKey = "ace.music.scene"

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)
        let saved = UserDefaults.standard.object(forKey: Self.volumeKey) as? Double
        mix = MusicMix(userVolume: saved ?? 0.35)
    }

    /// The scene the student last chose, for restoring on launch.
    var savedScene: FocusScene {
        UserDefaults.standard.string(forKey: Self.sceneKey)
            .flatMap(FocusScene.init(rawValue:)) ?? .off
    }

    // MARK: - Control

    func play(_ scene: FocusScene) {
        UserDefaults.standard.set(scene.rawValue, forKey: Self.sceneKey)

        guard scene != .off else {
            stop()
            return
        }

        self.scene = scene
        guard prepare() else { return }

        scheduler?.cancel()
        isPlaying = true
        applyMix(animated: false)
        if !player.isPlaying { player.play() }
        startScheduling()
    }

    func stop() {
        scheduler?.cancel()
        scheduler = nil
        player.stop()
        engine.stop()
        isPlaying = false
        scene = .off
    }

    /// Duck under Ace's voice. Called by `AppState` whenever speaking starts or
    /// stops, so the music dips for the model's audio *and* the local
    /// synthesiser without either having to know about the other.
    func setDucking(_ ducking: Bool) {
        guard mix.isDucking != ducking else { return }
        mix.isDucking = ducking
    }

    func setVolume(_ volume: Double) {
        mix.userVolume = min(max(volume, 0), 1)
        UserDefaults.standard.set(mix.userVolume, forKey: Self.volumeKey)
    }

    // MARK: - Engine

    private func prepare() -> Bool {
        guard let format else { return false }
        guard !engine.isRunning else { return true }

        if player.engine == nil {
            engine.attach(player)
            engine.attach(mixer)
            engine.connect(player, to: mixer, format: format)
            engine.connect(mixer, to: engine.mainMixerNode, format: format)
        }

        do {
            engine.prepare()
            try engine.start()
            return true
        } catch {
            // No engine means no music. Never fatal — the student can still study.
            isPlaying = false
            return false
        }
    }

    private func applyMix(animated: Bool) {
        let target = Float(mix.effectiveVolume)
        guard animated else {
            mixer.outputVolume = target
            return
        }
        // A short linear ramp. Stepping the gain produces an audible click, and
        // a click in ambient music is the only thing more distracting than the
        // music itself.
        let steps = 12
        let start = mixer.outputVolume
        let interval = mix.rampDuration / Double(steps)
        for step in 1...steps {
            let fraction = Float(step) / Float(steps)
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(step)) { [weak self] in
                self?.mixer.outputVolume = start + (target - start) * fraction
            }
        }
    }

    /// Render and schedule one window at a time, staying one ahead.
    private func startScheduling() {
        scheduler = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isPlaying else { return }
                self.scheduleNextWindow()
                // Wake just before the buffer runs out so there's never a gap.
                try? await Task.sleep(for: .seconds(Self.windowSeconds - 0.4))
            }
        }
    }

    private func scheduleNextWindow() {
        guard let format, let buffer = render(scene: scene, format: format) else { return }
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    // MARK: - Synthesis

    /// Render one window of a scene into a buffer.
    private func render(scene: FocusScene, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = Int(Self.windowSeconds * Self.sampleRate)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frameCount)),
              let channel = buffer.floatChannelData?[0] else { return nil }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        for index in 0..<frameCount { channel[index] = 0 }

        // The scored notes.
        let events = AmbientScore(scene: scene).events(windowSeconds: Self.windowSeconds, seed: seed)
        for event in events {
            mix(event, into: channel, frameCount: frameCount)
        }

        // The rain bed is noise rather than notes, so it's added separately.
        if scene == .rain {
            addRainBed(into: channel, frameCount: frameCount)
        }

        // Fade the window edges. Without this, a note still sounding at the end
        // of a buffer produces a click at the join — the exact artefact that
        // makes generated audio sound cheap.
        applyEdgeFades(channel, frameCount: frameCount)
        return buffer
    }

    /// Add one note into the buffer.
    private func mix(_ event: AmbientScore.Event,
                     into channel: UnsafeMutablePointer<Float>,
                     frameCount: Int) {
        let startFrame = Int(event.time * Self.sampleRate)
        let noteFrames = Int(event.duration * Self.sampleRate)
        let attackFrames = max(1, Int(event.attack * Self.sampleRate))
        guard startFrame < frameCount else { return }

        for offset in 0..<noteFrames {
            let index = startFrame + offset
            guard index < frameCount else { break }

            let t = Double(offset) / Self.sampleRate

            // Fundamental plus a quiet fifth and octave. One sine is thin; a
            // small stack reads as an instrument.
            let fundamental = sin(2 * .pi * event.frequency * t)
            let fifth = sin(2 * .pi * event.frequency * 1.5 * t) * 0.22
            let octave = sin(2 * .pi * event.frequency * 2 * t) * 0.14
            // A slow tremolo keeps a long pad from sounding synthetic.
            let shimmer = 1 + 0.06 * sin(2 * .pi * 0.19 * t)

            let attack = min(1.0, Double(offset) / Double(attackFrames))
            let progress = Double(offset) / Double(noteFrames)
            let release = progress > 0.6 ? (1 - (progress - 0.6) / 0.4) : 1.0
            let envelope = attack * max(0, release)

            let sample = (fundamental + fifth + octave) / 1.36 * shimmer * envelope * event.gain
            channel[index] += Float(sample)
        }
    }

    /// Filtered noise for the rain scene.
    ///
    /// White noise through a one-pole low-pass becomes something much closer to
    /// rain than raw hiss, and costs one multiply per sample.
    private func addRainBed(into channel: UnsafeMutablePointer<Float>, frameCount: Int) {
        var generator = SeededGenerator(seed: seed &+ 99)
        var lowPass: Float = 0
        let coefficient: Float = 0.14

        for index in 0..<frameCount {
            let white = Float(Double.random(in: -1...1, using: &generator))
            lowPass += coefficient * (white - lowPass)
            channel[index] += lowPass * 0.16
        }
    }

    /// 30ms fades at each end of the window, so consecutive buffers join
    /// silently.
    private func applyEdgeFades(_ channel: UnsafeMutablePointer<Float>, frameCount: Int) {
        let fadeFrames = min(Int(0.03 * Self.sampleRate), frameCount / 2)
        guard fadeFrames > 0 else { return }
        for offset in 0..<fadeFrames {
            let gain = Float(offset) / Float(fadeFrames)
            channel[offset] *= gain
            channel[frameCount - 1 - offset] *= gain
        }
    }
}
