//
//  VoicePersona.swift
//  Ace
//
//  The voice roster. Each persona is a personality first and a set of speech
//  parameters second — the numbers exist to make the personality audible.
//

import Foundation

/// How a persona presents. Students pick what they want to hear; we never infer
/// or assume anything about the student from the choice.
enum VoiceGenderPresentation: String, Codable, CaseIterable, Sendable {
    case feminine, masculine, neutral

    var displayName: String {
        switch self {
        case .feminine: "Female"
        case .masculine: "Male"
        case .neutral: "Neutral"
        }
    }
}

/// Speech shaping values. In Demo Mode these map onto `AVSpeechUtterance`
/// (rate / pitchMultiplier / volume). In Live Mode they become style hints in
/// the realtime session instructions. One struct, both worlds.
struct Prosody: Codable, Sendable, Equatable {
    /// 0...1 where 0.5 is `AVSpeechUtteranceDefaultSpeechRate`.
    var rate: Double
    /// 0.5...2.0, 1.0 is natural.
    var pitch: Double
    /// 0...1.
    var volume: Double
    /// Seconds of silence inserted before the utterance — a beat of thinking
    /// reads as human. Small values only; long pauses feel like a hang.
    var preDelay: Double

    init(rate: Double = 0.5, pitch: Double = 1.0, volume: Double = 1.0, preDelay: Double = 0) {
        self.rate = rate
        self.pitch = pitch
        self.volume = volume
        self.preDelay = preDelay
    }

    static let natural = Prosody()

    /// Clamp to the ranges AVFoundation actually accepts, so a bad computation
    /// can never produce a chipmunk or total silence.
    var clamped: Prosody {
        Prosody(rate: min(max(rate, 0.2), 0.75),
                pitch: min(max(pitch, 0.6), 1.8),
                volume: min(max(volume, 0.2), 1.0),
                preDelay: min(max(preDelay, 0), 0.6))
    }

    /// Blend toward another prosody. Used for mood matching: we never snap to a
    /// new delivery, we ease into it.
    func blended(with other: Prosody, amount: Double) -> Prosody {
        let t = min(max(amount, 0), 1)
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        return Prosody(rate: mix(rate, other.rate),
                       pitch: mix(pitch, other.pitch),
                       volume: mix(volume, other.volume),
                       preDelay: mix(preDelay, other.preDelay))
    }
}

/// One selectable voice + personality.
struct VoicePersona: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let displayName: String
    /// One line the student reads on the picker. This is the personality.
    let blurb: String
    let presentation: VoiceGenderPresentation
    /// Baseline delivery for this persona.
    let baseProsody: Prosody
    /// Candidate `AVSpeechSynthesisVoice` identifiers, best first. We try each
    /// in order and fall back to the system default — voice availability varies
    /// by device and by what the student has downloaded, so a hard-coded single
    /// identifier would silently break for some people.
    let systemVoiceCandidates: [String]
    /// Language for the fallback lookup.
    let languageCode: String
    /// Name of the voice to request from the realtime API in Live Mode.
    let realtimeVoiceName: String
    /// Short line Ace says when previewed.
    let previewLine: String

    static func == (lhs: VoicePersona, rhs: VoicePersona) -> Bool { lhs.id == rhs.id }
}

// MARK: - The roster

enum VoiceRoster {

    /// Apple's "premium"/"enhanced" US English voices. We list several
    /// candidates per persona because which ones exist depends on the device
    /// and on what the student has downloaded in Settings › Accessibility.
    static let all: [VoicePersona] = [
        VoicePersona(
            id: "nova",
            displayName: "Nova",
            blurb: "Bright and quick. Celebrates every win like it's a big deal.",
            presentation: .feminine,
            baseProsody: Prosody(rate: 0.53, pitch: 1.10, volume: 1.0),
            systemVoiceCandidates: [
                "com.apple.voice.premium.en-US.Ava",
                "com.apple.voice.enhanced.en-US.Ava",
                "com.apple.ttsbundle.siri_Nicky_en-US_compact",
                "com.apple.voice.compact.en-US.Samantha"
            ],
            languageCode: "en-US",
            realtimeVoiceName: "shimmer",
            previewLine: "Okay — I love this one. Walk me through what you're thinking."
        ),
        VoicePersona(
            id: "atlas",
            displayName: "Atlas",
            blurb: "Steady and grounded. Never rushes you, never loses the thread.",
            presentation: .masculine,
            baseProsody: Prosody(rate: 0.47, pitch: 0.92, volume: 1.0, preDelay: 0.05),
            systemVoiceCandidates: [
                "com.apple.voice.premium.en-US.Zoe",
                "com.apple.voice.enhanced.en-US.Tom",
                "com.apple.ttsbundle.siri_Aaron_en-US_compact",
                "com.apple.voice.compact.en-US.Alex"
            ],
            languageCode: "en-US",
            realtimeVoiceName: "ash",
            previewLine: "Take your time. Tell me the part that isn't clicking yet."
        ),
        VoicePersona(
            id: "sage",
            displayName: "Sage",
            blurb: "Calm and warm. The one you want at 11pm when it's not going well.",
            presentation: .feminine,
            baseProsody: Prosody(rate: 0.45, pitch: 0.98, volume: 0.95, preDelay: 0.08),
            systemVoiceCandidates: [
                "com.apple.voice.enhanced.en-US.Allison",
                "com.apple.voice.premium.en-US.Ava",
                "com.apple.voice.compact.en-US.Samantha"
            ],
            languageCode: "en-US",
            realtimeVoiceName: "coral",
            previewLine: "Hey. We can go as slow as you need. Where should we start?"
        ),
        VoicePersona(
            id: "rex",
            displayName: "Rex",
            blurb: "High energy. Treats a study session like the fourth quarter.",
            presentation: .masculine,
            baseProsody: Prosody(rate: 0.56, pitch: 1.02, volume: 1.0),
            systemVoiceCandidates: [
                "com.apple.voice.enhanced.en-US.Evan",
                "com.apple.ttsbundle.siri_Aaron_en-US_compact",
                "com.apple.voice.compact.en-US.Fred"
            ],
            languageCode: "en-US",
            realtimeVoiceName: "verse",
            previewLine: "Let's go. Give me your best guess — wrong is fine, I want the thinking."
        ),
        VoicePersona(
            id: "iris",
            displayName: "Iris",
            blurb: "Precise and curious. Asks the question that cracks it open.",
            presentation: .feminine,
            baseProsody: Prosody(rate: 0.50, pitch: 1.04, volume: 1.0, preDelay: 0.04),
            systemVoiceCandidates: [
                "com.apple.voice.enhanced.en-US.Susan",
                "com.apple.voice.premium.en-US.Ava",
                "com.apple.voice.compact.en-US.Victoria"
            ],
            languageCode: "en-US",
            realtimeVoiceName: "sage",
            previewLine: "Interesting. What made you pick that one — say the reason out loud."
        ),
        VoicePersona(
            id: "kai",
            displayName: "Kai",
            blurb: "Easygoing and dry. Keeps it light when you're grinding.",
            presentation: .neutral,
            baseProsody: Prosody(rate: 0.49, pitch: 1.0, volume: 0.98),
            systemVoiceCandidates: [
                "com.apple.voice.enhanced.en-US.Nathan",
                "com.apple.voice.compact.en-US.Alex",
                "com.apple.voice.compact.en-US.Samantha"
            ],
            languageCode: "en-US",
            realtimeVoiceName: "alloy",
            previewLine: "Alright, chapter four. Nobody's favourite. Let's make it quick."
        )
    ]

    static let `default`: VoicePersona = all[0]

    static func persona(id: String?) -> VoicePersona {
        guard let id, let match = all.first(where: { $0.id == id }) else { return `default` }
        return match
    }

    static func personas(presenting: VoiceGenderPresentation) -> [VoicePersona] {
        all.filter { $0.presentation == presenting }
    }
}

// MARK: - Mood → delivery

/// Turns "the student sounds frustrated" into "speak like this".
///
/// This is the Demo-Mode half of the voice-matching feature described in §9:
/// mirror the student's pace and energy without ever cloning their voice.
enum ProsodyMatcher {

    /// Target delivery for a given mood, expressed as a delta from the
    /// persona's baseline.
    static func target(for mood: Mood, base: Prosody) -> Prosody {
        switch mood {
        case .neutral, .focused:
            return base
        case .energized:
            // Match their energy: a little faster, a little brighter.
            return Prosody(rate: base.rate + 0.05, pitch: base.pitch + 0.06,
                           volume: base.volume, preDelay: 0)
        case .confused:
            // Slow down and leave room. This is the single most useful move.
            return Prosody(rate: base.rate - 0.08, pitch: base.pitch - 0.02,
                           volume: base.volume, preDelay: base.preDelay + 0.12)
        case .frustrated:
            // Slower, softer, unhurried. Do not sound cheerful at someone who
            // is annoyed — it reads as mocking.
            return Prosody(rate: base.rate - 0.06, pitch: base.pitch - 0.05,
                           volume: base.volume * 0.94, preDelay: base.preDelay + 0.15)
        case .low:
            // Gentlest setting we have.
            return Prosody(rate: base.rate - 0.09, pitch: base.pitch - 0.06,
                           volume: base.volume * 0.90, preDelay: base.preDelay + 0.2)
        case .distracted:
            // Slightly crisper to re-engage attention, but not loud.
            return Prosody(rate: base.rate + 0.02, pitch: base.pitch + 0.03,
                           volume: base.volume, preDelay: 0)
        }
    }

    /// Ease from the current delivery toward the mood target. `confidence`
    /// scales how far we move, so a hunch nudges and a certainty commits.
    static func next(current: Prosody, base: Prosody, reading: MoodReading) -> Prosody {
        guard reading.isActionable else {
            // Drift back to baseline when we have no read.
            return current.blended(with: base, amount: 0.25).clamped
        }
        let goal = target(for: reading.mood, base: base)
        return current.blended(with: goal, amount: 0.35 + 0.4 * reading.confidence).clamped
    }
}
