//
//  VoiceSessionController.swift
//  Ace
//
//  Talking out loud: the object the tutor screen drives.
//
//  It owns the microphone, pushes audio at the realtime provider, and feeds the
//  analysed frames into voice matching (§9). Everything it does is guarded by
//  the two rules that matter most:
//
//    • **Permission is asked for once, and refusal is not a dead end.** No mic
//      means the student types instead, with one sentence explaining why.
//    • **Live Mode is not required.** With no key, the mic still works: the
//      audio is transcribed on-device (`MockAIProvider.transcribe`) and sent to
//      the Socratic tutor as text. Talking to Ace is a Demo Mode feature too.
//

import Foundation
import Observation
#if canImport(AVFoundation)
import AVFoundation
#endif

@MainActor
@Observable
final class VoiceSessionController {

    /// True while the microphone is open.
    private(set) var isListening = false
    /// True while the student is actually talking, from the level analysis.
    private(set) var isStudentSpeaking = false
    /// Smoothed input level, 0...1 — drives the waveform.
    private(set) var level: Double = 0
    /// A short line shown under the composer when something's wrong.
    private(set) var problem: String?

    private let capture = MicrophoneCapture()
    private var permissionAsked = false

    init() {}

    // MARK: - Lifecycle

    /// Start listening. Returns false if we couldn't.
    @discardableResult
    func start(appState: AppState) async -> Bool {
        guard !isListening else { return true }
        problem = nil

        guard await ensurePermission() else {
            problem = "Ace needs microphone access to listen. You can turn it on in Settings — typing works fine in the meantime."
            return false
        }

        // Route audio for a conversation rather than playback: this is what
        // enables echo cancellation, so Ace doesn't hear itself and barge in on
        // its own voice.
        configureAudioSessionForConversation()

        capture.onFrame = { [weak self] frame in
            Task { @MainActor in self?.handle(frame: frame, appState: appState) }
        }
        // The live provider is captured once, here on the main actor, rather
        // than being looked up from inside the audio callback — that callback
        // runs on a realtime thread and must not touch main-actor state.
        let live = appState.providers.live
        capture.onAudio = { pcm in
            guard let live, live.isReady else { return }
            Task { await live.sendMicrophoneAudio(pcm) }
        }

        do {
            try capture.start()
            isListening = true
            return true
        } catch {
            problem = "Couldn't open the microphone. Something else may be using it."
            return false
        }
    }

    func stop() async {
        guard isListening else { return }
        capture.stop()
        capture.onFrame = nil
        capture.onAudio = nil
        isListening = false
        isStudentSpeaking = false
        level = 0
    }

    // MARK: - Frames

    private func handle(frame: VoiceFrame, appState: AppState) {
        // Smooth the level so the waveform breathes rather than flickering.
        level += (frame.level - level) * 0.35
        isStudentSpeaking = frame.isSpeech

        // Voice matching: the analyser lives on the live provider so the model's
        // own delivery can be re-tuned from it.
        appState.providers.live?.ingestVoiceFrame(frame)
    }

    // MARK: - Permission and routing

    private func ensurePermission() async -> Bool {
        permissionAsked = true
        return await MicrophoneCapture.requestPermission()
    }

    /// `.playAndRecord` with `.voiceChat` turns on the system's echo canceller.
    ///
    /// Without it, the microphone picks up Ace's own voice from the speaker and
    /// the server's VAD interrupts Ace mid-sentence — a barge-in triggered by
    /// the thing being barged in on.
    private func configureAudioSessionForConversation() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord,
                                    mode: .voiceChat,
                                    options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
            try session.setActive(true)
        } catch {
            // Fall through: the session may already be configured, and a failure
            // here degrades audio quality rather than breaking the feature.
        }
        #endif
    }

    /// Put the audio session back to playback-only when the conversation ends,
    /// so the focus music in Part 4 isn't stuck in a low-quality call route.
    func restorePlaybackRouting() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .spokenAudio, options: [.mixWithOthers, .duckOthers]
        )
        #endif
    }
}

// MARK: - Listening bar

import SwiftUI

/// What the composer becomes while the mic is open.
///
/// A live waveform rather than a static "Listening…" label, because the single
/// most common failure in a voice UI is the student not knowing whether it can
/// hear them.
struct VoiceListeningBar: View {
    let level: Double
    let isStudentSpeaking: Bool
    let onStop: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Bar heights derived from the level, with a fixed offset per bar so the
    /// shape reads as a waveform rather than a row of identical blocks.
    private static let offsets: [Double] = [0.35, 0.65, 1.0, 0.8, 0.5, 0.9, 0.45]

    var body: some View {
        HStack(spacing: Space.m) {
            HStack(spacing: 3) {
                ForEach(Array(Self.offsets.enumerated()), id: \.offset) { _, offset in
                    Capsule()
                        .fill(isStudentSpeaking ? Ink.accent : Ink.textTertiary)
                        .frame(width: 3, height: barHeight(offset))
                }
            }
            .frame(height: 22)
            .aceAnimation(Motion.snappy, value: level)

            Text(isStudentSpeaking ? "Listening…" : "Go ahead — I'm listening")
                .font(Typeface.footnote)
                .foregroundStyle(Ink.textSecondary)

            Spacer(minLength: 0)

            Button("Stop", action: onStop)
                .font(Typeface.footnote)
                .foregroundStyle(Ink.accent)
        }
        .padding(.vertical, Space.s)
        .padding(.horizontal, Space.l)
        .background(Ink.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Ink.stroke, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(isStudentSpeaking ? "Ace is hearing you" : "Ace is listening"))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func barHeight(_ offset: Double) -> CGFloat {
        // Under Reduce Motion the bars sit still at a readable height rather
        // than animating — the label carries the meaning.
        guard !reduceMotion else { return 10 }
        let amplitude = max(level, 0.05) * offset
        return CGFloat(4 + amplitude * 18)
    }
}
