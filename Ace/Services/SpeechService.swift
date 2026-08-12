//
//  SpeechService.swift
//  Ace
//
//  Ace's voice in Demo Mode: `AVSpeechSynthesizer`, driven hard enough that the
//  personality actually comes through (§9).
//
//  The trick to making system TTS not sound robotic is threefold:
//    1. Pick the best available voice, not the first one. Premium and enhanced
//       voices are night-and-day better than compact, but which exist depends on
//       the device and on what the student has downloaded.
//    2. Shape prosody per persona AND per mood, continuously (see `Prosody`).
//    3. Speak in phrases, not paragraphs — with real pauses between them. A
//       single 60-word utterance is what makes TTS sound like a robot.
//

import Foundation
import AVFoundation

/// Speaks text on-device. `@MainActor` because `AVSpeechSynthesizer` wants its
/// calls serialised and the UI observes `isSpeaking` directly.
@MainActor
final class SpeechService: NSObject {

    private let synthesizer = AVSpeechSynthesizer()
    /// Resumed when the current utterance sequence finishes or is cancelled.
    private var completion: CheckedContinuation<Void, Never>?
    /// Utterances still queued for the current `speak` call.
    private var pendingUtterances = 0

    private(set) var isSpeaking = false

    /// Set when `stop()` is called, so the delegate knows a cancellation is
    /// expected rather than a failure.
    private var isStopping = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Speaking

    /// Speak `text` and return once the audio has finished or been stopped.
    func speak(_ text: String, persona: VoicePersona, prosody: Prosody) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        await stop()

        let voice = Self.resolveVoice(for: persona)
        let shaped = prosody.clamped
        let phrases = PhraseSplitter.phrases(in: trimmed)
        guard !phrases.isEmpty else { return }

        isSpeaking = true
        isStopping = false
        pendingUtterances = phrases.count

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.completion = continuation

            for (index, phrase) in phrases.enumerated() {
                let utterance = AVSpeechUtterance(string: phrase)
                utterance.voice = voice
                // `AVSpeechUtteranceDefaultSpeechRate` is 0.5, and the usable
                // range is roughly 0.4–0.6 — outside that it stops sounding
                // like speech. `Prosody.clamped` already enforces this.
                utterance.rate = Float(shaped.rate)
                utterance.pitchMultiplier = Float(shaped.pitch)
                utterance.volume = Float(shaped.volume)

                // A beat before the first phrase reads as thinking; shorter
                // beats between phrases read as breathing.
                utterance.preUtteranceDelay = index == 0 ? shaped.preDelay : 0.10
                // Slightly longer pause after a question — it invites an answer,
                // which is the whole point of a Socratic tutor.
                utterance.postUtteranceDelay = phrase.hasSuffix("?") ? 0.28 : 0.06

                synthesizer.speak(utterance)
            }
        }

        isSpeaking = false
    }

    /// Stop immediately. Safe to call when nothing is playing.
    ///
    /// `.immediate` (rather than `.word`) is what makes barge-in feel instant —
    /// `.word` waits for the current word to finish, which can be 300ms.
    func stop() async {
        guard synthesizer.isSpeaking || completion != nil else { return }
        isStopping = true
        synthesizer.stopSpeaking(at: .immediate)
        pendingUtterances = 0
        finish()
    }

    /// Resume the waiting `speak` call exactly once.
    private func finish() {
        isSpeaking = false
        guard let continuation = completion else { return }
        completion = nil
        continuation.resume()
    }

    // MARK: - Voice resolution

    /// Find the best available voice for a persona.
    ///
    /// Tries each candidate in order, then falls back to any enhanced/premium
    /// voice in the right language, then to the system default. The result is
    /// cached because enumerating every installed voice is not free and this is
    /// called on every utterance.
    private static var voiceCache: [String: AVSpeechSynthesisVoice] = [:]

    static func resolveVoice(for persona: VoicePersona) -> AVSpeechSynthesisVoice? {
        if let cached = voiceCache[persona.id] { return cached }

        for identifier in persona.systemVoiceCandidates {
            if let voice = AVSpeechSynthesisVoice(identifier: identifier) {
                voiceCache[persona.id] = voice
                return voice
            }
        }

        // Nothing from the candidate list is installed. Prefer any higher-
        // quality voice in the right language over the compact default.
        let installed = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == persona.languageCode }
        let ranked = installed.sorted { lhs, rhs in
            Self.qualityRank(lhs.quality) > Self.qualityRank(rhs.quality)
        }
        if let best = ranked.first {
            voiceCache[persona.id] = best
            return best
        }

        return AVSpeechSynthesisVoice(language: persona.languageCode)
    }

    private static func qualityRank(_ quality: AVSpeechSynthesisVoiceQuality) -> Int {
        switch quality {
        case .premium: 3
        case .enhanced: 2
        case .default: 1
        @unknown default: 0
        }
    }

    /// True when the device has at least one enhanced or premium voice. Used by
    /// Settings to offer the "download better voices" tip.
    static var hasHighQualityVoice: Bool {
        AVSpeechSynthesisVoice.speechVoices().contains {
            $0.quality == .enhanced || $0.quality == .premium
        }
    }

}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechService: AVSpeechSynthesizerDelegate {

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard !isStopping else { return }
            pendingUtterances -= 1
            if pendingUtterances <= 0 { finish() }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            // A cancel fires per queued utterance; only the first needs to
            // resume the waiting caller, and `finish()` is idempotent.
            finish()
        }
    }
}
