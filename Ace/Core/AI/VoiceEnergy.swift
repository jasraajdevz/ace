//
//  VoiceEnergy.swift
//  Ace
//
//  Reading how the student *sounds*, not what they said (§9).
//
//  This is the other half of voice matching. `MoodHeuristics` reads behaviour —
//  streaks, latency, what they typed. This reads the audio itself: how loud they
//  are, how fast they're talking, how long they pause, how steady it is.
//
//  What it does NOT do, and must never do: identify the speaker, store audio,
//  or reproduce their voice. Matching means mirroring pace, energy and warmth.
//  Nothing here leaves the device and nothing here is retained — the analyser
//  keeps a rolling window of *numbers*, never samples.
//
//  Pure arithmetic over already-extracted features, so it's fully testable
//  without a microphone.
//

import Foundation

/// Features extracted from one chunk of microphone audio.
///
/// The audio layer computes these; this file never sees samples.
struct VoiceFrame: Sendable, Equatable {
    /// Root-mean-square amplitude, 0...1.
    var level: Double
    /// Zero-crossing rate, roughly 0...1. A crude proxy for how "bright" the
    /// signal is — useful for telling speech from a rumble.
    var brightness: Double
    /// Seconds this frame covers.
    var duration: TimeInterval
    /// Whether the VAD considered this speech.
    var isSpeech: Bool

    static let silence = VoiceFrame(level: 0, brightness: 0, duration: 0.02, isSpeech: false)
}

/// What we heard, over the last several seconds of talking.
struct VoiceReading: Sendable, Equatable {
    /// Loudness relative to this student's own baseline. 1.0 = their normal.
    var relativeEnergy: Double
    /// Speaking pace relative to their baseline. 1.0 = their normal.
    var relativePace: Double
    /// Fraction of the window that was silence *inside* their turn — hesitation.
    var hesitation: Double
    /// How much the level wobbles. Very steady + very quiet reads as flat.
    var variability: Double
    /// Seconds of speech this reading is based on.
    var speechSeconds: TimeInterval

    static let none = VoiceReading(relativeEnergy: 1, relativePace: 1,
                                   hesitation: 0, variability: 0, speechSeconds: 0)

    /// We need a couple of seconds of speech before any of this means anything.
    var isReliable: Bool { speechSeconds >= 1.5 }
}

/// Rolling analysis of the student's voice.
///
/// Everything is measured *relative to the same student's own baseline*, which
/// is the only way this can work: a quiet person talking normally and a loud
/// person mumbling produce the same absolute level.
struct VoiceEnergyAnalyzer: Sendable {

    /// How much history the rolling window keeps, in seconds.
    static let windowSeconds: TimeInterval = 6

    /// Time constant for the baseline, in SECONDS of speech.
    ///
    /// This has to be long. The baseline means "how this person normally
    /// sounds", so it must move far more slowly than the thing being measured
    /// against it. At 50 audio frames a second, a per-frame smoothing factor of
    /// 0.02 is a one-second time constant — which normalises away any sustained
    /// change within about two seconds, silently killing voice matching.
    /// Thirty seconds keeps the baseline stable across a whole answer.
    static let baselineTimeConstant: TimeInterval = 30

    private var frames: [VoiceFrame] = []
    /// The student's own normal loudness, learned over the session.
    private(set) var baselineLevel: Double = 0
    /// Their normal speech-to-silence ratio, a proxy for pace.
    private(set) var baselineDensity: Double = 0
    private(set) var totalSpeechSeconds: TimeInterval = 0

    init() {}

    /// Feed one chunk of analysed audio.
    mutating func ingest(_ frame: VoiceFrame) {
        frames.append(frame)

        // Trim to the window.
        var windowTotal = frames.reduce(0) { $0 + $1.duration }
        while windowTotal > Self.windowSeconds, frames.count > 1 {
            windowTotal -= frames.removeFirst().duration
        }

        guard frame.isSpeech else { return }
        totalSpeechSeconds += frame.duration

        // Adapt the baseline only on speech, and only once there's something to
        // adapt from — otherwise the first loud word becomes "normal".
        //
        // The smoothing factor is derived from the frame's real duration rather
        // than being a fixed per-frame constant, so the baseline moves at the
        // same rate regardless of what buffer size the audio engine hands us.
        if baselineLevel == 0 {
            baselineLevel = frame.level
        } else {
            let alpha = 1 - exp(-frame.duration / Self.baselineTimeConstant)
            baselineLevel += (frame.level - baselineLevel) * alpha
        }
    }

    /// Current reading over the window.
    func read() -> VoiceReading {
        let speechFrames = frames.filter(\.isSpeech)
        let speechSeconds = speechFrames.reduce(0) { $0 + $1.duration }
        let windowSeconds = frames.reduce(0) { $0 + $1.duration }

        guard !speechFrames.isEmpty, windowSeconds > 0, baselineLevel > 0 else {
            return .none
        }

        let meanLevel = speechFrames.reduce(0) { $0 + $1.level } / Double(speechFrames.count)
        let relativeEnergy = clampRatio(meanLevel / baselineLevel)

        // Density = how much of the window was actually speech. Talking faster
        // means fewer gaps, so density tracks pace well enough for mirroring.
        let density = speechSeconds / windowSeconds
        let referenceDensity = baselineDensity > 0 ? baselineDensity : 0.55
        let relativePace = clampRatio(density / referenceDensity)

        // Hesitation: silence *between* speech, ignoring leading and trailing
        // silence (which is just not-talking-yet, not hesitating).
        let hesitation = interiorSilenceFraction()

        let variability: Double
        if speechFrames.count >= 2 {
            let deviation = speechFrames
                .map { abs($0.level - meanLevel) }
                .reduce(0, +) / Double(speechFrames.count)
            variability = min(deviation / max(meanLevel, 0.0001), 1)
        } else {
            variability = 0
        }

        return VoiceReading(
            relativeEnergy: relativeEnergy,
            relativePace: relativePace,
            hesitation: hesitation,
            variability: variability,
            speechSeconds: speechSeconds
        )
    }

    /// Learn the student's normal speech density. Called once a turn completes,
    /// so the baseline is built from whole turns rather than fragments.
    mutating func completeTurn() {
        let windowSeconds = frames.reduce(0) { $0 + $1.duration }
        guard windowSeconds > 0 else { return }
        let density = frames.filter(\.isSpeech).reduce(0) { $0 + $1.duration } / windowSeconds
        if baselineDensity == 0 {
            baselineDensity = density
        } else {
            baselineDensity += (density - baselineDensity) * 0.15
        }
        frames.removeAll()
    }

    mutating func reset() {
        frames.removeAll()
        baselineLevel = 0
        baselineDensity = 0
        totalSpeechSeconds = 0
    }

    /// Fraction of the window between the first and last speech frame that was
    /// silent.
    private func interiorSilenceFraction() -> Double {
        guard let first = frames.firstIndex(where: \.isSpeech),
              let last = frames.lastIndex(where: \.isSpeech),
              last > first else { return 0 }

        let interior = frames[first...last]
        let total = interior.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return 0 }
        let silent = interior.filter { !$0.isSpeech }.reduce(0) { $0 + $1.duration }
        return min(silent / total, 1)
    }

    /// Keep ratios in a range where they mean something. A 10× reading is a
    /// microphone glitch, not a very enthusiastic student.
    private func clampRatio(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, 0.25), 3.0)
    }
}

// MARK: - From sound to mood

extension VoiceReading {

    /// Turn an acoustic reading into a mood.
    ///
    /// Deliberately conservative: audio alone is a weak signal, so confidences
    /// top out below what the behavioural heuristics can claim, and an
    /// unreliable reading returns `.unknown` rather than a guess. A tutor that
    /// changes personality because someone cleared their throat is worse than
    /// one that doesn't react at all.
    var inferredMood: MoodReading {
        guard isReliable else {
            return MoodReading(mood: .neutral, confidence: 0, rationale: "not enough speech yet")
        }

        // Quiet, slow and flat — the clearest acoustic signature there is.
        if relativeEnergy < 0.7 && relativePace < 0.85 && variability < 0.35 {
            return MoodReading(mood: .low, confidence: 0.6,
                               rationale: "quiet, slow, flat delivery")
        }

        // Lots of stopping and starting means they're working it out — or stuck.
        if hesitation > 0.45 {
            return MoodReading(mood: .confused, confidence: 0.55,
                               rationale: "long pauses mid-answer")
        }

        // Loud and fast, with a lot of variation, is either excitement or
        // annoyance. Variability is what separates them: frustration is spiky.
        if relativeEnergy > 1.35 && variability > 0.55 {
            return MoodReading(mood: .frustrated, confidence: 0.5,
                               rationale: "loud and uneven")
        }
        if relativeEnergy > 1.2 && relativePace > 1.15 {
            return MoodReading(mood: .energized, confidence: 0.6,
                               rationale: "louder and faster than usual")
        }

        // Steady and unhurried is someone concentrating.
        if variability < 0.25 && (0.85...1.15).contains(relativePace) {
            return MoodReading(mood: .focused, confidence: 0.45,
                               rationale: "steady, even delivery")
        }

        return MoodReading(mood: .neutral, confidence: 0.3, rationale: "nothing distinctive")
    }

    /// Mirror the student's delivery onto Ace's own.
    ///
    /// This is voice *matching*, and the ceiling is deliberate: Ace moves partway
    /// toward their pace and energy, never all the way. Fully matching an
    /// agitated student produces an agitated tutor, which helps nobody.
    func matchedProsody(base: Prosody) -> Prosody {
        guard isReliable else { return base }

        // Move 40% of the way toward their pace, and cap the total change.
        let paceShift = (relativePace - 1) * 0.4
        let energyShift = (relativeEnergy - 1) * 0.3

        return Prosody(
            rate: base.rate + clamp(paceShift, 0.10) ,
            pitch: base.pitch + clamp(energyShift * 0.5, 0.08),
            volume: base.volume,
            // Someone hesitating gets more room to think, not less.
            preDelay: base.preDelay + min(hesitation * 0.25, 0.2)
        ).clamped
    }

    private func clamp(_ value: Double, _ limit: Double) -> Double {
        min(max(value, -limit), limit)
    }
}

// MARK: - Combining the two signals

enum MoodFusion {

    /// Merge the acoustic read with the behavioural one.
    ///
    /// Behaviour wins ties. Getting three questions wrong in a row is a harder
    /// fact than sounding a bit quiet — but when the voice is confident and
    /// behaviour has nothing to say, the voice should be heard.
    static func combine(voice: MoodReading, behaviour: MoodReading) -> MoodReading {
        // Neither is worth acting on.
        if !voice.isActionable && !behaviour.isActionable {
            return behaviour.confidence >= voice.confidence ? behaviour : voice
        }
        if !voice.isActionable { return behaviour }
        if !behaviour.isActionable { return voice }

        // They agree — that's the strongest reading Ace ever gets.
        if voice.mood == behaviour.mood {
            return MoodReading(
                mood: voice.mood,
                confidence: min(0.95, max(voice.confidence, behaviour.confidence) + 0.2),
                rationale: "\(behaviour.rationale) + \(voice.rationale)"
            )
        }

        // They disagree. Prefer the gentler read: acting gently on a student who
        // was fine costs nothing, and the reverse costs a lot.
        if voice.mood.wantsGentleness != behaviour.mood.wantsGentleness {
            let gentle = voice.mood.wantsGentleness ? voice : behaviour
            return MoodReading(
                mood: gentle.mood,
                confidence: max(0.45, gentle.confidence * 0.9),
                rationale: "\(gentle.rationale) (mixed signals — erring gentle)"
            )
        }

        return behaviour.confidence >= voice.confidence ? behaviour : voice
    }
}
